const std = @import("std");
const builtin = @import("builtin");
const rui = @import("rui");
const rlfw = @import("rlfw");
const rgl = @import("rgl");
const Application = @import("Application");

pub const Window = @This();
pub const Context = *Window;

const log = std.log.scoped(.rui_backend);

const max_events = 128;
const num_cursor_shapes = std.meta.fieldNames(rlfw.Cursor.Shape).len + std.meta.fieldNames(rlfw.Cursor.Shape.Resize).len;

// TODO Input.zig: move this union
pub const Event = union(enum) {
    key: Button(rlfw.Input.Key),
    mouse_button: Button(rlfw.Input.Mouse),
    mouse_position: @Vector(2, f64), // TODO: linear algebra module, V2d
    text_input: u21,
    scroll_delta: @Vector(2, f64), // TODO: linear algebra module, V2d
    drop_paths: []const []const u8,

    pub fn Button(comptime T: type) type {
        return struct {
            which: T,
            action: rlfw.Input.Action,
            modifier: rlfw.Input.Modifier,
        };
    }

    // TODO Input.zig: gamepads are not associated to windows like the inputs here
    // gamepad_button: struct {
    //     which: rlfw.Input.Gamepad.Button,
    //     action: rlfw.Input.Action,
    // },
    // axis_delta: struct {
    //     which: rlfw.Input.Gamepad.Axis,
    //     action: f64,
    // },
};

rlfw_window: rlfw.Window,
rui_window: *rui.Window = undefined,
cursor_last: rui.enums.Cursor = .arrow,
cursor_cache: [num_cursor_shapes]??rlfw.Cursor = .{null} ** num_cursor_shapes,
arena: std.mem.Allocator = undefined,
event_queue: [max_events]Event = undefined,
num_events_queued: usize = 0,

pub const InitOptions = struct {
    /// The application title to display
    title: [:0]const u8 = "Ribbon Engine",
    /// The initial size of the application window
    size: rlfw.Size = .{ .width = 1024, .height = 576 }, // small 16:9 window by default
    /// Set the minimum size of the window
    min_size: ?rlfw.Window.SizeOptional = null,
    /// Set the maximum size of the window
    max_size: ?rlfw.Window.SizeOptional = null,
    vsync: bool = false,
    /// content of a PNG image (or any other format stb_image can load)
    /// tip: use @embedFile
    icon: ?[]const u8 = null,
};

