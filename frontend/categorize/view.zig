const std = @import("std");
const dvui = @import("dvui");

const time = @import("../time.zig");
const fetch = @import("../fetch.zig");

const videoSelector = @import("video_selector.zig").videoSelector;
const videoPlayer = @import("../video_player.zig").videoPlayer;

const Timestamp = @import("common").Timestamp;
const Schedule = @import("common").Schedule;
const Direction = @import("common").Direction;
const api = @import("common").api;

pub const route = "/categorize";

const TrainKey = struct {
    number: u32,
    type: api.Suggestion.Type,
};
const TrainInfo = struct {
    shunting: bool = false,
    from_direction: Direction align(@alignOf(usize)),
    to_direction: Direction align(@alignOf(usize)),
};

var selected_video: ?[Timestamp.fmt.len]u8 = undefined;
var selected_day: time.Date = undefined;
var selected_index: usize = 0;

var current_videos: ?std.json.Parsed(api.CategorizeFileList) = undefined;
var current_suggestions: ?std.json.Parsed(api.SuggestionList) = undefined;
var current_trains: std.AutoArrayHashMapUnmanaged(TrainKey, TrainInfo) = undefined;

var focused_text: struct {
    buffer: [64]u8 = undefined,
    id: dvui.Id = .undef,
} = .{};

var playback_config: @import("../video_player.zig").InitOptions.PlaybackConfig = .{ .playing = true, .update = true };

pub fn init(query: []const u8) void {
    // Reset state
    selected_video = null;
    selected_day = .today();

    current_videos = null;
    current_suggestions = null;
    current_trains = .empty;

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
        const data_paned = dvui.paned(@src(), .{ .direction = .vertical, .collapsed_size = 0, .handle_dynamic = .{} }, .{ .expand = .vertical });
        defer data_paned.deinit();

        if (data_paned.showFirst()) if (current_suggestions) |suggestions| {
            const quick_select = dvui.grid(@src(), .{ .num_cols = 6 }, .{}, .{ .background = true });
            defer quick_select.deinit();

            var highlight_style: dvui.GridWidget.CellStyle.HoveredRow = .{ .cell_opts = .{ .color_fill_hover = .gray, .background = true } };
            highlight_style.processEvents(quick_select);

            dvui.gridHeading(@src(), quick_select, 0, "", .fixed, .{});
            dvui.gridHeading(@src(), quick_select, 1, "Nr.", .fixed, .{});
            dvui.gridHeading(@src(), quick_select, 2, "Typ", .fixed, .{});
            dvui.gridHeading(@src(), quick_select, 3, "Herkunf", .fixed, .{});
            dvui.gridHeading(@src(), quick_select, 4, "Ziel", .fixed, .{});
            dvui.gridHeading(@src(), quick_select, 5, "Zeit", .fixed, .{});

            for (suggestions.value, 0..) |suggestion, row_idx| {
                const key: TrainKey = .{ .number = suggestion.number, .type = suggestion.type };
                const was_checked = current_trains.contains(key);
                var curr_checked = was_checked;

                var cell: dvui.GridWidget.Cell = .colRow(0, row_idx);

                // Selection
                {
                    defer cell.col_num += 1;
                    var cell_box = quick_select.bodyCell(@src(), cell, highlight_style.cellOptions(cell));
                    defer cell_box.deinit();

                    _ = dvui.checkbox(@src(), &curr_checked, null, .{});
                }
                // Nummer
                {
                    defer cell.col_num += 1;
                    var cell_box = quick_select.bodyCell(@src(), cell, highlight_style.cellOptions(cell));
                    defer cell_box.deinit();

                    if (dvui.clicked(cell_box.data(), .{})) curr_checked = !curr_checked;

                    dvui.label(@src(), "{d}", .{suggestion.number}, .{});
                }
                // Typ
                {
                    defer cell.col_num += 1;
                    var cell_box = quick_select.bodyCell(@src(), cell, highlight_style.cellOptions(cell));
                    defer cell_box.deinit();

                    if (dvui.clicked(cell_box.data(), .{})) curr_checked = !curr_checked;

                    dvui.labelNoFmt(@src(), suggestion.classifier, .{}, .{});
                }
                // Herkunf
                {
                    defer cell.col_num += 1;
                    var cell_box = quick_select.bodyCell(@src(), cell, highlight_style.cellOptions(cell));
                    defer cell_box.deinit();

                    if (dvui.clicked(cell_box.data(), .{})) curr_checked = !curr_checked;

                    dvui.labelNoFmt(@src(), suggestion.origin, .{}, .{});
                }
                // Ziel
                {
                    defer cell.col_num += 1;
                    var cell_box = quick_select.bodyCell(@src(), cell, highlight_style.cellOptions(cell));
                    defer cell_box.deinit();

                    if (dvui.clicked(cell_box.data(), .{})) curr_checked = !curr_checked;

                    dvui.labelNoFmt(@src(), suggestion.destination, .{}, .{});
                }
                // Zeit
                {
                    defer cell.col_num += 1;
                    var cell_box = quick_select.bodyCell(@src(), cell, highlight_style.cellOptions(cell));
                    defer cell_box.deinit();

                    if (dvui.clicked(cell_box.data(), .{})) curr_checked = !curr_checked;

                    dvui.label(@src(), "{d:0>2}:{d:0>2}", .{ suggestion.time.hour, suggestion.time.minute }, .{});
                }

                if (curr_checked != was_checked) {
                    if (curr_checked) {
                        current_trains.put(dvui.currentWindow().gpa, key, .{
                            .from_direction = Direction.known_directions.get(suggestion.origin).?,
                            .to_direction = Direction.known_directions.get(suggestion.destination).?,
                        }) catch {};
                    } else {
                        _ = current_trains.swapRemove(key);
                    }
                }
            }
        };

        if (data_paned.showSecond()) {
            var needs_reindex = false;
            // Always update, so that focusing something entirely different also clears the intermediate buffer
            defer if (dvui.focusedWidgetId()) |id| {
                focused_text.id = id;
            };

            for (current_trains.keys(), current_trains.values(), 0..) |*key, *value, idx| {
                const train_box = dvui.box(@src(), .{}, .{ .id_extra = idx, .style = .control, .background = true, .corner_radius = .all(8) });
                defer train_box.deinit();

                const theme = dvui.themeGet();
                const label_opts: dvui.Options = .{ .font = theme.font_body.withWeight(.bold), .gravity_y = 0.5 };
                const left_width = 175;

                // Number
                input_number: {
                    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
                    defer hbox.deinit();

                    dvui.labelNoFmt(@src(), "Zugnummer", .{}, label_opts.override(.{ .min_size_content = .{ .w = left_width - dvui.LabelWidget.defaults.padding.?.x * 2 } }));

                    const src = @src();
                    const result = if (key.number > 0)
                        textInput(src, "{d}", .{key.number})
                    else
                        // A value of zero indicates a 'null' value
                        textInput(src, "", .{});

                    if (result) |number_txt| {
                        key.number = if (number_txt.len > 0)
                            std.fmt.parseInt(u32, number_txt, 10) catch break :input_number
                        else
                            0;
                        needs_reindex = true;
                    }
                }
                // Diretion
                input_direction: {
                    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
                    defer hbox.deinit();

                    const style: dvui.Theme.Style.Name = if (value.from_direction != value.to_direction)
                        .control
                    else
                        .err;

                    const text_color: dvui.Color = if (value.shunting)
                        .average(theme.color(style, .text), theme.color(style, .fill))
                    else
                        theme.color(style, .text);

                    {
                        var dir_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .min_size_content = .{ .w = left_width } });
                        defer dir_box.deinit();

                        dvui.labelNoFmt(@src(), "Von", .{}, label_opts.override(.{ .color_text = text_color }));
                        var choice: usize = @intFromEnum(value.from_direction);
                        _ = enablableDropdown(@src(), &Direction.category_names.values, &choice, .{ .style = style, .color_text = text_color }, !value.shunting);
                        value.from_direction = @enumFromInt(choice);
                    }
                    {
                        var dir_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .min_size_content = .{ .w = left_width } });
                        defer dir_box.deinit();

                        dvui.labelNoFmt(@src(), "Nach", .{}, label_opts.override(.{ .color_text = text_color }));
                        var choice: usize = @intFromEnum(value.to_direction);
                        _ = enablableDropdown(@src(), &Direction.category_names.values, &choice, .{ .style = style, .color_text = text_color }, !value.shunting);
                        value.to_direction = @enumFromInt(choice);
                    }
                    {
                        var dir_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5 });
                        defer dir_box.deinit();

                        dvui.labelNoFmt(@src(), "Rangier", .{}, label_opts.override(.{ .color_text = text_color }));
                        _ = dvui.checkbox(@src(), &value.shunting, null, .{});
                    }

                    const new_type: api.Suggestion.Type = if (value.from_direction != .filisur and value.to_direction != .filisur)
                        .transit
                    else if (value.from_direction != .filisur)
                        .arrival
                    else if (value.to_direction != .filisur)
                        .departure
                    else
                        break :input_direction;

                    if (key.type != new_type) {
                        std.log.info("Change type of '{d}' from {} to {}", .{ key.number, key.type, new_type });
                        key.type = new_type;
                        needs_reindex = true;
                    }
                }
            }
            if (needs_reindex) {
                current_trains.reIndex(dvui.currentWindow().gpa) catch {};
            }
        }
    }
}

