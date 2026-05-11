const std = @import("std");
const tk = @import("tokamak");
const fr = @import("fridge");

const user_frontend = @import("user-frontend");
const database = @import("../database.zig");

const Timestamp = @import("common").Timestamp;
const Location = @import("common").Location;

/// Show the latest capture from a webcam
pub fn latest(comptime location: Location) tk.Route {
    const Capture = switch (location) {
        .filisur => database.FilisurCapture,
        .landwasser => database.LandwasserCapture,
        .landquart => database.LandquartCapture,
        .brusio => database.BrusioCapture,
        .livestream => database.LivestreamCapture,
    };

    const H = struct {
        pub fn handle(ctx: *tk.Context) anyerror!void {
            const db = try ctx.injector.get(*fr.Session);

            const query = db.raw("SELECT file FROM " ++ Capture.sql_table_name, .{})
                .orderBy("file DESC");

            var stmt = try query.prepare();
            defer stmt.deinit();

            const latest_entry = try stmt.next([]const u8, query.db.arena) orelse return error.MissingData;
            const previous_entry = try stmt.next([]const u8, query.db.arena);

            // Setup template data
            const image_view_opts: user_frontend.ImageVideoViewOptions = .{
                .title = "Aktuelle Aufnahme",
                .source = switch (location) {
                    .filisur => .filisur_new,
                    .landwasser => .landwasser,
                    .landquart => .landquart,
                    .brusio => .brusio,
                    .livestream => .livestream,
                },
                .time = Timestamp.parseSimpleTime(latest_entry) orelse return error.InvalidTimestamp,
                .path = latest_entry[0..Timestamp.time_fmt.len].*,
                .next = null,
                .prev = if (previous_entry) |prev| prev[0..Timestamp.time_fmt.len].* else null,
                .has_video = switch (location) {
                    .filisur, .livestream => true,
                    .landwasser, .landquart, .brusio => false,
                },
            };

            try user_frontend.imageVideoView(ctx.res.writer(), image_view_opts);

            // Cache for 5 minutes
            ctx.res.header("Cache-Control", "public, max-age=60");

            ctx.res.body = ctx.res.buffer.written();
            ctx.res.content_type = .HTML;
            ctx.responded = true;
        }
    };

    return .{ .handler = &H.handle };
}
