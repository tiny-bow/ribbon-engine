const Application = @This();

const std = @import("std");
const log = std.log.scoped(.application);

const zlfw = @import("zlfw");
const zgl = @import("zgl");
const zimalloc = @import("zimalloc");

const HostApi = @import("HostApi");
const G = HostApi;

const module_system = @import("module_system");

window: zlfw.Window,
watcher: module_system.Watcher,
stderr_writer: std.fs.File.Writer,
collection_allocator: CollectionAllocator,

api: HostApi,


/// * only call this function from the main thread
pub fn init() !*Application {
    try zlfw.init(.{});

    const width = 800;
    const height = 600;
    const self = try std.heap.page_allocator.create(Application);
    
    self.window = try zlfw.Window.init(width, height, "Triangle", null, null, .{
        .context = .{
            .version = .{
                .major = 4,
                .minor = 5,
            },
            .open_gl = .{ .profile = .core },
            .debug = true,
        },
    });
    
    self.window.setFramebufferSizeCallback(framebufferSizeCallback);

    try zlfw.makeCurrentContext(self.window);
    
    zgl.loadExtensions({}, struct {
        pub fn get_proc_address(_: void, symbol: [:0]const u8) ?zgl.binding.FunctionPointer {
            return zlfw.getProcAddress(symbol);
        }
    }.get_proc_address) catch |err| {
        std.debug.panic("Failed to initialize zgl: {}", .{err});
    };

    zgl.debugMessageCallback(self, struct {
        pub fn gl_debug_handler(_: *Application, source: zgl.DebugSource, msg_type: zgl.DebugMessageType, id: usize, severity: zgl.DebugSeverity, message: []const u8) void {
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

    log.info("vendor: {?s}", .{zgl.getString(.vendor)});
    log.info("renderer: {?s}", .{zgl.getString(.renderer)});
    log.info("version: {?s}", .{zgl.getString(.version)});
    log.info("shading language version: {?s}", .{zgl.getString(.shading_language_version)});
    log.info("glsl version: {?s}", .{zgl.getString(.shading_language_version)});
    log.info("extensions: {?s}", .{zgl.getString(.extensions)});

    const maj = zgl.getInteger(.major_version);
    const min = zgl.getInteger(.minor_version);
    log.info("{}.{}", .{maj, min});
    if (maj != 4 or min < 5) {
        log.warn("OpenGL version is {}.{} but 4.5 was requested", .{maj, min});
    }
    
    std.debug.assert(@as(?*const anyopaque, @ptrCast(zgl.binding.function_pointers.glCreateVertexArrays)) != null);
    
    zgl.viewport(0, 0, width, height);

    try zlfw.swapInterval(0);

    self.stderr_writer = std.io.getStdErr().writer();
    self.collection_allocator = try CollectionAllocator.init(std.heap.page_allocator);

    self.api.log = self.stderr_writer.any();

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

    inline for (comptime std.meta.declarations(Api)) |lib_decl| {
        const lib = comptime @field(Api, lib_decl.name);

        inline for (comptime std.meta.declarations(lib)) |decl| {
            const exp = comptime @field(lib, decl.name);

            @field(@field(self.api, lib_decl.name), "host_" ++ decl.name) = exp;
        }
    }
    
    {
        module_system.Watcher.mutex.lock();
        defer module_system.Watcher.mutex.unlock();

        self.watcher = try module_system.watch(&self.api);

        try module_system.load_all(&self.api);
    }

    return self;
}

/// * only call this function from the main thread
pub fn deinit(self: *Application) void {
    log.info("closing window ...", .{});
    self.window.deinit();

    self.watcher.stop();

    module_system.shutdown();

    log.info("de-initializing allocators ...", .{});

    self.collection_allocator.deinit();
    self.api.heap.temp.deinit();
    self.api.heap.last_frame.deinit();
    self.api.heap.frame.deinit();
    self.api.heap.long_term.deinit();
    self.api.heap.static.deinit();

    log.info("shutting down middleware ...", .{});

    zlfw.deinit();

    log.info("final cleanup ...", .{});

    std.heap.page_allocator.destroy(self);

    log.info("application closed; goodbye 💝", .{});
}

pub fn reload(self: *Application, rld: G.ReloadType) !void {
    var hard_reload = rld == .hard;

    // TODO: reverse order unload
    
    log.info("reloading Module(s) ...", .{});

    if (!hard_reload) {
        load_loop: for (module_system.modules.keys()) |modPath| {
            _ = module_system.Module.open(&self.api, .owned(@constCast(modPath)), .{.handle_existing = .re_open}) catch |err| {
                log.err("failed to reload Module[{s}]: {}", .{modPath, err});
                hard_reload = true;
                break :load_loop;
            };
        }
    }

    if (!hard_reload) return;

    log.warn("hard reload required ...", .{});

    const keys = self.api.allocator.temp.alloc([]const u8, module_system.modules.keys().len) catch @panic("OOM");

    for (module_system.modules.keys(), 0..) |modPath, i| {
        keys[i] = self.api.allocator.temp.dupe(u8, modPath) catch @panic("OOM");
    }


    for (module_system.modules.values()) |mod| {
        mod.close();
    }

    module_system.modules.clearRetainingCapacity();

    self.api.heap.collection.reset();
    _ = self.api.heap.frame.reset(.retain_capacity);
    _ = self.api.heap.last_frame.reset(.retain_capacity);
    _ = self.api.heap.long_term.reset(.retain_capacity);

    for (keys) |modPath| {
        _ = module_system.Module.open(&self.api, .borrowed(@constCast(modPath)), .{}) catch |err| {
            std.debug.panic("failed to hard reload Module[{s}]: {}", .{modPath, err});
        };
    }

    _ = self.api.heap.temp.reset(.retain_capacity);
}

pub fn loop(self: *Application) void {
    const error_sleep_time = 10;

    loop: while (!self.window.shouldClose() and !self.api.shutdown.load(.unordered)) {
        @branchHint(.likely);

        const rld = self.api.reload.load(.acquire);
        if (rld != .none) {
            @branchHint(.cold);
            log.info("{s} reload requested", .{@tagName(rld)});
            
            module_system.Watcher.mutex.lock();
            
            self.reload(rld) catch |err| {
                @branchHint(.cold);
                log.err("failed to reload: {}; sleeping main thread {}s", .{err, error_sleep_time});
                self.api.reload.store(.hard, .release);
                module_system.Watcher.mutex.unlock();
                std.Thread.sleep(error_sleep_time * std.time.ns_per_s);
                continue :loop;
            };

            self.api.reload.store(.none, .release);

            module_system.Watcher.mutex.unlock();

            continue :loop;
        }
        
        zlfw.pollEvents();

        module_system.Watcher.mutex.lock();

        module_system.update() catch |err| {
            @branchHint(.cold);
            log.err("failed to step modules: {}; sleeping main thread {}s", .{err, error_sleep_time});
            module_system.Watcher.mutex.unlock();
            std.Thread.sleep(error_sleep_time * std.time.ns_per_s);
            continue :loop;
        };

        module_system.Watcher.mutex.unlock();

        zgl.flush(); // shouldn't be necessary, but is on my machine :P

        self.window.swapBuffers() catch {
            @branchHint(.cold);
            @panic("failed to swap window buffers");
        };
    }
}


pub const CollectionAllocator = zimalloc.Allocator(.{});


fn framebufferSizeCallback(window: zlfw.Window, size: zlfw.Size) void {
    _ = window;
    zgl.viewport(0, 0, size.width, size.height);
}

fn convert_buffer_storage_flags(flags: G.Gl.BufferStorageFlags) zgl.binding.GLbitfield {
    var flag_bits: zgl.binding.GLbitfield = 0;
    if (flags.map_read) flag_bits |= zgl.binding.MAP_READ_BIT;
    if (flags.map_write) flag_bits |= zgl.binding.MAP_WRITE_BIT;
    if (flags.map_persistent) flag_bits |= zgl.binding.MAP_PERSISTENT_BIT;
    if (flags.map_coherent) flag_bits |= zgl.binding.MAP_COHERENT_BIT;
    if (flags.client_storage) flag_bits |= zgl.binding.CLIENT_STORAGE_BIT;
    return flag_bits;
}

pub const Api = struct {
    pub const win = struct {
        pub fn close(self: *const G.Api.win) callconv(.c) void {
            const api: *HostApi = @constCast(@fieldParentPtr("win", self));
            const app: *Application = @fieldParentPtr("api", api);

            app.window.close(true);
        }
    };

    pub const gl = struct {
        pub fn createVertexArray(self: *const G.Api.gl) callconv(.c) G.Gl.VertexArray {
            _ = self;
            const vao = zgl.createVertexArray();
            const out = enumCast(G.Gl.VertexArray, vao);
            log.info("created vao: {x}, {x}", .{@intFromEnum(vao), @intFromEnum(out)});
            return out;
        }

        pub fn deleteVertexArray(self: *const G.Api.gl, vao: G.Gl.VertexArray) callconv(.c) void {
            _ = self;
            zgl.deleteVertexArray(enumCast(zgl.VertexArray, vao));
        }

        pub fn bindVertexArray(self: *const G.Api.gl, vao: G.Gl.VertexArray) callconv(.c) void {
            _ = self;
            zgl.bindVertexArray(enumCast(zgl.VertexArray, vao));
        }

        pub fn unbindVertexArray(self: *const G.Api.gl) callconv(.c) void {
            _ = self;
            zgl.bindVertexArray(.invalid);
        }

        pub fn enableVertexArrayAttrib(self: *const G.Api.gl, vao: G.Gl.VertexArray, index: u32) callconv(.c) void {
            _ = self;
            zgl.enableVertexArrayAttrib(enumCast(zgl.VertexArray, vao), index);
        }

        pub fn disableVertexArrayAttrib(self: *const G.Api.gl, vao: G.Gl.VertexArray, index: u32) callconv(.c) void {
            _ = self;
            zgl.disableVertexArrayAttrib(enumCast(zgl.VertexArray, vao), index);
        }

        pub fn vertexArrayAttribFormat(self: *const G.Api.gl, vao: G.Gl.VertexArray, index: u32, size: u32, ty: G.Gl.Type, normalized: bool, relative_offset: u32) callconv(.c) void {
            _ = self;
            zgl.vertexArrayAttribFormat(enumCast(zgl.VertexArray, vao), index, size, enumCast(zgl.Type, ty), normalized, relative_offset);
        }

        pub fn vertexArrayAttribIFormat(self: *const G.Api.gl, vao: G.Gl.VertexArray, index: u32, size: u32, ty: G.Gl.Type, relative_offset: u32) callconv(.c) void {
            _ = self;
            zgl.vertexArrayAttribIFormat(enumCast(zgl.VertexArray, vao), index, size, enumCast(zgl.Type, ty), relative_offset);
        }

        pub fn vertexArrayAttribLFormat(self: *const G.Api.gl, vao: G.Gl.VertexArray, index: u32, size: u32, ty: G.Gl.Type, relative_offset: u32) callconv(.c) void {
            _ = self;
            zgl.vertexArrayAttribLFormat(enumCast(zgl.VertexArray, vao), index, size, enumCast(zgl.Type, ty), relative_offset);
        }

        pub fn vertexArrayAttribBinding(self: *const G.Api.gl, vao: G.Gl.VertexArray, index: u32, binding: u32) callconv(.c) void {
            _ = self;
            zgl.vertexArrayAttribBinding(enumCast(zgl.VertexArray, vao), index, binding);
        }

        pub fn vertexArrayVertexBuffer(self: *const G.Api.gl, vao: G.Gl.VertexArray, buffer: G.Gl.Buffer, binding_index: u32, offset: u32, stride: u32) callconv(.c) void {
            _ = self;
            zgl.vertexArrayVertexBuffer(enumCast(zgl.VertexArray, vao), binding_index, enumCast(zgl.Buffer, buffer), offset, stride);
        }

        pub fn vertexArrayElementBuffer(self: *const G.Api.gl, vao: G.Gl.VertexArray, buffer: G.Gl.Buffer) callconv(.c) void {
            _ = self;
            zgl.vertexArrayElementBuffer(enumCast(zgl.VertexArray, vao), enumCast(zgl.Buffer, buffer));
        }

        pub fn vertexAttribPointer(self: *const G.Api.gl, index: u32, size: u32, ty: G.Gl.Type, normalized: bool, stride: u32, offset: u32) callconv(.c) void {
            _ = self;
            zgl.vertexAttribPointer(index, size, enumCast(zgl.Type, ty), normalized, stride, offset);
        }

        pub fn vertexAttribIPointer(self: *const G.Api.gl, index: u32, size: u32, ty: G.Gl.Type, stride: u32, offset: u32) callconv(.c) void {
            _ = self;
            zgl.vertexAttribIPointer(index, size, enumCast(zgl.Type, ty), stride, offset);
        }

        pub fn enableVertexAttribArray(self: *const G.Api.gl, index: u32) callconv(.c) void {
            _ = self;
            zgl.enableVertexAttribArray(index);
        }


        pub fn createBuffer(self: *const G.Api.gl) callconv(.c) G.Gl.Buffer {
            _ = self;
            const buffer = zgl.createBuffer();
            return enumCast(G.Gl.Buffer, buffer);
        }

        pub fn deleteBuffer(self: *const G.Api.gl, buffer: G.Gl.Buffer) callconv(.c) void {
            _ = self;
            zgl.deleteBuffer(enumCast(zgl.Buffer, buffer));
        }

        pub fn bindBuffer(self: *const G.Api.gl, buffer: G.Gl.Buffer, target: G.Gl.BufferTarget) callconv(.c) void {
            _ = self;
            zgl.bindBuffer(enumCast(zgl.Buffer, buffer), enumCast(zgl.BufferTarget, target));
        }

        pub fn bufferData(self: *const G.Api.gl, target: G.Gl.BufferTarget, size: u32, data: ?*const anyopaque, usage: G.Gl.BufferUsage) callconv(.c) void {
            _ = self;
            zgl.binding.bufferData(@intFromEnum(target), @intCast(size), data, @intFromEnum(usage));
        }

        pub fn unbindBuffer(self: *const G.Api.gl, target: G.Gl.BufferTarget) callconv(.c) void {
            _ = self;
            zgl.bindBuffer(.invalid, enumCast(zgl.BufferTarget, target));
        }

        pub fn namedBufferData(self: *const G.Api.gl, buffer: G.Gl.Buffer, size: u32, data: ?*const anyopaque, usage: G.Gl.BufferUsage) callconv(.c) void {
            _ = self;
            zgl.binding.namedBufferData(@intFromEnum(buffer), @intCast(size), data, @intFromEnum(usage));
        }

        pub fn namedBufferSubData(self: *const G.Api.gl, buffer: G.Gl.Buffer, offset: u32, size: u32, data: ?*const anyopaque) callconv(.c) void {
            _ = self;
            zgl.binding.namedBufferSubData(@intFromEnum(buffer), offset, @intCast(size), data);
        }

        pub fn namedBufferStorage(self: *const G.Api.gl, buffer: G.Gl.Buffer, size: u32, data: ?*const anyopaque, flags: G.Gl.BufferStorageFlags) callconv(.c) void {
            _ = self;
            zgl.binding.namedBufferStorage(@intFromEnum(buffer), @intCast(size), data, convert_buffer_storage_flags(flags));
        }

        pub fn mapNamedBuffer(self: *const G.Api.gl, buffer: G.Gl.Buffer, access: G.Gl.MapAccess, out: **anyopaque) callconv(.c) G.Signal {
            _ = self;

            const ptr = zgl.binding.mapBuffer(@intFromEnum(buffer), @intFromEnum(access));

            if (ptr) |p| {
                out.* = @ptrCast(p);
                return .okay;
            } else {
                return .panic;
            }
        }

        pub fn unmapNamedBuffer(self: *const G.Api.gl, buffer: G.Gl.Buffer) callconv(.c) bool {
            _ = self;
            return zgl.binding.unmapNamedBuffer(@intFromEnum(buffer)) == 1;
        }


        pub fn createShader(self: *const G.Api.gl, ty: G.Gl.ShaderType) callconv(.c) G.Gl.Shader {
            _ = self;
            return enumCast(G.Gl.Shader, zgl.createShader(enumCast(zgl.ShaderType, ty)));
        }

        pub fn deleteShader(self: *const G.Api.gl, shader: G.Gl.Shader) callconv(.c) void {
            _ = self;
            zgl.deleteShader(enumCast(zgl.Shader, shader));
        }

        pub fn compileShader(self: *const G.Api.gl, shader: G.Gl.Shader) callconv(.c) void {
            _ = self;
            zgl.compileShader(enumCast(zgl.Shader, shader));
        }

        pub fn shaderSource(self: *const G.Api.gl, shader: G.Gl.Shader, count: u32, sources: [*]const [*:0]const u8) callconv(.c) void {
            _ = self;
            zgl.binding.shaderSource(@intFromEnum(shader), @intCast(count), @ptrCast(sources), null);
        }

        pub fn getShaderParameter(self: *const G.Api.gl, shader: G.Gl.Shader, param: G.Gl.ShaderParameter) callconv(.c) i32 {
            _ = self;
            return zgl.getShader(enumCast(zgl.Shader, shader), enumCast(zgl.ShaderParameter, param));
        }

        pub fn getShaderInfoLog(self: *const G.Api.gl, shader: G.Gl.Shader, allocator: *const std.mem.Allocator, out: *[:0]const u8) callconv(.c) G.Signal {
            _ = self;
            const buf = zgl.getShaderInfoLog(enumCast(zgl.Shader, shader), allocator.*) catch |err| {
                log.err("failed to get shader info log: {}", .{err});
                return .panic;
            };
            out.* = buf;
            return .okay;
        }


        pub fn createProgram(self: *const G.Api.gl) callconv(.c) G.Gl.Program {
            _ = self;
            return enumCast(G.Gl.Program, zgl.createProgram());
        }

        pub fn deleteProgram(self: *const G.Api.gl, program: G.Gl.Program) callconv(.c) void {
            _ = self;
            zgl.deleteProgram(enumCast(zgl.Program, program));
        }

        pub fn attachShader(self: *const G.Api.gl, program: G.Gl.Program, shader: G.Gl.Shader) callconv(.c) void {
            _ = self;
            zgl.attachShader(enumCast(zgl.Program, program), enumCast(zgl.Shader, shader));
        }

        pub fn detachShader(self: *const G.Api.gl, program: G.Gl.Program, shader: G.Gl.Shader) callconv(.c) void {
            _ = self;
            zgl.detachShader(enumCast(zgl.Program, program), enumCast(zgl.Shader, shader));
        }

        pub fn linkProgram(self: *const G.Api.gl, program: G.Gl.Program) callconv(.c) void {
            _ = self;
            zgl.linkProgram(enumCast(zgl.Program, program));
        }

        pub fn useProgram(self: *const G.Api.gl, program: G.Gl.Program) callconv(.c) void {
            _ = self;
            zgl.useProgram(enumCast(zgl.Program, program));
        }

        pub fn programUniform1ui(self: *const G.Api.gl, program: G.Gl.Program, location: u32, v0: u32) callconv(.c) void {
            _ = self;
            zgl.programUniform1ui(enumCast(zgl.Program, program), location, v0);
        }

        pub fn programUniform1i(self: *const G.Api.gl, program: G.Gl.Program, location: u32, v0: i32) callconv(.c) void {
            _ = self;
            zgl.programUniform1i(enumCast(zgl.Program, program), location, v0);
        }

        pub fn programUniform3ui(self: *const G.Api.gl, program: G.Gl.Program, location: u32, v0: u32, v1: u32, v2: u32) callconv(.c) void {
            _ = self;
            zgl.programUniform3ui(enumCast(zgl.Program, program), location, v0, v1, v2);
        }

        pub fn programUniform3i(self: *const G.Api.gl, program: G.Gl.Program, location: u32, v0: i32, v1: i32, v2: i32) callconv(.c) void {
            _ = self;
            zgl.programUniform3i(enumCast(zgl.Program, program), location, v0, v1, v2);
        }

        pub fn programUniform2i(self: *const G.Api.gl, program: G.Gl.Program, location: u32, v0: i32, v1: i32) callconv(.c) void {
            _ = self;
            zgl.programUniform2i(enumCast(zgl.Program, program), location, v0, v1);
        }
        pub fn programUniform1f(self: *const G.Api.gl, program: G.Gl.Program, location: u32, v0: f32) callconv(.c) void {
            _ = self;
            zgl.programUniform1f(enumCast(zgl.Program, program), location, v0);
        }

        pub fn programUniform2f(self: *const G.Api.gl, program: G.Gl.Program, location: u32, v0: f32, v1: f32) callconv(.c) void {
            _ = self;
            zgl.programUniform2f(enumCast(zgl.Program, program), location, v0, v1);
        }

        pub fn programUniform3f(self: *const G.Api.gl, program: G.Gl.Program, location: u32, v0: f32, v1: f32, v2: f32) callconv(.c) void {
            _ = self;
            zgl.programUniform3f(enumCast(zgl.Program, program), location, v0, v1, v2);
        }

        pub fn programUniform4f(self: *const G.Api.gl, program: G.Gl.Program, location: u32, v0: f32, v1: f32, v2: f32, v3: f32) callconv(.c) void {
            _ = self;
            zgl.programUniform4f(enumCast(zgl.Program, program), location, v0, v1, v2, v3);
        }
        
        pub fn programUniformMatrix4fv(self: *const G.Api.gl, program: G.Gl.Program, location: u32, count: u32, transpose: bool, value: [*]const f32) callconv(.c) void {
            _ = self;
            zgl.binding.programUniformMatrix4fv(@intFromEnum(program), @intCast(location), @intCast(count), @intFromBool(transpose), value);
        }

        pub fn getProgramParameter(self: *const G.Api.gl, program: G.Gl.Program, param: G.Gl.ProgramParameter) callconv(.c) i32 {
            _ = self;
            return zgl.getProgram(enumCast(zgl.Program, program), enumCast(zgl.ProgramParameter, param));
        }

        pub fn getProgramInfoLog(self: *const G.Api.gl, program: G.Gl.Program, allocator: *const std.mem.Allocator, out: *[:0]const u8) callconv(.c) G.Signal {
            _ = self;
            const buf = zgl.getProgramInfoLog(enumCast(zgl.Program, program), allocator.*) catch |err| {
                log.err("failed to get program info log: {}", .{err});
                return .panic;
            };
            out.* = buf;
            return .okay;
        }

        pub fn getUniformLocation(self: *const G.Api.gl, program: G.Gl.Program, name: *const [:0]const u8, out: *u32) callconv(.c) G.Signal {
            _ = self;
            out.* = @intCast(zgl.getUniformLocation(enumCast(zgl.Program, program), name.*) orelse return .panic);
            return .okay;
        }

        pub fn getUniformBlockIndex(self: *const G.Api.gl, program: G.Gl.Program, name: *const [:0]const u8, out: *u32) callconv(.c) G.Signal {
            _ = self;
            out.* = @intCast(zgl.getUniformBlockIndex(enumCast(zgl.Program, program), name.*) orelse return .panic);
            return .okay;
        }


        pub fn clearColor(self: *const G.Api.gl, r: f32, g: f32, b: f32, a: f32) callconv(.c) void {
            _ = self;
            zgl.clearColor(r, g, b, a);
        }

        pub fn clear(self: *const G.Api.gl, mask: G.Gl.ClearMask) callconv(.c) void {
            _ = self;
            zgl.binding.clear(
                @as(zgl.BitField, if (mask.color) zgl.binding.COLOR_BUFFER_BIT else 0) |
                @as(zgl.BitField, if (mask.depth) zgl.binding.DEPTH_BUFFER_BIT else 0) |
                @as(zgl.BitField, if (mask.stencil) zgl.binding.STENCIL_BUFFER_BIT else 0)
            );
        }

        pub fn clearDepth(self: *const G.Api.gl, depth: f32) callconv(.c) void {
            _ = self;
            zgl.clearDepth(depth);
        }

        pub fn enable(self: *const G.Api.gl, cap: G.Gl.Capability) callconv(.c) void {
            _ = self;
            zgl.enable(enumCast(zgl.Capabilities, cap));
        }

        pub fn disable(self: *const G.Api.gl, cap: G.Gl.Capability) callconv(.c) void {
            _ = self;
            zgl.disable(enumCast(zgl.Capabilities, cap));
        }

        pub fn drawArrays(self: *const G.Api.gl, mode: G.Gl.Primitive, first: u32, count: u32) callconv(.c) void {
            _ = self;
            zgl.drawArrays(enumCast(zgl.PrimitiveType, mode), first, count);
        }

        pub fn drawElements(self: *const G.Api.gl, mode: G.Gl.Primitive, count: u32, ty: G.Gl.Type, indices: u32) callconv(.c) void {
            _ = self;
            zgl.drawElements(enumCast(zgl.PrimitiveType, mode), count, enumCast(zgl.ElementType, ty), indices);
        }
    };
};

fn enumCast(comptime T: type, value: anytype) T {
    return @enumFromInt(@intFromEnum(value));
}