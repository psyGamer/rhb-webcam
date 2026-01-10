const std = @import("std");
const tk = @import("tokamak");

const Env = @import("main.zig").Env;
const Timestamp = @import("common").Timestamp;
const sendFile = @import("static.zig").sendFile;

pub fn handler(arena: std.mem.Allocator, ctx: *tk.Context, env: *Env, path: []const u8) anyerror!void {
    if (!Timestamp.isValid(path)) return;

    const day = path[0.."YYYY-MM-DD".len];

    const video_extension = ".mp4";
    var video_name: [Timestamp.fmt.len + video_extension.len]u8 = undefined;
    video_name[0..Timestamp.fmt.len].* = path[0..Timestamp.fmt.len].*;
    video_name[(video_name.len - video_extension.len)..][0..video_extension.len].* = video_extension.*;

    const video_path = try std.fs.path.join(arena, &.{ env.key(.WEBCAM_VIDEO_ARCHIVE), day, &video_name });
    if (std.fs.cwd().openFile(video_path, .{})) |file| {
        defer file.close();

        // All videos are static
        ctx.res.header("Cache-Control", "public, max-age=604800, immutable");

        try sendFile(ctx, file, "video/mp4");
    } else |err| {
        std.log.err("Failed to access video '{s}': {}", .{ video_path, err });

        ctx.res.status = @intFromEnum(std.http.Status.not_found);
        ctx.res.body = "Failed to access source video";
        ctx.responded = true;
        return;
    }
}
