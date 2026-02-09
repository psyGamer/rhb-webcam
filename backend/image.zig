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

    const file = try std.fs.cwd().openFile(image_path, .{});
    defer file.close();

    // All videos are static and therefore all images too
    ctx.res.header("Cache-Control", "public, max-age=604800, immutable");

    try sendFile(ctx, file, "image/png");
}
