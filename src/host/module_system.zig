const std = @import("std");
const log = std.log.scoped(.module_system);
const HostApi = @import("HostApi");
const G = HostApi;
const zlfw = @import("zlfw");

pub var modules = std.StringArrayHashMap(*Module).init(std.heap.page_allocator);
pub var meta_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
pub var path_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

pub var module_dir_path = "./zig-out/lib/";

pub fn shutdown() void {
    for (modules.values()) |mod| mod.stop() catch |err| {
        log.err("failed to stop Module[{s}]: {}", .{mod.meta.path, err});
    };
    for (modules.values()) |mod| mod.close();
}

pub fn update() !void {
    for (modules.values()) |mod| {
        mod.step() catch |err| {
            log.err("failed to step Module[{s}]: {}", .{mod.meta.path, err});
            return err;
        };
    }
}

pub fn load_all(api: *HostApi) !void {
    const cwd = std.fs.cwd();
    var moduleDir = cwd.openDir(module_dir_path, .{ .iterate = true }) catch |err| {
        const cwd_path = cwd.realpathAlloc(api.allocator.temp, ".") catch { return err; };
        log.err("cannot open module directory [{s}] from [{s}]: {}", .{module_dir_path, cwd_path, err });
        return err;
    };
    defer moduleDir.close();

    var it = moduleDir.iterate();

    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            log.warn("skipping directory: {s}", .{entry.name});
            continue;
        }

        const path = try std.fs.path.join(api.allocator.temp, &.{module_dir_path, entry.name});

        _ = try Module.open(api, .borrowed(path), .{});
    }
}


pub const Module = extern struct {
    // these fields are set by the module; on_start must be set by the dyn lib's initializer
    on_start: *const fn () callconv(.c) G.Signal,
    on_stop: ?*const fn () callconv(.c) G.Signal = null,
    on_step: ?*const fn () callconv(.c) G.Signal = null,

    // these fields are set by the module system just before calling on_start
    host: *HostApi = undefined,
    meta: *Meta = undefined,

    pub fn open(api: *HostApi, modulePath: G.View(u8), options: struct {
        handle_existing: enum { cached, re_open, only_once } = .cached,
    }) !*Module {
        log.info("opening Module[{s}]", .{modulePath.toBorrowed()});

        if (modules.get(modulePath.toBorrowed())) |existing_module| {
            switch (options.handle_existing) {
                .cached => {
                    log.info("Module[{s}] already loaded, returning cached version", .{modulePath.toBorrowed()});
                    return existing_module;
                },
                .only_once => {
                    log.err("Module[{s}] already loaded, reload not allowed", .{modulePath.toBorrowed()});
                    return error.ModuleAlreadyLoaded;
                },
                .re_open => {
                    log.info("Module[{s}] already loaded, soft reloading", .{modulePath.toBorrowed()});
                    
                    existing_module.stop() catch |err| {
                        log.err("failed to stop Module[{s}]: {}", .{existing_module.meta.path, err});
                        return err;
                    };

                    existing_module.meta.dyn_lib.close();
                },
            }
        } else {
            log.info("Module[{s}] not yet loaded, loading", .{modulePath.toBorrowed()});
        }

        const path = try modulePath.toOwned(path_arena.allocator());
        errdefer path_arena.allocator().free(path);

        const stat = std.fs.cwd().statFile(path) catch |err| {
            log.err("failed to stat Module[{s}]: {}", .{ path, err });
            return err;
        };

        log.info("Module[{s}] stat: {}", .{path, stat});

        var dyn_lib = std.DynLib.open(path) catch |err| {
            log.err("failed to open Module[{s}]: {}", .{ path, err });
            return err;
        };
        errdefer dyn_lib.close();


        log.info("Module[{s}] dyn lib opened successfully", .{path});

        const mod = if (dyn_lib.lookup(*Module, "api")) |module_ptr| module_ptr else {
            log.err("failed to find [{s}].api", .{path});
            return error.MissingModuleEntryPoint;
        };

        log.info("Got Module[{s}] address: {x}", .{path, @intFromPtr(mod)});
        
        mod.host = api;
        mod.meta = try meta_arena.allocator().create(Meta);
        errdefer meta_arena.allocator().destroy(mod.meta);

        mod.meta.* = Meta {
            .dyn_lib = dyn_lib,
            .latest = stat.mtime,
            .path = path,
            .state = .init,
        };

        log.info("Wrote metadata for Module[{s}]", .{path});

        const signal = mod.on_start();

        log.info("Module[{s}] start callback returned: {s}", .{path, @tagName(signal)});

        switch (signal) {
            .okay => {
                log.info("Module[{s}] start callback set", .{path});
            },
            .panic => {
                log.err("Module[{s}] start callback failed", .{path});
                return error.StartModuleFailed;
            },
        }

        mod.meta.state = .started;

        try modules.put(path, mod);
        log.info("Module[{s}] added to cache", .{path});

        return mod;
    }

    pub fn isDirty(self: *Module) bool {
        const stat = std.fs.cwd().statFile(self.meta.path) catch |err| {
            log.err("failed to stat Module[{s}]: {}", .{ self.meta.path, err });
            return false;
        };

        if (stat.mtime != self.meta.latest) {
            log.info("Module[{s}] is dirty", .{self.meta.path});
            return true;
        }

        return false;
    }

    pub fn close(self: *Module) void {
        if (self.meta.state == .started and self.on_stop != null) {
            log.err("Module[{s}] not stopped at close; good luck memory usage 🤞 ...", .{self.meta.path});
        }

        _ = modules.orderedRemove(self.meta.path);
        // arena only frees the top, so this is best effort;
        // however the modules should get unloaded in reverse order so...? maybe? doesnt hurt.
        path_arena.allocator().free(self.meta.path);
        self.meta.dyn_lib.close();
    }

    pub fn lookup(self: *Module, comptime T: type, name: []const u8) error{MissingSymbol}!*T {
        return self.meta.dyn_lib.lookup(*T, name) orelse {
            log.err("failed to find Module[{s}].{s}", .{ self.meta.path, name });
            return error.MissingSymbol;
        };
    }

    pub fn step(self: *Module) error{ InvalidModuleStateTransition, StepModuleFailed }!void {
        const callback = if (self.on_step) |step_callback| step_callback else return;

        if (self.meta.state != .started) {
            log.err("cannot step Module[{s}], it has not been started", .{self.meta.path});

            return error.InvalidModuleStateTransition;
        }

        switch (callback()) {
            .okay => {
                log.debug("Module[{s}] step successful", .{self.meta.path});
            },
            .panic => {
                log.err("Module[{s}] step failed", .{self.meta.path});
                return error.StepModuleFailed;
            },
        }
    }

    pub fn stop(self: *Module) error{ InvalidModuleStateTransition, StopModuleFailed }!void {
        const callback = if (self.on_stop) |stop_callback| stop_callback else return;

        if (self.meta.state != .started) {
            return error.InvalidModuleStateTransition;
        }

        switch (callback()) {
            .okay => {
                log.info("Module[{s}] stopped successfully", .{self.meta.path});
            },
            .panic => {
                log.err("Module[{s}] stop failed", .{self.meta.path});
                return error.StopModuleFailed;
            },
        }

        self.meta.state = .stopped;
    }

};

