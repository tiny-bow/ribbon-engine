const std = @import("std");
const log = std.log.scoped(.main);
const G = @import("framework");

pub const std_options = std.Options{
    .log_level = .info,
};

const module_dir = "zig-out/lib/";


export fn framebuffer_size_callback(window: C.) callconv(.c) void {

}

fn bootstrap() !void {

    if (C.glfwInit() == 0) {
        log.err("Failed to initialize GLFW\n", .{});
        return error.NoGLFW;
    }
    
    C.glfwWindowHint(C.GLFW_CONTEXT_VERSION_MAJOR, 4);
    C.glfwWindowHint(C.GLFW_CONTEXT_VERSION_MINOR, 1);
    C.glfwWindowHint(C.GLFW_OPENGL_PROFILE, C.GLFW_OPENGL_CORE_PROFILE);

    const window = if (C.glfwCreateWindow(640, 480, "OpenGL 4.1 Example", null, null)) |ptr| ptr else {
        log.err("Failed to create GLFW window\n", .{});
        C.glfwTerminate();
        return error.NoGLFW;
    };

    C.glfwMakeContextCurrent(window);
    C.glfwSetFramebufferSizeCallback(window, framebuffer_size_callback);
    
    if (!gladLoadGLLoader(C.glfwGetProcAddress)) {
        fprintf(stderr, "Failed to initialize GLAD\n");
        return -1;
    }


    while (!glfwWindowShouldClose(window)) {
        glClearColor(0.2f, 0.3f, 0.3f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        
        glfwSwapBuffers(window);
        glfwPollEvents();
    }

    C.glfwTerminate();
    return 0;
}

pub fn main() !void {

    bootstrap();

    log.info("main start", .{});

    const stderr_writer = std.io.getStdErr().writer();

    var heap = G.Heap{};

    var api = G.HostApi{
        .log = stderr_writer.any(),
        .allocator = .fromHeap(&heap),
        .heap = &heap,
    };

    const watcher = try G.Module.watch(&api);
    defer {
        watcher.stop();
        G.Module.shutdown();
    }

    {
        G.ModuleWatcher.mutex.lock();
        defer G.ModuleWatcher.mutex.unlock();

        var moduleDir = try std.fs.cwd().openDir(module_dir, .{ .iterate = true });
        defer moduleDir.close();

        var it = moduleDir.iterate();

        while (try it.next()) |entry| {
            if (entry.kind == .directory) {
                log.warn("skipping directory: {s}", .{entry.name});
                continue;
            }

            const path = try std.fs.path.join(api.allocator.temp, &.{module_dir, entry.name});

            _ = try G.Module.open(&api, .borrowed(path), .{});
        }
    }

    while (!api.shutdown.load(.unordered)) {
        G.ModuleWatcher.mutex.lock();

        G.Module.update() catch |err| {
            log.err("failed to step modules: {}; sleeping main thread 10s", .{err});
            G.ModuleWatcher.mutex.unlock();
            std.Thread.sleep(10 * std.time.ns_per_s);
        };

        G.ModuleWatcher.mutex.unlock();
    }
}
