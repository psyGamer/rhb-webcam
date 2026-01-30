const std = @import("std");
const dvui = @import("dvui");

const net = @import("../net.zig");

const videoSelector = @import("video_selector.zig").videoSelector;
const videoPlayer = @import("../video_player.zig").videoPlayer;

const Timestamp = @import("common").Timestamp;
const Schedule = @import("common").Schedule;
const Direction = @import("common").Direction;
const Locomotive = @import("common").Locomotive;
const api = @import("common").api;
const time = @import("common").time;

pub const route = "/admin/categorize";

const TrainKey = struct {
    number: u32,
    type: api.Suggestion.Type,
};
const TrainInfo = struct {
    shunting: bool = false,
    from_direction: Direction align(@alignOf(usize)),
    to_direction: Direction align(@alignOf(usize)),
    locomotives: std.ArrayList(Locomotive) = .empty,
};

var selected_video: ?[Timestamp.time_fmt.len]u8 = undefined;
var selected_day: time.Date = undefined;
var selected_index: usize = 0;

var current_videos: api.CategorizeFileList = undefined;
var current_suggestions: ?std.json.Parsed(api.SuggestionList) = undefined;
var current_trains: std.AutoArrayHashMapUnmanaged(TrainKey, TrainInfo) = undefined;

var scroll_to_suggestion: ?u32 = null;
var scroll_to_video: bool = false;
var show_categorized: bool = true;

var focused_text: struct {
    buffer: [64]u8 = undefined,
    id: dvui.Id = .undef,
} = .{};

var playback_config: @import("../video_player.zig").InitOptions.PlaybackConfig = .{ .playing = true, .update = true };

