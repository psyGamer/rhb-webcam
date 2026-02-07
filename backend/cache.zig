const std = @import("std");
const tk = @import("tokamak");
const httpz = @import("httpz");

pub const Storage = std.StringHashMapUnmanaged(struct {
    expire: u64,

    status: u16,
    body: []const u8,
    headers: httpz.key_value.StringKeyValue,
});

/// Parses the 'Cache-Control' header of child routes and caches the content on the server
pub fn withCache(children: []const tk.Route) tk.Route {
    const H = struct {
        pub fn handle(ctx: *tk.Context) anyerror!void {
            const storage = try ctx.injector.get(*Storage);
            const now: u64 = @intCast(std.time.timestamp());

            if (storage.getPtr(ctx.req.url.path)) |hit| {
                if (hit.expire > now) {
                    ctx.res.status = hit.status;
                    ctx.res.body = hit.body;

                    for (hit.headers.keys, hit.headers.values) |key, value| {
                        ctx.res.headers.add(key, value);
                    }

                    ctx.responded = true;
                    return;
                } else {
                    ctx.server.allocator.free(hit.body);
                    hit.headers.deinit(ctx.server.allocator);

                    _ = storage.remove(ctx.req.url.path);
                }
            }

            try ctx.next();

            if (ctx.res.headers.get("Cache-Control")) |cache_ctrl| {
                var arg_iter = std.mem.splitScalar(u8, cache_ctrl, ',');
                const max_age = while (arg_iter.next()) |arg| {
                    const arg_trimmed = std.mem.trim(u8, arg, &.{ ' ', '\n', '\r', '\t' });

                    if (!std.mem.startsWith(u8, arg_trimmed, "max-age=")) continue;
                    break std.fmt.parseInt(u32, arg_trimmed["max-age=".len..], 10) catch 0;
                } else 0;

                if (max_age == 0) return;

                var headers_copy: httpz.key_value.StringKeyValue = try .init(ctx.server.allocator, ctx.res.headers.len);
                for (ctx.res.headers.keys, ctx.res.headers.values) |key, value| {
                    headers_copy.add(key, value);
                }

                try storage.put(ctx.server.allocator, ctx.req.url.path, .{
                    .expire = now + max_age,
                    .status = ctx.res.status,
                    .body = try ctx.server.allocator.dupe(u8, ctx.res.body),
                    .headers = headers_copy,
                });
            }
        }
    };

    return .{ .handler = &H.handle, .children = children };
}
