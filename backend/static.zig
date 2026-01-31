const std = @import("std");
const tk = @import("tokamak");
const httpz = @import("httpz");

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

pub const CacheOptions = union(enum) {
    /// File will never-ever be changed
    immutable: void,
    /// File will be cached for the given timeout
    timeout: u64,
    /// File will never be cached
    never: void,
};

/// Serve a static directory from the filesystem
pub fn assetDirectory(comptime path: []const u8, comptime cache: CacheOptions) tk.Route {
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
            defer file.close();

            switch (cache) {
                .immutable => ctx.res.header("Cache-Control", "public, max-age=604800, immutable"),
                .timeout => |sec| ctx.res.header("Cache-Control", std.fmt.comptimePrint("public, max-age={d}", .{sec})),
                .never => ctx.res.header("Cache-Control", "no-cache"),
            }

            try sendFile(ctx, file, content_types.get(std.fs.path.extension(target)) orelse "application/octet-stream");
        }
    };

    return .{ .handler = &H.handleDir };
}
/// Serve a static file from the filesystem
pub fn staticFile(comptime path: []const u8, comptime cache: CacheOptions) tk.Route {
    const H = struct {
        pub fn handleFile(ctx: *tk.Context) anyerror!void {
            const file = std.fs.cwd().openFile(path, .{}) catch |e| return switch (e) {
                error.FileNotFound => {},
                else => e,
            };
            defer file.close();

            switch (cache) {
                .immutable => ctx.res.header("Cache-Control", "public, max-age=604800, immutable"),
                .timeout => |sec| ctx.res.header("Cache-Control", std.fmt.comptimePrint("public, max-age={d}", .{sec})),
                .never => ctx.res.header("Cache-Control", "no-cache"),
            }

            try sendFile(ctx, file, comptime content_types.get(std.fs.path.extension(path)) orelse "application/octet-stream");
        }
    };

    return .{ .handler = &H.handleFile };
}

/// Send the specified target file to the client
/// This completes the request and it cannot be changer later
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

            var write_buffer: [4096]u8 = undefined;
            var writer = ctx.res.conn.stream.writer(&write_buffer);

            ctx.res.written = true;
            ctx.responded = true;

            if (range_total == stat.size) {
                ctx.res.setStatus(.partial_content);
                ctx.res.header("Accept-Ranges", "bytes");
                ctx.res.header("Content-Type", content_type);
                ctx.res.header("Content-Length", try std.fmt.allocPrint(ctx.allocator, "{d}", .{stat.size}));
                ctx.res.header("Content-Range", try std.fmt.allocPrint(ctx.allocator, "bytes 0-{d}/{d}", .{ stat.size - 1, stat.size }));
                try ctx.res.writeHeader();

                try streamExactToConnection(ctx.res.conn, &file_reader.interface, &writer, stat.size);
            } else if (ranges.items.len == 1) {
                const range_start, const range_end = ranges.items[0];
                const range_size = range_end - range_start + 1;

                ctx.res.status = @intFromEnum(std.http.Status.partial_content);
                ctx.res.header("Accept-Ranges", "bytes");
                ctx.res.header("Content-Type", content_type);
                ctx.res.header("Content-Length", try std.fmt.allocPrint(ctx.allocator, "{d}", .{range_size}));
                ctx.res.header("Content-Range", try std.fmt.allocPrint(ctx.allocator, "bytes {d}-{d}/{d}", .{ range_start, range_end, stat.size }));
                try ctx.res.writeHeader();

                try file_reader.seekTo(range_start);

                try streamExactToConnection(ctx.res.conn, &file_reader.interface, &writer, range_size);
            } else {
                // Generate random part boundary
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

                // Generate header/footer for parts
                const metas = try ctx.allocator.alloc(struct { []const u8, []const u8 }, ranges.items.len);
                var meta_total: u64 = 0;
                for (ranges.items, metas, 0..) |range, *meta, idx| {
                    const range_start, const range_end = range;
                    const range_size = range_end - range_start + 1;

                    const header = try std.fmt.allocPrint(
                        ctx.allocator,
                        "--" ++
                            "{s}\r\n" ++
                            "Content-Type: {s}\r\n" ++
                            "Content-Range: bytes {d}-{d}/{d}\r\n\r\n",
                        .{ boundary, content_type, range_start, range_end, range_size },
                    );

                    const footer = if (idx == ranges.items.len - 1)
                        try std.fmt.allocPrint(ctx.allocator, "\r\n--{s}--\r\n", .{boundary})
                    else
                        "\r\n";

                    meta.* = .{ header, footer };
                    meta_total += header.len + footer.len;
                }

                ctx.res.status = @intFromEnum(if (range_total < stat.size) std.http.Status.partial_content else std.http.Status.ok);
                ctx.res.header("Accept-Ranges", "bytes");
                ctx.res.header("Content-Type", try std.fmt.allocPrint(ctx.allocator, "multipart/byteranges; boundary={s}", .{boundary}));
                ctx.res.header("Content-Length", try std.fmt.allocPrint(ctx.allocator, "{d}", .{range_total + meta_total}));
                try ctx.res.writeHeader();

                for (ranges.items, metas) |range, meta| {
                    const range_start, const range_end = range;
                    const range_size = range_end - range_start + 1;

                    const header, const footer = meta;

                    try writeAllToConnection(ctx.res.conn, &writer, header);

                    try file_reader.seekTo(range_start);
                    try streamExactToConnection(ctx.res.conn, &file_reader.interface, &writer, range_size);

                    try writeAllToConnection(ctx.res.conn, &writer, footer);
                }
            }

            try writer.interface.flush();
            return;
        }

        // Something failed while parsing the ranges
        ctx.res.status = @intFromEnum(std.http.Status.range_not_satisfiable);
        ctx.res.headers.reset();
        ctx.res.header("Content-Range", try std.fmt.allocPrint(ctx.allocator, "bytes */{d}", .{stat.size}));
        ctx.res.header("Accept-Ranges", "bytes");

        ctx.responded = true;
        return;
    }

    var write_buffer: [4096]u8 = undefined;
    var writer = ctx.res.conn.stream.writer(&write_buffer);

    ctx.res.written = true;
    ctx.responded = true;

    ctx.res.status = @intFromEnum(std.http.Status.ok);
    ctx.res.header("Accept-Ranges", "bytes");
    ctx.res.header("Content-Type", content_type);
    ctx.res.header("Content-Length", try std.fmt.allocPrint(ctx.allocator, "{d}", .{stat.size}));
    try ctx.res.writeHeader();

    try streamExactToConnection(ctx.res.conn, &file_reader.interface, &writer, stat.size);

    try writer.interface.flush();
}

const HTTPConn = @FieldType(httpz.Response, "conn");

fn streamExactToConnection(conn: HTTPConn, reader: *std.Io.Reader, writer: *std.net.Stream.Writer, n: usize) !void {
    var remaining = n;
    while (remaining != 0) {
        remaining -= reader.stream(&writer.interface, .limited(remaining)) catch |err| {
            if (writer.err) |socket_err| {
                if (socket_err == error.WouldBlock) {
                    try conn.blockingMode();
                    continue;
                }
            }
            return err;
        };
    }
}
fn writeAllToConnection(conn: HTTPConn, writer: *std.net.Stream.Writer, bytes: []const u8) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        index += writer.interface.write(bytes[index..]) catch |err| {
            if (writer.err) |socket_err| {
                if (socket_err == error.WouldBlock) {
                    try conn.blockingMode();
                    continue;
                }
            }
            return err;
        };
    }
}
