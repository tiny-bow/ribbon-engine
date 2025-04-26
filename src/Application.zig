const Application = @This();

const std = @import("std");
const app_log = std.log.scoped(.application);

const rlfw = @import("rlfw");
const rgl = @import("rgl");
const zimalloc = @import("zimalloc");

pub const assets = @import("assets");
pub const HostApi = @import("HostApi");
pub const HostApi_impl = @import("HostApi_impl");
const G = HostApi;

cwd: std.fs.Dir,
window: rlfw.Window,
watcher: assets.Watcher,
stderr_writer: std.fs.File.Writer,
collection_allocator: CollectionAllocator,

api: HostApi,


pub const CollectionAllocator = zimalloc.Allocator(.{});

/// * only call this function from the main thread
pub fn init() !*Application {
    try rlfw.init(.{});

    const width = 800;
    const height = 600;
    const self = try std.heap.page_allocator.create(Application);

    self.window = try rlfw.Window.init(width, height, "Triangle", null, null, .{
        .context = .{
            .version = .{
                .major = 4,
                .minor = 5,
            },
            .open_gl = .{ .profile = .core },
            .debug = true,
        },
    });

    self.window.setFramebufferSizeCallback(struct {
        pub fn framebuffer_size_callback(window: rlfw.Window, size: rlfw.Size) void {
            _ = window;
            rgl.viewport(0, 0, size.width, size.height);
        }
    }.framebuffer_size_callback);

    try rlfw.makeCurrentContext(self.window);

    rgl.loadExtensions({}, struct {
        pub fn get_proc_address(_: void, symbol: [:0]const u8) ?rgl.binding.FunctionPointer {
            return rlfw.getProcAddress(symbol);
        }
    }.get_proc_address) catch |err| {
        std.debug.panic("Failed to initialize rgl: {}", .{err});
    };

    rgl.debugMessageCallback(self, struct {
        pub fn gl_debug_handler(_: *Application, source: rgl.DebugSource, msg_type: rgl.DebugMessageType, id: usize, severity: rgl.DebugSeverity, message: []const u8) void {
            const logger = std.log.scoped(.gl);

            switch (msg_type) {
                .@"error" => {
                    logger.err("{s} {s} error #{}: {s}", .{@tagName(source), @tagName(severity), id, message});
                },
                .deprecated_behavior => {
                    logger.warn("{s} {s} deprecated behavior #{}: {s}", .{@tagName(source), @tagName(severity), id, message});
                },
                .undefined_behavior => {
                    logger.err("{s} {s} undefined behavior #{}: {s}", .{@tagName(source), @tagName(severity), id, message});
                },
                .portability => {
                    logger.info("{s} {s} portability #{}: {s}", .{@tagName(source), @tagName(severity), id, message});
                },
                .performance => {
                    logger.info("{s} {s} performance #{}: {s}", .{@tagName(source), @tagName(severity), id, message});
                },
                .other => {
                    logger.info("{s} {s} other #{}: {s}", .{@tagName(source), @tagName(severity), id, message});
                },
            }
        }
    }.gl_debug_handler);

    app_log.info("vendor: {?s}", .{rgl.getString(.vendor)});
    app_log.info("renderer: {?s}", .{rgl.getString(.renderer)});
    app_log.info("version: {?s}", .{rgl.getString(.version)});
    app_log.info("shading language version: {?s}", .{rgl.getString(.shading_language_version)});
    app_log.info("glsl version: {?s}", .{rgl.getString(.shading_language_version)});
    app_log.info("extensions: {?s}", .{rgl.getString(.extensions)});

    const maj = rgl.getInteger(.major_version);
    const min = rgl.getInteger(.minor_version);
    app_log.info("{}.{}", .{maj, min});
    if (maj != 4 or min != 5) {
        app_log.warn("OpenGL version is {}.{} but 4.5 was requested", .{maj, min});
    }

    // std.debug.assert(@as(?*const anyopaque, @ptrCast(rgl.binding.function_pointers.glCreateVertexArrays)) != null);

    rgl.viewport(0, 0, width, height);

    try rlfw.swapInterval(0);

    self.stderr_writer = std.io.getStdErr().writer();
    self.collection_allocator = try CollectionAllocator.init(std.heap.page_allocator);

    self.api.cwd = std.fs.cwd();
    self.api.reload = std.atomic.Value(G.ReloadType).init(.none);
    self.api.shutdown = std.atomic.Value(bool).init(false);

    self.api.heap.collection = G.CollectionAllocator {
        .backing_allocator = &self.collection_allocator,
        .vtable = &struct {
            pub const collection_vtable = G.CollectionAllocator.VTable {
                .allocator = allocator,
                .reset = reset_collection_allocator,
            };

            pub fn allocator(ca: *G.CollectionAllocator, out: *std.mem.Allocator) callconv(.c) void {
                const collection_allocator: *CollectionAllocator = @constCast(@alignCast(@ptrCast(ca.backing_allocator)));

                out.* = collection_allocator.allocator();
            }

            pub fn reset_collection_allocator(ca: *G.CollectionAllocator) callconv(.c) void {
                const collection_allocator: *CollectionAllocator = @constCast(@alignCast(@ptrCast(ca.backing_allocator)));

                collection_allocator.deinit();

                collection_allocator.* = CollectionAllocator.init(std.heap.page_allocator) catch @panic("OOM resetting collection");
            }
        }.collection_vtable,
    };
    self.api.heap.temp = .init(std.heap.page_allocator);
    self.api.heap.last_frame = .init(std.heap.page_allocator);
    self.api.heap.frame = .init(std.heap.page_allocator);
    self.api.heap.long_term = .init(std.heap.page_allocator);
    self.api.heap.static = .init(std.heap.page_allocator);

    self.api.allocator.collection = self.api.heap.collection.allocator();
    self.api.allocator.temp = self.api.heap.temp.allocator();
    self.api.allocator.last_frame = self.api.heap.last_frame.allocator();
    self.api.allocator.frame = self.api.heap.frame.allocator();
    self.api.allocator.long_term = self.api.heap.long_term.allocator();
    self.api.allocator.static = self.api.heap.static.allocator();

    inline for (comptime std.meta.declarations(HostApi_impl)) |lib_decl| {
        const lib = comptime @field(HostApi_impl, lib_decl.name);

        inline for (comptime std.meta.declarations(lib)) |decl| {
            const exp = comptime @field(lib, decl.name);

            @field(@field(self.api, lib_decl.name), "host_" ++ decl.name) = exp;
        }
    }

    // { FIXME
    //     assets.Watcher.mutex.lock();
    //     defer assets.Watcher.mutex.unlock();

    //     self.watcher = try assets.watch(&self.api);

    //     try assets.load_all(&self.api);
    // }

    return self;
}

