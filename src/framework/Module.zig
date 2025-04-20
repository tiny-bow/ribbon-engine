const Module = @This();

const std = @import("std");
const log = std.log.scoped(.module_system);

const HostApi = @import("HostApi");

start_callback: ?*const fn () callconv(.c) HostApi.Signal,
step_callback: ?*const fn () callconv(.c) HostApi.Signal,
stop_callback: ?*const fn () callconv(.c) HostApi.Signal,

lib: std.DynLib,
latest: i128,
path: []const u8,
state: enum { init, started, stopped },

pub var mutex = std.Thread.Mutex{};

var modules = std.StringHashMap(*Module).init(std.heap.page_allocator);
var module_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
threadlocal var path_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

pub fn open(api: *const HostApi, modulePath: []const u8) !*Module {
    const path = try path_arena.allocator().dupe(u8, modulePath);
    errdefer path_arena.allocator().free(path);

    mutex.lock();
    defer mutex.unlock();

    if (modules.get(path)) |existing_module| {
        log.info("Module[{s}] already loaded", .{path});
        return existing_module;
    }

    log.info("opening Module[{s}]", .{path});

    const stat = std.fs.cwd().statFile(path) catch |err| {
        log.err("failed to stat Module[{s}]: {}", .{ path, err });
        return err;
    };

    var lib = std.DynLib.open(path) catch |err| {
        log.err("failed to open Module[{s}]: {}", .{ path, err });
        return err;
    };
    errdefer lib.close();

    if (lib.lookup(**const HostApi, "host")) |host_ptr| {
        host_ptr.* = api;
    } else {
        log.info("failed to find [{s}].host", .{path});
    }

    const mod = try module_arena.allocator().create(Module);
    errdefer module_arena.allocator().destroy(mod);

    mod.* = Module{
        .start_callback = lib.lookup(*const fn () callconv(.c) HostApi.Signal, "module_start") orelse not_found: {
            log.info("failed to find [{s}].module_start", .{path});
            break :not_found null;
        },
        .step_callback = lib.lookup(*const fn () callconv(.c) HostApi.Signal, "module_step") orelse not_found: {
            log.info("failed to find [{s}].module_step", .{path});
            break :not_found null;
        },
        .stop_callback = lib.lookup(*const fn () callconv(.c) HostApi.Signal, "module_stop") orelse not_found: {
            log.info("failed to find [{s}].module_stop", .{path});
            break :not_found null;
        },

        .lib = lib,
        .latest = stat.mtime,
        .path = path,
        .state = .init,
    };

    try modules.put(path, mod);

    return mod;
}

pub fn isDirty(self: *Module) bool {
    const stat = std.fs.cwd().statFile(self.path) catch |err| {
        log.err("failed to stat Module[{s}]: {}", .{ self.path, err });
        return false;
    };

    if (stat.mtime != self.latest) {
        log.info("Module[{s}] is dirty", .{self.path});
        return true;
    }

    return false;
}

pub fn close(self: *Module) void {
    if (self.state == .started and self.stop_callback != null) {
        log.err("Module[{s}] not stopped at close, good luck 🤞 ...", .{self.path});
    }

    path_arena.allocator().free(self.path);
    self.lib.close();
}

pub fn lookup(self: *Module, comptime T: type, name: []const u8) error{MissingSymbol}!*T {
    return self.lib.lookup(*T, name) orelse {
        log.err("failed to find [{s}].{s}", .{ self.path, name });
        return error.MissingSymbol;
    };
}

pub fn start(self: *Module) error{ InvalidModuleStateTransition, StartModuleFailed }!void {
    const callback = if (self.start_callback) |start_callback| start_callback else return;

    if (self.state != .init) {
        return error.InvalidModuleStateTransition;
    }

    switch (callback()) {
        .okay => {
            log.info("Module[{s}] started successfully", .{self.path});
        },
        .panic => {
            log.err("Module[{s}] start failed", .{self.path});
            return error.StartModuleFailed;
        },
    }

    self.state = .started;
}

pub fn step(self: *Module) error{ InvalidModuleStateTransition, StepModuleFailed }!void {
    const callback = if (self.step_callback) |step_callback| step_callback else return;

    if (self.state != .started) {
        if (self.state == .init and self.start_callback == null) {
            self.state = .started;
        } else {
            return error.InvalidModuleStateTransition;
        }
    }

    switch (callback()) {
        .okay => {
            log.debug("Module[{s}] step successful", .{self.path});
        },
        .panic => {
            log.err("Module[{s}] step failed", .{self.path});
            return error.StepModuleFailed;
        },
    }
}

pub fn stop(self: *Module) error{ InvalidModuleStateTransition, StopModuleFailed }!void {
    const callback = if (self.stop_callback) |stop_callback| stop_callback else return;

    if (self.state != .started) {
        return error.InvalidModuleStateTransition;
    }

    switch (callback()) {
        .okay => {
            log.info("Module[{s}] stopped successfully", .{self.path});
        },
        .panic => {
            log.err("Module[{s}] stop failed", .{self.path});
            return error.StopModuleFailed;
        },
    }

    self.state = .stopped;
}
