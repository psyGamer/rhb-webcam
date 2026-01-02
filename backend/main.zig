const std = @import("std");
const builtin = @import("builtin");
const runtime_safety = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

const std_options: std.Options = .{
    .logFn = @import("logging.zig").logFn,
    .fmt_max_depth = 10,
};

const Context = struct {
    allocator: std.mem.Allocator,
};

pub fn main() !void {
    std.log.info("Hello World", .{});

    var debug_allocator: if (runtime_safety) std.heap.DebugAllocator(.{}) else void = if (runtime_safety) .init else {};
    defer if (runtime_safety) std.debug.assert(debug_allocator.deinit() == .ok);

    const allocator = if (runtime_safety) debug_allocator.allocator() else std.heap.smp_allocator;

    const address: std.net.Address = .initIp4(.{ 127, 0, 0, 1 }, 8000);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator });
    defer pool.deinit();

    var ctx: Context = .{ .allocator = allocator };

    std.log.info("Server running on http://127.0.0.1:{d}", .{server.listen_address.getPort()});

    while (true) {
        const connection = server.accept() catch |err| {
            std.log.err("Failed to accept connection: {s}", .{@errorName(err)});
            continue;
        };

        pool.spawn(acceptConnection, .{ &ctx, connection }) catch |err| {
            std.log.err("Failed to spawn thread for connection: {s}", .{@errorName(err)});
            connection.stream.close();
            continue;
        };
    }
}

fn acceptConnection(ctx: *Context, connection: std.net.Server.Connection) void {
    defer connection.stream.close();

    var recv_buffer: [4096]u8 = undefined;
    var send_buffer: [4096]u8 = undefined;
    var conn_reader = connection.stream.reader(&recv_buffer);
    var conn_writer = connection.stream.writer(&send_buffer);
    var server = std.http.Server.init(conn_reader.interface(), &conn_writer.interface);

    while (server.reader.state == .ready) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                std.log.err("Failed to receive request: {s}", .{@errorName(err)});
                return;
            },
        };

        serveRequest(ctx, &request) catch |err| {
            std.log.err("Failed to serve '{s}': {s}", .{ request.head.target, @errorName(err) });
            return;
        };
    }
}
fn serveRequest(ctx: *Context, request: *std.http.Server.Request) !void {
    const path_len = std.mem.indexOfScalar(u8, request.head.target, '?') orelse request.head.target.len;
    const target = request.head.target["/".len..path_len];

    // TODO: Don't lmao
    const file = std.fs.cwd().openFile(target, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try request.respond("File not found", .{
                .status = .not_found,
                .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain" }},
            });
            return;
        },
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();

    var range_start: u64 = 0;
    var range_end: u64 = stat.size - 1;

    var iter = request.iterateHeaders();
    while (iter.next()) |header| {
        const header_type = std.meta.stringToEnum(enum { Range }, header.name) orelse continue;

        switch (header_type) {
            // TODO: Support multiple ranges
            .Range => {
                if (!std.mem.startsWith(u8, header.value, "bytes=")) continue;
                const dash_idx = std.mem.indexOfScalar(u8, header.value, '-') orelse continue;

                if (dash_idx == header.value.len - 1) {
                    // Offset from beginning
                    const offset = std.fmt.parseInt(u64, header.value["bytes=".len..(header.value.len - "-".len)], 10) catch continue;
                    range_start = std.math.clamp(offset, 0, stat.size - 1);
                } else if (dash_idx == "bytes=".len) {
                    // Offset from end
                    const offset = std.fmt.parseInt(u64, header.value["bytes=-".len..], 10) catch continue;
                    range_start = std.math.clamp(range_end - @min(range_end, offset), 0, stat.size - 1);
                } else {
                    // Range within file
                    const offset_start = std.fmt.parseInt(u64, header.value["bytes=".len..dash_idx], 10) catch continue;
                    const offset_end = std.fmt.parseInt(u64, header.value[(dash_idx + 1)..], 10) catch continue;

                    if (offset_end >= offset_start) {
                        range_start = std.math.clamp(offset_start, 0, stat.size - 1);
                        range_end = std.math.clamp(offset_end, 0, stat.size - 1);
                    } else {
                        range_start = std.math.clamp(offset_end, 0, stat.size - 1);
                        range_end = std.math.clamp(offset_start, 0, stat.size - 1);
                    }
                }
            },
        }
    }

    const content_size = range_end - range_start + 1;
    std.log.debug("Requested file '{s}' with range {d}-{d} ({d} bytes)", .{ target, range_start, range_end, content_size });

    // Guess MIME type based on file extension
    const content_type_header = if (std.mem.endsWith(u8, target, ".html") or std.mem.endsWith(u8, target, ".htm"))
        "text/html"
    else if (std.mem.endsWith(u8, target, ".css"))
        "text/css"
    else if (std.mem.endsWith(u8, target, ".js"))
        "text/javascript"
    else if (std.mem.endsWith(u8, target, ".wasm"))
        "application/wasm"
    else if (std.mem.endsWith(u8, target, ".mp4"))
        "video/mp4"
    else
        "text/plain";

    const content_range_header = try std.fmt.allocPrint(ctx.allocator, "bytes {d}-{d}/{d}", .{ range_start, range_end, stat.size });
    defer ctx.allocator.free(content_range_header);
    const content_length_header = try std.fmt.allocPrint(ctx.allocator, "{d}", .{content_size});
    defer ctx.allocator.free(content_length_header);

    var send_buffer: [0x4000]u8 = undefined;
    var response = try request.respondStreaming(&send_buffer, .{
        .content_length = content_size,
        .respond_options = .{ .status = if (content_size == stat.size) .ok else .partial_content, .extra_headers = &.{
            .{ .name = "Content-Type", .value = content_type_header },
            .{ .name = "Content-Range", .value = content_range_header },
            .{ .name = "Accept-Ranges", .value = "bytes" },
        } },
    });

    var file_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(&file_buffer);

    try file_reader.seekTo(range_start);
    try file_reader.interface.streamExact(&response.writer, content_size);

    try response.end();
    std.log.info("done", .{});
}