/// * only call this function from the main thread
pub fn deinit(self: *Application) void {
    app_log.info("closing window ...", .{});
    self.window.deinit();

    // self.watcher.stop(); FIXME

    // assets.deinit(); FIXME

    app_log.info("de-initializing allocators ...", .{});

    self.collection_allocator.deinit();
    self.api.heap.temp.deinit();
    self.api.heap.last_frame.deinit();
    self.api.heap.frame.deinit();
    self.api.heap.long_term.deinit();
    self.api.heap.static.deinit();

    app_log.info("shutting down middleware ...", .{});

    rlfw.deinit();

    app_log.info("final cleanup ...", .{});

    std.heap.page_allocator.destroy(self);

    app_log.info("application closed; goodbye 💝", .{});
}

pub fn reload(self: *Application, rld: G.ReloadType) !void {
    if (rld == .hard) {
        self.api.heap.collection.reset();
        _ = self.api.heap.frame.reset(.retain_capacity);
        _ = self.api.heap.last_frame.reset(.retain_capacity);
        _ = self.api.heap.long_term.reset(.retain_capacity);
        _ = self.api.heap.temp.reset(.retain_capacity);

        try assets.reload(&self.api, .hard);
    } else {
        try assets.reload(&self.api, .soft);
    }
}

pub fn loop(self: *Application) void {
    const error_sleep_time = 10;

    loop: while (!self.window.shouldClose() and !self.api.shutdown.load(.unordered)) {
        @branchHint(.likely);

        const rld = self.api.reload.load(.acquire);
        if (rld != .none) {
            @branchHint(.cold);
            app_log.info("{s} reload requested", .{@tagName(rld)});

            // assets.Watcher.mutex.lock(); FIXME

            // self.reload(rld) catch |err| {
            //     @branchHint(.cold);
            //     app_log.err("failed to reload: {}; sleeping main thread {}s", .{err, error_sleep_time});
            //     self.api.reload.store(.hard, .release);
            //     assets.Watcher.mutex.unlock();
            //     std.Thread.sleep(error_sleep_time * std.time.ns_per_s);
            //     continue :loop;
            // };

            // self.api.reload.store(.none, .release);

            // assets.Watcher.mutex.unlock();

            continue :loop;
        }

        rlfw.pollEvents();

        // assets.Watcher.mutex.lock(); FIXME

        assets.stepBinaries() catch |err| {
            @branchHint(.cold);
            app_log.err("failed to step assets: {}; sleeping main thread {}s", .{err, error_sleep_time});
            // assets.Watcher.mutex.unlock();
            std.Thread.sleep(error_sleep_time * std.time.ns_per_s);
            continue :loop;
        };

        // assets.Watcher.mutex.unlock();

        rgl.flush(); // shouldn't be necessary, but is on my machine :P

        self.window.swapBuffers() catch {
            @branchHint(.cold);
            @panic("failed to swap window buffers");
        };
    }
}
