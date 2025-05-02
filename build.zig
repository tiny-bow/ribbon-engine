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

    const rui_dep = b.dependency("rui", .{
        .target = target,
        .optimize = optimize,
        .backend = .custom,
    });

    const roml_dep = b.dependency("roml", .{
        .target = target,
        .optimize = optimize,
    });

    const Application_mod = b.addModule("Application", .{
        .root_source_file = b.path("src/Application.zig"),
        .target = target,
        .optimize = optimize,
    });

    const assets_mod = b.createModule(.{
        .root_source_file = b.path("src/assets.zig"),
        .target = target,
        .optimize = optimize,
    });

    const HostApi_mod = b.addModule("HostApi", .{
        .root_source_file = b.path("src/HostApi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const HostApi_impl_mod = b.createModule(.{
        .root_source_file = b.path("src/HostApi_impl.zig"),
        .target = target,
        .optimize = optimize,
    });

    const Window_mod = b.createModule(.{
        .root_source_file = b.path("src/Window.zig"),
        .target = target,
        .optimize = optimize,
    });

    const input_mod = b.createModule(.{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    });

    const linalg_mod = b.createModule(.{
        .root_source_file = b.path("src/linalg.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // FIXME: currently, due to a bug/nyi details in std.DynLib, we need libc on host in order to have any globals in dyn libs.
        .link_libc = true,
    });

    Application_mod.addImport("zimalloc", zimalloc_dep.module("zimalloc"));
    Application_mod.addImport("rlfw", rlfw_dep.module("rlfw"));
    Application_mod.addImport("rgl", rgl_dep.module("rgl"));
    Application_mod.addImport("HostApi", HostApi_mod);
    Application_mod.addImport("HostApi_impl", HostApi_impl_mod);
    Application_mod.addImport("assets", assets_mod);
    Application_mod.addImport("Window", Window_mod);

    HostApi_impl_mod.addImport("Application", Application_mod);
    HostApi_impl_mod.addImport("HostApi", HostApi_mod);
    HostApi_impl_mod.addImport("assets", assets_mod);
    HostApi_impl_mod.addImport("rgl", rgl_dep.module("rgl"));

    Window_mod.addImport("rlfw", rlfw_dep.module("rlfw"));
    Window_mod.addImport("rgl", rgl_dep.module("rgl"));
    Window_mod.addImport("rui", rui_dep.module("rui"));
    Window_mod.addImport("HostApi", HostApi_mod);
    Window_mod.addImport("Application", Application_mod);
    Window_mod.addImport("input", input_mod);

    rui_dep.module("rui").addImport("backend", Window_mod);

    assets_mod.addImport("HostApi", HostApi_mod);
    assets_mod.addImport("zimalloc", zimalloc_dep.module("zimalloc"));
    assets_mod.addImport("rgl", rgl_dep.module("rgl"));
    assets_mod.addImport("roml", roml_dep.module("roml"));

    input_mod.addImport("linalg", linalg_mod);

    exe_mod.addImport("Application", Application_mod);




    const exe = b.addExecutable(.{
        .name = "host",
        .root_module = exe_mod,
    });

    const test_exe = b.addTest(.{
        .name = "host_test",
        .root_module = exe_mod,
    });

    const check = b.step("check", "Run semantic analysis");
    check.dependOn(&test_exe.step);


    const install = b.default_step;
    install.dependOn(&b.addInstallArtifact(exe, .{}).step);

    const run = b.step("run", "Run the proto");
    run.dependOn(&b.addRunArtifact(exe).step);
}
