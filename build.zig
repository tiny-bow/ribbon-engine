const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const HostApi_mod = b.createModule(.{
        .root_source_file = b.path("src/framework/HostApi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const Module_mod = b.createModule(.{
        .root_source_file = b.path("src/framework/Module.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    Module_mod.addImport("HostApi", HostApi_mod);
    exe_mod.addImport("HostApi", HostApi_mod);
    exe_mod.addImport("Module", Module_mod);
    lib_mod.addImport("HostApi", HostApi_mod);

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
