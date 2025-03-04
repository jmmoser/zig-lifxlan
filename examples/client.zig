const std = @import("std");
const network = @import("network");
const ansi = @import("ansi-term");
const lifxlan = @import("lifxlan");

var gSock: *network.Socket = undefined;
var client: *lifxlan.Client = undefined;
const stdout = std.io.getStdOut().writer();

fn onSendFn(message: []const u8, port: u16, address: [4]u8, serialNumber: ?[12]u8) anyerror!void {
    _ = serialNumber;
    const addr = network.Address.IPv4.init(address[0], address[1], address[2], address[3]);
    const endpoint: network.EndPoint = .{ .address = network.Address{ .ipv4 = addr }, .port = port };
    _ = gSock.sendTo(endpoint, message) catch |err| {
        std.debug.print("Failed to send message to {any}: {any}\n", .{ endpoint, err });
    };
}

fn onDeviceAdded(device: *lifxlan.Device) void {
    // std.debug.print("Device added: {s}\n", .{device.serialNumber});

    client.send(lifxlan.commands.GetLabelCommand(), device) catch |err| {
        std.debug.print("Failed to send GetLabelCommand to device {s}: {any}\n", .{ device.serialNumber, err });
    };

    client.send(lifxlan.commands.GetColorCommand(), device) catch |err| {
        std.debug.print("Failed to send GetColorCommand to device {s}: {any}\n", .{ device.serialNumber, err });
    };
}

pub fn main() !void {
    try network.init();
    defer network.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sock = try network.Socket.create(.ipv4, .udp);
    defer sock.close();
    try sock.setBroadcast(true);

    gSock = &sock;

    var router = try lifxlan.Router.init(allocator, .{
        .handlers = null,
        .onSend = onSendFn,
    });
    defer router.deinit();

    var devices = lifxlan.Devices.init(allocator, .{
        .onAdded = onDeviceAdded,
    });
    defer devices.deinit();

    const ClientMessageHandler = struct {
        devices: *lifxlan.Devices,

        pub fn onMessage(self: *const @This(), header: lifxlan.types.Header, payload: []const u8, serialNumber: [12]u8) void {
            _ = self;

            switch (header.type) {
                @intFromEnum(lifxlan.constants.CommandType.StateService) => {
                    // const serviceType: constants.ServiceType = @enumFromInt(payload[0]);
                    // std.debug.print("Client received StateService message from {s}: {s}\n", .{
                    //     serialNumber,
                    //     @tagName(serviceType),
                    // });
                },
                @intFromEnum(lifxlan.constants.CommandType.StateLabel) => {
                    std.debug.print("Client received StateLabel message from {s}: {s}\n", .{
                        serialNumber,
                        payload,
                    });
                },
                @intFromEnum(lifxlan.constants.CommandType.LightState) => {
                    // if (self.devices.get(serialNumber)) |device| {
                    //     client.send(commands.GetColorCommand(), device) catch {};
                    // }

                    var offsetRef = lifxlan.encoding.OffsetRef{ .current = 0 };
                    const color = lifxlan.encoding.decodeLightState(payload, &offsetRef) catch {
                        return;
                    };

                    const rgb = lifxlan.utils.hsbToRgb(color.hue, color.saturation, color.brightness);

                    const sty: ansi.style.Style = .{ .foreground = .{ .RGB = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } } };
                    stdout.print("{s}: ", .{serialNumber}) catch {};
                    ansi.format.updateStyle(stdout, sty, null) catch {};
                    stdout.print("{s}\n", .{"███████████"}) catch {};
                    ansi.format.updateStyle(stdout, .{}, sty) catch {};

                    // std.debug.print("Client received LightState message from {s} with label '{s}': {any}\n", .{
                    //     serialNumber,
                    //     color.label,
                    //     color,
                    // });
                },
                else => {
                    std.debug.print("Client received unhandled message from {s}: {any}\n", .{
                        serialNumber,
                        header.type,
                    });
                },
            }
        }
    };

    var lifxClient = try lifxlan.Client.init(allocator, .{
        .router = &router,
        .onMessage = lifxlan.types.MessageHandler.init(&ClientMessageHandler{ .devices = &devices }),
    });
    defer client.deinit();

    client = &lifxClient;

    try router.register(client.source, .{
        .handler = lifxlan.Client.onMessage,
        .context = client,
    });
    defer router.deregister(client.source) catch {};

    const discover_thread = try std.Thread.spawn(.{}, discoverDevicesThread, .{});
    const getLightStatesThread = try std.Thread.spawn(.{}, getLightStates, .{&devices});

    const read_thread = try std.Thread.spawn(.{}, socketReader, .{
        &sock,
        &router,
        &devices,
    });
    read_thread.join();
    discover_thread.join();
    getLightStatesThread.join();
}

fn socketReader(sock: *network.Socket, router: *lifxlan.Router, devices: *lifxlan.Devices) !void {
    var buffer: [1024]u8 = undefined;
    while (true) {
        const recv_result = try sock.receiveFrom(&buffer);
        const result = try router.receive(buffer[0..recv_result.numberOfBytes]);
        _ = devices.register(result.serialNumber, recv_result.sender.port, recv_result.sender.address.ipv4.value, result.header.target) catch {};
    }
}

fn discoverDevicesThread() !void {
    while (true) {
        try client.broadcast(lifxlan.commands.GetServiceCommand());
        std.time.sleep(5 * 1000 * 1000 * 1000);
    }
}

fn getLightStates(devices: *lifxlan.Devices) void {
    while (true) {
        var value_iterator = devices.knownDevices.valueIterator();
        while (value_iterator.next()) |value| {
            client.send(lifxlan.commands.GetColorCommand(), value.*) catch |err| {
                std.debug.print("Error sending GetColorCommand: {any}\n", .{err});
            };
        }
        std.time.sleep(1 * 1000 * 1000 * 1000);
    }
}
