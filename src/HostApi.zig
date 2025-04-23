const HostApi = @This();

const std = @import("std");

const rgl = @import("rgl");

allocator: AllocatorSet,
heap: Heap,
reload: std.atomic.Value(ReloadType),
shutdown: std.atomic.Value(bool),

log: Api.log,
module: Api.module,
win: Api.win,
gl: Api.gl,

pub const ReloadType = enum(i8) {
    hard = -1,
    none = 0,
    soft = 1,
};
pub const Signal = enum(i8) {
    panic = -1,
    okay = 0,
};

pub const Api = struct {
    pub const log = struct {
        const Self = @This();

        host_log: std.io.AnyWriter,
        host_lock_mutex: *const fn (*const Self) callconv(.c) void,
        host_unlock_mutex: *const fn (*const Self) callconv(.c) void,

        pub fn message(self: *const Self, comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
            const level_txt = comptime level.asText();
            const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

            self.host_lock_mutex(self);
            defer self.host_unlock_mutex(self);

            self.host_log.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
        }
    };

    pub const module = struct {
        const Self = @This();

        host_lookupModule: *const fn(self: *const Self, name: *const []const u8, out: **Module) callconv(.c) Signal,
        host_lookupAddress: *const fn(self: *const Self, ref: *Module, name: *const [:0]const u8, out: **anyopaque) callconv(.c) Signal,

        pub fn lookupModule(self: *const Self, name: []const u8) error{ModuleNotFound}!*Module {
            var out: *Module = undefined;
            return switch (self.host_lookupModule(self, &name, &out)) {
                .okay => out,
                .panic => error.ModuleNotFound,
            };
        }

        pub fn lookupAddress(self: *const Self, ref: *Module, name: [:0]const u8) error{UnboundSymbol}!*anyopaque {
            var out: *anyopaque = undefined;
            return switch (self.host_lookupAddress(self, ref, &name, &out)) {
                .okay => out,
                .panic => error.UnboundSymbol,
            };
        }
    };

    pub const win = struct {
        const Self = @This();

        host_close: *const fn(self: *const Self) callconv(.c) void,

        pub fn close(self: *const Self) callconv(.c) void { return self.host_close(self); }
    };

    pub const gl = struct {
        const Self = @This();

        host_createVertexArray: *const fn (self: *const Self) callconv(.c) Gl.VertexArray,
        host_deleteVertexArray: *const fn (self: *const Self, vao: Gl.VertexArray) callconv(.c) void,
        host_bindVertexArray: *const fn (self: *const Self, vao: Gl.VertexArray) callconv(.c) void,
        host_unbindVertexArray: *const fn (self: *const Self) callconv(.c) void,
        host_enableVertexArrayAttrib: *const fn (self: *const Self, vao: Gl.VertexArray, index: u32) callconv(.c) void,
        host_disableVertexArrayAttrib: *const fn (self: *const Self, vao: Gl.VertexArray, index: u32) callconv(.c) void,
        host_vertexArrayAttribFormat: *const fn (self: *const Self, vao: Gl.VertexArray, index: u32, size: u32, ty: Gl.Type, normalized: bool, relative_offset: u32) callconv(.c) void,
        host_vertexArrayAttribIFormat: *const fn (self: *const Self, vao: Gl.VertexArray, index: u32, size: u32, ty: Gl.Type, relative_offset: u32) callconv(.c) void,
        host_vertexArrayAttribLFormat: *const fn (self: *const Self, vao: Gl.VertexArray, index: u32, size: u32, ty: Gl.Type, relative_offset: u32) callconv(.c) void,
        host_vertexArrayAttribBinding: *const fn (self: *const Self, vao: Gl.VertexArray, index: u32, binding: u32) callconv(.c) void,
        host_vertexArrayVertexBuffer: *const fn (self: *const Self, vao: Gl.VertexArray, buffer: Gl.Buffer, binding_index: u32, offset: u32, stride: u32) callconv(.c) void,
        host_vertexArrayElementBuffer: *const fn (self: *const Self, vao: Gl.VertexArray, buffer: Gl.Buffer) callconv(.c) void,
        host_vertexAttribPointer: *const fn (self: *const Self, index: u32, size: u32, ty: Gl.Type, normalized: bool, stride: u32, offset: u32) callconv(.c) void,
        host_vertexAttribIPointer: *const fn (self: *const Self, index: u32, size: u32, ty: Gl.Type, stride: u32, offset: u32) callconv(.c) void,
        host_enableVertexAttribArray: *const fn (self: *const Self, index: u32) callconv(.c) void,
        host_createBuffer: *const fn (self: *const Self) callconv(.c) Gl.Buffer,
        host_bindBuffer: *const fn (self: *const Self, buffer: Gl.Buffer, target: Gl.BufferTarget) callconv(.c) void,
        host_bufferData: *const fn (self: *const Self, target: Gl.BufferTarget, size: u32, data: ?*const anyopaque, usage: Gl.BufferUsage) callconv(.c) void,
        host_deleteBuffer: *const fn (self: *const Self, buffer: Gl.Buffer) callconv(.c) void,
        host_unbindBuffer: *const fn (self: *const Self, target: Gl.BufferTarget) callconv(.c) void,
        host_namedBufferData: *const fn (self: *const Self, buffer: Gl.Buffer, size: u32, data: ?*const anyopaque, usage: Gl.BufferUsage) callconv(.c) void,
        host_namedBufferSubData: *const fn (self: *const Self, buffer: Gl.Buffer, offset: u32, size: u32, data: ?*const anyopaque) callconv(.c) void,
        host_namedBufferStorage: *const fn (self: *const Self, buffer: Gl.Buffer, size: u32, data: ?*const anyopaque, flags: Gl.BufferStorageFlags) callconv(.c) void,
        host_mapNamedBuffer: *const fn (self: *const Self, buffer: Gl.Buffer, access: Gl.MapAccess, out: **anyopaque) callconv(.c) Signal,
        host_unmapNamedBuffer: *const fn (self: *const Self, buffer: Gl.Buffer) callconv(.c) bool,
        host_createShader: *const fn (self: *const Self, ty: Gl.ShaderType) callconv(.c) Gl.Shader,
        host_deleteShader: *const fn (self: *const Self, shader: Gl.Shader) callconv(.c) void,
        host_compileShader: *const fn (self: *const Self, shader: Gl.Shader) callconv(.c) void,
        host_shaderSource: *const fn (self: *const Self, shader: Gl.Shader, count: u32, sources: [*]const [*:0]const u8) callconv(.c) void,
        host_getShaderParameter: *const fn (self: *const Self, shader: Gl.Shader, param: Gl.ShaderParameter) callconv(.c) i32,
        host_getShaderInfoLog: *const fn (self: *const Self, shader: Gl.Shader, allocator: *const std.mem.Allocator, out: *[:0]const u8) callconv(.c) Signal,
        host_createProgram: *const fn (self: *const Self) callconv(.c) Gl.Program,
        host_deleteProgram: *const fn (self: *const Self, program: Gl.Program) callconv(.c) void,
        host_attachShader: *const fn (self: *const Self, program: Gl.Program, shader: Gl.Shader) callconv(.c) void,
        host_detachShader: *const fn (self: *const Self, program: Gl.Program, shader: Gl.Shader) callconv(.c) void,
        host_linkProgram: *const fn (self: *const Self, program: Gl.Program) callconv(.c) void,
        host_useProgram: *const fn (self: *const Self, program: Gl.Program) callconv(.c) void,
        host_programUniform1ui: *const fn (self: *const Self, program: Gl.Program, location: u32, v0: u32) callconv(.c) void,
        host_programUniform1i: *const fn (self: *const Self, program: Gl.Program, location: u32, v0: i32) callconv(.c) void,
        host_programUniform3ui: *const fn (self: *const Self, program: Gl.Program, location: u32, v0: u32, v1: u32, v2: u32) callconv(.c) void,
        host_programUniform3i: *const fn (self: *const Self, program: Gl.Program, location: u32, v0: i32, v1: i32, v2: i32) callconv(.c) void,
        host_programUniform2i: *const fn (self: *const Self, program: Gl.Program, location: u32, v0: i32, v1: i32) callconv(.c) void,
        host_programUniform1f: *const fn (self: *const Self, program: Gl.Program, location: u32, v0: f32) callconv(.c) void,
        host_programUniform2f: *const fn (self: *const Self, program: Gl.Program, location: u32, v0: f32, v1: f32) callconv(.c) void,
        host_programUniform3f: *const fn (self: *const Self, program: Gl.Program, location: u32, v0: f32, v1: f32, v2: f32) callconv(.c) void,
        host_programUniform4f: *const fn (self: *const Self, program: Gl.Program, location: u32, v0: f32, v1: f32, v2: f32, v3: f32) callconv(.c) void,
        host_programUniformMatrix4fv: *const fn (self: *const Self, program: Gl.Program, location: u32, count: u32, transpose: bool, value: [*]const f32) callconv(.c) void,
        host_getProgramParameter: *const fn (self: *const Self, program: Gl.Program, param: Gl.ProgramParameter) callconv(.c) i32,
        host_getProgramInfoLog: *const fn (self: *const Self, program: Gl.Program, allocator: *const std.mem.Allocator, out: *[:0]const u8) callconv(.c) Signal,
        host_getUniformLocation: *const fn (self: *const Self, program: Gl.Program, name: *const [:0]const u8, out: *u32) callconv(.c) Signal,
        host_getUniformBlockIndex: *const fn (self: *const Self, program: Gl.Program, name: *const [:0]const u8, out: *u32) callconv(.c) Signal,
        host_clearColor: *const fn (self: *const Self, r: f32, g: f32, b: f32, a: f32) callconv(.c) void,
        host_clear: *const fn (self: *const Self, mask: Gl.ClearMask) callconv(.c) void,
        host_clearDepth: *const fn (self: *const Self, depth: f32) callconv(.c) void,
        host_enable: *const fn (self: *const Self, cap: Gl.Capability) callconv(.c) void,
        host_disable: *const fn (self: *const Self, cap: Gl.Capability) callconv(.c) void,
        host_drawArrays: *const fn (self: *const Self, mode: Gl.Primitive, first: u32, count: u32) callconv(.c) void,
        host_drawElements: *const fn (self: *const Self, mode: Gl.Primitive, count: u32, ty: Gl.Type, indices: u32) callconv(.c) void,

        pub fn createVertexArray(self: *const Self) Gl.VertexArray {
            const out = self.host_createVertexArray(self);
            std.log.info("createVertexArray wrapper {x}", .{out});
            return out;
        }

        pub fn deleteVertexArray(self: *const Self, vao: Gl.VertexArray) void { return self.host_deleteVertexArray(self, vao); }
        pub fn bindVertexArray(self: *const Self, vao: Gl.VertexArray) void { return self.host_bindVertexArray(self, vao); }
        pub fn unbindVertexArray(self: *const Self) void { return self.host_unbindVertexArray(self); }
        pub fn enableVertexArrayAttrib(self: *const Self, vao: Gl.VertexArray, index: u32) void { return self.host_enableVertexArrayAttrib(self, vao, index); }
        pub fn disableVertexArrayAttrib(self: *const Self, vao: Gl.VertexArray, index: u32) void { return self.host_disableVertexArrayAttrib(self, vao, index); }
        pub fn vertexArrayAttribFormat(self: *const Self, vao: Gl.VertexArray, index: u32, size: u32, ty: Gl.Type, normalized: bool, relative_offset: u32) void { return self.host_vertexArrayAttribFormat(self, vao, index, size, ty, normalized, relative_offset); }
        pub fn vertexArrayAttribIFormat(self: *const Self, vao: Gl.VertexArray, index: u32, size: u32, ty: Gl.Type, relative_offset: u32) void { return self.host_vertexArrayAttribIFormat(self, vao, index, size, ty, relative_offset); }
        pub fn vertexArrayAttribLFormat(self: *const Self, vao: Gl.VertexArray, index: u32, size: u32, ty: Gl.Type, relative_offset: u32) void { return self.host_vertexArrayAttribLFormat(self, vao, index, size, ty, relative_offset); }
        pub fn vertexArrayAttribBinding(self: *const Self, vao: Gl.VertexArray, index: u32, binding: u32) void { return self.host_vertexArrayAttribBinding(self, vao, index, binding); }
        pub fn vertexArrayVertexBuffer(self: *const Self, vao: Gl.VertexArray, buffer: Gl.Buffer, binding_index: u32, offset: u32, stride: u32) void { return self.host_vertexArrayVertexBuffer(self, vao, buffer, binding_index, offset, stride); }
        pub fn vertexArrayElementBuffer(self: *const Self, vao: Gl.VertexArray, buffer: Gl.Buffer) void { return self.host_vertexArrayElementBuffer(self, vao, buffer); }
        pub fn vertexAttribPointer(self: *const Self, index: u32, size: u32, ty: Gl.Type, normalized: bool, stride: u32, offset: u32) void { return self.host_vertexAttribPointer(self, index, size, ty, normalized, stride, offset); }
        pub fn vertexAttribIPointer(self: *const Self, index: u32, size: u32, ty: Gl.Type, stride: u32, offset: u32) void { return self.host_vertexAttribIPointer(self, index, size, ty, stride, offset); }
        pub fn enableVertexAttribArray(self: *const Self, index: u32) void { return self.host_enableVertexAttribArray(self, index); }
        pub fn createBuffer(self: *const Self) Gl.Buffer { return self.host_createBuffer(self); }
        pub fn bindBuffer(self: *const Self, buffer: Gl.Buffer, target: Gl.BufferTarget) void { return self.host_bindBuffer(self, buffer, target); }
        pub fn bufferData(self: *const Self, target: Gl.BufferTarget, size: u32, data: ?*const anyopaque, usage: Gl.BufferUsage) void { return self.host_bufferData(self, target, size, data, usage); }
        pub fn unbindBuffer(self: *const Self, target: Gl.BufferTarget) void { return self.host_unbindBuffer(self, target); }
        pub fn deleteBuffer(self: *const Self, buffer: Gl.Buffer) void { return self.host_deleteBuffer(self, buffer); }
        pub fn namedBufferData(self: *const Self, buffer: Gl.Buffer, size: u32, data: ?*const anyopaque, usage: Gl.BufferUsage) void { return self.host_namedBufferData(self, buffer, size, data, usage); }
        pub fn namedBufferSubData(self: *const Self, buffer: Gl.Buffer, offset: u32, size: u32, data: ?*const anyopaque) void { return self.host_namedBufferSubData(self, buffer, offset, size, data); }
        pub fn namedBufferStorage(self: *const Self, buffer: Gl.Buffer, size: u32, data: ?*const anyopaque, flags: Gl.BufferStorageFlags) void { return self.host_namedBufferStorage(self, buffer, size, data, flags); }
        pub fn mapNamedBuffer(self: *const Self, buffer: Gl.Buffer, access: Gl.MapAccess) ?*anyopaque {
            var out: *anyopaque = undefined;
            return switch (self.host_mapNamedBuffer(self, buffer, access, &out)) {
                .okay => out,
                .panic => null,
            };
        }
        pub fn unmapNamedBuffer(self: *const Self, buffer: Gl.Buffer) bool { return self.host_unmapNamedBuffer(self, buffer); }
        pub fn createShader(self: *const Self, ty: Gl.ShaderType) Gl.Shader { return self.host_createShader(self, ty); }
        pub fn deleteShader(self: *const Self, shader: Gl.Shader) void { return self.host_deleteShader(self, shader); }
        pub fn compileShader(self: *const Self, shader: Gl.Shader) void { return self.host_compileShader(self, shader); }
        pub fn shaderSource(self: *const Self, shader: Gl.Shader, count: u32, sources: [*]const [*:0]const u8) void { return self.host_shaderSource(self, shader, count, sources); }
        pub fn getShaderParameter(self: *const Self, shader: Gl.Shader, param: Gl.ShaderParameter) i32 { return self.host_getShaderParameter(self, shader, param); }
        pub fn getShaderInfoLog(self: *const Self, shader: Gl.Shader, allocator: std.mem.Allocator) error{OutOfMemory}![:0]const u8 {
            var out: [:0]const u8 = undefined;
            return switch (self.host_getShaderInfoLog(self, shader, &allocator, &out)) {
                .okay => out,
                .panic => error.OutOfMemory,
            };
        }
        pub fn createProgram(self: *const Self) Gl.Program { return self.host_createProgram(self); }
        pub fn deleteProgram(self: *const Self, program: Gl.Program) void { return self.host_deleteProgram(self, program); }
        pub fn attachShader(self: *const Self, program: Gl.Program, shader: Gl.Shader) void { return self.host_attachShader(self, program, shader); }
        pub fn detachShader(self: *const Self, program: Gl.Program, shader: Gl.Shader) void { return self.host_detachShader(self, program, shader); }
        pub fn linkProgram(self: *const Self, program: Gl.Program) void { return self.host_linkProgram(self, program); }
        pub fn useProgram(self: *const Self, program: Gl.Program) void { return self.host_useProgram(self, program); }
        pub fn programUniform1ui(self: *const Self, program: Gl.Program, location: u32, v0: u32) void { return self.host_programUniform1ui(self, program, location, v0); }
        pub fn programUniform1i(self: *const Self, program: Gl.Program, location: u32, v0: i32) void { return self.host_programUniform1i(self, program, location, v0); }
        pub fn programUniform3ui(self: *const Self, program: Gl.Program, location: u32, v0: u32, v1: u32, v2: u32) void { return self.host_programUniform3ui(self, program, location, v0, v1, v2); }
        pub fn programUniform3i(self: *const Self, program: Gl.Program, location: u32, v0: i32, v1: i32, v2: i32) void { return self.host_programUniform3i(self, program, location, v0, v1, v2); }
        pub fn programUniform2i(self: *const Self, program: Gl.Program, location: u32, v0: i32, v1: i32) void { return self.host_programUniform2i(self, program, location, v0, v1); }
        pub fn programUniform1f(self: *const Self, program: Gl.Program, location: u32, v0: f32) void { return self.host_programUniform1f(self, program, location, v0); }
        pub fn programUniform2f(self: *const Self, program: Gl.Program, location: u32, v0: f32, v1: f32) void { return self.host_programUniform2f(self, program, location, v0, v1); }
        pub fn programUniform3f(self: *const Self, program: Gl.Program, location: u32, v0: f32, v1: f32, v2: f32) void { return self.host_programUniform3f(self, program, location, v0, v1, v2); }
        pub fn programUniform4f(self: *const Self, program: Gl.Program, location: u32, v0: f32, v1: f32, v2: f32, v3: f32) void { return self.host_programUniform4f(self, program, location, v0, v1, v2, v3); }
        pub fn programUniformMatrix4fv(self: *const Self, program: Gl.Program, location: u32, count: u32, transpose: bool, value: [*]const f32) void { return self.host_programUniformMatrix4(self, program, location, count, transpose, value); }
        pub fn getProgramParameter(self: *const Self, program: Gl.Program, param: Gl.ProgramParameter) i32 { return self.host_getProgramParameter(self, program, param); }
        pub fn getProgramInfoLog(self: *const Self, program: Gl.Program, allocator: std.mem.Allocator) error{OutOfMemory}![:0]const u8 {
            var out: [:0]const u8 = undefined;
            return switch (self.host_getProgramInfoLog(self, program, &allocator, &out)) {
                .okay => out,
                .panic => error.OutOfMemory,
            };
        }
        pub fn getUniformLocation(self: *const Self, program: Gl.Program, name: [:0]const u8) ?u32 {
            var out: u32 = undefined;
            return switch(self.host_getUniformLocation(self, program, name, &out)) {
                .okay => out,
                .panic => null,
            };
        }
        pub fn getUniformBlockIndex(self: *const Self, program: Gl.Program, name: [:0]const u8) ?u32 {
            var out: u32 = undefined;
            return switch(self.host_getUniformBlockIndex(self, program, name, &out)) {
                .okay => out,
                .panic => null,
            };
        }
        pub fn clearColor(self: *const Self, r: f32, g: f32, b: f32, a: f32) void { return self.host_clearColor(self, r, g, b, a); }
        pub fn clear(self: *const Self, mask: Gl.ClearMask) void { return self.host_clear(self, mask); }
        pub fn clearDepth(self: *const Self, depth: f32) void { return self.host_clearDepth(self, depth); }
        pub fn enable(self: *const Self, cap: Gl.Capability) void { return self.host_enable(self, cap); }
        pub fn disable(self: *const Self, cap: Gl.Capability) void { return self.host_disable(self, cap); }
        pub fn drawArrays(self: *const Self, mode: Gl.Primitive, first: u32, count: u32) void { return self.host_drawArrays(self, mode, first, count); }
        pub fn drawElements(self: *const Self, mode: Gl.Primitive, count: u32, ty: Gl.Type, indices: u32) void { return self.host_drawElements(self, mode, count, ty, indices); }
    };
};

