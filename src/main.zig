const std = @import("std");
const log = std.log.scoped(.main);
const Application = @import("Application");

pub const std_options = std.Options{
    .log_level = .info,
};

pub const Transform = struct {
    position: Application.linalg.V2f,
};

pub const Velocity = struct {
    vector: Application.linalg.V2f,
};

pub fn main() !void {
    log.info("main start", .{});

    var app = try Application.init();
    defer app.deinit();

    var ecs: Application.ecs.Universe = .empty;
    defer ecs.deinit(&app.api);

    const ent0 = ecs.createEntityFromPrototype(&app.api, .{
        .flags = .{},
        .components = .{
            Transform { .position = .{ -10, 0 } },
            Velocity { .vector = .{ 1, 0 } },
        },
    });

    const ent1 = ecs.createEntityFromPrototype(&app.api, .{
        .flags = .{},
        .components = .{
            Transform { .position = .{ 10, 0 } },
            Velocity { .vector = .{ -1, 0 } },
        },
    });

    std.debug.print("ent0: {}\n", .{ent0});
    std.debug.print("  transform: {}\n", .{ecs.getComponent(&app.api, ent0, Transform).?});
    std.debug.print("  velocity: {}\n", .{ecs.getComponent(&app.api, ent0, Velocity).?});
    std.debug.print("ent1: {}\n", .{ent1});
    std.debug.print("  transform: {}\n", .{ecs.getComponent(&app.api, ent1, Transform).?});
    std.debug.print("  velocity: {}\n", .{ecs.getComponent(&app.api, ent1, Velocity).?});

    // const x = try Application.assets.discover(&app.api);
    // var y = try Application.assets.analyze(&app.api, x);
    // defer y.deinit(&app.api);

    // y.dump();

    // const scc = try Application.assets.tarjan_scc(&app.api, &y);

    // log.info("SCCs:", .{});
    // for (scc.items, 1..) |component, i| {
    //     log.info("  {}:", .{i});
    //     for (component.items) |mod| {
    //         log.info("    {s}", .{mod});
    //     }
    // }


    try app.loop();

    log.info("main end", .{});
}
