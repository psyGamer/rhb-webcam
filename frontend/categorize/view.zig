const std = @import("std");
const dvui = @import("dvui");

const time = @import("../time.zig");
const fetch = @import("../fetch.zig");

const videoSelector = @import("video_selector.zig").videoSelector;
const videoPlayer = @import("../video_player.zig").videoPlayer;

const Timestamp = @import("common").Timestamp;
const Schedule = @import("common").Schedule;
const api = @import("common").api;

pub const route = "/categorize";

var selected_video: ?[Timestamp.fmt.len]u8 = undefined;
var selected_day: time.Date = undefined;
var selected_index: usize = 0;

var current_videos: ?std.json.Parsed(api.CategorizeFileList) = undefined;
var current_suggestions: ?std.json.Parsed(api.SuggestionList) = undefined;
var current_checked_suggestions: []bool = &.{};

var playback_config: @import("../video_player.zig").InitOptions.PlaybackConfig = .{ .playing = true, .update = true };

pub fn init(query: []const u8) void {
    // Reset state
    selected_video = null;
    selected_day = .today();

    current_videos = null;
    current_suggestions = null;

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

    const lifo = dvui.currentWindow().lifo();

    const filelist_url = std.fmt.allocPrint(lifo, "/categorize-api/file-list?day={f}", .{selected_day}) catch "";
    defer lifo.free(filelist_url);
    const suggestions_url = std.fmt.allocPrint(lifo, "/categorize-api/suggestions?day={f}", .{selected_day}) catch "";
    defer lifo.free(suggestions_url);

    fetch.fetchJsonObject(api.CategorizeFileList, filelist_url, struct {
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

    fetch.fetchJsonObject(api.SuggestionList, suggestions_url, struct {
        pub fn callback(value: fetch.JsonResult(api.SuggestionList), window: *dvui.Window) void {
            if (current_suggestions) |suggestions| {
                suggestions.deinit();
            }

            current_suggestions = value catch |err| {
                std.log.err("Failed to fetch train suggestion list: {}", .{err});
                current_suggestions = null;
                return;
            };
            current_checked_suggestions = window.gpa.realloc(current_checked_suggestions, current_suggestions.?.value.len) catch |err| {
                std.log.err("Failed to allocate checked suggestion list: {}", .{err});
                current_suggestions = null;
                return;
            };

            dvui.refresh(window, @src(), null);
        }
    }.callback) catch {};
}
pub fn frame() void {
    const videos = current_videos orelse {
        dvui.spinner(@src(), .{ .gravity_x = 0.5, .gravity_y = 0.5 });
        return;
    };
    if (selected_video == null or videos.value.len == 0) {
        dvui.labelNoFmt(@src(), "No videos available", .{}, .{ .gravity_x = 0.5, .gravity_y = 0.5 });
        return;
    }

    const box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer box.deinit();

    const lifo = dvui.currentWindow().lifo();

    {
        const selector_box = dvui.box(@src(), .{}, .{ .expand = .vertical });
        defer selector_box.deinit();

        dvui.label(@src(), "Video: '{s}' // Day: {f}", .{ if (selected_video) |video| &video else "", selected_day }, .{});
        if (videoSelector(@src(), .{ .videos = videos.value, .selected = &selected_index }, .{ .background = false })) {
            selected_video = videos.value[selected_index].path;
            playback_config.playing = true; // Enable auto-play
            playback_config.update = true; // Enable auto-play
        }
    }
    {
        const player_box = dvui.box(@src(), .{}, .{ .expand = .vertical });
        defer player_box.deinit();

        const selected = selected_video orelse videos.value[0].path;
        const video_url = std.fmt.allocPrint(lifo, "video/{s}", .{selected}) catch "";
        defer lifo.free(video_url);

        // videoPlayer(@src(), .{
        //     .source = video_url,
        //     .control_bar = .show,
        //     .playback = &playback_config,
        // }, .{});
    }
    {
        const data_box = dvui.box(@src(), .{}, .{ .expand = .vertical });
        defer data_box.deinit();

        if (current_suggestions) |suggestions| {
            const quick_select = dvui.grid(@src(), .{ .num_cols = 6 }, .{}, .{ .background = true });
            defer quick_select.deinit();

            // // Find out if any row was clicked on.
            // for (dvui.events()) |*e| {
            //     if (!dvui.eventMatchSimple(e, quick_select.data()) or e.evt != .mouse)
            //         continue;

            //     const me = e.evt.mouse;
            //     if (!(me.action == .press and me.button.pointer()) or !(me.action == .release and me.button.touch()))
            //         continue;

            //     if (quick_select.pointToCell(me.p)) |cell| {
            //         if (cell.col_num <= 0) continue;
            //         current_checked_suggestions[cell.row_num] = !current_checked_suggestions[cell.row_num];
            //         break;
            //     }
            // }

            var highlight_style: dvui.GridWidget.CellStyle.HoveredRow = .{ .cell_opts = .{ .color_fill_hover = .gray, .background = true } };
            highlight_style.processEvents(quick_select);

            dvui.gridHeading(@src(), quick_select, 0, "", .fixed, .{});
            dvui.gridHeading(@src(), quick_select, 1, "Nr.", .fixed, .{});
            dvui.gridHeading(@src(), quick_select, 2, "Typ", .fixed, .{});
            dvui.gridHeading(@src(), quick_select, 3, "Herkunf", .fixed, .{});
            dvui.gridHeading(@src(), quick_select, 4, "Ziel", .fixed, .{});
            dvui.gridHeading(@src(), quick_select, 5, "Zeit", .fixed, .{});

            for (suggestions.value, 0..) |suggestion, row_idx| {
                const curr_checked = &current_checked_suggestions[row_idx];
                var cell: dvui.GridWidget.Cell = .colRow(0, row_idx);

                // Selection
                {
                    defer cell.col_num += 1;
                    var cell_box = quick_select.bodyCell(@src(), cell, highlight_style.cellOptions(cell));
                    defer cell_box.deinit();

                    _ = dvui.checkbox(@src(), curr_checked, null, .{});
                }
                // Nummer
                {
                    defer cell.col_num += 1;
                    var cell_box = quick_select.bodyCell(@src(), cell, highlight_style.cellOptions(cell));
                    defer cell_box.deinit();

                    if (dvui.clicked(cell_box.data(), .{})) curr_checked.* = !curr_checked.*;

                    dvui.label(@src(), "{d}", .{suggestion.number}, .{});
                }
                // Typ
                {
                    defer cell.col_num += 1;
                    var cell_box = quick_select.bodyCell(@src(), cell, highlight_style.cellOptions(cell));
                    defer cell_box.deinit();

                    if (dvui.clicked(cell_box.data(), .{})) curr_checked.* = !curr_checked.*;

                    dvui.labelNoFmt(@src(), suggestion.classifier, .{}, .{});
                }
                // Herkunf
                {
                    defer cell.col_num += 1;
                    var cell_box = quick_select.bodyCell(@src(), cell, highlight_style.cellOptions(cell));
                    defer cell_box.deinit();

                    if (dvui.clicked(cell_box.data(), .{})) curr_checked.* = !curr_checked.*;

                    dvui.labelNoFmt(@src(), suggestion.origin, .{}, .{});
                }
                // Ziel
                {
                    defer cell.col_num += 1;
                    var cell_box = quick_select.bodyCell(@src(), cell, highlight_style.cellOptions(cell));
                    defer cell_box.deinit();

                    if (dvui.clicked(cell_box.data(), .{})) curr_checked.* = !curr_checked.*;

                    dvui.labelNoFmt(@src(), suggestion.destination, .{}, .{});
                }
                // Zeit
                {
                    defer cell.col_num += 1;
                    var cell_box = quick_select.bodyCell(@src(), cell, highlight_style.cellOptions(cell));
                    defer cell_box.deinit();

                    if (dvui.clicked(cell_box.data(), .{})) curr_checked.* = !curr_checked.*;

                    dvui.label(@src(), "{d:0>2}:{d:0>2}", .{ suggestion.time.hour, suggestion.time.minute }, .{});
                }
            }
        }
    }
}