pub const watch = Watcher.watch;

pub const Meta = struct {
    dyn_lib: std.DynLib = undefined,
    latest: i128 = undefined,
    path: []const u8 = undefined,
    state: enum { uninit, init, started, stopped } = .uninit,
};

pub const Watcher = struct {
    api: *HostApi,
    thread: std.Thread,

    pub var mutex = std.Thread.Mutex{};

    pub var sleep_time: u64 = 5 * std.time.ns_per_s;
    pub var dirty_sleep_multiplier: u64 = 2;

    pub fn watch(api: *HostApi) !Watcher {
        const watch_thread = try std.Thread.spawn(.{.allocator = api.allocator.static}, struct {
            pub fn watcher(host: *HostApi) void {
                log.info("starting Module watcher ...", .{});

                while (!host.shutdown.load(.unordered)) {
                    log.info("module watcher run ...", .{});
                    var dirty = false;
                    {
                        mutex.lock();
                        defer mutex.unlock();

                        dirty_loop: for (modules.values()) |mod| {
                            if (mod.isDirty()) {
                                dirty = true;
                                break :dirty_loop;
                            }
                        }

                        if (dirty) {
                            log.info("Module(s) dirty, requesting reload ...", .{});
                            host.reload.store(.soft, .release);
                        } else {
                            log.info("Module(s) clean, no reload needed", .{});
                        }
                    }
                    
                    std.Thread.sleep(if (dirty) sleep_time * dirty_sleep_multiplier else sleep_time);
                }

                log.info("Module watcher stopping ...", .{});
            }
        }.watcher, .{ api });

        return Watcher{
            .api = api,
            .thread = watch_thread,
        };
    }

    pub fn stop(self: Watcher) void {
        log.info("stopping Watcher ...", .{});
        self.api.shutdown.store(true, .unordered);
        self.thread.join();
        log.info("Watcher stopped", .{});
    }
};