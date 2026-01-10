const std = @import("std");
const tk = @import("tokamak");

const Env = @import("main.zig").Env;
const Timestamp = @import("common").Timestamp;
const sendFile = @import("static.zig").sendFile;

pub fn handler(arena: std.mem.Allocator, ctx: *tk.Context, env: *Env, path: []const u8) anyerror!void {
    if (!Timestamp.isValid(path)) return;

    const day = path[0.."YYYY-MM-DD".len];

    const thumbnail_extension = ".png";
    var thumbnail_name: [Timestamp.fmt.len + thumbnail_extension.len]u8 = undefined;
    thumbnail_name[0..Timestamp.fmt.len].* = path[0..Timestamp.fmt.len].*;
    thumbnail_name[(thumbnail_name.len - thumbnail_extension.len)..][0..thumbnail_extension.len].* = thumbnail_extension.*;

    const thumbnail_path = try std.fs.path.join(arena, &.{ env.key(.THUMBNAIL_CACHE), day, &thumbnail_name });
    if (std.fs.cwd().openFile(thumbnail_path, .{})) |file| {
        defer file.close();

        // All videos are static and therefore all thumbnails too
        ctx.res.header("Cache-Control", "public, max-age=604800, immutable");

        try sendFile(ctx, file, "image/png");
    } else |_| {
        const video_extension = ".mp4";
        var video_name: [Timestamp.fmt.len + video_extension.len]u8 = undefined;
        video_name[0..Timestamp.fmt.len].* = path[0..Timestamp.fmt.len].*;
        video_name[(video_name.len - video_extension.len)..][0..video_extension.len].* = video_extension.*;

        const video_path = try std.fs.path.join(arena, &.{ env.key(.WEBCAM_VIDEO_ARCHIVE), day, &video_name });
        std.log.info("Generating thumbnail for video '{s}'...", .{video_path});

        // Early access check to give a better status code
        std.fs.cwd().access(video_path, .{ .mode = .read_only }) catch |err| {
            std.log.err("Failed to access video '{s}': {}", .{ video_path, err });

            ctx.res.status = @intFromEnum(std.http.Status.not_found);
            ctx.res.body = "Failed to access source video";
            ctx.responded = true;
            return;
        };
        // Ensure the target directory exists
        try std.fs.cwd().makePath(try std.fs.path.join(arena, &.{ env.key(.THUMBNAIL_CACHE), day }));

        const res = std.process.Child.run(.{
            .allocator = arena,
            .argv = &.{ "ffmpegthumbnailer", "-i", video_path, "-o", thumbnail_path, "-s0", "-t00:00:10" },
        }) catch |err| {
            std.log.err("Failed to spawn 'ffmpegthumbnailer' process for video '{s}': {}", .{ video_path, err });

            ctx.res.status = @intFromEnum(std.http.Status.internal_server_error);
            ctx.res.body = "Failed to generate thumbnail";
            ctx.responded = true;
            return;
        };

        if (res.term != .Exited or res.term.Exited != 0) {
            std.log.err("Failed to generate thumbnail for video '{s}': {}", .{ video_path, res.term });
            var line_iter = std.mem.tokenizeAny(u8, res.stderr, "\n\r");
            while (line_iter.next()) |line| {
                std.log.err("    {s}", .{line});
            }

            ctx.res.status = @intFromEnum(std.http.Status.internal_server_error);
            ctx.res.body = "Failed to generate thumbnail";
            ctx.responded = true;
            return;
        }

        const file = std.fs.cwd().openFile(thumbnail_path, .{}) catch |err| {
            std.log.err("Failed to read thumbnail file '{s}': {}", .{ thumbnail_path, err });

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