pub fn init(query: []const u8) void {
    // Reset state
    selected_video = null;
    selected_day = .today();

    current_videos = &.{};
    current_suggestions = null;
    current_trains = .empty;

    scroll_to_suggestion = null;
    scroll_to_video = false;

    // Parse query arguments
    var query_arg_iter = std.mem.tokenizeScalar(u8, query, '&');
    while (query_arg_iter.next()) |query_arg| {
        const equal = std.mem.indexOfScalar(u8, query_arg, '=') orelse continue;
        const key = query_arg[0..equal];
        const value = query_arg[(equal + 1)..];

        if (std.mem.eql(u8, key, "video") and value.len == Timestamp.time_fmt.len) {
            selected_video = value[0..Timestamp.time_fmt.len].*;
        } else if (std.mem.eql(u8, key, "day")) {
            selected_day = time.Date.parse(value) catch continue;
        }
    }

    const lifo = dvui.currentWindow().lifo();

    const filelist_url = std.fmt.allocPrint(lifo, "/admin/api/file-list?day={f}", .{selected_day}) catch "";
    defer lifo.free(filelist_url);
    const suggestions_url = std.fmt.allocPrint(lifo, "/admin/api/suggestions?day={f}", .{selected_day}) catch "";
    defer lifo.free(suggestions_url);

    net.fetchJsonObjectLeaky(api.CategorizeFileList, filelist_url, struct {
        pub fn callback(value: net.JsonResultLeaky(api.CategorizeFileList), window: *dvui.Window) void {
            const gpa = window.gpa;

            // Free old data
            for (current_videos) |video| {
                for (video.descs) |desc| {
                    gpa.free(desc.locomotives);
                }
                gpa.free(video.descs);
            }
            gpa.free(current_videos);

            const new_videos = value catch |err| {
                std.log.err("Failed to fetch video list: {}", .{err});
                current_videos = &.{};
                return;
            };

            current_videos = gpa.alloc(api.CategorizeFileEntry, new_videos.len) catch {
                std.log.err("Failed to allocate new videos", .{});
                return;
            };

            for (current_videos, new_videos) |*curr_video, new_video| {
                const descs = gpa.alloc(api.TrainDescription, new_video.descs.len) catch {
                    std.log.err("Failed to new train descriptions for video", .{});
                    current_videos = &.{};
                    return;
                };

                for (descs, new_video.descs) |*curr_desc, new_desc| {
                    const locomotives = gpa.alloc(Locomotive, new_desc.locomotives.len) catch {
                        std.log.err("Failed to new locomotives for train descriptions", .{});
                        current_videos = &.{};
                        return;
                    };

                    for (locomotives, new_desc.locomotives) |*curr_loco, new_loco| {
                        curr_loco.* = new_loco;
                    }

                    curr_desc.number = new_desc.number;
                    curr_desc.shunting = new_desc.shunting;
                    curr_desc.from_direction = new_desc.from_direction;
                    curr_desc.to_direction = new_desc.to_direction;
                    curr_desc.locomotives = locomotives;
                }

                curr_video.path = new_video.path;
                curr_video.descs = descs;
            }

            // Find currently selected
            if (selected_video) |selected| {
                for (current_videos, 0..) |video, idx| {
                    if (std.mem.eql(u8, &video.path, &selected)) {
                        selected_index = idx;
                        break;
                    }
                } else {
                    selected_video = if (current_videos.len > 0) current_videos[0].path else null;
                    selected_index = 0;
                }
            } else {
                selected_video = if (current_videos.len > 0) current_videos[0].path else null;
                selected_index = 0;
            }

            updateCurrentVideo(gpa);

            dvui.refresh(window, @src(), null);
        }
    }.callback) catch {
        const gpa = dvui.currentWindow().gpa;

        for (current_videos) |video| {
            for (video.descs) |desc| {
                gpa.free(desc.locomotives);
            }
            gpa.free(video.descs);
        }
        gpa.free(current_videos);

        current_videos = &.{};
    };

    net.fetchJsonObject(api.SuggestionList, suggestions_url, struct {
        pub fn callback(value: net.JsonResult(api.SuggestionList), window: *dvui.Window) void {
            if (current_suggestions) |suggestions| {
                suggestions.deinit();
            }

            current_suggestions = value catch |err| {
                std.log.err("Failed to fetch train suggestion list: {}", .{err});
                current_suggestions = null;
                return;
            };

            updateCurrentVideo(window.gpa);

            dvui.refresh(window, @src(), null);
        }
    }.callback) catch {};
}
pub fn frame() void {
    if (selected_video == null or current_videos.len == 0) {
        dvui.spinner(@src(), .{ .gravity_x = 0.5, .gravity_y = 0.5 });
        return;
    }

    const box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer box.deinit();

    const theme = dvui.themeGet();
    const gpa = dvui.currentWindow().gpa;
    const lifo = dvui.currentWindow().lifo();

    {
        const selector_box = dvui.box(@src(), .{}, .{ .expand = .vertical });
        defer selector_box.deinit();

        if (videoSelector(@src(), .{
            .videos = current_videos,
            .selected = &selected_index,
            .show_categorized = show_categorized,
            .scroll_to_current = scroll_to_video,
        }, .{ .background = false })) {
            selected_video = current_videos[selected_index].path;
            // Enable auto-play
            playback_config.playing = true;
            playback_config.update = true;
            updateCurrentVideo(gpa);
        }
        scroll_to_video = false;
    }
    {
        const player_box = dvui.box(@src(), .{}, .{ .expand = .both });
        defer player_box.deinit();

        const selected = selected_video orelse current_videos[0].path;
        const video_url = std.fmt.allocPrint(lifo, "/video/{s}", .{selected}) catch "";
        defer lifo.free(video_url);

        videoPlayer(@src(), .{
            .source = video_url,
            .control_bar = .show,
            .playback = &playback_config,
        }, .{ .expand = .both, .corner_radius = .all(6) });

        {
            const video = selected_video.?;

            const ctrl_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5, .padding = .all(8) });
            defer ctrl_box.deinit();

            const valid = current_trains.count() > 0 and check: for (current_trains.values()) |value| {
                if (value.from_direction == value.to_direction and !value.shunting) break false;
                var all_towed = true;
                for (value.locomotives.items) |loco| {
                    if (!loco.towed) all_towed = false;
                    if (loco.number == 0 and loco.category != .none) continue;
                    if (loco.number != 0 and Locomotive.getCategory(loco.number) == loco.category) continue;
                    break :check false;
                }
                if (all_towed) break false;
            } else true;

            const opts: dvui.Options = .{ .font = theme.font_body.larger(2).withWeight(.bold), .padding = .all(8), .margin = .rect(8, 4, 8, 4) };

            _ = dvui.checkbox(@src(), &show_categorized, "Kategorisierte anzeigen", opts);

            const save = enablableButtonLabelIcon(@src(), "Speichern", dvui.entypo.save, .{}, .{}, opts.override(.{ .style = .highlight }), valid);
            const next = enablableButtonLabelIcon(@src(), "Weiter", dvui.entypo.controller_next, .{}, .{}, opts.override(.{ .style = .highlight }), selected_index + 1 < current_videos.len);
            if (enablableButtonLabelIcon(@src(), "Zuschneiden", dvui.entypo.scissors, .{}, .{}, opts.override(.{}), false)) {
                // TODO
            }
            if (enablableButtonLabelIcon(@src(), "Löschen", dvui.entypo.trash, .{}, .{}, opts.override(.{ .style = .err }), true)) {
                dvui.dialog(@src(), .{}, .{
                    .title = "Video löschen?",
                    .message = "Bist du sicher, dass du dieses Video löschen möchtest?",
                    .callafterFn = struct {
                        fn callafter(_: dvui.Id, response: dvui.enums.DialogResponse) !void {
                            if (response == .ok) {
                                // Delete on server
                                const lifo_alloc = dvui.currentWindow().lifo();
                                const delete_path = std.fmt.allocPrint(lifo_alloc, "/admin/api/delete?file={s}", .{&selected_video.?}) catch {
                                    std.log.err("Failed to allocate DELETE url to delete current video", .{});
                                    return;
                                };
                                defer lifo_alloc.free(delete_path);

                                net.delete(delete_path, null);

                                // Delete on client
                                if (dvui.currentWindow().gpa.resize(current_videos, current_videos.len - 1)) {
                                    @memmove(current_videos[selected_index..(current_videos.len - 1)], current_videos[(selected_index + 1)..]);
                                    current_videos.len -= 1;
                                } else {
                                    const videos = dvui.currentWindow().gpa.alloc(api.CategorizeFileEntry, current_videos.len - 1) catch {
                                        std.log.err("Failed to shrink allocation after deleting video", .{});
                                        return;
                                    };

                                    @memcpy(videos[0..selected_index], current_videos[0..selected_index]);
                                    @memcpy(videos[selected_index..], current_videos[(selected_index + 1)..]);

                                    dvui.currentWindow().gpa.free(current_videos);
                                    current_videos = videos;
                                }

                                selected_index = std.math.clamp(selected_index, 0, current_videos.len - 1);
                                selected_video = if (current_videos.len > 0) current_videos[selected_index].path else null;

                                // Enable auto-play
                                playback_config.playing = true;
                                playback_config.update = true;

                                updateCurrentVideo(dvui.currentWindow().gpa);
                            }
                        }
                    }.callafter,
                    .ok_label = "Löschen",
                    .cancel_label = "Abbrechen",
                    .default = .cancel,
                });
            }

            const enter = check: for (dvui.events()) |*ev| {
                if (ev.evt != .key or ev.handled) continue;

                const ke = ev.evt.key;
                if (ke.action != .down) continue;

                switch (ke.code) {
                    .enter => {
                        ev.handled = true;
                        break :check true;
                    },
                    else => continue,
                }
            } else false;

            if (save or (valid and (next or enter))) b: {
                const train_descs = gpa.alloc(api.TrainDescription, current_trains.count()) catch {
                    std.log.err("Failed to allocate current train descriptions", .{});
                    break :b;
                };

                for (current_videos[selected_index].descs) |desc| {
                    gpa.free(desc.locomotives);
                }
                current_videos[selected_index].descs = train_descs;

                for (current_trains.keys(), current_trains.values(), train_descs) |key, value, *desc| {
                    desc.* = .{
                        .number = key.number,

                        .shunting = value.shunting,
                        .from_direction = value.from_direction,
                        .to_direction = value.to_direction,

                        .locomotives = gpa.dupe(Locomotive, value.locomotives.items) catch {
                            std.log.err("Failed to clone locomotives of train description", .{});
                            break :b;
                        },
                    };
                }

                const put_path = std.fmt.allocPrint(lifo, "/admin/api/update?file={s}", .{&video}) catch {
                    std.log.err("Failed to allocate PUT url to update current train descriptions", .{});
                    break :b;
                };
                defer lifo.free(put_path);

                var body_writer: std.Io.Writer.Allocating = .init(lifo);
                defer body_writer.deinit();

                const json_formatter = std.json.fmt(train_descs, .{});
                json_formatter.format(&body_writer.writer) catch {
                    std.log.err("Failed to generate body to update current train descriptions", .{});
                    break :b;
                };

                net.put(put_path, body_writer.written());
            }
            if ((valid or current_trains.count() == 0) and selected_index + 1 < current_videos.len and (next or enter)) {
                selected_index += 1;
                selected_video = current_videos[selected_index].path;

                // Enable auto-play
                playback_config.playing = true;
                playback_config.update = true;

                updateCurrentVideo(gpa);
            }
        }
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
                    const cell_box = quick_select.bodyCell(@src(), cell, highlight_style.cellOptions(cell));
                    defer cell_box.deinit();

                    if (!dvui.firstFrame(cell_box.data().id) and row_idx == scroll_to_suggestion) {
                        quick_select.scroll.si.scrollToOffset(.vertical, cell_box.data().rect.y + cell_box.data().rect.h / 2.0 - quick_select.data().rect.h / 2.0);
                        scroll_to_suggestion = null;
                    }

                    _ = dvui.checkbox(@src(), &curr_checked, null, .{});
                }
                // Nummer
                {
                    defer cell.col_num += 1;
                    const cell_box = quick_select.bodyCell(@src(), cell, highlight_style.cellOptions(cell));
                    defer cell_box.deinit();

                    if (dvui.clicked(cell_box.data(), .{})) curr_checked = !curr_checked;

                    dvui.label(@src(), "{d}", .{suggestion.number}, .{});
                }
                // Typ
                {
                    defer cell.col_num += 1;
                    const cell_box = quick_select.bodyCell(@src(), cell, highlight_style.cellOptions(cell));
                    defer cell_box.deinit();

                    if (dvui.clicked(cell_box.data(), .{})) curr_checked = !curr_checked;

                    dvui.labelNoFmt(@src(), suggestion.classifier, .{}, .{});
                }
                // Herkunf
                {
                    defer cell.col_num += 1;
                    const cell_box = quick_select.bodyCell(@src(), cell, highlight_style.cellOptions(cell));
                    defer cell_box.deinit();

                    if (dvui.clicked(cell_box.data(), .{})) curr_checked = !curr_checked;

                    dvui.labelNoFmt(@src(), suggestion.origin, .{}, .{});
                }
                // Ziel
                {
                    defer cell.col_num += 1;
                    const cell_box = quick_select.bodyCell(@src(), cell, highlight_style.cellOptions(cell));
                    defer cell_box.deinit();

                    if (dvui.clicked(cell_box.data(), .{})) curr_checked = !curr_checked;

                    dvui.labelNoFmt(@src(), suggestion.destination, .{}, .{});
                }
                // Zeit
                {
                    defer cell.col_num += 1;
                    const cell_box = quick_select.bodyCell(@src(), cell, highlight_style.cellOptions(cell));
                    defer cell_box.deinit();

                    if (dvui.clicked(cell_box.data(), .{})) curr_checked = !curr_checked;

                    dvui.label(@src(), "{d:0>2}:{d:0>2}", .{ suggestion.time.hour, suggestion.time.minute }, .{});
                }

                if (curr_checked != was_checked) b: {
                    if (curr_checked) {
                        current_trains.put(gpa, key, .{
                            .from_direction = Direction.known_directions.get(suggestion.origin).?,
                            .to_direction = Direction.known_directions.get(suggestion.destination).?,
                            .locomotives = .fromOwnedSlice(gpa.dupe(Locomotive, suggestion.locomotives) catch {
                                std.log.err("Failed to allocate locomotives for train entry from suggestions", .{});
                                break :b;
                            }),
                        }) catch {
                            std.log.err("Failed to allocate train entry from suggestions", .{});
                        };
                    } else {
                        _ = current_trains.orderedRemove(key);
                    }
                }
            }
        } else dvui.spinner(@src(), .{ .gravity_x = 0.5, .gravity_y = 0.5 });

        if (data_paned.showSecond()) {
            var needs_reindex = false;
            // Always update, so that focusing something entirely different also clears the intermediate buffer
            defer if (dvui.focusedWidgetId()) |id| {
                focused_text.id = id;
            };

            const bold_font = theme.font_body.withWeight(.bold);
            if (dvui.buttonLabelAndIcon(@src(), .{ .button_opts = .{}, .label = "Zug Hinzufügen", .tvg_bytes = dvui.entypo.plus, .icon_first = true }, .{ .expand = .horizontal, .font = bold_font, .style = .highlight })) {
                const key: TrainKey = .{
                    .number = 0,
                    .type = .transit,
                };
                current_trains.put(dvui.currentWindow().gpa, key, .{
                    .from_direction = .filisur,
                    .to_direction = .filisur,
                }) catch {};
            }

            const scroll_area = dvui.scrollArea(@src(), .{}, .{ .background = false, .expand = .horizontal });
            defer scroll_area.deinit();

            var delete_train: usize = std.math.maxInt(usize);
            for (current_trains.keys(), current_trains.values(), 0..) |*key, *value, train_idx| {
                const train_box = dvui.box(@src(), .{}, .{ .id_extra = train_idx, .style = .content, .background = true, .expand = .horizontal, .corner_radius = .all(8), .margin = .all(5), .padding = .all(5) });
                defer train_box.deinit();

                const label_opts: dvui.Options = .{ .font = bold_font, .gravity_y = 0.5 };
                const opt_suggestion_arrival = if (current_suggestions) |suggestions| for (suggestions.value) |sug| {
                    if (sug.number == key.number and sug.type == .arrival) break sug;
                } else null else null;
                const opt_suggestion_departure = if (current_suggestions) |suggestions| for (suggestions.value) |sug| {
                    if (sug.number == key.number and sug.type == .departure) break sug;
                } else null else null;
                const opt_suggestion_transit = if (current_suggestions) |suggestions| for (suggestions.value) |sug| {
                    if (sug.number == key.number and sug.type == .transit) break sug;
                } else null else null;

                const opt_suggestion = opt_suggestion_arrival orelse opt_suggestion_departure orelse opt_suggestion_transit;

                // Information
                if (opt_suggestion) |sug| {
                    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
                    defer hbox.deinit();

                    const full_classifier_names: std.StaticStringMap([]const u8) = .initComptime(.{
                        .{ "R 1", "Regio 1" },
                        .{ "R 38", "Regio 38" },
                        .{ "RE 38", "RegioExpress 38" },
                        .{ "IR 38", "InterRegio 38" },
                        .{ "GEX", "Glacier Express" },
                        .{ "BEX", "Bernina Express" },
                        .{ "G", "Güterzug" },
                    });

                    dvui.labelNoFmt(@src(), full_classifier_names.get(sug.classifier) orelse "", .{}, label_opts);
                    dvui.labelNoFmt(@src(), sug.origin, .{}, .{ .gravity_y = 0.5 });
                    dvui.icon(@src(), "nach", dvui.entypo.arrow_right, .{}, .{ .gravity_y = 0.5 });
                    dvui.labelNoFmt(@src(), sug.destination, .{}, .{ .gravity_y = 0.5 });

                    if (opt_suggestion_arrival) |sug_arrival| if (opt_suggestion_departure) |sug_departure| {
                        dvui.label(@src(), "({f} / {f})", .{ sug_arrival.time, sug_departure.time }, .{ .gravity_y = 0.5 });
                    };
                    if (opt_suggestion_transit) |sug_transit| {
                        dvui.label(@src(), "({f})", .{sug_transit.time}, .{ .gravity_y = 0.5 });
                    }
                }

                var la_train: dvui.Alignment = .init(@src(), 0);
                defer la_train.deinit();

                // Number
                {
                    const hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
                    defer hbox.deinit();

                    input_number: {
                        const src = @src();
                        const result = if (key.number > 0)
                            textInput(src, "{d}", .{key.number}, .{ .intention = .number, .placeholder = "Zugnummer" }, .{ .max_size_content = .sizeM(20, 1) })
                        else
                            // A value of zero indicates a 'null' value
                            textInput(src, "", .{}, .{ .intention = .number, .placeholder = "Zugnummer" }, .{ .max_size_content = .sizeM(20, 1) });

                        if (result) |number_txt| {
                            key.number = if (number_txt.len > 0)
                                std.fmt.parseInt(u32, number_txt, 10) catch break :input_number
                            else
                                0;

                            fetchTrainInfo(key.number);
                            needs_reindex = true;
                        }
                    }

                    la_train.spacer(@src(), 0);

                    {
                        var dir_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5 });
                        defer dir_box.deinit();

                        dvui.labelNoFmt(@src(), "Rangierfahrt", .{}, label_opts.override(.{}));
                        _ = dvui.checkbox(@src(), &value.shunting, null, .{});
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
                        var dir_box = dvui.box(@src(), .{ .dir = .horizontal }, .{});
                        defer dir_box.deinit();

                        dvui.labelNoFmt(@src(), "Von", .{}, label_opts.override(.{ .color_text = text_color }));
                        var choice: usize = @intFromEnum(value.from_direction);
                        _ = enablableDropdown(@src(), &Direction.category_names.values, &choice, .{ .style = style }, !value.shunting);
                        value.from_direction = @enumFromInt(choice);
                    }

                    la_train.spacer(@src(), 0);

                    {
                        var dir_box = dvui.box(@src(), .{ .dir = .horizontal }, .{});
                        defer dir_box.deinit();

                        dvui.labelNoFmt(@src(), "Nach", .{}, label_opts.override(.{ .color_text = text_color }));
                        var choice: usize = @intFromEnum(value.to_direction);
                        _ = enablableDropdown(@src(), &Direction.category_names.values, &choice, .{ .style = style }, !value.shunting);
                        value.to_direction = @enumFromInt(choice);
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
                        key.type = new_type;
                        needs_reindex = true;
                    }
                }

                // Buttons
                {
                    const hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                    defer hbox.deinit();

                    if (dvui.buttonLabelAndIcon(@src(), .{ .button_opts = .{}, .label = "Lok Hinzufügen", .tvg_bytes = dvui.entypo.plus, .icon_first = true }, .{ .expand = .horizontal, .font = bold_font, .style = .highlight })) {
                        value.locomotives.append(dvui.currentWindow().gpa, .{ .number = 0, .category = .none, .towed = false }) catch {};
                    }

                    la_train.spacer(@src(), 0);

                    if (dvui.buttonLabelAndIcon(@src(), .{ .button_opts = .{}, .label = "Zug Löschen", .tvg_bytes = dvui.entypo.trash, .icon_first = true }, .{ .expand = .horizontal, .font = bold_font, .style = .err })) {
                        delete_train = train_idx;
                    }
                }

                // Locomotives
                var modify_loco: struct { usize, usize } = .{ 0, 0 };
                for (value.locomotives.items, 0..) |*loco, loco_idx| {
                    const loco_box = dvui.box(@src(), .{}, .{ .id_extra = loco_idx, .style = .window, .background = true, .expand = .horizontal, .corner_radius = .all(8), .margin = .all(5), .padding = .all(5) });
                    defer loco_box.deinit();

                    var la_loco: dvui.Alignment = .init(@src(), 0);
                    defer la_loco.deinit();

                    {
                        const hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
                        defer hbox.deinit();

                        {
                            const nr_valid = dvui.dataGetPtrDefault(null, hbox.data().id, "nr_valid", bool, true);

                            const src = @src();
                            const text_entry = if (loco.number > 0)
                                textEntry(src, "{d} «{s}»", .{ loco.number, Locomotive.getVariantName(loco.number, selected_day) }, .{ .intention = .number, .placeholder = "Loknummer" }, .{ .min_size_content = .sizeM(18, 1), .style = if (nr_valid.*) null else .err })
                            else
                                // A value of zero indicates a 'null' value
                                textEntry(src, "", .{}, .{ .intention = .number, .placeholder = "Loknummer" }, .{ .min_size_content = .sizeM(18, 1), .style = if (nr_valid.*) null else .err });

                            const id = text_entry.data().id;
                            defer if (focused_text.id != id and id == dvui.focusedWidgetId()) {
                                if (loco.number > 0) {
                                    const written = std.fmt.bufPrint(&focused_text.buffer, "{d}", .{loco.number}) catch unreachable;
                                    @memset(focused_text.buffer[written.len..], 0);
                                } else {
                                    @memset(&focused_text.buffer, 0);
                                }
                            };

                            var suggestion = dvui.suggestion(text_entry, .{ .button = true, .open_on_focus = false, .open_on_text_change = false });

                            if (text_entry.text_changed) b: {
                                nr_valid.* = false;
                                const number = std.fmt.parseInt(u32, text_entry.textGet(), 10) catch break :b;
                                const cateogry = Locomotive.getCategory(number) orelse break :b;

                                loco.number = number;
                                loco.category = cateogry;
                                nr_valid.* = true;
                            }

                            if (suggestion.dropped()) {
                                for (Locomotive.category_ranges.values, 0..) |range, category_idx| {
                                    const category: Locomotive.Category = @enumFromInt(category_idx);
                                    if (loco.category != .none and category != loco.category) continue;

                                    for (range.start..range.end) |number| {
                                        const variant = if (loco.category == .none)
                                            Locomotive.getSpecialVariantName(number, selected_day) orelse continue
                                        else
                                            Locomotive.getVariantName(number, selected_day);

                                        const mi = suggestion.addChoice();
                                        defer mi.deinit();

                                        dvui.label(@src(), "{d} «{s}»", .{ number, variant }, .{});

                                        if (mi.activeRect()) |_| {
                                            suggestion.close();
                                            loco.number = number;
                                            loco.category = category;
                                        }
                                    }
                                }
                            }

                            suggestion.deinit();

                            text_entry.draw();
                            text_entry.deinit();
                        }

                        la_loco.spacer(@src(), 0);

                        dvui.labelNoFmt(@src(), "Geschleppt", .{}, label_opts.override(.{}));
                        _ = dvui.checkbox(@src(), &loco.towed, null, .{ .gravity_y = 0.5 });
                    }
                    {
                        const hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
                        defer hbox.deinit();

                        var choice: usize = @intFromEnum(loco.category);
                        _ = dvui.dropdown(@src(), &Locomotive.category_names.values, &choice, .{ .font = bold_font, .min_size_content = .{ .w = 100 }, .gravity_y = 0.5, .max_size_content = .width(bold_font.sizeM(18, 1).w) });
                        loco.category = @enumFromInt(choice);

                        la_loco.spacer(@src(), 0);

                        const text_disabled: dvui.Color = .average(theme.color(.control, .text), theme.color(.control, .fill));

                        if (enablableButtonIcon(@src(), "Hoch", dvui.entypo.chevron_up, .{}, .{}, .{ .color_text = if (loco_idx == 0) text_disabled else null }, loco_idx > 0)) {
                            modify_loco = .{ loco_idx, loco_idx - 1 };
                        }
                        if (enablableButtonIcon(@src(), "Runter", dvui.entypo.chevron_down, .{}, .{}, .{ .color_text = if (loco_idx == value.locomotives.items.len - 1) text_disabled else null }, loco_idx < value.locomotives.items.len - 1)) {
                            modify_loco = .{ loco_idx, loco_idx + 1 };
                        }
                        if (dvui.buttonIcon(@src(), "Löschen", dvui.entypo.trash, .{}, .{}, .{ .font = bold_font, .style = .err })) {
                            modify_loco = .{ loco_idx, std.math.maxInt(usize) };
                        }
                    }
                }

                const modify_a, const modify_b = modify_loco;
                if (modify_a != modify_b) {
                    if (modify_b == std.math.maxInt(usize)) {
                        _ = value.locomotives.orderedRemove(modify_a);
                    } else {
                        const tmp = value.locomotives.items[modify_a];
                        value.locomotives.items[modify_a] = value.locomotives.items[modify_b];
                        value.locomotives.items[modify_b] = tmp;
                    }
                }
            }

            if (needs_reindex) {
                current_trains.reIndex(dvui.currentWindow().gpa) catch {};
            }
            if (delete_train != std.math.maxInt(usize)) {
                _ = current_trains.orderedRemoveAt(delete_train);
            }
        }
    }

    // Map keys 1-4 onto Albulas for efficency
    for (dvui.events()) |*ev| {
        if (ev.evt != .key or ev.handled) continue;

        const ke = ev.evt.key;
        if (ke.action != .down) continue;

        switch (ke.code) {
            .one, .two, .three, .four => {},
            else => continue,
        }

        const curr_time = Timestamp.parseSimpleTime(&(selected_video orelse break)) orelse break;
        const curr_clock: Schedule.Clock = .{ .hour = curr_time.hour, .minute = curr_time.minute };
        const curr_hour: u32 = if (curr_time.minute < 30) curr_time.hour else (curr_time.hour + 1) % 24;

        const train_number: u32 = switch (ke.code) {
            // St. Moritz -> Chur
            .one, .two => 1110 + @as(u32, switch (curr_hour) {
                6...7 => if (curr_clock.cmp(.{ .hour = 6, .minute = 15 }) == .lt and @intFromEnum(curr_time.weekday()) < @intFromEnum(Timestamp.Weekday.sat))
                    0
                else if (curr_time.weekday() == .sun)
                    6
                else
                    4,

                8...21 => 10 + (curr_hour - 8) * 4,

                22 => if (curr_time.weekday() == .fri or curr_time.weekday() == .sat) 66 else break,
                else => break,
            }),
            // Chur -> St. Moritz
            .three, .four => 1109 + @as(u32, switch (curr_hour) {
                6 => if (curr_time.weekday() != .sun) 0 else break,

                8...22 => 8 + (curr_hour - 8) * 4,

                23 => if (curr_time.weekday() == .fri or curr_time.weekday() == .sat) 68 else break,
                else => break,
            }),
            else => unreachable,
        };

        const key: TrainKey = .{
            .number = train_number,
            .type = switch (ke.code) {
                .one, .three => .arrival,
                .two, .four => .departure,
                else => unreachable,
            },
        };
        if (!current_trains.orderedRemove(key)) {
            current_trains.put(dvui.currentWindow().gpa, key, switch (ke.code) {
                .one => .{ .from_direction = .moritz, .to_direction = .filisur },
                .two => .{ .from_direction = .filisur, .to_direction = .chur },
                .three => .{ .from_direction = .chur, .to_direction = .filisur },
                .four => .{ .from_direction = .filisur, .to_direction = .moritz },
                else => unreachable,
            }) catch {
                std.log.err("Failed to allocate train entry", .{});
            };

            fetchTrainInfo(key.number);
        }

        ev.handled = true;
    }
}

