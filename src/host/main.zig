const std = @import("std");
const zlfw = @import("zlfw");
const zgl = @import("zgl");

const Vertex = extern struct {
    x: f32,
    y: f32,
    z: f32,
};

const vertices: []const Vertex = &.{
    .{ .x = -0.5, .y = -0.5, .z = 0.0 },
    .{ .x = 0.5, .y = -0.5, .z = 0.0 },
    .{ .x = 0.0, .y = 0.5, .z = 0.0 },
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
    \\   FragColor = vec4(1.0f, 0.5f, 0.2f, 1.0f); // Orange color
    \\}
    ;

fn framebufferSizeCallback(window: zlfw.Window, size: zlfw.Size) void {
    _ = window;
    zgl.viewport(0, 0, size.width, size.height);
}

pub fn main() !void {
    // Initialize GLFW
    try zlfw.init(.{});
    defer zlfw.deinit();

    // if (std.os.tag == .darwin) {
    //     glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, glfw.TRUE);
    // }

    // Create a window
    const width = 800;
    const height = 600;
    var window = try zlfw.Window.init(width, height, "Triangle", null, null, .{
        .context = .{
            .version = .{
                .major = 4,
                .minor = 5,
            },
            .open_gl = .{ .profile = .core },
        },
    });
    defer window.deinit();

    try zlfw.makeCurrentContext(window);
    window.setFramebufferSizeCallback(framebufferSizeCallback);

    // Initialize zgl
    zgl.loadExtensions({}, struct {
        pub fn get_proc_address(_: void, symbol: [:0]const u8) ?zgl.binding.FunctionPointer {
            return zlfw.getProcAddress(symbol);
        }
    }.get_proc_address) catch |err| {
        std.debug.panic("Failed to initialize zgl: {}", .{err});
    };

    zgl.viewport(0, 0, width, height);
    try zlfw.swapInterval(0);

    // Create Vertex Buffer Object (VBO) and Vertex Array Object (VAO)
    const vbo = zgl.genBuffer();
    defer vbo.delete();

    const vao = zgl.genVertexArray();
    defer vao.delete();

    // Bind the VAO first, then bind and set vertex buffers, then configure vertex attributes.
    vao.bind();

    vbo.bind(.array_buffer);
    
    zgl.bufferData(
        .array_buffer,
        Vertex,
        vertices,
        .static_draw,
    );

    // Configure vertex attributes
    zgl.vertexAttribPointer(
        0, // layout (location = 0)
        3, // size of the vertex attribute
        .float,
        false, // normalized?
        @sizeOf(Vertex),
        @offsetOf(Vertex, "x"),
    );
    zgl.enableVertexAttribArray(0);

    // Unbind the VBO and VAO
    zgl.bindBuffer(.invalid, .array_buffer);
    zgl.bindVertexArray(.invalid);

    // Compile vertex shader
    const vertexShader = zgl.createShader(.vertex);
    defer vertexShader.delete();

    vertexShader.source(1, &.{vertexShaderSource});
    vertexShader.compile();

    {
        const log = try vertexShader.getCompileLog(std.heap.page_allocator);

        if (log.len != 0) {
            std.debug.print("Vertex shader compile log:\n{s}\n", .{log});
        }

        std.heap.page_allocator.free(log);

        if (vertexShader.get(.compile_status) == 0) {
            return error.InvalidVertexShader;
        }
    }

    // Compile fragment shader
    const fragmentShader = zgl.createShader(.fragment);
    defer fragmentShader.delete();

    fragmentShader.source(1, &.{fragmentShaderSource});
    fragmentShader.compile();

    {
        const log = try fragmentShader.getCompileLog(std.heap.page_allocator);

        if (log.len != 0) {
            std.debug.print("Fragment shader compile log:\n{s}\n", .{log});
        }
        
        std.heap.page_allocator.free(log);

        if (fragmentShader.get(.compile_status) == 0) {
            return error.InvalidFragmentShader;
        }
    }
    

    // Create and link the shader program
    const shaderProgram = zgl.createProgram();
    defer shaderProgram.delete();

    shaderProgram.attach(vertexShader);
    shaderProgram.attach(fragmentShader);
    shaderProgram.link();

    {
        const log = try shaderProgram.getCompileLog(std.heap.page_allocator);

        if (log.len != 0) {
            std.debug.print("Shader program link log:\n{s}\n", .{log});
        }

        std.heap.page_allocator.free(log);

        if (shaderProgram.get(.link_status) == 0) {
            return error.InvalidShaderProgram;
        }
    }

    // Render loop
    while (!window.shouldClose()) {
        zlfw.pollEvents();

        // Input processing
        if (window.getKey(.escape) == .press) {
            window.close(true);
        }

        // Rendering commands
        zgl.clearColor(0.2, 0.3, 0.3, 1.0);
        zgl.clear(.{ .color = true, .depth = true, .stencil = true });

        // Draw the triangle
        shaderProgram.use();
        vao.bind();
        zgl.drawArrays(.triangles, 0, 3);


        // finish up frame

        zgl.flush(); // shouldn't be necessary, but is on my machine :P

        try window.swapBuffers();
    }
}