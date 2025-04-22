const std = @import("std");
const log = std.log.scoped(.module_system);
const builtin = @import("builtin");
const HostApi = @import("HostApi");
const G = HostApi;
const zlfw = @import("zlfw");
const zimalloc = @import("zimalloc");

pub var modules = std.StringArrayHashMap(*Module).init(std.heap.page_allocator);
pub var meta_heap = zimalloc.Allocator(.{}).init(std.heap.page_allocator) catch @panic("no memory?");
pub var name_heap = zimalloc.Allocator(.{}).init(std.heap.page_allocator) catch @panic("no memory?");

pub var module_dir_path = "./zig-out/lib/";
pub const dyn_lib_prefix = builtin.os.tag.libPrefix(builtin.abi);
pub const dyn_lib_suffix = builtin.os.tag.dynamicLibSuffix();

pub const ShutdownStyle = enum { soft, hard };

pub fn nameSanitize(name: []const u8) []const u8 {
    var trimmed = name;

    if (std.mem.startsWith(u8, trimmed, dyn_lib_prefix)) {
        trimmed = trimmed[dyn_lib_prefix.len..];
    }

    if (std.mem.endsWith(u8, trimmed, dyn_lib_suffix)) {
        trimmed = trimmed[0..trimmed.len - dyn_lib_suffix.len];
    }

    return name_heap.allocator().dupe(u8, trimmed) catch @panic("OOM in module name heap");
}

pub fn nameToPath(api: *HostApi, name: []const u8) []const u8 {
    const fileName = std.fmt.allocPrint(api.allocator.temp, "{s}{s}{s}", .{
        if (!std.mem.startsWith(u8, name, dyn_lib_prefix)) dyn_lib_prefix else "",
        name,
        if (!std.mem.endsWith(u8, name, dyn_lib_suffix)) dyn_lib_suffix else "",
    }) catch @panic("OOM in temp allocator");
    return std.fs.path.join(api.allocator.temp, &.{module_dir_path, fileName}) catch @panic("OOM in temp allocator");
}

pub const watch = Watcher.watch;

pub fn deinit() void {
    log.info("de-initializing module system ...", .{});
    shutdown(.soft) catch |err| {
        log.err("failed to shutdown module system: {}", .{err});
    };
    modules.deinit();
    meta_heap.deinit();
    name_heap.deinit();
    log.info("module system deinit complete", .{});
}

pub fn shutdown(style: ShutdownStyle) !void {
    log.info("module system shutting down {s} ...", .{@tagName(style)});
    const mods = modules.values();
    if (style != .hard) {
        for (0..mods.len) |i| {
            const j = mods.len - i - 1;
            log.info("stopping module {}/{}", .{j, mods.len});
            const mod = mods[j];
            mod.stop() catch |err| {
                log.err("failed to stop Module[{s}]: {}", .{mod.meta.name, err});
                return err;
            };
        }
    }
    log.info("closing all modules ...", .{});
    while (modules.count() > 0) {
        modules.values()[modules.count() - 1].close();
    }
    log.info("all modules closed", .{});
    modules.clearAndFree();
    log.info("module system shutdown complete", .{});
}

pub fn step() !void {
    for (modules.values()) |mod| {
        mod.step() catch |err| {
            log.err("failed to step Module[{s}]: {}", .{mod.meta.name, err});
            return err;
        };
    }
}

pub fn load_all(api: *HostApi) !void {
    log.info("opening modules ...", .{});

    const cwd = std.fs.cwd();
    var moduleDir = cwd.openDir(module_dir_path, .{ .iterate = true }) catch |err| {
        const cwd_path = cwd.realpathAlloc(api.allocator.temp, ".") catch { return err; };
        log.err("cannot open module directory [{s}] from cwd [{s}]: {}", .{module_dir_path, cwd_path, err });
        return err;
    };
    defer moduleDir.close();

    var it = moduleDir.iterate();

    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            log.warn("skipping directory: {s}", .{entry.name});
            continue;
        }

        try Module.open(api, entry.name);
    }

    log.info("all modules loaded: {s}", .{modules.keys()});

    for (modules.values()) |mod| {
        log.info("starting Module[{s}]", .{mod.meta.name});
        mod.start() catch |err| {
            log.err("failed to start Module[{s}]: {}", .{mod.meta.name, err});
            return err;
        };
    }

    log.info("all modules started", .{});
}