fn updateCurrentVideo(gpa: std.mem.Allocator) void {
    // Scroll most likely suggestion into view
    if (current_suggestions) |suggestions| if (selected_video) |video| {
        const curr_time = Timestamp.parseSimpleTime(&video) orelse return;
        const curr_clock: Schedule.Clock = .{ .hour = curr_time.hour, .minute = curr_time.minute };

        var min_dist: u32 = std.math.maxInt(i32);
        var min_idx: u32 = 0;

        for (suggestions.value, 0..) |sug, idx| {
            const dist = @abs(sug.time.minuteDiff(curr_clock));
            if (dist < min_dist) {
                min_dist = dist;
                min_idx = @intCast(idx);
            }
        }

        scroll_to_suggestion = min_idx;
    };

    // Scroll current video into view
    scroll_to_video = true;

    // Load train descriptions
    current_trains.clearRetainingCapacity();
    if (current_videos.len > 0) {
        iter_desc: for (current_videos[selected_index].descs) |desc| {
            const key: TrainKey = .{
                .number = desc.number,
                .type = if (desc.from_direction != .filisur and desc.to_direction != .filisur)
                    .transit
                else if (desc.from_direction != .filisur)
                    .arrival
                else if (desc.to_direction != .filisur)
                    .departure
                else {
                    std.log.err("Got invalid train description from {}", .{desc});
                    continue :iter_desc;
                },
            };
            current_trains.put(gpa, key, .{
                .shunting = desc.shunting,
                .from_direction = desc.from_direction,
                .to_direction = desc.to_direction,
                .locomotives = .fromOwnedSlice(gpa.dupe(Locomotive, desc.locomotives) catch {
                    std.log.err("Failed to duplicate locomotives of train description", .{});
                    break :iter_desc;
                }),
            }) catch {
                std.log.err("Failed to allocate train entry", .{});
                break :iter_desc;
            };
        }
    }
}
fn fetchTrainInfo(train_number: u32) void {
    const lifo = dvui.currentWindow().lifo();

    const info_url = std.fmt.allocPrint(lifo, "/admin/api/train-info?day={f}&number={d}", .{ selected_day, train_number }) catch "";
    defer lifo.free(info_url);

    net.fetchJsonObjectLeaky(?api.TrainDescription, info_url, struct {
        pub fn callback(opt_desc: net.JsonResultLeaky(?api.TrainDescription), window: *dvui.Window) void {
            const desc = opt_desc catch return orelse return;

            for (current_trains.keys(), current_trains.values()) |key, *value| {
                if (key.number != desc.number) continue;

                value.locomotives.clearRetainingCapacity();
                value.locomotives.appendSlice(window.gpa, desc.locomotives) catch {
                    std.log.err("Failed to insert locomotives from fetched train desciption", .{});
                };

                return;
            }
        }
    }.callback) catch {
        std.log.err("Failed to fetch locomotive information for train", .{});
    };
}