pub const Gl = struct {
    pub const VertexArray = enum(u32) {
        invalid = 0,
        _,
    };

    pub const Buffer = enum(u32) {
        invalid = 0,
        _,
    };

    pub const Shader = enum(u32) {
        invalid = 0,
        _,
    };

    pub const Program = enum(u32) {
        invalid = 0,
        _,
    };

    // these values must match exactly to OpenGl 4.5

    pub const BufferTarget = enum(u32) {
        /// Vertex attributes
        array_buffer = 0x8892,
        /// Atomic counter storage
        atomic_counter_buffer = 0x92C0,
        /// Buffer copy source
        copy_read_buffer = 0x8F36,
        /// Buffer copy destination
        copy_write_buffer = 0x8F37,
        /// Indirect compute dispatch commands
        dispatch_indirect_buffer = 0x90EE,
        /// Indirect command arguments
        draw_indirect_buffer = 0x8F3F,
        /// Vertex array indices
        element_array_buffer = 0x8893,
        /// Pixel read target
        pixel_pack_buffer = 0x88EB,
        /// Texture data source
        pixel_unpack_buffer = 0x88EC,
        /// Query result buffer
        query_buffer = 0x9192,
        /// Read-write storage for shaders
        shader_storage_buffer = 0x90D2,
        /// Texture data buffer
        texture_buffer = 0x8C2A,
        /// Transform feedback buffer
        transform_feedback_buffer = 0x8C8E,
        /// Uniform block storage
        uniform_buffer = 0x8A11,
    };

    pub const BufferUsage = enum(u32) {
        stream_draw = 0x88E0,
        stream_read = 0x88E1,
        stream_copy = 0x88E2,
        static_draw = 0x88E4,
        static_read = 0x88E5,
        static_copy = 0x88E6,
        dynamic_draw = 0x88E8,
        dynamic_read = 0x88E9,
        dynamic_copy = 0x88EA,
    };

    pub const BufferStorageFlags = packed struct(u8) {
        dynamic_storage: bool = false,
        map_read: bool = false,
        map_write: bool = false,
        map_persistent: bool = false,
        map_coherent: bool = false,
        client_storage: bool = false,
        _unused: u2 = 0,
    };

    pub const Type = enum(u32) {
        byte = 0x1400,
        short = 0x1402,
        int = 0x1404,
        fixed = 0x140C,
        float = 0x1406,
        half_float = 0x140B,
        double = 0x140A,
        unsigned_byte = 0x1401,
        unsigned_short = 0x1403,
        unsigned_int = 0x1405,
        int_2_10_10_10_rev = 0x8D9F,
        unsigned_int_2_10_10_10_rev = 0x8368,
        unsigned_int_10_f_11_f_11_f_rev = 0x8C3B,
    };

    pub const ShaderType = enum(u32) {
        compute = 0x91B9,
        vertex = 0x8B31,
        tess_control = 0x8E88,
        tess_evaluation = 0x8E87,
        geometry = 0x8DD9,
        fragment = 0x8B30,
    };

    pub const ShaderParameter = enum(u32) {
        shader_type = 0x8B4F,
        delete_status = 0x8B80,
        compile_status = 0x8B81,
        info_log_length = 0x8B84,
        shader_source_length = 0x8B88,
    };

    pub const ProgramParameter = enum(u32) {
        delete_status = 0x8B80,
        link_status = 0x8B82,
        validate_status = 0x8B83,
        info_log_length = 0x8B84,
        attached_shaders = 0x8B85,
        active_atomic_counter_buffers = 0x92D9,
        active_attributes = 0x8B89,
        active_attribute_max_length = 0x8B8A,
        active_uniforms = 0x8B86,
        active_uniform_blocks = 0x8A36,
        active_uniform_block_max_name_length = 0x8A35,
        active_uniform_max_length = 0x8B87,
        compute_work_group_size = 0x8267,
        program_binary_length = 0x8741,
        program_binary_retrievable_hint = 0x8257,
        program_separable = 0x8258,
        transform_feedback_buffer_mode = 0x8C7F,
        transform_feedback_varyings = 0x8C83,
        transform_feedback_varying_max_length = 0x8C76,
        geometry_vertices_out = 0x8916,
        geometry_input_type = 0x8917,
        geometry_output_type = 0x8918,
    };

    pub const DrawMode = enum(u32) {
        point = 0x1B00,
        line = 0x1B01,
        fill = 0x1B02,
    };

    pub const Primitive = enum(u32) {
        points = 0x0000,
        lines = 0x0001,
        line_loop = 0x0002,
        line_strip = 0x0003,
        triangles = 0x0004,
        triangle_strip = 0x0005,
        triangle_fan = 0x0006,
        lines_adjacency = 0x000A,
        line_strip_adjacency = 0x000B,
        triangles_adjacency = 0x000C,
        triangle_strip_adjacency = 0x000D,
        patches = 0x000E,
    };

    pub const ClearMask = packed struct(u8) {
        color: bool = false,
        depth: bool = false,
        stencil: bool = false,
        _unused: u5 = 0,
    };

    pub const MapAccess = enum(u32) {
        read_only = 0x88B8,
        write_only = 0x88B9,
        read_write = 0x88BA,
    };

    pub const Capability = enum(u32) {
        blend = 0x0BE2,
        // clip_distance = rgl.binding.CLIP_DISTANCE,
        color_logic_op = 0x0BF2,
        cull_face = 0x0B44,
        debug_output = 0x92E0,
        debug_output_synchronous = 0x8242,
        depth_clamp = 0x864F,
        depth_test = 0x0B71,
        dither = 0x0BD0,
        framebuffer_srgb = 0x8DB9,
        line_smooth = 0x0B20,
        multisample = 0x809D,
        polygon_offset_fill = 0x8037,
        polygon_offset_line = 0x2A02,
        polygon_offset_point = 0x2A01,
        polygon_smooth = 0x0B41,
        primitive_restart = 0x8F9D,
        primitive_restart_fixed_index = 0x8D69,
        rasterizer_discard = 0x8C89,
        sample_alpha_to_coverage = 0x809E,
        sample_alpha_to_one = 0x809F,
        sample_coverage = 0x80A0,
        sample_shading = 0x8C36,
        sample_mask = 0x8E51,
        scissor_test = 0x0C11,
        stencil_test = 0x0B90,
        texture_cube_map_seamless = 0x884F,
        program_point_size = 0x8642,
    };
};

