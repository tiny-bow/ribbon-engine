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

    const Application_mod = b.createModule(.{
        .root_source_file = b.path("src/host/Application.zig"),
        .target = target,
        .optimize = optimize,
    });

    const module_system_mod = b.createModule(.{
        .root_source_file = b.path("src/host/module_system.zig"),
        .target = target,
        .optimize = optimize,
    });

    const HostApi_mod = b.createModule(.{
        .root_source_file = b.path("src/HostApi.zig"),
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
        // FIXME: currently, due to a bug in std.DynLib, we need libc on host in order to have any globals in dyn libs.
        .link_libc = true,
    });

    Application_mod.addImport("zimalloc", zimalloc_dep.module("zimalloc"));
    Application_mod.addImport("zlfw", zlfw_dep.module("zlfw"));
    Application_mod.addImport("zgl", zgl_dep.module("zgl"));
    Application_mod.addImport("HostApi", HostApi_mod);
    Application_mod.addImport("module_system", module_system_mod);

    module_system_mod.addImport("HostApi", HostApi_mod);
    
    exe_mod.addImport("Application", Application_mod);

    gl_mod.addImport("HostApi", HostApi_mod);

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