var tmp_buffer: [focused_text.buffer.len]u8 = undefined;
fn textInput(src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype, init_opts: dvui.TextEntryWidget.InitOptions, opts: dvui.Options) ?[]const u8 {
    const te = textEntry(src, fmt, args, init_opts, opts);
    const id = te.data().id;

    defer if (focused_text.id != id and id == dvui.focusedWidgetId()) {
        const written = std.fmt.bufPrint(&focused_text.buffer, fmt, args) catch unreachable;
        @memset(focused_text.buffer[written.len..], 0);
    };

    defer te.deinit();

    te.processEvents();
    te.draw();

    return if (te.text_changed) te.textGet() else null;
}
fn textEntry(src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype, init_opts: dvui.TextEntryWidget.InitOptions, opts: dvui.Options) *dvui.TextEntryWidget {
    const id = dvui.parentGet().extendId(src, opts.idExtra());

    var te_opts = init_opts;
    if (id == dvui.focusedWidgetId()) {
        te_opts.text = .{ .buffer = &focused_text.buffer };

        var te = dvui.widgetAlloc(dvui.TextEntryWidget);
        te.init(src, te_opts, opts);
        te.data().was_allocated_on_widget_stack = true;
        return te;
    } else {
        te_opts.text = .{ .buffer = std.fmt.bufPrint(&tmp_buffer, fmt, args) catch unreachable };

        var te = dvui.widgetAlloc(dvui.TextEntryWidget);
        te.init(src, te_opts, opts);
        te.data().was_allocated_on_widget_stack = true;
        return te;
    }
}

