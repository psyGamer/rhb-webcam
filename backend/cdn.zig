const std = @import("std");
const tk = @import("tokamak");

const Env = @import("main.zig").Env;
const Timestamp = @import("common").Timestamp;
const Location = @import("common").Location;

const sendFile = @import("static.zig").sendFile;

pub fn handler(comptime location: Location, comptime content_type: enum { image, video }) tk.Route {
    if (location != .filisur and content_type != .image) {
        @compileError("Currently, only the Filisur webcam provides video content");
    }

    const H = struct {
        pub fn handle(ctx: *tk.Context) anyerror!void {
            const path = ctx.params.get(0) orelse return error.MissingParamter;
            const time = Timestamp.parseSimpleTime(path) orelse return error.NotFound;

            const extension_len = ".xyz".len;
            var content_name: [Timestamp.time_fmt.len + extension_len]u8 = undefined;
            content_name[0..Timestamp.time_fmt.len].* = path[0..Timestamp.time_fmt.len].*;

            if (location == .filisur and content_type == .image and time.year <= 2022) {
                // Manfred Luckmann archive uses JPEG images
                content_name[(content_name.len - extension_len)..][0..extension_len].* = ".jpg".*;
            } else {
                content_name[(content_name.len - extension_len)..][0..extension_len].* = switch (content_type) {
                    .image => ".png".*,
                    .video => ".mp4".*,
                };
            }

            const env = try ctx.injector.get(*Env);

            const content_dir = env.key(switch (location) {
                .filisur => switch (content_type) {
                    .image => .WEBCAM_FILISUR_IMAGE,
                    .video => .WEBCAM_FILISUR_VIDEO,
                },
                .landwasser => .WEBCAM_LANDWASSER_IMAGE,
                .landquart => .WEBCAM_LANDQUART_IMAGE,
                .brusio => .WEBCAM_BRUSIO_IMAGE,
            });
            const day_dir = path[0..Timestamp.date_fmt.len];

            const content_path = try std.fs.path.join(ctx.allocator, &.{ content_dir, day_dir, &content_name });

            const file = try std.fs.cwd().openFile(content_path, .{});
            defer file.close();

            // All videos are static and therefore all images too
            ctx.res.header("Cache-Control", "public, max-age=604800, immutable");

            if (location == .filisur and content_type == .image and time.year <= 2022) {
                // Manfred Luckmann archive uses JPEG images
                try sendFile(ctx, file, "image/jpeg");
            } else {
                switch (content_type) {
                    .image => try sendFile(ctx, file, "image/png"),
                    .video => try sendFile(ctx, file, "video/mp4"),
                }
            }
        }
    };

    return .{ .handler = &H.handle };
}
