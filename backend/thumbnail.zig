const std = @import("std");
const tk = @import("tokamak");

const Env = @import("main.zig").Env;
const Timestamp = @import("Timestamp.zig");
const sendFile = @import("static.zig").sendFile;

pub fn handler(arena: std.mem.Allocator, ctx: *tk.Context, env: *Env, path: []const u8) anyerror!void {
    const extension = ".png";
    if (!std.mem.endsWith(u8, path, extension) or !Timestamp.isValid(path[0..(path.len - extension.len)])) return;

    const day = path[0.."YYYY-MM-DD".len];

    const thumbnailPath = try std.fs.path.join(arena, &.{ env.key(.THUMBNAIL_CACHE), day, path });
    if (std.fs.cwd().openFile(thumbnailPath, .{})) |file| {
        defer file.close();

        // All videos are static and therefore all thumbnails too
        ctx.res.header("Cache-Control", "public, max-age=604800, immutable");

        try sendFile(ctx, file, "image/png");
    } else |_| {
        const videoName = try arena.dupe(u8, path);
        const videoExtension: *[3]u8 = videoName[(videoName.len - 3)..][0..3];
        videoExtension.* = "mp4".*;

        const videoPath = try std.fs.path.join(arena, &.{ env.key(.WEBCAM_VIDEO_ARCHIVE), day, videoName });
        std.log.info("Generating thumbnail for video '{s}'...", .{videoPath});

        // Early access check to give a better status code
        std.fs.cwd().access(videoPath, .{ .mode = .read_only }) catch |err| {
            std.log.err("Failed to access video '{s}': {}", .{ videoPath, err });

            ctx.res.status = @intFromEnum(std.http.Status.not_found);
            ctx.res.body = "Failed to access source video";
            ctx.responded = true;
            return;
        };
        // Ensure the target directory exists
        try std.fs.cwd().makePath(try std.fs.path.join(arena, &.{ env.key(.THUMBNAIL_CACHE), day }));

        const res = std.process.Child.run(.{
            .allocator = arena,
            .argv = &.{ "ffmpegthumbnailer", "-i", videoPath, "-o", thumbnailPath, "-s0", "-t00:00:10" },
        }) catch |err| {
            std.log.err("Failed to spawn 'ffmpegthumbnailer' process for video '{s}': {}", .{ videoPath, err });

            ctx.res.status = @intFromEnum(std.http.Status.internal_server_error);
            ctx.res.body = "Failed to generate thumbnail";
            ctx.responded = true;
            return;
        };

        if (res.term != .Exited or res.term.Exited != 0) {
            std.log.err("Failed to generate thumbnail for video '{s}': {}", .{ videoPath, res.term });
            var line_iter = std.mem.tokenizeAny(u8, res.stderr, "\n\r");
            while (line_iter.next()) |line| {
                std.log.err("    {s}", .{line});
            }

            ctx.res.status = @intFromEnum(std.http.Status.internal_server_error);
            ctx.res.body = "Failed to generate thumbnail";
            ctx.responded = true;
            return;
        }

        const file = std.fs.cwd().openFile(thumbnailPath, .{}) catch |err| {
            std.log.err("Failed to read thumbnail file '{s}': {}", .{ thumbnailPath, err });

            ctx.res.status = @intFromEnum(std.http.Status.internal_server_error);
            ctx.res.body = "Failed to generate thumbnail";
            ctx.responded = true;
            return;
        };
        defer file.close();

        // All videos are static and therefore all thumbnails too
        ctx.res.header("Cache-Control", "public, max-age=604800, immutable");

        try sendFile(ctx, file, "image/png");
    }
}
