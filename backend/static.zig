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

            const file = std.fs.cwd().openFile(target, .{}) catch |e| return switch (e) {
                error.FileNotFound => {},
                else => e,
            };

            // Static files are expected to never change
            ctx.res.header("Cache-Control", "public, max-age=604800, immutable");

            try streamFile(ctx, file, content_types.get(std.fs.path.extension(target)) orelse "application/octet-stream");
        }
    };

    return .{
        .handler = &H.handleDir,
    };
}

/// Send the specified target file to the client
pub fn sendFile(ctx: *tk.Context, file: std.fs.File, content_type: []const u8) !void {
    const stat = try file.stat();

    var file_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(&file_buffer);

    if (ctx.req.header("range")) |range_header| {
        b: {
            const prefix = "bytes=";
            if (range_header.len < prefix.len) break :b;

            var ranges: std.ArrayList(struct { u64, u64 }) = .empty;
            var prev_range: u64 = 0;
            var range_total: u64 = 0;

            var range_iter = std.mem.tokenizeScalar(u8, range_header[prefix.len..], ',');
            while (range_iter.next()) |range| {
                const dash_idx = std.mem.indexOfScalar(u8, range, '-') orelse continue;

                if (dash_idx == range.len - 1) {
                    // Offset from beginning
                    const offset = std.fmt.parseInt(u64, range[0..(range.len - "-".len)], 10) catch continue;
                    if (offset < 0 or offset >= stat.size or offset < prev_range) break :b;

                    try ranges.append(ctx.allocator, .{ offset, stat.size - 1 });
                    prev_range = stat.size;
                    range_total += stat.size - offset;
                } else if (dash_idx == 0) {
                    // Offset from end
                    const offset = std.fmt.parseInt(u64, range["-".len..], 10) catch continue;
                    if (offset < 0 or offset >= stat.size or stat.size - offset < prev_range) break :b;

                    try ranges.append(ctx.allocator, .{ stat.size - offset, stat.size - 1 });
                    prev_range = stat.size;
                    range_total += offset;
                } else {
                    // Range within file
                    const offset_start = std.fmt.parseInt(u64, range[0..dash_idx], 10) catch continue;
                    const offset_end = std.fmt.parseInt(u64, range[(dash_idx + 1)..], 10) catch continue;
                    if (offset_start < 0 or offset_end < 0 or offset_start >= stat.size or offset_end >= stat.size or offset_end < offset_start or offset_start < prev_range) break :b;

                    try ranges.append(ctx.allocator, .{ offset_start, offset_end });
                    prev_range = offset_end + 1;
                    range_total += offset_end - offset_start + 1;
                }
            }
            if (ranges.items.len == 0) break :b;

            const writer = ctx.res.writer();
            try ctx.res.buffer.ensureTotalCapacity(range_total);

            if (range_total == stat.size) {
                _ = try file_reader.interface.streamRemaining(writer);

                ctx.res.status = @intFromEnum(std.http.Status.ok);
                ctx.res.header("Content-Type", content_type);
                ctx.res.header("Accept-Ranges", "bytes");
            } else if (ranges.items.len == 1) {
                const range_start, const range_end = ranges.items[0];

                try file_reader.seekTo(range_start);
                _ = try file_reader.interface.streamExact(writer, range_end - range_start + 1);

                ctx.res.status = @intFromEnum(std.http.Status.partial_content);
                ctx.res.header("Content-Range", try std.fmt.allocPrint(ctx.allocator, "bytes {d}-{d}/{d}", .{ range_start, range_end, stat.size }));
                ctx.res.header("Content-Type", content_type);
                ctx.res.header("Accept-Ranges", "bytes");
            } else {
                var rng_seed: u64 = undefined;
                std.posix.getrandom(@ptrCast(&rng_seed)) catch {
                    rng_seed = @intFromPtr(ctx);
                };
                var prng: std.Random.DefaultPrng = .init(rng_seed);
                var rand = prng.random();

                var boundary: [50]u8 = undefined;
                boundary[0..25].* = ("-" ** 25).*; // First half are dashes
                for (boundary[25..50]) |*c| { // Second half are random numbers
                    c.* = '0' + rand.uintLessThan(u8, 10);
                }

                for (ranges.items, 0..) |range, idx| {
                    const range_start, const range_end = range;
                    const range_size = range_end - range_start + 1;

                    // Multi-Part header
                    try writer.print(
                        "--" ++
                            "{s}\r\n" ++
                            "Content-Type: {s}\r\n" ++
                            "Content-Range: bytes {d}-{d}/{d}\r\n\r\n",
                        .{ boundary, content_type, range_start, range_end, range_size },
                    );

                    // Multi-Part content
                    try file_reader.seekTo(range_start);
                    try file_reader.interface.streamExact(writer, range_size);

                    // Multi-Part footer
                    if (idx == ranges.items.len - 1) {
                        try writer.print("\r\n--{s}--\r\n", .{boundary});
                    } else {
                        try writer.writeAll("\r\n");
                    }
                }

                ctx.res.status = @intFromEnum(if (range_total < stat.size) std.http.Status.partial_content else std.http.Status.ok);
                ctx.res.header("Content-Type", try std.fmt.allocPrint(ctx.allocator, "multipart/byteranges; boundary={s}", .{boundary}));
                ctx.res.header("Accept-Ranges", "bytes");
            }
            return;
        }

        // Something failed while parsing the ranges
        ctx.res.status = @intFromEnum(std.http.Status.range_not_satisfiable);
        ctx.res.header("Content-Range", try std.fmt.allocPrint(ctx.allocator, "bytes */{d}", .{stat.size}));
        ctx.res.header("Accept-Ranges", "bytes");

        ctx.responded = true;
        return;
    }

    const writer = ctx.res.writer();
    try ctx.res.buffer.ensureTotalCapacity(stat.size);
    _ = try file_reader.interface.streamRemaining(writer);

    ctx.res.status = @intFromEnum(std.http.Status.ok);
    ctx.res.header("Content-Type", content_type);
    ctx.res.header("Accept-Ranges", "bytes");
}

