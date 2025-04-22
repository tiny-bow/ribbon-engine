const G = @import("HostApi");
const std = @import("std");
const log = std.log.scoped(.gl2);

pub export var api = G.Module.fromNamespace(@This());

pub const std_options = std.Options{
    .log_level = .info,
    .logFn = struct {
        pub fn log(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
            api.host.log.message(message_level, scope, format, args);
        }
    }.log,
};

var self: struct {
    draw: *const fn () callconv(.c) G.Signal,
} = undefined;

var g: *G = undefined;
pub fn on_start() !void {
    log.info("gl2 starting...", .{});
    log.info("api.host: {x}", .{@intFromPtr(api.host)});

    g = api.host;

    log.info("g: {x}", .{@intFromPtr(g)});

    const gl1 = try g.module.lookupModule("gl1");

    self.draw = @alignCast(@ptrCast(try g.module.lookupAddress(gl1, "draw")));

    log.info("self.draw: {x}", .{@intFromPtr(self.draw)});
}

pub fn on_step() !void {
    switch (self.draw()) {
        .okay => {},
        .panic => return error.DrawCallFailed,
    }
}