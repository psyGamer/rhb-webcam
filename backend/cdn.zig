const std = @import("std");
const tk = @import("tokamak");

const Env = @import("main.zig").Env;
const Timestamp = @import("common").Timestamp;
const Location = @import("common").Location;

const sendFile = @import("static.zig").sendFile;

pub fn handler(comptime location: Location, comptime content_type: enum { image, video, thumnail }) tk.Route {
    if (location != .filisur and location != .livestream and content_type == .video) {
        @compileError("Currently, only the Filisur and Livestream webcams provide video content");
    }

    const H = struct {
        pub fn handle(ctx: *tk.Context) anyerror!void {
            const path = ctx.params.get(0) orelse return error.MissingParamter;

            const extension_len = ".xyz".len;
            var content_name: [Timestamp.time_fmt.len + extension_len]u8 = undefined;
            content_name[0..Timestamp.time_fmt.len].* = path[0..Timestamp.time_fmt.len].*;

            content_name[(content_name.len - extension_len)..][0..extension_len].* = switch (content_type) {
                .image => switch (location) {
                    .filisur => ".png".*,
                    .livestream, .landwasser, .landquart, .brusio => ".jpg".*,
                },
                .video => ".mp4".*,
                .thumnail => ".jpg".*,
            };

            const env = try ctx.injector.get(*Env);

            const content_dir = env.key(switch (location) {
                .filisur => switch (content_type) {
                    .image => .WEBCAM_FILISUR_IMAGE,
                    .video => .WEBCAM_FILISUR_VIDEO,
                    .thumnail => .WEBCAM_FILISUR_THUMBNAIL,
                },
                .landwasser => switch (content_type) {
                    .video => unreachable,
                    .image => .WEBCAM_LANDWASSER_IMAGE,
                    .thumnail => .WEBCAM_LANDWASSER_THUMBNAIL,
                },
                .landquart => switch (content_type) {
                    .video => unreachable,
                    .image => .WEBCAM_LANDQUART_IMAGE,
                    .thumnail => .WEBCAM_LANDQUART_THUMBNAIL,
                },
                .brusio => switch (content_type) {
                    .video => unreachable,
                    .image => .WEBCAM_BRUSIO_IMAGE,
                    .thumnail => .WEBCAM_BRUSIO_THUMBNAIL,
                },
                .livestream => switch (content_type) {
                    .image => .LIVESTREAM_IMAGE,
                    .video => .LIVESTREAM_VIDEO,
                    .thumnail => .LIVESTREAM_THUMBNAIL,
                },
            });
            const day_dir = path[0..Timestamp.date_fmt.len];

            const content_path = try std.fs.path.join(ctx.allocator, &.{ content_dir, day_dir, &content_name });

            const file = try std.fs.cwd().openFile(content_path, .{});
            defer file.close();

            // All videos are static and therefore all images too
            ctx.res.header("Cache-Control", "public, max-age=604800, immutable");

            switch (content_type) {
                .image => try sendFile(ctx, file, switch (location) {
                    .filisur => "image/png",
                    .livestream, .landwasser, .landquart, .brusio => "image/jpeg",
                }),
                .video => try sendFile(ctx, file, "video/mp4"),
                .thumnail => try sendFile(ctx, file, "image/jpeg"),
            }
        }
    };

    return .{ .handler = &H.handle };
}
