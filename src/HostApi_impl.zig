const HostApi_impl = @This();

const std = @import("std");
const app_log = std.log.scoped(.app);

const HostApi = @import("HostApi");
const G = HostApi;
const rgl = @import("rgl");
const assets = @import("assets");
const Application = @import("Application");


fn convert_buffer_storage_flags(flags: G.Gl.BufferStorageFlags) rgl.binding.GLbitfield {
    var flag_bits: rgl.binding.GLbitfield = 0;
    if (flags.map_read) flag_bits |= rgl.binding.MAP_READ_BIT;
    if (flags.map_write) flag_bits |= rgl.binding.MAP_WRITE_BIT;
    if (flags.map_persistent) flag_bits |= rgl.binding.MAP_PERSISTENT_BIT;
    if (flags.map_coherent) flag_bits |= rgl.binding.MAP_COHERENT_BIT;
    if (flags.client_storage) flag_bits |= rgl.binding.CLIENT_STORAGE_BIT;
    return flag_bits;
}

fn enumCast(comptime T: type, value: anytype) T {
    return @enumFromInt(@intFromEnum(value));
}


pub const log = struct {
    pub const log = std.io.getStdErr().writer().any();

    pub fn lock_mutex(self: *const G.Api.log) callconv(.c) void {
        _ = self;
        std.debug.lockStdErr();
    }

    pub fn unlock_mutex(self: *const G.Api.log) callconv(.c) void {
        _ = self;
        std.debug.unlockStdErr();
    }
};

