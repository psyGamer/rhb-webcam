const std = @import("std");
const tk = @import("tokamak");

const Env = @import("main.zig").Env;
const Timestamp = @import("common").Timestamp;
const sendFile = @import("static.zig").sendFile;

pub fn handler(arena: std.mem.Allocator, ctx: *tk.Context, env: *Env, path: []const u8) anyerror!void {
    if (!Timestamp.isValidSimpleTime(path)) return;

    const day = path[0.."YYYY-MM-DD".len];

    const image_extension = ".png";
    var image_name: [Timestamp.time_fmt.len + image_extension.len]u8 = undefined;
    image_name[0..Timestamp.time_fmt.len].* = path[0..Timestamp.time_fmt.len].*;
    image_name[(image_name.len - image_extension.len)..][0..image_extension.len].* = image_extension.*;

    const image_path = try std.fs.path.join(arena, &.{ env.key(.WEBCAM_FILISUR_IMAGE), day, &image_name });
    if (std.fs.cwd().openFile(image_path, .{})) |file| {
        defer file.close();

        // All videos are static and therefore all images too
        ctx.res.header("Cache-Control", "public, max-age=604800, immutable");

        try sendFile(ctx, file, "image/png");
    } else |_| {
        const video_extension = ".mp4";
        var video_name: [Timestamp.time_fmt.len + video_extension.len]u8 = undefined;
        video_name[0..Timestamp.time_fmt.len].* = path[0..Timestamp.time_fmt.len].*;
        video_name[(video_name.len - video_extension.len)..][0..video_extension.len].* = video_extension.*;

        const video_path = try std.fs.path.join(arena, &.{ env.key(.WEBCAM_FILISUR_VIDEO), day, &video_name });
        std.log.info("Generating image for video '{s}'...", .{video_path});

        // Early access check to give a better status code
        std.fs.cwd().access(video_path, .{ .mode = .read_only }) catch |err| {
            std.log.err("Failed to access video '{s}': {}", .{ video_path, err });

            ctx.res.status = @intFromEnum(std.http.Status.not_found);
            ctx.res.body = "Failed to access source video";
            ctx.responded = true;
            return;
        };
        // Ensure the target directory exists
        try std.fs.cwd().makePath(try std.fs.path.join(arena, &.{ env.key(.WEBCAM_FILISUR_IMAGE), day }));

        const res = std.process.Child.run(.{
            .allocator = arena,
            .argv = &.{ "ffmpegthumbnailer", "-i", video_path, "-o", image_path, "-s0", "-t00:00:10" },
        }) catch |err| {
            std.log.err("Failed to spawn 'ffmpegthumbnailer' process for video '{s}': {}", .{ video_path, err });

            ctx.res.status = @intFromEnum(std.http.Status.internal_server_error);
            ctx.res.body = "Failed to generate image";
            ctx.responded = true;
            return;
        };

        if (res.term != .Exited or res.term.Exited != 0) {
            std.log.err("Failed to generate image for video '{s}': {}", .{ video_path, res.term });
            var line_iter = std.mem.tokenizeAny(u8, res.stderr, "\n\r");
            while (line_iter.next()) |line| {
                std.log.err("    {s}", .{line});
            }

            ctx.res.status = @intFromEnum(std.http.Status.internal_server_error);
            ctx.res.body = "Failed to generate image";
            ctx.responded = true;
            return;
        }

        const file = std.fs.cwd().openFile(image_path, .{}) catch |err| {
            std.log.err("Failed to read image file '{s}': {}", .{ image_path, err });

            ctx.res.status = @intFromEnum(std.http.Status.internal_server_error);
            ctx.res.body = "Failed to generate image";
            ctx.responded = true;
            return;
        };
        defer file.close();

        // All videos are static and therefore all images too
        ctx.res.header("Cache-Control", "public, max-age=604800, immutable");

        try sendFile(ctx, file, "image/png");
    }
}