pub const Module = extern struct {
    // these fields are set by the module; on_start must be set by the dyn lib's initializer
    on_start: *const fn () callconv(.c) Signal,
    on_stop: ?*const fn () callconv(.c) Signal = null,
    on_step: ?*const fn () callconv(.c) Signal = null,

    // this field is set by the module system just before calling on_start
    host: *HostApi = undefined,

    pub fn fromNamespace(comptime ns: type) Module {
        const log = std.log.scoped(.api);

        return Module {
            .on_start = struct {
                pub export fn module_start() callconv(.c) Signal {
                    ns.on_start() catch |err| {
                        log.err("failed to start module: {}", .{err});
                        return .panic;
                    };

                    return .okay;
                }
            }.module_start,

            .on_step = if (comptime @hasDecl(ns, "on_step")) struct {
                pub export fn module_step() callconv(.c) Signal {
                    ns.on_step() catch |err| {
                        log.err("failed to step module: {}", .{err});
                        return .panic;
                    };

                    return .okay;
                }
            }.module_step else null,

            .on_stop = if (comptime @hasDecl(ns, "on_stop")) struct {
                pub export fn module_stop() callconv(.c) Signal {
                    ns.on_stop() catch |err| {
                        log.err("failed to stop module: {}", .{err});
                        return .panic;
                    };

                    return .okay;
                }
            }.module_stop else null,
        };
    }
};

