const std = @import("std");
const builtin = @import("builtin");
const rui = @import("rui");
const rlfw = @import("rlfw");
const rgl = @import("rgl");
const Application = @import("Application");
const input = @import("input");
const linalg = @import("linalg");

pub const Window = @This();
pub const Context = *Window;

const log = std.log.scoped(.rui_backend);

const max_events = 128;
const num_cursor_shapes = std.meta.fieldNames(rlfw.Cursor.Shape).len + std.meta.fieldNames(rlfw.Cursor.Shape.Resize).len;

const vertex_shader_src =
    \\# version 450 core
    \\
    \\in vec4 aVertexPosition;
    \\in vec4 aVertexColor;
    \\in vec2 aTextureCoord;
    \\
    \\uniform mat4 uMatrix;
    \\
    \\out vec4 vColor;
    \\out vec2 vTextureCoord;
    \\
    \\void main() {
    \\  gl_Position = uMatrix * aVertexPosition;
    \\  vColor = aVertexColor / 255.0;  // normalize u8 colors to 0-1
    \\  vTextureCoord = aTextureCoord;
    \\}
    ;

const fragment_shader_src =
    \\# version 450 core
    \\
    \\in vec4 vColor;
    \\in vec2 vTextureCoord;
    \\
    \\uniform sampler2D uSampler;
    \\uniform bool useTex;
    \\
    \\out vec4 fragColor;
    \\
    \\void main() {
    \\    if (useTex) {
    \\        fragColor = texture(uSampler, vTextureCoord) * vColor;
    \\    }
    \\    else {
    \\        fragColor = vColor;
    \\    }
    \\}
    ;

// TODO Input.zig: move this union


rlfw_window: rlfw.Window,
rui_window: rui.Window = undefined,
cursor_last: rui.enums.Cursor = .arrow,
cursor_cache: [num_cursor_shapes]??rlfw.Cursor = .{null} ** num_cursor_shapes,
arena: std.mem.Allocator = undefined,
event_queue: [max_events]input.WindowEvent = undefined,
num_events_queued: usize = 0,
program_info: ProgramInfo = undefined,

pub const InitOptions = struct {
    /// The application title to display
    title: [:0]const u8 = "Ribbon Engine",
    /// The initial size of the application window
    size: struct {width: u32 = 1024, height: u32 = 576} = .{}, // small 16:9 window by default
    /// Set the minimum size of the window
    min_size: struct {width: ?u32 = null, height: ?u32 = null} = .{},
    /// Set the maximum size of the window
    max_size: struct {width: ?u32 = null, height: ?u32 = null} = .{},
    /// Control vertical blank synchronization
    vsync: bool = false,
    /// content of a PNG image (or any other format stb_image can load)
    /// tip: use @embedFile
    icon: ?[]const u8 = null,
};

pub const ProgramInfo = struct {
    using_fb: bool,
    framebuffer: rgl.Framebuffer,
    window_size: [2]u32,
    render_target_size: [2]u32,
    shader_program: rgl.Program,
    vertex_array: rgl.VertexArray,
    index_buffer: rgl.Buffer,
    vertex_buffer: rgl.Buffer,
    attrib_locations: struct {
        vertex_position: u32,
        vertex_color: u32,
        texture_coord: u32,
    },
    uniform_locations: struct {
        matrix: u32,
        use_tex: u32,
        u_sampler: u32,
    },
};

