const Application = @This();

const std = @import("std");
const app_log = std.log.scoped(.application);

const rlfw = @import("rlfw");
const rgl = @import("rgl");
const rui = @import("rui");
const zimalloc = @import("zimalloc");

pub const Window = @import("Window");
pub const linalg = @import("linalg");
pub const surface = @import("surface");
pub const ecs = @import("ecs");
pub const assets = @import("assets");
pub const HostApi = @import("HostApi");
pub const HostApi_impl = @import("HostApi_impl");
const G = HostApi;

cwd: std.fs.Dir,
window: Window,
watcher: assets.Watcher,
stderr_writer: std.fs.File.Writer,
collection_allocator: CollectionAllocator,

api: HostApi,


pub const CollectionAllocator = zimalloc.Allocator(.{});

/// * only call this function from the main thread
pub fn init() !*Application {
    try rlfw.init(.{});

    const self = try std.heap.page_allocator.create(Application);

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


    try self.window.init(.{
        .size = .{ .width = 800, .height = 600 },
    });

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

pub fn loop(self: *Application) !void {
    // const error_sleep_time = 10;

    // var loading_window_open: bool = true;
    // var loading_window_rect: rui.Rect = .{ .x = 1, .y = 1, .w = 400, .h = 400 };

    var running_timer = std.time.Timer.start() catch unreachable;

    var frame_timer = std.time.Timer.start() catch unreachable;

    loop: while (!self.window.rlfw_window.shouldClose() and !self.api.shutdown.load(.unordered)) {
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

        _ = frame_timer.lap();
        _ = running_timer.read();

        try rlfw.makeCurrentContext(self.window.rlfw_window);
        rgl.clearColor(0.2, 0.3, 0.3, 1.0);
        rgl.clear(.{ .color = true, .depth = true, .stencil = true });

        try self.window.rui_window.begin(std.time.nanoTimestamp());

        // assets.Watcher.mutex.lock(); FIXME

        // assets.stepBinaries() catch |err| {
        //     @branchHint(.cold);
        //     app_log.err("failed to step assets: {}; sleeping main thread {}s", .{err, error_sleep_time});
        //     // assets.Watcher.mutex.unlock();
        //     std.Thread.sleep(error_sleep_time * std.time.ns_per_s);
        //     continue :loop;
        // };

        // assets.Watcher.mutex.unlock();

        {
            var float = try rui.floatingWindow(@src(), .{}, .{ .max_size_content = .{ .w = 400, .h = 400 } });
            defer float.deinit();

            try rui.windowHeader("Floating Window", "", null);

            var scroll = try rui.scrollArea(@src(), .{}, .{ .expand = .both, .color_fill = .{ .name = .fill_window } });
            defer scroll.deinit();

            var tl = try rui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font_style = .title_4 });
            const lorem = "This example shows how to use rui for floating windows on top of an existing application.";
            try tl.addText(lorem, .{});
            tl.deinit();
        }

        _ = try self.window.rui_window.end(.{
            .show_toasts = true,
        });

        if (self.window.rui_window.cursorRequestedFloating()) |cursor| {
            // cursor is over floating window, rui sets it
            self.window.setCursor(cursor);
        } else {
            // cursor should be handled by application
            self.window.setCursor(.arrow);
        }

        rgl.flush(); // shouldn't be necessary, but is on my machine :P

        try self.window.rlfw_window.swapBuffers();
    }
}