pub const AllocatorSet = struct {
    collection: std.mem.Allocator,
    temp: std.mem.Allocator,
    last_frame: std.mem.Allocator,
    frame: std.mem.Allocator,
    long_term: std.mem.Allocator,
    static: std.mem.Allocator,
};

pub const CollectionAllocator = struct {
    backing_allocator: *const anyopaque,
    vtable: *const VTable,

    pub fn allocator(self: *CollectionAllocator) std.mem.Allocator {
        var out: std.mem.Allocator = undefined;
        (self.vtable.allocator orelse unreachable)(self, &out);
        return out;
    }

    pub fn reset(self: *CollectionAllocator) void {
        (self.vtable.reset orelse unreachable)(self);
    }

    pub const VTable = struct {
        allocator: ?*const fn (*CollectionAllocator, *std.mem.Allocator) callconv(.c) void,
        reset: ?*const fn (*CollectionAllocator) callconv(.c) void,
    };
};

pub const Heap = struct {
    collection: CollectionAllocator,
    temp: std.heap.ArenaAllocator,
    last_frame: std.heap.ArenaAllocator,
    frame: std.heap.ArenaAllocator,
    long_term: std.heap.ArenaAllocator,
    static: std.heap.ArenaAllocator,
};

pub fn View(comptime T: type) type {
    return union(enum) {
        const Self = @This();

        owned_buf: []T,
        borrowed_buf: []const T,

        pub fn owned(b: []T) Self {
            return Self{ .owned_buf = b };
        }

        pub fn borrowed(b: []const T) Self {
            return Self{ .borrowed_buf = b };
        }

        pub fn toOwned(self: Self, allocator: std.mem.Allocator) std.mem.Allocator.Error![]T {
            if (self == .owned_buf) return self.owned_buf;

            return allocator.dupe(T, self.borrowed_buf);
        }

        pub fn toBorrowed(self: Self) []const T {
            return switch (self) {
                inline else => |x| x,
            };
        }

        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            if (self == .owned_buf) allocator.free(self.owned_buf);
        }
    };
}



pub const Key = enum(u8) {
    close_menu,
};
