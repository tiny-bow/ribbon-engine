const G = @import("HostApi");
const std = @import("std");
const log = std.log.scoped(.gl1);

pub const std_options = std.Options{
    .log_level = .info,
    .logFn = struct {
        pub fn log(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
            api.host.log.message(message_level, scope, format, args);
        }
    }.log,
};

pub export var api = G.Binary.fromNamespace(@This());

var self: struct {
    vao: G.Gl.VertexArray,
    vbo: G.Gl.Buffer,
    shader_program: G.Gl.Program,
} = undefined;

var g: *G = undefined;



const Vertex = extern struct {
    x: f32,
    y: f32,
    z: f32,
};

const vertices: []const Vertex = &.{
    .{ .x = -0.5, .y = -0.5, .z = 0.0 },
    .{ .x =  0.5, .y = -0.5, .z = 0.0 },
    .{ .x =  0.0, .y =  0.5, .z = 0.0 },
};

const vertexShaderSource =
    \\#version 450 core
    \\layout (location = 0) in vec3 aPos;
    \\void main()
    \\{
    \\   gl_Position = vec4(aPos.x, aPos.y, aPos.z, 1.0);
    \\}
    ;

const fragmentShaderSource =
    \\#version 450 core
    \\out vec4 FragColor;
    \\void main()
    \\{
    \\   FragColor = vec4(1.0f, 0.5f, 1.0f, 1.0f);
    \\}
    ;



pub fn on_start() !void {
    log.info("gl1 starting...", .{});
    log.info("api.host: {x}", .{@intFromPtr(api.host)});

    g = api.host;

    log.info("g: {x}", .{@intFromPtr(g)});

    const new_vao = g.gl.createVertexArray();
    self.vao = new_vao;
    log.info("vao: {x} {x}", .{@intFromEnum(new_vao), self.vao});

    self.vbo = g.gl.createBuffer();
    g.gl.bindBuffer(self.vbo, .array_buffer);
    g.gl.vertexArrayVertexBuffer(self.vao, self.vbo, 0, 0, @sizeOf(Vertex));
    log.info("vbo: {x}", .{@intFromEnum(self.vbo)});

    g.gl.namedBufferData(
        self.vbo,
        @sizeOf(Vertex) * vertices.len,
        vertices.ptr,
        .static_draw,
    );
    log.info("set vbo data", .{});

    g.gl.vertexArrayAttribBinding(self.vao, 0, 0);
    log.info("set attrib binding", .{});

    // Configure vertex attributes
    g.gl.vertexArrayAttribFormat(
        self.vao,
        0,
        3,
        .float,
        false,
        0,
    );
    log.info("set attrib format", .{});

    g.gl.enableVertexArrayAttrib(self.vao, 0);
    log.info("enabled attrib", .{});


    self.shader_program = shader_program: {
        const vertexShader = g.gl.createShader(.vertex);
        defer g.gl.deleteShader(vertexShader);

        {
            const sources = [_][*:0]const u8 {vertexShaderSource};

            g.gl.shaderSource(vertexShader, sources.len, &sources);
            g.gl.compileShader(vertexShader);

            const compileLog = try g.gl.getShaderInfoLog(vertexShader, std.heap.page_allocator);

            if (compileLog.len != 0) {
                std.debug.print("Vertex shader compile log:\n{s}\n", .{compileLog});
            }

            std.heap.page_allocator.free(compileLog);

            if (g.gl.getShaderParameter(vertexShader, .compile_status) == 0) {
                return error.InvalidVertexShader;
            }
        }

        const fragmentShader = g.gl.createShader(.fragment);
        defer g.gl.deleteShader(fragmentShader);

        {
            const sources = [_][*:0]const u8 {fragmentShaderSource};

            g.gl.shaderSource(fragmentShader, sources.len, &sources);
            g.gl.compileShader(fragmentShader);

            const compileLog = try g.gl.getShaderInfoLog(fragmentShader, std.heap.page_allocator);

            if (compileLog.len != 0) {
                std.debug.print("Fragment shader compile log:\n{s}\n", .{compileLog});
            }

            std.heap.page_allocator.free(compileLog);

            if (g.gl.getShaderParameter(fragmentShader, .compile_status) == 0) {
                return error.InvalidFragmentShader;
            }
        }

        const shader_program = g.gl.createProgram();

        g.gl.attachShader(shader_program, vertexShader);
        g.gl.attachShader(shader_program, fragmentShader);
        g.gl.linkProgram(shader_program);

        {
            const compileLog = try g.gl.getProgramInfoLog(shader_program, std.heap.page_allocator);

            if (compileLog.len != 0) {
                std.debug.print("Shader program link log:\n{s}\n", .{compileLog});
            }

            std.heap.page_allocator.free(compileLog);

            if (g.gl.getProgramParameter(shader_program, .link_status) == 0) {
                return error.InvalidShaderProgram;
            }
        }

        break :shader_program shader_program;
    };
}

pub fn on_step() !void {
    g.gl.clearColor(0.2, 0.3, 0.3, 1.0);
    g.gl.clear(.{ .color = true, .depth = true, .stencil = true });
    g.gl.useProgram(self.shader_program);
    g.gl.bindVertexArray(self.vao);
    g.gl.drawArrays(.triangles, 0, 3);
}

pub fn on_stop() !void {
    g.gl.deleteBuffer(self.vbo);
    g.gl.deleteVertexArray(self.vao);
    g.gl.deleteProgram(self.shader_program);
}
