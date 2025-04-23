const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zimalloc_dep = b.dependency("zimalloc", .{
        .target = target,
        .optimize = optimize,
    });

    const rlfw_dep = b.dependency("rlfw", .{
        .target = target,
        .optimize = optimize,
    });
    const rgl_dep = b.dependency("rgl", .{
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

    const gl1_mod = b.createModule(.{
        .root_source_file = b.path("src/guest/gl1.zig"),
        .target = target,
        .optimize = optimize,
    });

    const gl2_mod = b.createModule(.{
        .root_source_file = b.path("src/guest/gl2.zig"),
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
    Application_mod.addImport("rlfw", rlfw_dep.module("rlfw"));
    Application_mod.addImport("rgl", rgl_dep.module("rgl"));
    Application_mod.addImport("HostApi", HostApi_mod);
    Application_mod.addImport("module_system", module_system_mod);

    module_system_mod.addImport("HostApi", HostApi_mod);
    module_system_mod.addImport("zimalloc", zimalloc_dep.module("zimalloc"));

    exe_mod.addImport("Application", Application_mod);

    gl1_mod.addImport("HostApi", HostApi_mod);
    gl2_mod.addImport("HostApi", HostApi_mod);

    const exe = b.addExecutable(.{
        .name = "host",
        .root_module = exe_mod,
    });

    const gl1 = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "gl1",
        .root_module = gl1_mod,
    });

    const gl2 = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "gl2",
        .root_module = gl2_mod,
    });

    const lib = b.step("lib", "Build the modules");
    lib.dependOn(&b.addInstallArtifact(gl1, .{}).step);
    lib.dependOn(&b.addInstallArtifact(gl2, .{}).step);

    exe.step.dependOn(lib);

    const install = b.default_step;
    install.dependOn(&b.addInstallArtifact(exe, .{}).step);

    const run = b.step("run", "Run the proto");
    run.dependOn(&b.addRunArtifact(exe).step);
}