/// Stream the specified target file to the client
/// This takes ownership of the file handle and it should not be used afterwards
/// Will handle closing the file on its own
pub fn streamFile(ctx: *tk.Context, file: std.fs.File, content_type: []const u8) !void {
    const stat = try file.stat();

    if (ctx.req.header("range")) |range_header| {
        b: {
            const prefix = "bytes=";
            if (range_header.len < prefix.len) break :b;

            var ranges: std.ArrayList(FileStreamContext.Range) = .empty;
            var prev_range: u64 = 0;
            var range_total: u64 = 0;

            var range_iter = std.mem.tokenizeScalar(u8, range_header[prefix.len..], ',');
            while (range_iter.next()) |range| {
                const dash_idx = std.mem.indexOfScalar(u8, range, '-') orelse continue;

                if (dash_idx == range.len - 1) {
                    // Offset from beginning
                    const offset = std.fmt.parseInt(u64, range[0..(range.len - "-".len)], 10) catch continue;
                    if (offset < 0 or offset >= stat.size or offset < prev_range) break :b;

                    try ranges.append(ctx.allocator, .{ offset, stat.size - 1 });
                    prev_range = stat.size;
                    range_total += stat.size - offset;
                } else if (dash_idx == 0) {
                    // Offset from end
                    const offset = std.fmt.parseInt(u64, range["-".len..], 10) catch continue;
                    if (offset < 0 or offset >= stat.size or stat.size - offset < prev_range) break :b;

                    try ranges.append(ctx.allocator, .{ stat.size - offset, stat.size - 1 });
                    prev_range = stat.size;
                    range_total += offset;
                } else {
                    // Range within file
                    const offset_start = std.fmt.parseInt(u64, range[0..dash_idx], 10) catch continue;
                    const offset_end = std.fmt.parseInt(u64, range[(dash_idx + 1)..], 10) catch continue;
                    if (offset_start < 0 or offset_end < 0 or offset_start >= stat.size or offset_end >= stat.size or offset_end < offset_start or offset_start < prev_range) break :b;

                    try ranges.append(ctx.allocator, .{ offset_start, offset_end });
                    prev_range = offset_end + 1;
                    range_total += offset_end - offset_start + 1;
                }
            }
            if (ranges.items.len == 0) break :b;

            if (range_total == stat.size) {
                ctx.res.status = @intFromEnum(std.http.Status.ok);
                ctx.res.header("Content-Type", content_type);
                ctx.res.header("Accept-Ranges", "bytes");

                try ctx.res.startEventStream(FileStreamContext{ .file = file, .stat = stat }, FileStreamContext.sendFull);
                ctx.responded = true;
            } else if (ranges.items.len == 1) {
                const range_start, const range_end = ranges.items[0];

                ctx.res.status = @intFromEnum(std.http.Status.partial_content);
                ctx.res.header("Content-Range", try std.fmt.allocPrint(ctx.allocator, "bytes {d}-{d}/{d}", .{ range_start, range_end, stat.size }));
                ctx.res.header("Content-Type", content_type);
                ctx.res.header("Accept-Ranges", "bytes");

                try ctx.res.startEventStream(FileStreamContext{ .file = file, .stat = stat, .content_type = content_type, .ranges = ranges.items }, FileStreamContext.sendRange);
                ctx.responded = true;
            } else {
                var rng_seed: u64 = undefined;
                std.posix.getrandom(@ptrCast(&rng_seed)) catch {
                    rng_seed = @intFromPtr(ctx);
                };
                var prng: std.Random.DefaultPrng = .init(rng_seed);
                var rand = prng.random();

                var boundary: [50]u8 = undefined;
                boundary[0..25].* = ("-" ** 25).*; // First half are dashes
                for (boundary[25..50]) |*c| { // Second half are random numbers
                    c.* = '0' + rand.uintLessThan(u8, 10);
                }

                ctx.res.status = @intFromEnum(std.http.Status.partial_content);
                ctx.res.header("Content-Type", try std.fmt.allocPrint(ctx.allocator, "multipart/byteranges; boundary={s}", .{boundary}));
                ctx.res.header("Accept-Ranges", "bytes");

                try ctx.res.startEventStream(FileStreamContext{ .file = file, .stat = stat, .content_type = content_type, .boundary = try ctx.allocator.dupe(u8, &boundary), .ranges = ranges.items }, FileStreamContext.sendMultipart);
                ctx.responded = true;
            }
            return;
        }

        // Something failed while parsing the ranges
        ctx.res.status = @intFromEnum(std.http.Status.range_not_satisfiable);
        ctx.res.header("Content-Range", try std.fmt.allocPrint(ctx.allocator, "bytes */{d}", .{stat.size}));
        ctx.res.header("Accept-Ranges", "bytes");

        ctx.responded = true;

        file.close();
        return;
    }

    ctx.res.status = @intFromEnum(std.http.Status.ok);
    ctx.res.header("Content-Type", content_type);
    ctx.res.header("Accept-Ranges", "bytes");

    try ctx.res.startEventStream(FileStreamContext{ .file = file, .stat = stat }, FileStreamContext.sendFull);
    ctx.responded = true;
}

