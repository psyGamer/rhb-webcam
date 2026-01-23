const std = @import("std");
const builtin = @import("builtin");
const runtime_safety = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

const tk = @import("tokamak");
const dotenv = @import("dotenv");

const assetDirectory = @import("static.zig").assetDirectory;
const staticFile = @import("static.zig").staticFile;

const Schedule = @import("common").Schedule;

pub const std_options: std.Options = .{
    .logFn = @import("logging.zig").logFn,
    .fmt_max_depth = 10,
};

const dist_dir = "dist/";

const routes: []const tk.Route = &.{
    // Views (all point to index.html, since the router is in the frontend)
    .get("/", staticFile(dist_dir ++ "index.html")),
    .get("/categorize", staticFile(dist_dir ++ "index.html")),

    // DVUI assets
    .get("/web.wasm", staticFile(dist_dir ++ "web.wasm")),
    .get("/web.js", staticFile(dist_dir ++ "web.js")),
    .get("/video.js", staticFile(dist_dir ++ "video.js")),
    .get("/meta.js", staticFile(dist_dir ++ "meta.js")),

    // CDN
    .get("/video/:path", @import("video.zig").handler),
    .get("/thumbnail/:path", @import("thumbnail.zig").handler),

    // API
    .group("/categorize-api", @import("categorize.zig").routes),
};

pub const Env = dotenv.Env(enum {
    /// Directory where the captured train videos are stored
    WEBCAM_VIDEO_ARCHIVE,
    /// Directory where hourly images are stored
    WEBCAM_IMAGE_ARCHIVE,
    /// Directory where raw webcam footage is stored
    WEBCAM_SNIPPET_CACHE,

    /// Directory for temporarily caching thumbnail images for videos
    THUMBNAIL_CACHE,

    /// Directory for temporarily archiving deleted videos
    DELETED_VIDEO_ARCHIVE,

    /// Directory for archiving original locomotive allocation PDFs
    LOCOMOTIVE_ALLOCATIONS_ARCHIVE,
    /// Directory for storing parsed JSON files for the locomotive allocations
    LOCOMOTIVE_ALLOCATIONS_STORAGE,
});
/// Collection of parsed train schedules
pub const Schedules = []const Schedule;

pub fn main() !void {
    var debug_allocator: if (runtime_safety) std.heap.DebugAllocator(.{}) else void = if (runtime_safety) .init else {};
    defer if (runtime_safety) std.debug.assert(debug_allocator.deinit() == .ok);

    const allocator = if (runtime_safety) debug_allocator.allocator() else std.heap.smp_allocator;

    // Load .env
    var env: Env = .init(allocator, false);
    defer env.deinit();

    try env.load(.{});

    // Load train schedules
    var schedules: Schedules = b: {
        var schedule_dir = try std.fs.cwd().openDir("schedule", .{});
        defer schedule_dir.close();

        break :b try Schedule.load(schedule_dir, allocator);
    };

    const server_routes = if (builtin.mode == .Debug) &.{tk.logger(.{}, routes)} else routes;

    var injector: tk.Injector = .init(&.{ .ref(&env), .ref(&schedules) }, null);
    var server: tk.Server = try .init(allocator, server_routes, .{
        .listen = .{ .hostname = "0.0.0.0", .port = 8000 },
        .injector = &injector,
    });
    defer server.deinit();

    std.log.info("Server running on http://localhost:8000", .{});
    try server.start();
}