fn textInput(src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    const id = dvui.parentGet().extendId(src, 0);

    if (id == focused_text.id or id == dvui.focusedWidgetId()) {
        if (focused_text.id != id) {
            focused_text.id = id;

            const written = std.fmt.bufPrint(&focused_text.buffer, fmt, args) catch unreachable;
            @memset(focused_text.buffer[written.len..], 0);
        }

        var te = dvui.textEntry(src, .{ .text = .{ .buffer = &focused_text.buffer }, .intention = .number }, .{ .max_size_content = .sizeM(20, 1) });
        defer te.deinit();

        return if (te.text_changed) te.textGet() else null;
    } else {
        var tmp_buffer: [focused_text.buffer.len]u8 = undefined;
        const written = std.fmt.bufPrint(&tmp_buffer, fmt, args) catch unreachable;

        var te = dvui.textEntry(src, .{ .text = .{ .buffer = written }, .intention = .number }, .{ .max_size_content = .sizeM(20, 1) });
        defer te.deinit();

        return null;
    }
}
fn enablableDropdown(src: std.builtin.SourceLocation, entries: []const []const u8, choice: *usize, opts: dvui.Options, enabled: bool) bool {
    var dd: dvui.DropdownWidget = undefined;
    dd.init(src, .{ .selected_index = choice.*, .label = entries[choice.*] }, if (enabled) opts else opts.override(.{
        .color_fill_hover = opts.color_fill,
        .color_fill_press = opts.color_fill,
        .color_text_hover = opts.color_text,
        .color_text_press = opts.color_text,
        .ninepatch_hover = opts.ninepatch_fill,
        .ninepatch_press = opts.ninepatch_fill,
    }));

    if (!enabled) {
        dd.deinit();
        return false;
    }

    var ret = false;
    if (dd.dropped()) {
        for (entries, 0..) |e, i| {
            if (dd.addChoiceLabel(e)) {
                choice.* = i;
                ret = true;
            }
        }
    }

    dd.deinit();
    return ret;
}
