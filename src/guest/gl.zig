const G = @import("framework");
const std = @import("std");
const log = std.log.scoped(.example_module);

pub const std_options = std.Options{
    .log_level = .info,
    .logFn = struct {
        pub fn log(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
            const level_txt = comptime message_level.asText();
            const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

            g.host.log.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
        }
    }.log,
};

pub export var api = G.Module {
    .on_start = module_start,
    .on_step = module_step,
    .on_stop = module_stop,
};

const g = &api;

export fn module_start() callconv(.c) G.Signal {
    // Start the module
    // This is where you would start any threads or processes that the module needs to run, set up any necessary state or resources, etc.
    

    log.info("gl started", .{});
    return .okay;
}

export fn module_step() callconv(.c) G.Signal {
    // Step the module
    // This is the per-frame callback function for the module-level logic.
    // log.info("steppy", .{});

    return .okay;
}

export fn module_stop() callconv(.c) G.Signal {
    // Stop the module
    // This is where you would clean up any resources or threads that the module has created.
    // log.info("example stopped", .{});

    return .okay;
}
