const std = @import("std");
const tk = @import("tokamak");

const Env = @import("main.zig").Env;
const Timestamp = @import("common").Timestamp;
const api = @import("common").api;

pub const routes: []const tk.Route = &.{
    .get("/file-list?", handleFileList),
};

fn handleFileList(arena: std.mem.Allocator, env: *Env, query: struct { day: tk.time.Date, includeCategorized: bool = false }) !api.CategorizeFileList {
    _ = query; // autofix
    _ = env; // autofix
    const videos: []const []const u8 = &.{
        "2026-01-10_09-25-34.mp4",
        "2026-01-10_09-27-59.mp4",
        "2026-01-10_09-29-33.mp4",
        "2026-01-10_09-30-44.mp4",
        "2026-01-10_09-33-01.mp4",
        "2026-01-10_09-58-25.mp4",
        "2026-01-10_10-00-15.mp4",
        "2026-01-10_10-01-34.mp4",
        "2026-01-10_10-57-57.mp4",
        "2026-01-10_10-59-20.mp4",
        "2026-01-10_11-00-21.mp4",
        "2026-01-10_11-01-23.mp4",
        "2026-01-10_11-58-08.mp4",
        "2026-01-10_12-01-39.mp4",
        "2026-01-10_12-02-56.mp4",
        "2026-01-10_12-04-07.mp4",
        "2026-01-10_12-26-51.mp4",
        "2026-01-10_12-27-47.mp4",
        "2026-01-10_12-50-20.mp4",
        "2026-01-10_13-00-24.mp4",
        "2026-01-10_13-01-49.mp4",
        "2026-01-10_13-02-37.mp4",
        "2026-01-10_13-03-37.mp4",
        "2026-01-10_13-42-42.mp4",
    };

    const entries = try arena.alloc(api.CategorizeFileEntry, videos.len);
    for (videos, entries) |video, *entry| {
        entry.* = .{ .path = video, .categorized = false };
    }
    return entries;
}
