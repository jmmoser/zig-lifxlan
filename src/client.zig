const std = @import("std");
const types = @import("types.zig");
const constants = @import("constants.zig");
const encoding = @import("encoding.zig");
const Router = @import("router.zig");
const Device = @import("device.zig");
const commands = @import("commands.zig");

const Client = @This();

const ResponseKey = [15]u8;

pub const ClientOptions = struct {
    router: *Router,
    defaultTimeoutMs: ?u32 = 3000,
    source: ?u32 = null,
    onMessage: ?types.MessageHandler = null,
};

config: struct {
    onMessage: ?types.MessageHandler = null,
},
router: *Router,
source: u32,
defaultTimeoutMs: u32,
responseHandlers: std.AutoHashMap(ResponseKey, ResponseHandler),
allocator: std.mem.Allocator,

fn getResponseKey(serialNumber: [12]u8, sequence: u8) !ResponseKey {
    var key: ResponseKey = undefined;
    _ = try std.fmt.bufPrint(&key, "{s}{d}", .{ serialNumber, sequence });
    return key;
}

test "get response key" {
    const key = try getResponseKey(constants.NO_SERIAL_NUMBER, 255);
    try std.testing.expect(std.mem.eql(u8, &key, "000000000000255"));
}

fn incrementSequence(sequence: ?u8) u8 {
    if (sequence) |seq| {
        return (seq + 1) % 0xFF;
    }
    return 0;
}

pub const ResponseHandler = struct {
    handler: *const fn (context: *anyopaque, typ: u16, bytes: []const u8, offsetRef: *encoding.OffsetRef) void,
    context: *anyopaque,
};

pub fn init(allocator: std.mem.Allocator, options: ClientOptions) !Client {
    return .{
        .config = .{
            .onMessage = options.onMessage,
        },
        .router = options.router,
        .source = options.source orelse try options.router.nextSource(),
        .defaultTimeoutMs = options.defaultTimeoutMs orelse 3000,
        .responseHandlers = std.AutoHashMap(ResponseKey, ResponseHandler).init(allocator),
        .allocator = allocator,
    };
}

pub fn deinit(self: *Client) void {
    self.responseHandlers.deinit();
}

pub fn broadcast(self: *Client, command: commands.Command) !void {
    var buffer: [1024]u8 = undefined;

    const message = encoding.encode(
        &buffer,
        true,
        self.source,
        constants.NO_TARGET,
        false,
        false,
        0xFF,
        command.type,
        command.payload,
    );

    try self.router.send(message, constants.PORT, constants.BROADCAST, null);
}

pub fn unicast(self: *Client, command: commands.Command, device: Device) !void {
    var buffer: [1024]u8 = undefined;

    const message = encoding.encode(
        &buffer,
        false,
        self.source,
        &device.target,
        false,
        false,
        device.sequence,
        command.type,
        command.payload,
    );

    self.router.send(message, device.port, device.address, device.serialNumber);
    device.sequence = incrementSequence(device.sequence);
}

pub fn sendOnlyAcknowledgement(self: *Client, command: commands.Command, device: Device) !void {
    var buffer: [1024]u8 = undefined;

    const message = encoding.encode(
        &buffer,
        false,
        self.source,
        &device.target,
        false,
        true,
        device.sequence,
        command.type,
        command.payload,
    );

    // const key = try getResponseKey(device.serialNumber, device.sequence);
    // try self.registerAckHandler(key);

    device.sequence = incrementSequence(device.sequence);
    self.router.send(message, device.port, device.address, device.serialNumber);
}

pub fn send(self: *Client, command: commands.Command, device: *Device) !void {
    var buffer: [1024]u8 = undefined;

    const message = encoding.encode(
        &buffer,
        false,
        self.source,
        device.target,
        true,
        false,
        device.sequence,
        command.type,
        command.payload,
    );

    // const key = try getResponseKey(device.serialNumber, device.sequence);
    // try self.registerResponseHandler(key, command.decode);

    device.sequence = incrementSequence(device.sequence);
    try self.router.send(message, device.port, device.address, device.serialNumber);
}

pub fn onMessage(context: *anyopaque, header: types.Header, payload: []const u8, serialNumber: [12]u8) void {
    const self: *Client = @ptrCast(@alignCast(context));
    if (self.config.onMessage) |onMessageFn| {
        onMessageFn.onMessage(header, payload, serialNumber);
    }
    const key = getResponseKey(serialNumber, header.sequence) catch return;
    if (self.responseHandlers.get(key)) |handler| {
        var offsetRef = encoding.OffsetRef{ .current = 0 };

        handler.handler(handler.context, header.type, payload, &offsetRef);
        _ = self.responseHandlers.remove(key);
    }
}

fn registerAckHandler(self: *Client, key: [64]u8) !void {
    if (self.responseHandlers.contains(key)) {
        return error.HandlerConflict;
    }

    const handler = ResponseHandler{
        .handler = struct {
            fn handle(typ: u16, _: []const u8, _: *encoding.OffsetRef) void {
                if (typ == @intFromEnum(constants.CommandType.Acknowledgement)) {
                    // TODO: Handle acknowledgement
                }
            }
        }.handle,
    };

    try self.responseHandlers.put(key, handler);
}

fn registerResponseHandler(
    self: *Client,
    key: ResponseKey,
    decode: *const fn ([]const u8, *encoding.OffsetRef) anyerror!void,
) !void {
    if (self.responseHandlers.contains(key)) {
        return error.HandlerConflict;
    }

    const handler = ResponseHandler{
        .context = @constCast(@ptrCast(decode)),
        .handler = struct {
            fn handle(resCtx: *anyopaque, responseType: u16, bytes: []const u8, offsetRef: *encoding.OffsetRef) void {
                const decodeFn: commands.Decode = @ptrCast(@alignCast(resCtx));
                if (responseType == @intFromEnum(constants.CommandType.StateUnhandled)) {
                    const requestType = encoding.decodeStateUnhandled(bytes, offsetRef) catch return;
                    // Handle unhandled request
                    std.debug.print("Unhandled request: {}\n", .{requestType});
                    std.debug.assert(false);
                }
                _ = decodeFn(bytes, offsetRef) catch return; // Access decode via context
            }
        }.handle,
    };

    try self.responseHandlers.put(key, handler);
}