pub const binary = struct {
    pub fn lookupBinary(self: *const G.Api.binary, name: *const []const u8, out: **G.Binary) callconv(.c) G.Signal {
        _ = self;
        _ = name;
        _ = out;

        // out.* = @ptrCast(assets.lookupBinary(name.*) catch { FIXME
        //     return .panic;
        // });
        return .okay;
    }

    pub fn lookupAddress(self: *const G.Api.binary, ref: *G.Binary, name: *const [:0]const u8, out: **anyopaque) callconv(.c) G.Signal {
        _ = self;
        const bin: *assets.Binary = @alignCast(@constCast(@ptrCast(ref)));
        out.* = bin.lookup(anyopaque, name.*) catch {
            return .panic;
        };
        return .okay;
    }
};

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
        const vao = rgl.createVertexArray();
        const out = enumCast(G.Gl.VertexArray, vao);
        app_log.info("created vao: {x}, {x}", .{@intFromEnum(vao), @intFromEnum(out)});
        return out;
    }

    pub fn deleteVertexArray(self: *const G.Api.gl, vao: G.Gl.VertexArray) callconv(.c) void {
        _ = self;
        rgl.deleteVertexArray(enumCast(rgl.VertexArray, vao));
    }

    pub fn bindVertexArray(self: *const G.Api.gl, vao: G.Gl.VertexArray) callconv(.c) void {
        _ = self;
        rgl.bindVertexArray(enumCast(rgl.VertexArray, vao));
    }

    pub fn unbindVertexArray(self: *const G.Api.gl) callconv(.c) void {
        _ = self;
        rgl.bindVertexArray(.invalid);
    }

    pub fn enableVertexArrayAttrib(self: *const G.Api.gl, vao: G.Gl.VertexArray, index: u32) callconv(.c) void {
        _ = self;
        rgl.enableVertexArrayAttrib(enumCast(rgl.VertexArray, vao), index);
    }

    pub fn disableVertexArrayAttrib(self: *const G.Api.gl, vao: G.Gl.VertexArray, index: u32) callconv(.c) void {
        _ = self;
        rgl.disableVertexArrayAttrib(enumCast(rgl.VertexArray, vao), index);
    }

    pub fn vertexArrayAttribFormat(self: *const G.Api.gl, vao: G.Gl.VertexArray, index: u32, size: u32, ty: G.Gl.Type, normalized: bool, relative_offset: u32) callconv(.c) void {
        _ = self;
        rgl.vertexArrayAttribFormat(enumCast(rgl.VertexArray, vao), index, size, enumCast(rgl.Type, ty), normalized, relative_offset);
    }

    pub fn vertexArrayAttribIFormat(self: *const G.Api.gl, vao: G.Gl.VertexArray, index: u32, size: u32, ty: G.Gl.Type, relative_offset: u32) callconv(.c) void {
        _ = self;
        rgl.vertexArrayAttribIFormat(enumCast(rgl.VertexArray, vao), index, size, enumCast(rgl.Type, ty), relative_offset);
    }

    pub fn vertexArrayAttribLFormat(self: *const G.Api.gl, vao: G.Gl.VertexArray, index: u32, size: u32, ty: G.Gl.Type, relative_offset: u32) callconv(.c) void {
        _ = self;
        rgl.vertexArrayAttribLFormat(enumCast(rgl.VertexArray, vao), index, size, enumCast(rgl.Type, ty), relative_offset);
    }

    pub fn vertexArrayAttribBinding(self: *const G.Api.gl, vao: G.Gl.VertexArray, index: u32, binding: u32) callconv(.c) void {
        _ = self;
        rgl.vertexArrayAttribBinding(enumCast(rgl.VertexArray, vao), index, binding);
    }

    pub fn vertexArrayVertexBuffer(self: *const G.Api.gl, vao: G.Gl.VertexArray, buffer: G.Gl.Buffer, binding_index: u32, offset: u32, stride: u32) callconv(.c) void {
        _ = self;
        rgl.vertexArrayVertexBuffer(enumCast(rgl.VertexArray, vao), binding_index, enumCast(rgl.Buffer, buffer), offset, stride);
    }

    pub fn vertexArrayElementBuffer(self: *const G.Api.gl, vao: G.Gl.VertexArray, buffer: G.Gl.Buffer) callconv(.c) void {
        _ = self;
        rgl.vertexArrayElementBuffer(enumCast(rgl.VertexArray, vao), enumCast(rgl.Buffer, buffer));
    }

    pub fn vertexAttribPointer(self: *const G.Api.gl, index: u32, size: u32, ty: G.Gl.Type, normalized: bool, stride: u32, offset: u32) callconv(.c) void {
        _ = self;
        rgl.vertexAttribPointer(index, size, enumCast(rgl.Type, ty), normalized, stride, offset);
    }

    pub fn vertexAttribIPointer(self: *const G.Api.gl, index: u32, size: u32, ty: G.Gl.Type, stride: u32, offset: u32) callconv(.c) void {
        _ = self;
        rgl.vertexAttribIPointer(index, size, enumCast(rgl.Type, ty), stride, offset);
    }

    pub fn enableVertexAttribArray(self: *const G.Api.gl, index: u32) callconv(.c) void {
        _ = self;
        rgl.enableVertexAttribArray(index);
    }


    pub fn createBuffer(self: *const G.Api.gl) callconv(.c) G.Gl.Buffer {
        _ = self;
        const buffer = rgl.createBuffer();
        return enumCast(G.Gl.Buffer, buffer);
    }

    pub fn deleteBuffer(self: *const G.Api.gl, buffer: G.Gl.Buffer) callconv(.c) void {
        _ = self;
        rgl.deleteBuffer(enumCast(rgl.Buffer, buffer));
    }

    pub fn bindBuffer(self: *const G.Api.gl, buffer: G.Gl.Buffer, target: G.Gl.BufferTarget) callconv(.c) void {
        _ = self;
        rgl.bindBuffer(enumCast(rgl.Buffer, buffer), enumCast(rgl.BufferTarget, target));
    }

    pub fn bufferData(self: *const G.Api.gl, target: G.Gl.BufferTarget, size: u32, data: ?*const anyopaque, usage: G.Gl.BufferUsage) callconv(.c) void {
        _ = self;
        rgl.binding.bufferData(@intFromEnum(target), @intCast(size), data, @intFromEnum(usage));
    }

    pub fn unbindBuffer(self: *const G.Api.gl, target: G.Gl.BufferTarget) callconv(.c) void {
        _ = self;
        rgl.bindBuffer(.invalid, enumCast(rgl.BufferTarget, target));
    }

    pub fn namedBufferData(self: *const G.Api.gl, buffer: G.Gl.Buffer, size: u32, data: ?*const anyopaque, usage: G.Gl.BufferUsage) callconv(.c) void {
        _ = self;
        rgl.binding.namedBufferData(@intFromEnum(buffer), @intCast(size), data, @intFromEnum(usage));
    }

    pub fn namedBufferSubData(self: *const G.Api.gl, buffer: G.Gl.Buffer, offset: u32, size: u32, data: ?*const anyopaque) callconv(.c) void {
        _ = self;
        rgl.binding.namedBufferSubData(@intFromEnum(buffer), offset, @intCast(size), data);
    }

    pub fn namedBufferStorage(self: *const G.Api.gl, buffer: G.Gl.Buffer, size: u32, data: ?*const anyopaque, flags: G.Gl.BufferStorageFlags) callconv(.c) void {
        _ = self;
        rgl.binding.namedBufferStorage(@intFromEnum(buffer), @intCast(size), data, convert_buffer_storage_flags(flags));
    }

    pub fn mapNamedBuffer(self: *const G.Api.gl, buffer: G.Gl.Buffer, access: G.Gl.MapAccess, out: **anyopaque) callconv(.c) G.Signal {
        _ = self;

        const ptr = rgl.binding.mapBuffer(@intFromEnum(buffer), @intFromEnum(access));

        if (ptr) |p| {
            out.* = @ptrCast(p);
            return .okay;
        } else {
            return .panic;
        }
    }

    pub fn unmapNamedBuffer(self: *const G.Api.gl, buffer: G.Gl.Buffer) callconv(.c) bool {
        _ = self;
        return rgl.binding.unmapNamedBuffer(@intFromEnum(buffer)) == 1;
    }


    pub fn createShader(self: *const G.Api.gl, ty: G.Gl.ShaderType) callconv(.c) G.Gl.Shader {
        _ = self;
        return enumCast(G.Gl.Shader, rgl.createShader(enumCast(rgl.ShaderType, ty)));
    }

    pub fn deleteShader(self: *const G.Api.gl, shader: G.Gl.Shader) callconv(.c) void {
        _ = self;
        rgl.deleteShader(enumCast(rgl.Shader, shader));
    }

    pub fn compileShader(self: *const G.Api.gl, shader: G.Gl.Shader) callconv(.c) void {
        _ = self;
        rgl.compileShader(enumCast(rgl.Shader, shader));
    }

    pub fn shaderSource(self: *const G.Api.gl, shader: G.Gl.Shader, count: u32, sources: [*]const [*:0]const u8) callconv(.c) void {
        _ = self;
        rgl.binding.shaderSource(@intFromEnum(shader), @intCast(count), @ptrCast(sources), null);
    }

    pub fn getShaderParameter(self: *const G.Api.gl, shader: G.Gl.Shader, param: G.Gl.ShaderParameter) callconv(.c) i32 {
        _ = self;
        return rgl.getShader(enumCast(rgl.Shader, shader), enumCast(rgl.ShaderParameter, param));
    }

    pub fn getShaderInfoLog(self: *const G.Api.gl, shader: G.Gl.Shader, allocator: *const std.mem.Allocator, out: *[:0]const u8) callconv(.c) G.Signal {
        _ = self;
        const buf = rgl.getShaderInfoLog(enumCast(rgl.Shader, shader), allocator.*) catch |err| {
            app_log.err("failed to get shader info log: {}", .{err});
            return .panic;
        };
        out.* = buf;
        return .okay;
    }


    pub fn createProgram(self: *const G.Api.gl) callconv(.c) G.Gl.Program {
        _ = self;
        return enumCast(G.Gl.Program, rgl.createProgram());
    }

    pub fn deleteProgram(self: *const G.Api.gl, program: G.Gl.Program) callconv(.c) void {
        _ = self;
        rgl.deleteProgram(enumCast(rgl.Program, program));
    }

    pub fn attachShader(self: *const G.Api.gl, program: G.Gl.Program, shader: G.Gl.Shader) callconv(.c) void {
        _ = self;
        rgl.attachShader(enumCast(rgl.Program, program), enumCast(rgl.Shader, shader));
    }

    pub fn detachShader(self: *const G.Api.gl, program: G.Gl.Program, shader: G.Gl.Shader) callconv(.c) void {
        _ = self;
        rgl.detachShader(enumCast(rgl.Program, program), enumCast(rgl.Shader, shader));
    }

    pub fn linkProgram(self: *const G.Api.gl, program: G.Gl.Program) callconv(.c) void {
        _ = self;
        rgl.linkProgram(enumCast(rgl.Program, program));
    }

    pub fn useProgram(self: *const G.Api.gl, program: G.Gl.Program) callconv(.c) void {
        _ = self;
        rgl.useProgram(enumCast(rgl.Program, program));
    }

    pub fn programUniform1ui(self: *const G.Api.gl, program: G.Gl.Program, location: u32, v0: u32) callconv(.c) void {
        _ = self;
        rgl.programUniform1ui(enumCast(rgl.Program, program), location, v0);
    }

    pub fn programUniform1i(self: *const G.Api.gl, program: G.Gl.Program, location: u32, v0: i32) callconv(.c) void {
        _ = self;
        rgl.programUniform1i(enumCast(rgl.Program, program), location, v0);
    }

    pub fn programUniform3ui(self: *const G.Api.gl, program: G.Gl.Program, location: u32, v0: u32, v1: u32, v2: u32) callconv(.c) void {
        _ = self;
        rgl.programUniform3ui(enumCast(rgl.Program, program), location, v0, v1, v2);
    }

    pub fn programUniform3i(self: *const G.Api.gl, program: G.Gl.Program, location: u32, v0: i32, v1: i32, v2: i32) callconv(.c) void {
        _ = self;
        rgl.programUniform3i(enumCast(rgl.Program, program), location, v0, v1, v2);
    }

    pub fn programUniform2i(self: *const G.Api.gl, program: G.Gl.Program, location: u32, v0: i32, v1: i32) callconv(.c) void {
        _ = self;
        rgl.programUniform2i(enumCast(rgl.Program, program), location, v0, v1);
    }
    pub fn programUniform1f(self: *const G.Api.gl, program: G.Gl.Program, location: u32, v0: f32) callconv(.c) void {
        _ = self;
        rgl.programUniform1f(enumCast(rgl.Program, program), location, v0);
    }

    pub fn programUniform2f(self: *const G.Api.gl, program: G.Gl.Program, location: u32, v0: f32, v1: f32) callconv(.c) void {
        _ = self;
        rgl.programUniform2f(enumCast(rgl.Program, program), location, v0, v1);
    }

    pub fn programUniform3f(self: *const G.Api.gl, program: G.Gl.Program, location: u32, v0: f32, v1: f32, v2: f32) callconv(.c) void {
        _ = self;
        rgl.programUniform3f(enumCast(rgl.Program, program), location, v0, v1, v2);
    }

    pub fn programUniform4f(self: *const G.Api.gl, program: G.Gl.Program, location: u32, v0: f32, v1: f32, v2: f32, v3: f32) callconv(.c) void {
        _ = self;
        rgl.programUniform4f(enumCast(rgl.Program, program), location, v0, v1, v2, v3);
    }

    pub fn programUniformMatrix4fv(self: *const G.Api.gl, program: G.Gl.Program, location: u32, count: u32, transpose: bool, value: [*]const f32) callconv(.c) void {
        _ = self;
        rgl.binding.programUniformMatrix4fv(@intFromEnum(program), @intCast(location), @intCast(count), @intFromBool(transpose), value);
    }

    pub fn getProgramParameter(self: *const G.Api.gl, program: G.Gl.Program, param: G.Gl.ProgramParameter) callconv(.c) i32 {
        _ = self;
        return rgl.getProgram(enumCast(rgl.Program, program), enumCast(rgl.ProgramParameter, param));
    }

    pub fn getProgramInfoLog(self: *const G.Api.gl, program: G.Gl.Program, allocator: *const std.mem.Allocator, out: *[:0]const u8) callconv(.c) G.Signal {
        _ = self;
        const buf = rgl.getProgramInfoLog(enumCast(rgl.Program, program), allocator.*) catch |err| {
            app_log.err("failed to get program info log: {}", .{err});
            return .panic;
        };
        out.* = buf;
        return .okay;
    }

    pub fn getUniformLocation(self: *const G.Api.gl, program: G.Gl.Program, name: *const [:0]const u8, out: *u32) callconv(.c) G.Signal {
        _ = self;
        out.* = @intCast(rgl.getUniformLocation(enumCast(rgl.Program, program), name.*) orelse return .panic);
        return .okay;
    }

    pub fn getUniformBlockIndex(self: *const G.Api.gl, program: G.Gl.Program, name: *const [:0]const u8, out: *u32) callconv(.c) G.Signal {
        _ = self;
        out.* = @intCast(rgl.getUniformBlockIndex(enumCast(rgl.Program, program), name.*) orelse return .panic);
        return .okay;
    }


    pub fn clearColor(self: *const G.Api.gl, r: f32, g: f32, b: f32, a: f32) callconv(.c) void {
        _ = self;
        rgl.clearColor(r, g, b, a);
    }

    pub fn clear(self: *const G.Api.gl, mask: G.Gl.ClearMask) callconv(.c) void {
        _ = self;
        rgl.binding.clear(
            @as(rgl.BitField, if (mask.color) rgl.binding.COLOR_BUFFER_BIT else 0) |
            @as(rgl.BitField, if (mask.depth) rgl.binding.DEPTH_BUFFER_BIT else 0) |
            @as(rgl.BitField, if (mask.stencil) rgl.binding.STENCIL_BUFFER_BIT else 0)
        );
    }

    pub fn clearDepth(self: *const G.Api.gl, depth: f32) callconv(.c) void {
        _ = self;
        rgl.clearDepth(depth);
    }

    pub fn enable(self: *const G.Api.gl, cap: G.Gl.Capability) callconv(.c) void {
        _ = self;
        rgl.enable(enumCast(rgl.Capabilities, cap));
    }

    pub fn disable(self: *const G.Api.gl, cap: G.Gl.Capability) callconv(.c) void {
        _ = self;
        rgl.disable(enumCast(rgl.Capabilities, cap));
    }

    pub fn drawArrays(self: *const G.Api.gl, mode: G.Gl.Primitive, first: u32, count: u32) callconv(.c) void {
        _ = self;
        rgl.drawArrays(enumCast(rgl.PrimitiveType, mode), first, count);
    }

    pub fn drawElements(self: *const G.Api.gl, mode: G.Gl.Primitive, count: u32, ty: G.Gl.Type, indices: u32) callconv(.c) void {
        _ = self;
        rgl.drawElements(enumCast(rgl.PrimitiveType, mode), count, enumCast(rgl.ElementType, ty), indices);
    }
};
