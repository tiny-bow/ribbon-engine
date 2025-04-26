const std = @import("std");
const log = std.log.scoped(.main);
const Application = @import("Application");

pub const std_options = std.Options{
    .log_level = .info,
};


pub fn main() !void {
    log.info("main start", .{});

    var app = try Application.init();
    defer app.deinit();

    const x = try Application.assets.discover(&app.api);
    var y = try Application.assets.analyze(&app.api, x);
    defer y.deinit(&app.api);

    y.dump();


    // app.loop();

    log.info("main end", .{});
}
