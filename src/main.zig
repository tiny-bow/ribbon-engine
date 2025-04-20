const std = @import("std");
const log = std.log.scoped(.main);
const G = @import("framework");

pub const std_options = std.Options{
    .log_level = .info,
};


pub fn main() !void {
    log.info("main start", .{});

    const stderr_writer = std.io.getStdErr().writer();

    var heap = G.Heap{};

    var api = G.HostApi{
        .log = stderr_writer.any(),
        .allocator = .fromHeap(&heap),
        .heap = &heap,
    };

    var mod = G.Module.open(&api, .borrowed("zig-out/lib/libproto1.so"), .{}) catch |err| {
        log.err("failed to open module: {}", .{err});
        return err;
    };
    defer mod.close();
    defer mod.stop() catch |err| {
        log.err("failed to stop module: {}", .{err});
    };

    const watcher = try G.Module.watch(&api);
    defer {
        log.info("end of main body", .{});
        watcher.stop();
    }

    while (!api.shutdown.load(.unordered)) {
        G.ModuleWatcher.mutex.lock();

        mod.step() catch |err| {
            log.err("failed to step module: {}; sleeping main thread 10s", .{err});
            G.ModuleWatcher.mutex.unlock();
            std.Thread.sleep(10 * std.time.ns_per_s);
        };

        G.ModuleWatcher.mutex.unlock();
    }
}
