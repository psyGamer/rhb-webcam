const std = @import("std");
const dvui = @import("dvui");

const time = @import("../time.zig");
const fetch = @import("../fetch.zig");

const videoSelector = @import("../video_selector.zig").videoSelector;

const Timestamp = @import("common").Timestamp;
const api = @import("common").api;

pub const route = "/categorize";

var selected_video: ?[Timestamp.fmt.len]u8 = undefined;
var selected_day: time.Date = undefined;
var selected_index: usize = 0;

var current_videos: ?std.json.Parsed(api.CategorizeFileList) = undefined;

pub fn init(query: []const u8) void {
    // Reset state
    selected_video = null;
    selected_day = .today();
    current_videos = null;

    // Parse query arguments
    var query_arg_iter = std.mem.tokenizeScalar(u8, query, '&');
    while (query_arg_iter.next()) |query_arg| {
        const equal = std.mem.indexOfScalar(u8, query_arg, '=') orelse continue;
        const key = query_arg[0..equal];
        const value = query_arg[(equal + 1)..];

        if (std.mem.eql(u8, key, "video") and value.len == Timestamp.fmt.len) {
            selected_video = value[0..Timestamp.fmt.len].*;
        } else if (std.mem.eql(u8, key, "day")) {
            selected_day = time.Date.parse(value) catch continue;
        }
    }

    fetch.fetchJsonObject(api.CategorizeFileList, "/categorize-api/file-list?day=2024-02-28", struct {
        pub fn callback(value: fetch.JsonResult(api.CategorizeFileList), window: *dvui.Window) void {
            if (current_videos) |videos| {
                videos.deinit();
            }

            current_videos = value catch |err| {
                std.log.err("Failed to fetch video list: {}", .{err});
                current_videos = null;
                return;
            };
            const videos = current_videos.?.value;

            // Find currently selected
            if (selected_video) |selected| {
                for (videos, 0..) |video, idx| {
                    if (std.mem.eql(u8, &video.path, &selected)) {
                        selected_index = idx;
                        break;
                    }
                } else {
                    selected_video = if (videos.len > 0) videos[0].path else null;
                    selected_index = 0;
                }
            } else {
                selected_video = if (videos.len > 0) videos[0].path else null;
                selected_index = 0;
            }

            dvui.refresh(window, @src(), null);
        }
    }.callback) catch {
        if (current_videos) |videos| {
            videos.deinit();
        }
    };
}
pub fn frame() void {
    dvui.label(@src(), "Video: '{s}' // Day: {f}", .{ if (selected_video) |video| &video else "", selected_day }, .{});

    if (current_videos) |videos| {
        if (videoSelector(@src(), .{ .videos = videos.value, .selected = &selected_index }, .{ .background = false })) {
            selected_video = videos.value[selected_index].path;
        }
    } else {
        dvui.spinner(@src(), .{});
    }
}
