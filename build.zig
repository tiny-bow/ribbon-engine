const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zimalloc_dep = b.dependency("zimalloc", .{
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
        .root_source_file = b.path("src/framework.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
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

    lib_mod.addImport("framework", framework_mod);

    const exe = b.addExecutable(.{
        .name = "proto1",
        .root_module = exe_mod,
    });

    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "proto1",
        .root_module = lib_mod,
    });

    const install = b.default_step;
    install.dependOn(&b.addInstallArtifact(exe, .{}).step);
    install.dependOn(&b.addInstallArtifact(lib, .{}).step);

    const build_lib = b.step("lib", "Build the hcm");
    build_lib.dependOn(&b.addInstallArtifact(lib, .{}).step);

    const run = b.step("run", "Run the proto");

    run.dependOn(&b.addInstallArtifact(lib, .{}).step);
    run.dependOn(&b.addRunArtifact(exe).step);
}
