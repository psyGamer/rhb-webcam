const std = @import("std");
const tk = @import("tokamak");

const Env = @import("main.zig").Env;
const Timestamp = @import("Timestamp.zig");
const sendFile = @import("static.zig").sendFile;

pub fn handler(arena: std.mem.Allocator, ctx: *tk.Context, env: *Env, path: []const u8) anyerror!void {
    const extension = ".mp4";
    if (!std.mem.endsWith(u8, path, extension) or !Timestamp.isValid(path[0..(path.len - extension.len)])) return;

    const day = path[0.."YYYY-MM-DD".len];

    const videoPath = try std.fs.path.join(arena, &.{ env.key(.WEBCAM_VIDEO_ARCHIVE), day, path });
    if (std.fs.cwd().openFile(videoPath, .{})) |file| {
        defer file.close();

        // All videos are static
        ctx.res.header("Cache-Control", "public, max-age=604800, immutable");

        try sendFile(ctx, file, "video/mp4");
    } else |err| {
        std.log.err("Failed to access video '{s}': {}", .{ videoPath, err });

        ctx.res.status = @intFromEnum(std.http.Status.not_found);
        ctx.res.body = "Failed to access source video";
        ctx.responded = true;
        return;
    }
}
