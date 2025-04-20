const std = @import("std");
const log = std.log.scoped(.main);
const HostApi = @import("HostApi");

const Module = @import("Module");

pub const std_options = std.Options{
    .log_level = .info,
};


pub fn main() !void {
    log.info("main start", .{});

    const stderr_writer = std.io.getStdErr().writer();

    var heap = HostApi.Heap{};

    var api = HostApi{
        .log = stderr_writer.any(),
        .allocator = .fromHeap(&heap),
        .heap = &heap,
    };

    var mod = Module.open(&api, "zig-out/lib/libproto1.so") catch |err| {
        log.err("failed to open module: {}", .{err});
        return err;
    };
    defer mod.close();

    try mod.start();
    defer mod.stop() catch |err| {
        log.err("failed to stop module: {}", .{err});
    };

    const watch_thread = try std.Thread.spawn(.{}, module_watch, .{ &api, mod });
    defer {
        log.info("stopping watch thread ...", .{});
        api.shutdown.store(true, .unordered);
        watch_thread.join();
        log.info("watch thread stopped; goodbye =]", .{});
    }

    while (true) {
        try mod.step();
    }
}

fn module_watch(api: *const HostApi, module: *Module) void {
    while (!api.shutdown.load(.unordered)) {
        Module.mutex.lock();
        defer Module.mutex.unlock();

        if (module.isDirty()) {
            log.info("Module[{s}] is dirty", .{module.path});
        }

        std.Thread.sleep(5 * std.time.ns_per_s);
    }
}