const FileStreamContext = struct {
    pub const Range = struct { u64, u64 };

    file: std.fs.File,
    stat: std.fs.File.Stat,
    content_type: []const u8 = undefined,
    boundary: []const u8 = undefined,
    ranges: []const Range = undefined,

    pub fn sendFull(ctx: FileStreamContext, stream: std.net.Stream) void {
        defer {
            ctx.file.close();
            stream.close();
        }

        var read_buffer: [4096]u8 = undefined;
        var reader = ctx.file.reader(&read_buffer);

        var write_buffer: [4096]u8 = undefined;
        var writer = stream.writer(&write_buffer);

        _ = reader.interface.streamExact(&writer.interface, ctx.stat.size) catch return;
    }
    pub fn sendRange(ctx: FileStreamContext, stream: std.net.Stream) void {
        defer {
            ctx.file.close();
            stream.close();
        }

        const range_start, const range_end = ctx.ranges[0];

        var read_buffer: [4096]u8 = undefined;
        var reader = ctx.file.reader(&read_buffer);

        var write_buffer: [4096]u8 = undefined;
        var writer = stream.writer(&write_buffer);

        reader.seekTo(range_start) catch return;
        _ = reader.interface.streamExact(&writer.interface, range_end - range_start + 1) catch return;
    }
    pub fn sendMultipart(ctx: FileStreamContext, stream: std.net.Stream) void {
        defer {
            ctx.file.close();
            stream.close();
        }

        var read_buffer: [4096]u8 = undefined;
        var reader = ctx.file.reader(&read_buffer);

        var write_buffer: [4096]u8 = undefined;
        var writer = stream.writer(&write_buffer);

        for (ctx.ranges, 0..) |range, idx| {
            const range_start, const range_end = range;
            const range_size = range_end - range_start + 1;

            // Multi-Part header
            writer.interface.print(
                "--" ++
                    "{s}\r\n" ++
                    "Content-Type: {s}\r\n" ++
                    "Content-Range: bytes {d}-{d}/{d}\r\n\r\n",
                .{ ctx.boundary, ctx.content_type, range_start, range_end, range_size },
            ) catch return;

            // Multi-Part content
            reader.seekTo(range_start) catch return;
            reader.interface.streamExact(&writer.interface, range_size) catch return;

            // Multi-Part footer
            if (idx == ctx.ranges.len - 1) {
                writer.interface.print("\r\n--{s}--\r\n", .{ctx.boundary}) catch return;
            } else {
                writer.interface.writeAll("\r\n") catch return;
            }
        }
    }
};