pub fn init(self: *Window, options: InitOptions) !void {
    const app = @as(*Application, @fieldParentPtr("window", self));

    self.* = .{
        .rlfw_window = try rlfw.Window.init(
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
            const a: *Window = @alignCast(@ptrCast(w.getUserPointer()));
            a.program_info.window_size = .{ size.width, size.height };
            rgl.viewport(0, 0, size.width, size.height);
        }
    }.framebuffer_size_callback);

    self.rlfw_window.setCursorPosCallback(struct {
        pub fn cursor_pos_callback(w: rlfw.Window, pos: rlfw.Cursor.Position) void {
            const back: *Window = @alignCast(@ptrCast(w.getUserPointer()));
            std.debug.assert(back.num_events_queued < max_events);
            back.event_queue[back.num_events_queued] = input.WindowEvent{
                .mouse_position = .{ pos.x, pos.y },
            };
        }
    }.cursor_pos_callback);

    self.rlfw_window.setMouseButtonCallback(struct {
        pub fn mouse_button_callback(w: rlfw.Window, button: rlfw.Input.Mouse, action: rlfw.Input.Action, modifier: rlfw.Input.Modifier) void {
            const back: *Window = @alignCast(@ptrCast(w.getUserPointer()));
            std.debug.assert(back.num_events_queued < max_events);
            back.event_queue[back.num_events_queued] = input.WindowEvent{
                .mouse_button = .{
                    .which = @enumFromInt(@intFromEnum(button)),
                    .action = @enumFromInt(@intFromEnum(action)),
                    .modifiers = @bitCast(modifier),
                },
            };
        }
    }.mouse_button_callback);

    self.rlfw_window.setScrollCallback(struct {
        pub fn scroll_callback(w: rlfw.Window, offset: rlfw.Cursor.Position) void {
            const back: *Window = @alignCast(@ptrCast(w.getUserPointer()));
            std.debug.assert(back.num_events_queued < max_events);
            back.event_queue[back.num_events_queued] = input.WindowEvent{
                .scroll_delta = .{ offset.x, offset.y },
            };
        }
    }.scroll_callback);

    self.rlfw_window.setKeyCallback(struct {
        pub fn key_callback(w: rlfw.Window, key: rlfw.Input.Key, scan_code: i32, action: rlfw.Input.Action, modifier: rlfw.Input.Modifier) void {
            _ = scan_code;

            const back: *Window = @alignCast(@ptrCast(w.getUserPointer()));
            std.debug.assert(back.num_events_queued < max_events);
            back.event_queue[back.num_events_queued] = input.WindowEvent{
                .key = input.KeyEvent {
                    .which = @enumFromInt(@intFromEnum(key)),
                    .action = @enumFromInt(@intFromEnum(action)),
                    .modifiers = @bitCast(modifier),
                },
            };
        }
    }.key_callback);

    self.rlfw_window.setCharCallback(struct {
        pub fn text_input_callback(w: rlfw.Window, codepoint: u21) void {
            const back: *Window = @alignCast(@ptrCast(w.getUserPointer()));
            std.debug.assert(back.num_events_queued < max_events);
            back.event_queue[back.num_events_queued] = input.WindowEvent{
                .text_input = codepoint,
            };
        }
    }.text_input_callback);

    self.rlfw_window.setDropCallback(struct {
        pub fn drop_callback(w: rlfw.Window, paths: []const [*:0]const u8) void {
            const back: *Window = @alignCast(@ptrCast(w.getUserPointer()));
            const application: *Application = @fieldParentPtr("window", back);
            std.debug.assert(back.num_events_queued < max_events);
            const owned_paths = application.api.allocator.collection.alloc([]const u8, paths.len) catch @panic("OOM in collection allocator");
            for (paths, 0..) |unowned_path, i| {
                const owned_path = application.api.allocator.collection.dupe(u8, std.mem.span(unowned_path)) catch @panic("OOM in collection allocator");
                owned_paths[i] = owned_path;
            }
            back.event_queue[back.num_events_queued] = input.WindowEvent{
                .drop_paths = owned_paths,
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

    rgl.viewport(0, 0, options.size.width, options.size.height);

    try rlfw.swapInterval(if (options.vsync) 1 else 0);

    if (options.icon) |bytes| {
        self.setIconFromFileContent(bytes);
    }
    try self.rlfw_window.setSizeLimits(
        .{ .width = options.min_size.width, .height = options.min_size.height },
        .{ .width = options.max_size.width, .height = options.max_size.height },
    );

    self.program_info.window_size = .{ options.size.width, options.size.height };
    self.program_info.render_target_size = self.program_info.window_size;

    self.program_info.using_fb = false;
    self.program_info.framebuffer = rgl.genFramebuffer();

    const vertexShader = rgl.createShader(.vertex);
    defer rgl.deleteShader(vertexShader);

    rgl.shaderSource(vertexShader, 1, &.{vertex_shader_src});
    rgl.compileShader(vertexShader);
    if (rgl.getShader(vertexShader, .compile_status) == 0) {
        const info = rgl.getShaderInfoLog(vertexShader, app.api.allocator.temp) catch @panic("OOM in temp allocator");
        log.err("Error compiling rui vertex shader:\n{s}", .{info});
        unreachable;
    }

    const fragmentShader = rgl.createShader(.fragment);
    defer rgl.deleteShader(fragmentShader);

    rgl.shaderSource(fragmentShader, 1, &.{fragment_shader_src});
    rgl.compileShader(fragmentShader);
    if (rgl.getShader(fragmentShader, .compile_status) == 0) {
        const info = rgl.getShaderInfoLog(vertexShader, app.api.allocator.temp) catch @panic("OOM in temp allocator");
        log.err("Error compiling rui fragment shader:\n{s}", .{info});
        unreachable;
    }

    self.program_info.shader_program = rgl.createProgram();
    rgl.attachShader(self.program_info.shader_program, vertexShader);
    rgl.attachShader(self.program_info.shader_program, fragmentShader);
    rgl.linkProgram(self.program_info.shader_program);

    if (rgl.getProgram(self.program_info.shader_program, .link_status) == 0) {
        const info = rgl.getProgramInfoLog(self.program_info.shader_program, app.api.allocator.temp) catch @panic("OOM in temp allocator");
        log.err("Error linking rui program:\n{s}", .{info});
        unreachable;
    }

    self.program_info.attrib_locations = .{
        .vertex_position = rgl.getAttribLocation(
            self.program_info.shader_program,
            "aVertexPosition",
        ).?,
        .vertex_color = rgl.getAttribLocation(
            self.program_info.shader_program,
            "aVertexColor",
        ).?,
        .texture_coord = rgl.getAttribLocation(
            self.program_info.shader_program,
            "aTextureCoord",
        ).?,
    };
    self.program_info.uniform_locations = .{
        .matrix = rgl.getUniformLocation(
            self.program_info.shader_program,
            "uMatrix",
        ).?,
        .u_sampler = rgl.getUniformLocation(
            self.program_info.shader_program,
            "uSampler",
        ).?,
        .use_tex = rgl.getUniformLocation(
            self.program_info.shader_program,
            "useTex",
        ).?,
    };


    self.program_info.vertex_array = rgl.genVertexArray();

    // 2. Bind VAO
    rgl.bindVertexArray(self.program_info.vertex_array); // <<< BIND VAO FIRST

    // 3. Generate Buffers
    self.program_info.index_buffer = rgl.genBuffer();
    self.program_info.vertex_buffer = rgl.genBuffer(); // <<< GENERATE BUFFERS

    // 4. Bind VBO
    rgl.bindBuffer(self.program_info.vertex_buffer, .array_buffer); // <<< BIND VBO

    // 5. Setup ALL Vertex Attributes (while VAO and VBO are bound)
    const offset_pos = @offsetOf(rui.Vertex, "pos");
    const offset_col = @offsetOf(rui.Vertex, "col");
    const offset_uv = @offsetOf(rui.Vertex, "uv");

    // Position Attribute
    rgl.vertexAttribPointer(
        self.program_info.attrib_locations.vertex_position,
        2, // num components
        .float,
        false, // don't normalize
        @sizeOf(rui.Vertex), // stride
        offset_pos, // offset
    );
    rgl.enableVertexAttribArray(
        self.program_info.attrib_locations.vertex_position,
    );

    // Color Attribute
    rgl.vertexAttribPointer(
        self.program_info.attrib_locations.vertex_color,
        4, // num components
        .unsigned_byte,
        false, // don't normalize (will be normalized in shader)
        @sizeOf(rui.Vertex), // stride
        offset_col, // offset
    );
    rgl.enableVertexAttribArray(self.program_info.attrib_locations.vertex_color);

    // Texture Coordinate Attribute
    rgl.vertexAttribPointer(
        self.program_info.attrib_locations.texture_coord,
        2, // num components
        .float,
        false, // don't normalize
        @sizeOf(rui.Vertex), // stride
        offset_uv, // offset
    );
    rgl.enableVertexAttribArray(
        self.program_info.attrib_locations.texture_coord,
    );

    // 6. Bind IBO (associates it with the current VAO)
    rgl.bindBuffer(self.program_info.index_buffer, .element_array_buffer);

    // 7. Unbind VAO (and implicitly the IBO binding for this VAO)
    // VBO binding (.array_buffer) is global, not part of VAO state, so unbind separately if desired.
    rgl.bindVertexArray(.invalid);
    rgl.bindBuffer(.invalid, .array_buffer); // Optional, but clean

    self.rui_window = try rui.Window.init(@src(), app.api.allocator.collection, self.backend(), .{});
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

    log.info("... window {s} closed", .{self.rlfw_window.getTitle()});
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

    self.setIconFromABGR8888(data, @intCast(icon_w), @intCast(icon_h));
}

pub fn setIconFromABGR8888(self: *Window, data: [*]const u8, icon_w: usize, icon_h: usize) void {
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

pub fn setIconRGBA(self: *Window, data: []const u8, icon_w: usize, icon_h: usize) void {
    self.rlfw_window.setIcon(&.{ .{ .width = @intCast(icon_w), .height = @intCast(icon_h), .pixels = @constCast(data.ptr) } }) catch |err| {
        log.warn("Failed to set window icon: {}", .{err});
    };
}

pub fn setCursor(self: *Window, cursor: rui.enums.Cursor) void {
    if (cursor == self.cursor_last) return;
    self.cursor_last = cursor;

    const index = @intFromEnum(cursor);

    const rlfw_cursor = if (self.cursor_cache[index]) |rlfw_cursor_maybe|
        (if (rlfw_cursor_maybe) |c| c else return) // already failed before, don't log
    else switch (cursor) {
        .arrow => rlfw.Cursor.initStandard(rlfw.Cursor.Shape.arrow),
        .ibeam => rlfw.Cursor.initStandard(rlfw.Cursor.Shape.ibeam),
        .wait, .wait_arrow => error.NotYetImplemented, // TODO implement wait cursors
        // .wait => rlfw.Cursor.initStandard(rlfw.Cursor.Shape.wait),
        // .wait_arrow => rlfw.Cursor.initStandard(rlfw.Cursor.Shape.wait_arrow),
        .crosshair => rlfw.Cursor.initStandard(rlfw.Cursor.Shape.crosshair) ,
        .arrow_nw_se => rlfw.Cursor.initStandard(rlfw.Cursor.Shape.Resize.nwse) ,
        .arrow_ne_sw => rlfw.Cursor.initStandard(rlfw.Cursor.Shape.Resize.nesw) ,
        .arrow_w_e => rlfw.Cursor.initStandard(rlfw.Cursor.Shape.Resize.ew) ,
        .arrow_n_s => rlfw.Cursor.initStandard(rlfw.Cursor.Shape.Resize.ns) ,
        .arrow_all => rlfw.Cursor.initStandard(rlfw.Cursor.Shape.Resize.all) ,
        .bad => rlfw.Cursor.initStandard(rlfw.Cursor.Shape.not_allowed) ,
        .hand => rlfw.Cursor.initStandard(rlfw.Cursor.Shape.pointing_hand) ,
    } catch |err| {
        log.warn("Failed to create cursor {s}: {}", .{@tagName(cursor), err});
        self.cursor_cache[index] = @as(?rlfw.Cursor, null);
        return;
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
    rgl.disable(.depth_test);
    rgl.disable(.cull_face);
    rgl.disable(.stencil_test);

    rgl.enable(.blend);
    rgl.blendFunc(.src_alpha, .one_minus_src_alpha);

    if (maybe_clip_rect) |clip_rect| {
        rgl.enable(.scissor_test);
        rgl.scissor(@intFromFloat(clip_rect.x), @intFromFloat(clip_rect.y), @intFromFloat(clip_rect.w), @intFromFloat(clip_rect.h));
    } else {
        rgl.disable(.scissor_test);
    }

    defer {
        if (maybe_clip_rect != null) {
            rgl.disable(.scissor_test);
        }

        rgl.disable(.blend);
    }

    rgl.bindBuffer(
        self.program_info.index_buffer,
        .element_array_buffer,
    );

    rgl.bufferData(
        .element_array_buffer,
        u16,
        indices,
        .dynamic_draw,
    );

    rgl.bindBuffer(self.program_info.vertex_buffer, .array_buffer);
    rgl.bufferData(
        .array_buffer,
        rui.Vertex,
        vertices,
        .dynamic_draw,
    );

    const hw = 2.0 / @as(f32, @floatFromInt(self.program_info.render_target_size[0]));

    const hh =
        if (self.program_info.using_fb) 2.0 / @as(f32, @floatFromInt(self.program_info.render_target_size[1]))
        else -2.0 / @as(f32, @floatFromInt(self.program_info.render_target_size[1]));

    const y: f32 = if (self.program_info.using_fb) -1.0 else 1.0;

    var matrix = linalg.Matrix4{
        .{ hw,  0, 0, 0 },
        .{  0, hh, 0, 0 },
        .{  0,  0, 1, 0 },
        .{ -1,  y, 0, 1 },
    };


    // bind program
    rgl.bindVertexArray(self.program_info.vertex_array);
    rgl.useProgram(self.program_info.shader_program);

    // Set the shader uniforms
    rgl.uniformMatrix4fv(
        self.program_info.uniform_locations.matrix,
        false, // matrix transpose
        @ptrCast(&matrix),
    );

    if (texture) |tex| {
        rgl.activeTexture(.texture_0);
        rgl.bindTexture(
            @enumFromInt(@intFromPtr(tex.ptr)),
            .@"2d",
        );
        rgl.uniform1i(
            self.program_info.uniform_locations.use_tex,
            1,
        );
    } else {
        rgl.bindTexture(.invalid, .@"2d");
        rgl.uniform1i(
            self.program_info.uniform_locations.use_tex,
            0,
        );
    }

    rgl.uniform1i(
        self.program_info.uniform_locations.u_sampler,
        0,
    );

    //console.log("drawElements " + texture_id);
    rgl.drawElements(
        .triangles,
        indices.len,
        .unsigned_short,
        0,
    );
}

pub fn textureCreate(_: *Window, pixels: [*]u8, width: u32, height: u32, interpolation: rui.enums.TextureInterpolation) rui.Texture {
    const texture = rgl.genTexture();

    rgl.bindTexture(texture, .@"2d");

    rgl.textureImage2D(
        .@"2d",
        0,
        .rgba,
        width,
        height,
        .rgba,
        .unsigned_byte,
        pixels,
    );

    rgl.generateMipmap(.@"2d");

    if (interpolation == .nearest) {
        rgl.texParameter(
            .@"2d",
            .min_filter,
            .nearest,
        );
        rgl.texParameter(
            .@"2d",
            .mag_filter,
            .nearest,
        );
    } else {
        rgl.texParameter(
            .@"2d",
            .min_filter,
            .linear,
        );
        rgl.texParameter(
            .@"2d",
            .mag_filter,
            .linear,
        );
    }
    rgl.texParameter(
        .@"2d",
        .wrap_s,
        .clamp_to_edge,
    );
    rgl.texParameter(
        .@"2d",
        .wrap_t,
        .clamp_to_edge,
    );

    rgl.bindTexture(.invalid, .@"2d");

    return .{
        .ptr = @ptrFromInt(@intFromEnum(texture)),
        .width = width,
        .height = height,
    };
}

pub fn textureDestroy(_: *Window, texture: rui.Texture) void {
    const gpu: rgl.Texture = @enumFromInt(@intFromPtr(texture.ptr));
    gpu.delete();
}

pub fn textureCreateTarget(_: *Window, width: u32, height: u32, interpolation: rui.enums.TextureInterpolation) !rui.TextureTarget {
    const texture = rgl.genTexture();

    rgl.bindTexture(texture, .@"2d");

    rgl.textureImage2D(
        .@"2d",
        0,
        .rgba,
        width,
        height,
        .rgba,
        .unsigned_byte,
        null,
    );

    if (interpolation == .nearest) {
        rgl.texParameter(
            .@"2d",
            .min_filter,
            .nearest,
        );
        rgl.texParameter(
            .@"2d",
            .mag_filter,
            .nearest,
        );
    } else {
        rgl.texParameter(
            .@"2d",
            .min_filter,
            .linear,
        );
        rgl.texParameter(
            .@"2d",
            .mag_filter,
            .linear,
        );
    }
    rgl.texParameter(
        .@"2d",
        .wrap_s,
        .clamp_to_edge,
    );
    rgl.texParameter(
        .@"2d",
        .wrap_t,
        .clamp_to_edge,
    );

    rgl.bindTexture(.invalid, .@"2d");

    return .{
        .ptr = @ptrFromInt(@intFromEnum(texture)),
        .width = width,
        .height = height,
    };
}

pub fn textureReadTarget(self: *Window, texture: rui.TextureTarget, pixels_out: [*]u8) error{TextureRead}!void {
    rgl.bindFramebuffer(
        self.program_info.framebuffer,
        .buffer,
    );
    rgl.framebufferTexture2D(
        self.program_info.framebuffer,
        .buffer,
        .color0,
        .@"2d",
        @enumFromInt(@intFromPtr(texture.ptr)),
        0,
    );

    rgl.readPixels(
        0,
        0,
        texture.width,
        texture.height,
        .rgba,
        .unsigned_byte,
        pixels_out,
    );

    rgl.bindFramebuffer(.invalid, .buffer);
}

pub fn renderTarget(self: *Window, texture: ?rui.TextureTarget) void {
    if (texture) |tex| {
        self.program_info.using_fb = true;
        rgl.bindFramebuffer(
            self.program_info.framebuffer,
            .buffer,
        );

        rgl.framebufferTexture2D(
            self.program_info.framebuffer,
            .buffer,
            .color0,
            .@"2d",
            @enumFromInt(@intFromPtr(tex.ptr)),
            0,
        );
        self.program_info.render_target_size = .{
            tex.width,
            tex.height,
        };
    } else {
        self.program_info.using_fb = false;
        rgl.bindFramebuffer(.invalid, .buffer);
        self.program_info.render_target_size = self.program_info.window_size;
    }
    rgl.viewport(
        0,
        0,
        self.program_info.render_target_size[0],
        self.program_info.render_target_size[1],
    );
    rgl.scissor(
        0,
        0,
        self.program_info.render_target_size[0],
        self.program_info.render_target_size[1],
    );
}

pub fn textureFromTarget(_: *Window, texture: rui.TextureTarget) rui.Texture {
    return .{ .ptr = texture.ptr, .width = texture.width, .height = texture.height };
}



pub fn clipboardText(self: *Window) ![]const u8 {
    const str = rlfw.getClipboardString();
    return try self.arena.dupe(u8, str);
}

pub fn clipboardTextSet(self: *Window, text: []const u8) !void {
    if (text.len == 0) return;

    const tempZ = self.arena.dupeZ(u8, text) catch return;

    rlfw.setClipboardString(tempZ);
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
            return;
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
