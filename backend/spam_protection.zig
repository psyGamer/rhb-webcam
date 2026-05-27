const std = @import("std");
const tk = @import("tokamak");

pub fn withProtection(children: []const tk.Route) tk.Route {
    const log = std.log.scoped(.spam);

    const H = struct {
        pub fn handle(ctx: *tk.Context) anyerror!void {
            // Block AI bots
            if (ctx.req.header("user-agent")) |ua| {
                var block = false;
                if (std.mem.containsAtLeast(u8, ua, 1, "openai")) {
                    log.info("Blocked OpenAI bot", .{});
                    block = true;
                }
                if (std.mem.containsAtLeast(u8, ua, 1, "scrapy")) {
                    log.info("Blocked Scrapy bot", .{});
                    block = true;
                }
                if (std.mem.containsAtLeast(u8, ua, 1, "anthropic")) {
                    log.info("Blocked Claude bot", .{});
                    block = true;
                }

                if (block) {
                    ctx.res.body =
                        \\You have been blocked due to suspicious activity!
                        \\If you think this is an error or want to use the content for legitimate purposes, please contact rhb.webcam@gmail.com
                    ;
                    ctx.res.setStatus(.forbidden);
                    ctx.responded = true;
                    return;
                }
            }

            try ctx.next();
        }
    };

    return .{ .handler = &H.handle, .children = children };
}
