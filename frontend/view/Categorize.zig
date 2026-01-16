const std = @import("std");
const dvui = @import("dvui");

const time = @import("../time.zig");
const fetch = @import("../fetch.zig");

const Timestamp = @import("common").Timestamp;
const api = @import("common").api;

pub const route = "/categorize";

const Categorize = @This();

selected_video: ?[Timestamp.fmt.len]u8,
selected_day: time.Date,

pub fn init(query: []const u8) Categorize {
    var view: Categorize = .{
        .selected_video = null,
        .selected_day = .today(),
    };

    // Parse query arguments
    var query_arg_iter = std.mem.tokenizeScalar(u8, query, '&');
    while (query_arg_iter.next()) |query_arg| {
        const equal = std.mem.indexOfScalar(u8, query_arg, '=') orelse continue;
        const key = query_arg[0..equal];
        const value = query_arg[(equal + 1)..];

        if (std.mem.eql(u8, key, "video") and value.len == Timestamp.fmt.len) {
            view.selected_video = value[0..Timestamp.fmt.len].*;
        } else if (std.mem.eql(u8, key, "day")) {
            view.selected_day = time.Date.parse(value) catch continue;
        }
    }

    // fetch.fetch("/categorize-api/file-list?day=2024-02-28", struct {
    //     pub fn callback(status: std.http.Status, data: []const u8) void {
    //         std.log.info("Get response {}: {s}", .{ status, data });
    //     }
    // }.callback);
    fetch.fetchJsonObject(api.CategorizeFileList, "/categorize-api/file-list?day=2024-02-28", struct {
        pub fn callback(list: fetch.JsonError!api.CategorizeFileList, window: *dvui.Window) void {
            _ = window; // autofix
            std.log.info("Get response {!any}", .{list});
        }
    }.callback) catch {};

    // dvui.currentWindow().gpa
    // dvui.refresh(win: ?*Window, src: SourceLocation, id: ?Id)

    return view;
}
pub fn frame(view: *Categorize) void {
    dvui.label(@src(), "Video: '{s}' // Day: {f}", .{ if (view.selected_video) |video| &video else "", view.selected_day }, .{});
}
