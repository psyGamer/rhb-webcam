const std = @import("std");
const tk = @import("tokamak");

const db = @import("database.zig");

pub fn withAnalytics(children: []const tk.Route) tk.Route {
    const log = std.log.scoped(.server);

    const H = struct {
        pub fn handle(ctx: *tk.Context) anyerror!void {
            const start = std.time.milliTimestamp();
            defer if (ctx.responded) {
                log.debug("{s} {s} {} [{}ms]", .{
                    @tagName(ctx.req.method),
                    ctx.req.url.path,
                    ctx.res.status,
                    std.time.milliTimestamp() - start,
                });
            } else {
                log.debug("{s} {s} NOT FOUND [{}ms]", .{
                    @tagName(ctx.req.method),
                    ctx.req.url.path,
                    std.time.milliTimestamp() - start,
                });
            };

            const pool = try ctx.injector.get(*db.Pool);

            var session = try pool.getSession(ctx.allocator);
            defer session.deinit();

            var child = .{session};
            const request_err = ctx.nextScoped(&child);

            session.query(db.Analytics)
                .insert(.{
                    .path = ctx.req.url.raw,
                    .method = @tagName(ctx.req.method),
                    .status = if (ctx.responded) ctx.res.status else 0,
                })
                .exec() catch |err| std.log.err("Failed to save analytics for request '{s} {s}': {}", .{ @tagName(ctx.req.method), ctx.req.url.raw, err });

            try request_err;
        }
    };

    return .{ .handler = &H.handle, .children = children };
}
