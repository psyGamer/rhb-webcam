const std = @import("std");
const tk = @import("tokamak");

const content_types: std.StaticStringMap([]const u8) = .initComptime(.{
    .{ ".html", "text/html; charset=utf-8" },
    .{ ".css", "text/css; charset=utf-8" },
    .{ ".js", "text/javascript; charset=utf-8" },
    .{ ".wasm", "application/wasm" },

    .{ ".png", "image/png" },
    .{ ".jpg", "image/jpeg" },
    .{ ".jpeg", "image/jpeg" },
    .{ ".gif", "image/gif" },
    .{ ".svg", "image/svg+xml" },
    .{ ".ico", "image/x-icon" },

    .{ ".mp4", "video/mp4" },
});

pub fn assetDirectory(comptime path: []const u8) tk.Route {
    const H = struct {
        pub fn handleDir(ctx: *tk.Context) anyerror!void {
            // We only support GET for now
            if (ctx.req.method != .GET) return;

            var target = ctx.req.url.path;

            // Strip the prefix if we are inside of Route.get("/xxx/*")
            if (ctx.current.path) |p| {
                std.debug.assert(p.len >= 2);
                std.debug.assert(ctx.params.len == 0);
                target = target[p.len - 2 ..];
            }

            // Map / to index file
            if (target.len == 1 and target[0] == '/') {
                target = "index.html";
            }

            // Resolve relative paths (this is important for the check below to work)
            target = try std.fs.path.resolvePosix(ctx.allocator, &.{ path, std.mem.trimLeft(u8, target, "/") });

            // Prevent (out-of-directory) traversal attacks
            if (!std.mem.startsWith(u8, target, path)) {
                return;
            }

            return sendFile(ctx, target) catch |e| return switch (e) {
                error.FileNotFound => {},
                else => e,
            };
        }
    };

    return .{
        .handler = &H.handleDir,
    };
}

fn sendFile(ctx: *tk.Context, target: []const u8) !void {
    const file = try std.fs.cwd().openFile(target, .{});
    defer file.close();

    const stat = try file.stat();

    var file_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(&file_buffer);

    if (ctx.req.header("Range")) |range_header| {
        b: {
            const prefix = "bytes=";
            if (range_header.len < prefix.len) break :b;

            var ranges: std.ArrayList(struct { u64, u64 }) = .empty;
            var prev_range: u64 = 0;
            var range_total: u64 = 0;

            var range_iter = std.mem.tokenizeScalar(u8, range_header, ',');
            while (range_iter.next()) |range| {
                const dash_idx = std.mem.indexOfScalar(u8, range, '-') orelse continue;

                if (dash_idx == range.len - 1) {
                    // Offset from beginning
                    const offset = std.fmt.parseInt(u64, range["bytes=".len..(range.len - "-".len)], 10) catch continue;
                    if (offset < 0 or offset >= stat.size or offset < prev_range) break :b;

                    try ranges.append(ctx.allocator, .{ offset, stat.size - 1 });
                    prev_range = stat.size;
                    range_total += stat.size - offset;
                } else if (dash_idx == "bytes=".len) {
                    // Offset from end
                    const offset = std.fmt.parseInt(u64, range["bytes=-".len..], 10) catch continue;
                    if (offset < 0 or offset >= stat.size or stat.size - offset < prev_range) break :b;

                    try ranges.append(ctx.allocator, .{ stat.size - offset, stat.size - 1 });
                    prev_range = stat.size;
                    range_total += offset;
                } else {
                    // Range within file
                    const offset_start = std.fmt.parseInt(u64, range["bytes=".len..dash_idx], 10) catch continue;
                    const offset_end = std.fmt.parseInt(u64, range[(dash_idx + 1)..], 10) catch continue;
                    if (offset_start < 0 or offset_end < 0 or offset_start >= stat.size or offset_end >= stat.size or offset_end < offset_start or offset_start < prev_range) break :b;

                    try ranges.append(ctx.allocator, .{ offset_start, offset_end });
                    prev_range = offset_end + 1;
                    range_total += offset_end - offset_start + 1;
                }
            }

            const writer = ctx.res.writer();
            try ctx.res.buffer.ensureTotalCapacity(range_total);

            for (ranges.items) |range| {
                const range_start, const range_end = range;
                try file_reader.interface.streamExact(writer, range_end - range_start + 1);
            }
            return;
        }

        // Something failed while parsing the ranges
        ctx.res.status = @intFromEnum(std.http.Status.range_not_satisfiable);
        ctx.res.header("Content-Range", try std.fmt.allocPrint(ctx.allocator, "bytes */{d}", .{stat.size}));
        ctx.res.header("Content-Type", content_types.get(std.fs.path.extension(target)) orelse "application/octet-stream");
        ctx.res.header("Cache-Control", "public, max-age=604800, immutable");
        ctx.res.header("Accept-Ranges", "bytes");

        ctx.responded = true;
        return;
    }

    const writer = ctx.res.writer();
    try ctx.res.buffer.ensureTotalCapacity(stat.size);
    _ = try file_reader.interface.streamRemaining(writer);

    ctx.res.header("Content-Type", content_types.get(std.fs.path.extension(target)) orelse "application/octet-stream");
    ctx.res.header("Cache-Control", "public, max-age=604800, immutable");
    ctx.res.header("Accept-Ranges", "bytes");

    ctx.responded = true;
}
