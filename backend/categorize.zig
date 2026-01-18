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
    const videos: []const [Timestamp.fmt.len]u8 = &.{
        "2026-01-10_09-25-34".*,
        "2026-01-10_09-27-59".*,
        "2026-01-10_09-29-33".*,
        "2026-01-10_09-30-44".*,
        "2026-01-10_09-33-01".*,
        "2026-01-10_09-58-25".*,
        "2026-01-10_10-00-15".*,
        "2026-01-10_10-01-34".*,
        "2026-01-10_10-57-57".*,
        "2026-01-10_10-59-20".*,
        "2026-01-10_11-00-21".*,
        "2026-01-10_11-01-23".*,
        "2026-01-10_11-58-08".*,
        "2026-01-10_12-01-39".*,
        "2026-01-10_12-02-56".*,
        "2026-01-10_12-04-07".*,
        "2026-01-10_12-26-51".*,
        "2026-01-10_12-27-47".*,
        "2026-01-10_12-50-20".*,
        "2026-01-10_13-00-24".*,
        "2026-01-10_13-01-49".*,
        "2026-01-10_13-02-37".*,
        "2026-01-10_13-03-37".*,
        "2026-01-10_13-42-42".*,
    };

    const entries = try arena.alloc(api.CategorizeFileEntry, videos.len);
    for (videos, entries) |video, *entry| {
        entry.* = .{ .path = video, .categorized = false };
    }
    return entries;
}
