const std = @import("std");
const tk = @import("tokamak");
const fr = @import("fridge");

const user_frontend = @import("user-frontend");

const Timestamp = @import("common").Timestamp;

/// Show a specific capture rom the Filisur webcam
pub fn filisurLatest(ctx: *tk.Context, db: *fr.Session) !void {
    const latest = try db.raw("SELECT file FROM " ++ @import("../database.zig").FilisurCapture.sql_table_name, .{})
        .orderBy("file DESC")
        .fetchOne([]const u8) orelse return error.MissingData;

    // Setup template data
    const image_view_opts: user_frontend.ImageVideoViewOptions = .{
        .title = "Aktuelle Aufnahme",
        .source = .filisur_new,
        .time = Timestamp.parseSimpleTime(latest) orelse return error.InvalidTimestamp,
        .path = latest[0..Timestamp.time_fmt.len].*,
        .has_video = true,
    };

    try user_frontend.imageVideoView(ctx.res.writer(), image_view_opts);

    // Cache for 5 minutes
    ctx.res.header("Cache-Control", "public, max-age=60");

    ctx.res.body = ctx.res.buffer.written();
    ctx.res.content_type = .HTML;
    ctx.responded = true;
}
