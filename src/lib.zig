const HostApi = @import("HostApi");
const std = @import("std");
const log = std.log.scoped(.example_module);

export var host: *const HostApi = undefined;

pub const std_options = std.Options{
    .log_level = .info,
    .logFn = struct {
        pub fn log(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
            const level_txt = comptime message_level.asText();
            const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

            host.log.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
        }
    }.log,
};

export fn module_start() callconv(.c) HostApi.Signal {
    // Start the module
    // This is where you would start any threads or processes that the module needs to run, set up any necessary state or resources, etc.
    log.info("example started", .{});

    return .okay;
}

export fn module_step() callconv(.c) HostApi.Signal {
    // Step the module
    // This is the per-frame callback function for the module-level logic.
    log.info("example step", .{});

    return .okay;
}

export fn module_stop() callconv(.c) HostApi.Signal {
    // Stop the module
    // This is where you would clean up any resources or threads that the module has created.
    log.info("example stopped", .{});

    return .okay;
}
