const std = @import("std");
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ribbon_dep = b.dependency("ribbon_engine", .{
        .target = target,
        .optimize = optimize,
    });

    const HostApi_mod = ribbon_dep.module("HostApi");

    const base_mod = b.createModule(.{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });

    base_mod.addImport("HostApi", HostApi_mod);

    const base = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "base",
        .root_module = base_mod,
    });

    // TODO: cross compile gnu targets, concatenate into .bin file

    b.default_step.dependOn(&b.addInstallArtifact(base, .{
        .dest_dir = .{ .override = .{ .custom = "../../assets/base" } },
        .dest_sub_path = "base.bin",
    }).step);
}