pub fn init(self: *Window, options: InitOptions) !void {
    const app = @as(*Application, @fieldParentPtr("window", self));

    self.* = .{
        .window = try rlfw.Window.init(
            options.size.width, options.size.height, options.title, null, null,
            .{
                .scale_to_monitor = false,
                .resizable = true,
                .context = .{
                    .version = .{
                        .major = 4,
                        .minor = 5,
                    },
                    .open_gl = .{ .profile = .core },
                    .debug = std.debug.runtime_safety,
                },
            }
        ),
    };

    self.rlfw_window.setUserPointer(self);

    self.rlfw_window.setFramebufferSizeCallback(struct {
        pub fn framebuffer_size_callback(w: rlfw.Window, size: rlfw.Size) void {
            _ = w;
            rgl.viewport(0, 0, size.width, size.height);
        }
    }.framebuffer_size_callback);

    self.rlfw_window.setCursorPosCallback(struct {
        pub fn cursor_pos_callback(w: rlfw.Window, pos: rlfw.Cursor.Position) void {
            const back: *Window = @alignCast(@ptrCast(w.getUserPointer()));
            std.debug.assert(back.num_events_queued < max_events);
            back.event_queue[back.num_events_queued] = Event{
                .mouse_position = @Vector(2, f64){ .x = pos.x, .y = pos.y },
            };
        }
    }.cursor_pos_callback);

    self.rlfw_window.setMouseButtonCallback(struct {
        pub fn mouse_button_callback(w: rlfw.Window, button: rlfw.Input.Mouse, action: rlfw.Input.Action, modifier: rlfw.Input.Modifier) void {
            const back: *Window = @alignCast(@ptrCast(w.getUserPointer()));
            std.debug.assert(back.num_events_queued < max_events);
            back.event_queue[back.num_events_queued] = Event{
                .mouse_button = .{
                    .which = button,
                    .action = action,
                    .modifier = modifier,
                },
            };
        }
    }.mouse_button_callback);

    self.rlfw_window.setScrollCallback(struct {
        pub fn scroll_callback(w: rlfw.Window, offset: rlfw.Cursor.Position) void {
            const back: *Window = @alignCast(@ptrCast(w.getUserPointer()));
            std.debug.assert(back.num_events_queued < max_events);
            back.event_queue[back.num_events_queued] = Event{
                .scroll_delta = .{ .x = offset.x, .y = offset.y },
            };
        }
    }.scroll_callback);

    self.rlfw_window.setKeyCallback(struct {
        pub fn key_callback(w: rlfw.Window, key: rlfw.Input.Key, action: rlfw.Input.Action, modifier: rlfw.Input.Modifier) void {
            const back: *Window = @alignCast(@ptrCast(w.getUserPointer()));
            std.debug.assert(back.num_events_queued < max_events);
            back.event_queue[back.num_events_queued] = Event{
                .key = Event.Button(rlfw.Input.Key){
                    .which = key,
                    .action = action,
                    .modifier = modifier,
                },
            };
        }
    }.key_callback);

    self.rlfw_window.setCharCallback(struct {
        pub fn text_input_callback(w: rlfw.Window, codepoint: u21) void {
            const back: *Window = @alignCast(@ptrCast(w.getUserPointer()));
            std.debug.assert(back.num_events_queued < max_events);
            back.event_queue[back.num_events_queued] = Event{
                .text_input = .{ .codepoint = codepoint },
            };
        }
    }.text_input_callback);

    self.rlfw_window.setDropCallback(struct {
        pub fn drop_callback(w: rlfw.Window, paths: []const []const u8) void {
            const back: *Window = @alignCast(@ptrCast(w.getUserPointer()));
            const application: *Application = @fieldParentPtr("window", back);
            std.debug.assert(back.num_events_queued < max_events);
            const owned_paths = application.api.allocator.collection.alloc([]const u8, paths.len) catch @panic("OOM in collection allocator");
            for (paths, 0..) |unowned_path, i| {
                const owned_path = application.api.allocator.collection.dupe(u8, unowned_path) catch @panic("OOM in collection allocator");
                owned_paths[i] = owned_path;
            }
            back.event_queue[back.num_events_queued] = Event{
                .drop_path = owned_paths,
            };
        }
    }.drop_callback);


    try rlfw.makeCurrentContext(self.rlfw_window);

    rgl.loadExtensions({}, struct {
        pub fn get_proc_address(_: void, symbol: [:0]const u8) ?rgl.binding.FunctionPointer {
            return rlfw.getProcAddress(symbol);
        }
    }.get_proc_address) catch |err| {
        std.debug.panic("Failed to initialize rgl: {}", .{err});
    };

    rgl.debugMessageCallback({}, struct {
        pub fn gl_debug_handler(source: rgl.DebugSource, msg_type: rgl.DebugMessageType, id: usize, severity: rgl.DebugSeverity, message: []const u8) void {
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

    log.info("vendor: {?s}", .{rgl.getString(.vendor)});
    log.info("renderer: {?s}", .{rgl.getString(.renderer)});
    log.info("version: {?s}", .{rgl.getString(.version)});
    log.info("shading language version: {?s}", .{rgl.getString(.shading_language_version)});
    log.info("glsl version: {?s}", .{rgl.getString(.shading_language_version)});
    log.info("extensions: {?s}", .{rgl.getString(.extensions)});

    const maj = rgl.getInteger(.major_version);
    const min = rgl.getInteger(.minor_version);
    log.info("{}.{}", .{maj, min});
    if (maj != 4 or min != 5) {
        log.warn("OpenGL version is {}.{} but 4.5 was requested", .{maj, min});
    }

    rgl.viewport(0, 0, options.size.w, options.size.h);

    try rlfw.swapInterval(if (options.vsync) 1 else 0);

    if (options.icon) |bytes| {
        self.setIconFromFileContent(bytes);
    }
    try self.rlfw_window.setSizeLimits(options.min_size, options.max_size);

    self.rui_window = try rui.Window.init(@src(), app.api.allocator.collection, self.backend(), .{});

    return self;
}

pub fn deinit(self: *Window) void {
    log.info("closing window {s} ...", .{self.rlfw_window.getTitle()});

    self.rui_window.deinit();
    self.rlfw_window.deinit();

    for (self.cursor_cache) |cursor_attempt| {
        if (cursor_attempt) |cursor_maybe| {
            if (cursor_maybe) |cur| {
                cur.deinit();
            }
        }
    }

    log.info("... window closed", .{self.rlfw_window.getTitle()});
}

pub fn setIconFromFileContent(self: *Window, file_content: []const u8) void {
    var icon_w: c_int = undefined;
    var icon_h: c_int = undefined;
    var channels_in_file: c_int = undefined;
    const data = rui.c.stbi_load_from_memory(file_content.ptr, @as(c_int, @intCast(file_content.len)), &icon_w, &icon_h, &channels_in_file, 4);
    if (data == null) {
        log.warn("when setting icon, stbi_load error: {s}", .{rui.c.stbi_failure_reason()});
        return;
    }
    defer rui.c.stbi_image_free(data);

    self.setIconFromABGR8888(data, icon_w, icon_h);
}

pub fn setIconFromABGR8888(self: *Window, data: [*]const u8, icon_w: c_int, icon_h: c_int) void {
    // rlfw expects RGBA
    var translated_data = self.arena.alloc(u8, icon_w * icon_h * 4) catch return;
    for (0..icon_w * icon_h) |i| {
        translated_data[i * 4 + 0] = data[i * 4 + 2];
        translated_data[i * 4 + 1] = data[i * 4 + 1];
        translated_data[i * 4 + 2] = data[i * 4 + 0];
        translated_data[i * 4 + 3] = data[i * 4 + 3];
    }
    self.setIconRGBA(translated_data, icon_w, icon_h);
}

pub fn setIconRGBA(self: *Window, data: [*]const u8, icon_w: c_int, icon_h: c_int) void {
    self.rlfw_window.setIcon(icon_w, icon_h, data) catch |err| {
        std.debug.warn("Failed to set window icon: {}", .{err});
    };
}

pub fn setCursor(self: *Window, cursor: rui.enums.Cursor) void {
    if (cursor == self.cursor_last) return;
    self.cursor_last = cursor;

    const index = @intFromEnum(cursor);

    const rlfw_cursor = if (self.cursor_cache[index]) |rlfw_cursor_maybe|
        (if (rlfw_cursor_maybe) |c| c else return) // already failed before, don't log
    else switch (cursor) {
        .arrow => try rlfw.Cursor.initStandard(rlfw.Cursor.Shape.arrow),
        .ibeam => try rlfw.Cursor.initStandard(rlfw.Cursor.Shape.ibeam),
        .wait, .wait_arrow => {
            log.err("wait and wait_arrow cursor nyi", .{});
            self.cursor_cache[index] = @as(?rlfw.Cursor, null);
            return;
        },
        // .wait => try rlfw.Cursor.initStandard(rlfw.Cursor.Shape.wait),
        // .wait_arrow => try rlfw.Cursor.initStandard(rlfw.Cursor.Shape.wait_arrow),
        .crosshair => try rlfw.Cursor.initStandard(rlfw.Cursor.Shape.crosshair),
        .arrow_nw_se => try rlfw.Cursor.initStandard(rlfw.Cursor.Shape.Resize.nwse),
        .arrow_ne_sw => try rlfw.Cursor.initStandard(rlfw.Cursor.Shape.Resize.nesw),
        .arrow_w_e => try rlfw.Cursor.initStandard(rlfw.Cursor.Shape.Resize.ew),
        .arrow_n_s => try rlfw.Cursor.initStandard(rlfw.Cursor.Shape.Resize.ns),
        .arrow_all => try rlfw.Cursor.initStandard(rlfw.Cursor.Shape.Resize.all),
        .bad => try rlfw.Cursor.initStandard(rlfw.Cursor.Shape.not_allowed),
        .hand => try rlfw.Cursor.initStandard(rlfw.Cursor.Shape.pointing_hand),
    };

    self.cursor_cache[index] = @as(?rlfw.Cursor, rlfw_cursor);

    self.rlfw_window.setCursor(rlfw_cursor);
}


pub fn hasEvent(self: *Window) bool {
    return self.num_events_queued > 0;
}

pub fn backend(self: *Window) rui.Backend {
    return rui.Backend.init(self, @This());
}

pub fn nanoTime(self: *Window) i128 {
    _ = self;
    return std.time.nanoTimestamp();
}

pub fn sleep(self: *Window, ns: u64) void {
    _ = self;
    std.time.sleep(ns);
}

pub fn begin(self: *Window, arena: std.mem.Allocator) void {
    self.arena = arena;
}

pub fn end(_: *Window) void {}

pub fn pixelSize(self: *Window) rui.Size {
    const rlfw_size = self.rlfw_window.getFramebufferSize();

    return rui.Size{
        .w = @floatFromInt(rlfw_size.width),
        .h = @floatFromInt(rlfw_size.height),
    };
}

pub fn windowSize(self: *Window) rui.Size {
    const rlfw_size = self.rlfw_window.getSize();

    return rui.Size{
        .w = @floatFromInt(rlfw_size.width),
        .h = @floatFromInt(rlfw_size.height),
    };
}

pub fn contentScale(_: *Window) f32 {
    return 1.0;
}

pub fn drawClippedTriangles(self: *Window, texture: ?rui.Texture, vertices: []const rui.Vertex, indices: []const u16, maybe_clip_rect: ?rui.Rect) void {
    if (maybe_clip_rect) |clip_rect| {
        // just calling getParameter here is quite slow (5-10 ms per frame according to chrome)
        //old_scissor = gl.getParameter(gl.SCISSOR_BOX);
        rgl.scissor(@intFromFloat(clip_rect.x), @intFromFloat(clip_rect.y), @intFromFloat(clip_rect.w), @intFromFloat(clip_rect.h));
    }

    rgl.bindBuffer(
        self.index_buffer,
        .element_array_buffer,
    );

    rgl.bufferData(
        .element_array_buffer,
        u16,
        indices,
        .static_draw,
    );

    rgl.bindBuffer(self.vertex_buffer, self.array_buffer);
    rgl.bufferData(
        .array_buffer,
        rui.Vertex,
        vertices,
        .static_draw,
    );

    var matrix = [1]f32{0} ** 16; // TODO linear algebra module, Matrix4
    matrix[0] = 2.0 / self.render_target_size[0];
    matrix[1] = 0.0;
    matrix[2] = 0.0;
    matrix[3] = 0.0;
    matrix[4] = 0.0;
    if (self.using_fb) {
        matrix[5] = 2.0 / self.render_target_size[1];
    } else {
        matrix[5] = -2.0 / self.render_target_size[1];
    }
    matrix[6] = 0.0;
    matrix[7] = 0.0;
    matrix[8] = 0.0;
    matrix[9] = 0.0;
    matrix[10] = 1.0;
    matrix[11] = 0.0;
    matrix[12] = -1.0;
    if (self.using_fb) {
        matrix[13] = -1.0;
    } else {
        matrix[13] = 1.0;
    }
    matrix[14] = 0.0;
    matrix[15] = 1.0;

    const offset_pos = @offsetOf(rui.Vertex, "pos");
    const offset_col = @offsetOf(rui.Vertex, "col");
    const offset_uv = @offsetOf(rui.Vertex, "uv");

    // vertex
    rgl.bindBuffer(rgl.ARRAY_BUFFER, self.vertex_buffer);
    rgl.vertexAttribPointer(
        self.program_info.attrib_locations.vertex_position,
        2, // num components
        rgl.FLOAT,
        false, // don't normalize
        @sizeOf(rui.Vertex), // stride
        offset_pos, // offset
    );
    rgl.enableVertexAttribArray(
        self.program_info.attrib_locations.vertex_position,
    );

    // color
    rgl.bindBuffer(rgl.ARRAY_BUFFER, self.vertex_buffer);
    rgl.vertexAttribPointer(
        self.program_info.attrib_locations.vertex_color,
        4, // num components
        rgl.UNSIGNED_BYTE,
        false, // don't normalize
        @sizeOf(rui.Vertex), // stride
        offset_col, // offset
    );
    rgl.enableVertexAttribArray(
        self.program_info.attrib_locations.vertex_color,
    );

    // texture
    rgl.bindBuffer(rgl.ARRAY_BUFFER, self.vertex_buffer);
    rgl.vertexAttribPointer(
        self.program_info.attrib_locations.texture_coord,
        2, // num components
        rgl.FLOAT,
        false, // don't normalize
        @sizeOf(rui.Vertex), // stride
        offset_uv, // offset
    );
    rgl.enableVertexAttribArray(
        self.program_info.attrib_locations.texture_coord,
    );

    // Tell WebGL to use our program when drawing
    rgl.useProgram(self.shader_program);

    // Set the shader uniforms
    rgl.uniformMatrix4fv(
        self.program_info.uniform_locations.matrix,
        false,
        matrix,
    );

    // if (texture_id != 0) {
    //     rgl.activeTexture(rgl.TEXTURE0);
    //     rgl.bindTexture(
    //         rgl.TEXTURE_2D,
    //         self.textures.get(texture_id)[0],
    //     );
    //     rgl.uniform1i(
    //         self.program_info.uniform_locations.use_tex,
    //         1,
    //     );
    // } else {
    //     rgl.bindTexture(rgl.TEXTURE_2D, null);
    //     rgl.uniform1i(
    //         self.program_info.uniform_locations.use_tex,
    //         0,
    //     );
    // }

    rgl.uniform1i(
        self.program_info.uniform_locations.u_sampler,
        0,
    );

    //console.log("drawElements " + texture_id);
    rgl.drawElements(
        .triangles,
        indices.length,
        .unsigned_short,
        0,
    );

    if (maybe_clip_rect != null) {
        rgl.scissor(
            0,
            0,
            self.render_target_size[0],
            self.render_target_size[1],
        );
    }
}

pub fn textureCreate(self: *Window, pixels: [*]u8, width: u32, height: u32, interpolation: rui.enums.TextureInterpolation) rui.Texture {
    return rui.Texture{ .ptr = _, .width = width, .height = height };
}

pub fn textureDestroy(self: *Window, texture: rui.Texture) void {

}

pub fn textureFromTarget(self: *Window, texture: rui.TextureTarget) rui.Texture {

}

pub fn textureCreateTarget(self: *Window, width: u32, height: u32, interpolation: rui.enums.TextureInterpolation) !rui.TextureTarget {
    return rui.TextureTarget{ .ptr = _, .width = width, .height = height };
}

pub fn textureReadTarget(self: *Window, texture: rui.TextureTarget, pixels_out: [*]u8) error{TextureRead}!void {

}

pub fn renderTarget(self: *Window, texture: ?rui.TextureTarget) void {

}



pub fn clipboardText(self: *Window) ![]const u8 {
    const str = rlfw.getClipboardString();
    return try self.arena.dupe(u8, str);
}

pub fn clipboardTextSet(_: *Window, text: []const u8) !void {
    if (text.len == 0) return;

    rlfw.setClipboardString(text);
}


pub fn openURL(self: *Window, url: []const u8) !void {
    if (comptime @import("builtin").os.tag != .linux) {
        log.warn("openURL({s}) nyi on this platform", .{url});
        return;
    } else {
        const res = std.process.Child.run(.{
            .allocator = self.arena,
            .argv = &.{ "xdg-open", url }
        }) catch |err| {
            log.warn("openURL({s}) failed: {}", .{url, err});
            return err;
        };

        switch (res.term) {
            .Exited => |exit_code| {
                if (exit_code != 0) {
                    log.err("openURL({s}) failed: {d}", .{url, exit_code});
                    log.info("xdg-open stdout: {s}", .{res.stdout});
                    log.err("xdg-open stderr: {s}", .{res.stderr});
                }
            },
            else => {
                log.err("openURL({s}) failed: term: {}", .{url, res.term});
                log.info("xdg-open stdout: {s}", .{res.stdout});
                log.err("xdg-open stderr: {s}", .{res.stderr});
            },
        }
    }
}

pub fn refresh(self: *Window) void {
    _ = self; // we do not draw this way
}
