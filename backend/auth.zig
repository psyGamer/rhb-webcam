const std = @import("std");
const tk = @import("tokamak");

pub const AuthOptions = struct {
    /// User-facing name for the authenticated area
    realm: []const u8,

    /// Validation function to check if given login credentials are valid
    validate: fn (ctx: *tk.Context, username: []const u8, password: []const u8) bool,
};

pub fn requireAuth(options: AuthOptions, children: []const tk.Route) tk.Route {
    const H = struct {
        fn handleAuth(ctx: *tk.Context) anyerror!void {
            const token = ctx.req.header("authorization") orelse {
                try sendAuthRequest(ctx);
                return;
            };
            if (!try validateAuth(ctx, token)) {
                try sendAuthRequest(ctx);
                return;
            }

            return ctx.next();
        }

        /// Allows the client to authenticate with the 'Basic' method
        pub fn sendAuthRequest(ctx: *tk.Context) !void {
            ctx.res.setStatus(.unauthorized);
            ctx.res.header("WWW-Authenticate", try std.fmt.allocPrint(ctx.allocator,
                \\Basic
                \\    realm="{s}",
                \\    charset="UTF-8"
            , .{options.realm}));
            ctx.responded = true;
        }

        /// Validates the contents of the 'Authentication' header
        pub fn validateAuth(ctx: *tk.Context, token: []const u8) !bool {
            const prefix = "Basic";
            if (!std.mem.startsWith(u8, token, prefix)) return false;

            var stack_fallback = std.heap.stackFallback(64, ctx.allocator);
            const allocator = stack_fallback.get();

            const b64_decoder = std.base64.standard.Decoder;
            const b64_data = std.mem.trim(u8, token[prefix.len..], "\t\n\r ");

            const src_len = b64_decoder.calcSizeForSlice(b64_data) catch return false;
            const src_data = try allocator.alloc(u8, src_len);
            b64_decoder.decode(src_data, b64_data) catch return false;

            const sep_idx = std.mem.indexOfScalar(u8, src_data, ':') orelse return false;
            const username = src_data[0..sep_idx];
            const password = src_data[(sep_idx + 1)..];

            return options.validate(ctx, username, password);
        }
    };

    return .{
        .handler = H.handleAuth,
        .children = children,
    };
}
