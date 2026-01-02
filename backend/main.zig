const std = @import("std");

const std_options: std.Options = .{
    .logFn = @import("logging.zig").logFn,
};

pub fn main() !void {
    std.log.info("Hello World", .{});
}