pub fn lookup(name: []const u8) error{ModuleNotFound}!*Module {
    return modules.get(name) orelse {
        log.err("Module[{s}] not found", .{name});
        return error.ModuleNotFound;
    };
}

pub fn reload(api: *HostApi, style: ShutdownStyle) !void {
    log.info("reloading module system ...", .{});

    const keys = api.allocator.temp.alloc([]const u8, modules.keys().len) catch @panic("OOM in temp allocator");

    for (modules.keys(), 0..) |mod_name, i| {
        keys[i] = api.allocator.temp.dupe(u8, mod_name) catch @panic("OOM in temp allocator");
    }

    log.info("copied loaded mod names", .{});

    try shutdown(style);

    for (keys) |mod_name| {
        try Module.open(api, mod_name);
    }

    for (keys) |mod_name| {
        log.info("restarting Module[{s}]", .{mod_name});

        const mod = lookup(mod_name) catch unreachable;

        try mod.start();
    }

    log.info("reloaded module system", .{});
}


pub const Meta = struct {
    dyn_lib: std.DynLib,
    latest: i128,
    name: []const u8,
    state: State,
    pub const State = enum { init, started, stopped };
};

pub const Module = extern struct {
    // these fields are set by the module; on_start must be set by the dyn lib's initializer
    on_start: *const fn () callconv(.c) G.Signal,
    on_stop: ?*const fn () callconv(.c) G.Signal = null,
    on_step: ?*const fn () callconv(.c) G.Signal = null,

    // fields following this line are set by the module system just before calling on_start

    host: *HostApi = undefined,

    // fields following this line are hidden from HostApi

    meta: *Meta = undefined,

    pub fn open(api: *HostApi, name: []const u8) !void {
        log.info("opening Module[{s}]", .{name});

        if (modules.contains(name)) {
            log.err("Module[{s}] already loaded", .{name});
            return error.ModuleAlreadyLoaded;
        }

        const moduleName = nameSanitize(name);

        const path = nameToPath(api, moduleName);

        const stat = std.fs.cwd().statFile(path) catch |err| {
            log.err("failed to stat Module @ [{s}]: {}", .{ path, err });
            return err;
        };

        log.info("[{s}] stat: {}", .{path, stat});

        var dyn_lib = std.DynLib.open(path) catch |err| {
            log.err("failed to open Module @ [{s}]: {}", .{ path, err });
            return err;
        };
        errdefer dyn_lib.close();


        log.info("Module[{s}] dyn lib opened successfully", .{moduleName});

        const mod = if (dyn_lib.lookup(*Module, "api")) |module_ptr| module_ptr else {
            log.err("failed to find Module[{s}].api", .{moduleName});
            return error.MissingModuleEntryPoint;
        };

        log.info("got Module[{s}].api address: {x}", .{moduleName, @intFromPtr(mod)});
        
        mod.host = api;
        mod.meta = meta_heap.allocator().create(Meta) catch @panic("OOM in module meta heap");
        errdefer meta_heap.allocator().destroy(mod.meta);

        mod.meta.* = Meta {
            .dyn_lib = dyn_lib,
            .latest = stat.mtime,
            .name = moduleName,
            .state = .init,
        };

        log.info("Wrote metadata for Module[{s}]", .{moduleName});

        modules.put(moduleName, mod) catch @panic("OOM in module cache");
        log.info("Module[{s}] added to cache", .{moduleName});
    }

    pub fn close(self: *Module) void {
        log.info("closing Module[{s}]", .{self.meta.name});

        if (self.meta.state == .started and self.on_stop != null) {
            log.err("Module[{s}] not stopped at close; good luck memory usage 🤞 ...", .{self.meta.name});
        }

        _ = modules.orderedRemove(self.meta.name);
        
        name_heap.allocator().free(self.meta.name);
        meta_heap.allocator().destroy(self.meta);

        self.meta.dyn_lib.close();

        log.info("Module closed", .{});
    }

    pub fn lookup(self: *Module, comptime T: type, name: [:0]const u8) error{MissingSymbol}!*T {
        return self.meta.dyn_lib.lookup(*T, name) orelse {
            log.err("failed to find Module[{s}].{s}", .{ self.meta.name, name });
            return error.MissingSymbol;
        };
    }

    pub fn isDirty(self: *Module) bool {
        const path = nameToPath(self.host, self.meta.name);

        const stat = std.fs.cwd().statFile(path) catch |err| {
            log.err("failed to stat Module @ [{s}]: {}", .{ path, err });
            return false;
        };

        if (stat.mtime != self.meta.latest) {
            log.info("Module[{s}] is dirty", .{self.meta.name});
            return true;
        }

        return false;
    }

    pub fn start(self: *Module) !void {
        log.info("starting Module[{s}]", .{self.meta.name});

        const signal = self.on_start();

        log.info("Module[{s}] start callback returned: {s}", .{self.meta.name, @tagName(signal)});

        switch (signal) {
            .okay => {
                self.meta.state = .started;
            },
            .panic => {
                return error.StartModuleFailed;
            },
        }
    }

    pub fn step(self: *Module) error{ InvalidModuleStateTransition, StepModuleFailed }!void {
        const callback = if (self.on_step) |step_callback| step_callback else return;

        if (self.meta.state != .started) {
            log.err("cannot step Module[{s}], it has not been started", .{self.meta.name});

            return error.InvalidModuleStateTransition;
        }

        switch (callback()) {
            .okay => {
                log.debug("Module[{s}] step successful", .{self.meta.name});
            },
            .panic => {
                log.err("Module[{s}] step failed", .{self.meta.name});
                return error.StepModuleFailed;
            },
        }
    }

    pub fn stop(self: *Module) error{ InvalidModuleStateTransition, StopModuleFailed }!void {
        log.info("stopping Module[{s}]", .{self.meta.name});

        if (self.meta.state != .started) {
            return error.InvalidModuleStateTransition;
        }

        if (self.on_stop) |stop_callback| {
            switch (stop_callback()) {
                .okay => {
                    log.info("Module[{s}] stopped successfully", .{self.meta.name});
                },
                .panic => {
                    log.err("Module[{s}] stop failed", .{self.meta.name});
                    return error.StopModuleFailed;
                },
            }
        } else {
            log.info("Module[{s}] has no stop callback", .{self.meta.name});
        }

        self.meta.state = .stopped;
    }
};

pub const Watcher = struct {
    api: *HostApi,
    thread: std.Thread,

    pub var mutex = std.Thread.Mutex{};

    pub var sleep_time: u64 = 1 * std.time.ns_per_s;
    pub var dirty_sleep_multiplier: u64 = 2;

    pub fn watch(api: *HostApi) !Watcher {
        const watch_thread = try std.Thread.spawn(.{}, struct {
            pub fn watcher(host: *HostApi) void {
                log.info("starting Module watcher ...", .{});

                while (!host.shutdown.load(.unordered)) {
                    log.debug("module watcher run ...", .{});
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
                            log.debug("Module(s) dirty, requesting reload ...", .{});
                            host.reload.store(.soft, .release);
                        } else {
                            log.debug("Module(s) clean, no reload needed", .{});
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
        self.api.shutdown.store(true, .release);
        self.thread.join();
        log.info("Watcher stopped", .{});
    }
};