const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zimalloc_dep = b.dependency("zimalloc", .{
        .target = target,
        .optimize = optimize,
    });

    const zlfw_dep = b.dependency("zlfw", .{
        .target = target,
        .optimize = optimize,
    });
    const zgl_dep = b.dependency("zgl", .{
        .target = target,
        .optimize = optimize,
    });

    const HostApi_mod = b.createModule(.{
        .root_source_file = b.path("src/framework/HostApi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const module_system_mod = b.createModule(.{
        .root_source_file = b.path("src/framework/module_system.zig"),
        .target = target,
        .optimize = optimize,
    });

    const framework_mod = b.createModule(.{
        .root_source_file = b.path("src/framework/framework.zig"),
        .target = target,
        .optimize = optimize,
    });

    const gl_mod = b.createModule(.{
        .root_source_file = b.path("src/guest/gl.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/host/main.zig"),
        .target = target,
        .optimize = optimize,
        // FIXME: currently, due to a bug in std.DynLib, we need libc really to have any globals in dyn libs.
        .link_libc = true,
    });

    HostApi_mod.addImport("zimalloc", zimalloc_dep.module("zimalloc"));

    module_system_mod.addImport("HostApi", HostApi_mod);
    framework_mod.addImport("HostApi", HostApi_mod);
    framework_mod.addImport("module_system", module_system_mod);
    
    exe_mod.addImport("framework", framework_mod);
    exe_mod.addImport("zlfw", zlfw_dep.module("zlfw"));
    exe_mod.addImport("zgl", zgl_dep.module("zgl"));

    gl_mod.addImport("framework", framework_mod);

    const exe = b.addExecutable(.{
        .name = "host",
        .root_module = exe_mod,
    });

    const gl = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "gl",
        .root_module = gl_mod,
    });

    const install = b.default_step;
    install.dependOn(&b.addInstallArtifact(exe, .{}).step);
    install.dependOn(&b.addInstallArtifact(gl, .{}).step);

    const lib = b.step("lib", "Build the modules");
    lib.dependOn(&b.addInstallArtifact(gl, .{}).step);

    const run = b.step("run", "Run the proto");

    exe.step.dependOn(lib);
    run.dependOn(&b.addRunArtifact(exe).step);
}
