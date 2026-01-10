const std = @import("std");
const builtin = @import("builtin");
const runtime_safety = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

const tk = @import("tokamak");
const dotenv = @import("dotenv");

const assetDirectory = @import("static.zig").assetDirectory;

pub const std_options: std.Options = .{
    .logFn = @import("logging.zig").logFn,
    .fmt_max_depth = 10,
};

const routes: []const tk.Route = &.{
    .get("/*", assetDirectory("dist")),
    .get("/thumbnail/:path", @import("thumbnail.zig").handler),
};

pub const Env = dotenv.Env(enum {
    /// Directory where the captured train videos are stored
    WEBCAM_VIDEO_ARCHIVE,
    /// Directory where hourly images are stored
    WEBCAM_IMAGE_ARCHIVE,
    /// Directory where raw webcam footage is stored
    WEBCAM_SNIPPET_CACHE,

    /// Directory for temporarily archiving deleted videos
    DELETED_VIDEO_ARCHIVE,

    /// Directory for archiving original locomotive allocation PDFs
    LOCOMOTIVE_ALLOCATIONS_ARCHIVE,
    /// Directory for storing parsed JSON files for the locomotive allocations
    LOCOMOTIVE_ALLOCATIONS_STORAGE,

    /// Directory for temporarily caching thumbnail images for videos
    THUMBNAIL_CACHE,
});

pub fn main() !void {
    var debug_allocator: if (runtime_safety) std.heap.DebugAllocator(.{}) else void = if (runtime_safety) .init else {};
    defer if (runtime_safety) std.debug.assert(debug_allocator.deinit() == .ok);

    const allocator = if (runtime_safety) debug_allocator.allocator() else std.heap.smp_allocator;

    var env: Env = .init(allocator, false);
    defer env.deinit();

    try env.load(.{});

    var injector: tk.Injector = .init(&.{.ref(&env)}, null);
    var server: tk.Server = try .init(allocator, routes, .{
        .listen = .{ .hostname = "0.0.0.0", .port = 8000 },
        .injector = &injector,
    });
    defer server.deinit();

    std.log.info("Server running on http://localhost:8000", .{});
    try server.start();
}