fn enablableButtonIcon(src: std.builtin.SourceLocation, name: []const u8, tvg_bytes: []const u8, init_opts: dvui.ButtonWidget.InitOptions, icon_opts: dvui.IconRenderOptions, opts: dvui.Options, enabled: bool) bool {
    // set label on the button and clear role on icon so they don't duplicate
    const defaults: dvui.Options = .{ .padding = .all(4), .label = .{ .text = name } };
    var bw: dvui.ButtonWidget = undefined;

    const disabled_text_color: dvui.Color = .average(opts.color(.text), opts.color(.fill));
    const disabled_opts: dvui.Options = if (enabled) .{} else .{
        .color_fill_hover = opts.color_fill,
        .color_fill_press = opts.color_fill,
        .color_text = disabled_text_color,
        .color_text_hover = disabled_text_color,
        .color_text_press = disabled_text_color,
        .ninepatch_hover = opts.ninepatch_fill,
        .ninepatch_press = opts.ninepatch_fill,
    };

    bw.init(src, init_opts, defaults.override(opts).override(disabled_opts));
    if (enabled) {
        bw.processEvents();
    }
    bw.drawBackground();

    // When someone passes min_size_content to buttonIcon, they want the icon
    // to be that size, so we pass it through.
    dvui.icon(
        @src(),
        name,
        tvg_bytes,
        icon_opts,
        opts.strip().override(bw.style()).override(.{ .gravity_x = 0.5, .gravity_y = 0.5, .min_size_content = opts.min_size_content, .expand = .ratio, .color_text = opts.color_text, .role = .none }).override(disabled_opts),
    );

    const click = bw.clicked();
    if (enabled) {
        bw.drawFocus();
    }
    bw.deinit();
    return enabled and click;
}
fn enablableButtonLabelIcon(src: std.builtin.SourceLocation, label: []const u8, tvg_bytes: []const u8, init_opts: dvui.ButtonWidget.InitOptions, icon_opts: dvui.IconRenderOptions, opts: dvui.Options, enabled: bool) bool {
    // set label on the button and clear role on icon so they don't duplicate
    const defaults: dvui.Options = .{ .padding = .all(4), .label = .{ .text = label } };
    var bw: dvui.ButtonWidget = undefined;

    const disabled_text_color: dvui.Color = .average(opts.color(.text), opts.color(.fill));
    const disabled_opts: dvui.Options = if (enabled) .{} else .{
        .color_fill_hover = opts.color_fill,
        .color_fill_press = opts.color_fill,
        .color_text = disabled_text_color,
        .color_text_hover = disabled_text_color,
        .color_text_press = disabled_text_color,
        .ninepatch_hover = opts.ninepatch_fill,
        .ninepatch_press = opts.ninepatch_fill,
    };

    bw.init(src, init_opts, defaults.override(opts).override(disabled_opts));
    if (enabled) {
        bw.processEvents();
    }
    bw.drawBackground();

    {
        const outer_hbox = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer outer_hbox.deinit();

        dvui.icon(@src(), label, tvg_bytes, icon_opts, opts.strip().override(.{ .gravity_x = 0.0, .gravity_y = 0.5, .color_text = opts.color_text }).override(disabled_opts));
        dvui.labelNoFmt(@src(), label, .{ .align_x = 0.5, .align_y = 0.5 }, opts.strip().override(.{ .expand = .both }).override(disabled_opts));
    }

    const click = bw.clicked();
    if (enabled) {
        bw.drawFocus();
    }
    bw.deinit();
    return enabled and click;
}

fn enablableDropdown(src: std.builtin.SourceLocation, entries: []const []const u8, choice: *usize, opts: dvui.Options, enabled: bool) bool {
    var dd: dvui.DropdownWidget = undefined;

    const disabled_text_color: dvui.Color = .average(opts.color(.text), opts.color(.fill));
    dd.init(src, .{ .selected_index = choice.*, .label = entries[choice.*] }, if (enabled) opts else opts.override(.{
        .color_fill_hover = opts.color_fill,
        .color_fill_press = opts.color_fill,
        .color_text = disabled_text_color,
        .color_text_hover = disabled_text_color,
        .color_text_press = disabled_text_color,
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
