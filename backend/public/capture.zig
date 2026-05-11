const std = @import("std");
const tk = @import("tokamak");
const fr = @import("fridge");
const zeit = @import("zeit");

const user_frontend = @import("user-frontend");

const Timestamp = @import("common").Timestamp;
const Clock = @import("common").Schedule.Clock;
const Direction = @import("common").Direction;
const Locomotive = @import("common").Locomotive;

const Env = @import("../main.zig").Env;
const Schedules = @import("../main.zig").Schedules;

const DatabaseTrain = @import("../database.zig").Train;
const DatabaseLocomotive = @import("../database.zig").Locomotive;

/// Timestamp for the first video captured by the Filisur webcam
const first_filisur_video = zeit.instant(.{ .source = .{ .iso8601 = "2025-11-19T23:31:21+01:00" } }) catch unreachable;

/// Show a specific capture from the Filisur webcam
pub fn filisurCapture(ctx: *tk.Context, db: *fr.Session, env: *Env, schedules: Schedules, path: []const u8) !void {
    const capture_time = Timestamp.parseSimpleTime(path) orelse return error.NotFound;
    const capture_day = path[0.."YYYY-MM-DD".len];

    // Get previous / next file entry
    const seq = try db.raw(
        \\SELECT * FROM (
        \\    SELECT
        \\        file,
        \\        LAG(file)  OVER (ORDER BY file) AS prev_file,
        \\        LEAD(file) OVER (ORDER BY file) AS next_file
        \\    FROM filisur_capture
        \\)
        \\WHERE file = ?
    , .{path})
        .fetchOne(struct { file: []const u8, prev_file: ?[]const u8, next_file: ?[]const u8 }) orelse return error.NotFound;

    const extension_len = ".xyz".len;
    var image_name: [Timestamp.time_fmt.len + extension_len]u8 = undefined;
    image_name[0..Timestamp.time_fmt.len].* = path[0..Timestamp.time_fmt.len].*;
    if (capture_time.year <= 2022) {
        // Manfred Luckmann archive
        image_name[(image_name.len - extension_len)..][0..extension_len].* = ".jpg".*;
    } else {
        // Our archive
        image_name[(image_name.len - extension_len)..][0..extension_len].* = ".png".*;
    }

    const image_path = try std.fs.path.join(ctx.allocator, &.{ env.key(.WEBCAM_FILISUR_IMAGE), capture_day, &image_name });

    // Validate image exists
    try std.fs.cwd().access(image_path, .{});

    // Setup template data
    var image_view_opts: user_frontend.ImageVideoViewOptions = .{
        .title = "Archiv Aufnahme",
        .source = if (capture_time.year <= 2022) .filisur_old else .filisur_new,
        .time = capture_time,
        .path = path[0..Timestamp.time_fmt.len].*,
        .prev = if (seq.prev_file) |prev| prev[0..Timestamp.time_fmt.len].* else null,
        .next = if (seq.next_file) |next| next[0..Timestamp.time_fmt.len].* else null,
        .has_video = capture_time.instant().timestamp >= first_filisur_video.timestamp,
    };

    // Find associated trains
    find_trains: {
        const schedule = for (schedules) |s| {
            if (s.start_date.after(capture_time) or s.end_date.before(capture_time)) continue;
            break s;
        } else break :find_trains;

        const db_trains = try db.query(DatabaseTrain)
            .where("file", path)
            .findAll();

        var trains: std.ArrayList(user_frontend.ImageVideoViewOptions.Train) = .empty;

        const DirectionData = ?struct { arrival: bool, departure: bool };
        var train_directions: std.AutoArrayHashMapUnmanaged(u32, DirectionData) = .empty;

        for (db_trains) |train| {
            const value_ptr = b: {
                const gop = try train_directions.getOrPut(ctx.allocator, train.number);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .arrival = false, .departure = false };
                }
                break :b gop.value_ptr;
            };

            const from = std.meta.stringToEnum(Direction, train.from_direction orelse {
                value_ptr.* = null;
                continue;
            }) orelse continue;
            const to = std.meta.stringToEnum(Direction, train.to_direction orelse {
                value_ptr.* = null;
                continue;
            }) orelse continue;

            if (from != .filisur and to == .filisur) value_ptr.* = .{ .arrival = true, .departure = value_ptr.*.?.departure };
            if (from == .filisur and to != .filisur) value_ptr.* = .{ .arrival = value_ptr.*.?.arrival, .departure = true };
        }

        const default_date: Timestamp = .{};
        // Scheduled trains
        for (schedule.trains) |train| {
            if (train.applicable_start_date.year != default_date.year and train.applicable_start_date.after(capture_time)) continue;
            if (train.applicable_end_date.year != default_date.year and train.applicable_end_date.before(capture_time)) continue;
            if (!train.applicable_weekdays.contains(capture_time.weekday())) continue;

            // Shunting drives should never be in the scheudle
            const dir_data = (train_directions.get(train.number) orelse continue) orelse continue;

            const train_id = for (db_trains) |db_train| {
                if (db_train.number == train.number) break db_train.id;
            } else continue;

            const db_locos = try db.query(DatabaseLocomotive)
                .where("train_id", train_id)
                .findAll();

            var locos = try ctx.allocator.alloc(Locomotive, db_locos.len);
            for (db_locos) |db_loco| {
                if (db_loco.position >= locos.len) {
                    std.log.err("Out-of-bounds locomotive position {d} (expected < {d})", .{ db_loco.position, locos.len });
                    ctx.allocator.free(locos);
                    locos = &.{};
                    break;
                }

                locos[db_loco.position] = .{
                    .number = db_loco.number,
                    .category = std.meta.stringToEnum(Locomotive.Category, db_loco.category) orelse {
                        std.log.err("Invalid locomotive category '{s}'", .{db_loco.category});
                        ctx.allocator.free(locos);
                        locos = &.{};
                        break;
                    },
                    .towed = db_loco.towed,
                };
            }

            try trains.append(ctx.allocator, .{
                .number = train.number,

                .classifier = @import("common").full_train_classifier_names.get(train.information.classifier) orelse train.information.classifier,
                .origin = train.information.origin,
                .destination = train.information.destination,

                .time = if (dir_data.arrival and dir_data.departure) switch (train.time) {
                    .arrival_departure => |t| .{ .stop = t },
                    .transit => |t| .{ .transit = t },
                } else if (dir_data.arrival) switch (train.time) {
                    .arrival_departure => |t| .{ .arrival = t[0] },
                    .transit => |t| .{ .arrival = t },
                } else if (dir_data.departure) switch (train.time) {
                    .arrival_departure => |t| .{ .departure = t[1] },
                    .transit => |t| .{ .departure = t },
                } else switch (train.time) {
                    .arrival_departure => |t| .{ .transit = t[0] },
                    .transit => |t| .{ .transit = t },
                },

                .locomotives = locos,
            });
        }
        // Service trains
        service_trains: for (train_directions.keys(), train_directions.values()) |k, v| {
            for (trains.items) |existing_train| {
                if (existing_train.number == k) continue :service_trains;
            }

            const train_id = for (db_trains) |db_train| {
                if (db_train.number == k) break db_train.id;
            } else continue;

            const db_locos = try db.query(DatabaseLocomotive)
                .where("train_id", train_id)
                .findAll();

            var locos = try ctx.allocator.alloc(Locomotive, db_locos.len);
            for (db_locos) |db_loco| {
                if (db_loco.position >= locos.len) {
                    std.log.err("Out-of-bounds locomotive position {d} (expected < {d})", .{ db_loco.position, locos.len });
                    ctx.allocator.free(locos);
                    locos = &.{};
                    break;
                }

                locos[db_loco.position] = .{
                    .number = db_loco.number,
                    .category = std.meta.stringToEnum(Locomotive.Category, db_loco.category) orelse {
                        std.log.err("Invalid locomotive category '{s}'", .{db_loco.category});
                        ctx.allocator.free(locos);
                        locos = &.{};
                        break;
                    },
                    .towed = db_loco.towed,
                };
            }

            if (v) |dir_data| {
                try trains.append(ctx.allocator, .{
                    .number = k,

                    .classifier = "Dienstfahrt",
                    .origin = if (dir_data.arrival) "Von Chur" else "Filisur",
                    .destination = if (dir_data.departure) "Nach St. Moritz" else "Filisur",

                    .time = .shunting,

                    .locomotives = locos,
                });
            } else {
                try trains.append(ctx.allocator, .{
                    .number = k,

                    .classifier = "Rangierfahrt",
                    .origin = "",
                    .destination = "",

                    .time = .shunting,

                    .locomotives = locos,
                });
            }
        }

        image_view_opts.trains = trains.items;
    }

    try user_frontend.imageVideoView(ctx.res.writer(), image_view_opts);

    // Cache for a week
    ctx.res.header("Cache-Control", "public, max-age=604800, immutable");

    ctx.res.body = ctx.res.buffer.written();
    ctx.res.content_type = .HTML;
    ctx.responded = true;
}

/// Show a specific capture from the Livestream webcam
pub fn livestreamCapture(ctx: *tk.Context, db: *fr.Session, env: *Env, path: []const u8) !void {
    const capture_time = Timestamp.parseSimpleTime(path) orelse return error.NotFound;
    const capture_day = path[0.."YYYY-MM-DD".len];

    // Get previous / next file entry
    const seq = try db.raw(
        \\SELECT * FROM (
        \\    SELECT
        \\        file, location,
        \\        LAG(file)  OVER (ORDER BY file) AS prev_file,
        \\        LEAD(file) OVER (ORDER BY file) AS next_file
        \\    FROM livestream_capture
        \\)
        \\WHERE file = ?
    , .{path})
        .fetchOne(struct { file: []const u8, location: ?[]const u8, prev_file: ?[]const u8, next_file: ?[]const u8 }) orelse return error.NotFound;

    const extension_len = ".xyz".len;
    var image_name: [Timestamp.time_fmt.len + extension_len]u8 = undefined;
    image_name[0..Timestamp.time_fmt.len].* = path[0..Timestamp.time_fmt.len].*;
    image_name[(image_name.len - extension_len)..][0..extension_len].* = ".png".*;

    const image_path = try std.fs.path.join(ctx.allocator, &.{ env.key(.LIVESTREAM_IMAGE), capture_day, &image_name });

    // Validate image exists
    try std.fs.cwd().access(image_path, .{});

    // Setup template data
    const image_view_opts: user_frontend.ImageVideoViewOptions = .{
        .title = "Archiv Aufnahme",
        .source = .livestream,
        .time = capture_time,
        .path = path[0..Timestamp.time_fmt.len].*,
        .prev = if (seq.prev_file) |prev| prev[0..Timestamp.time_fmt.len].* else null,
        .next = if (seq.next_file) |next| next[0..Timestamp.time_fmt.len].* else null,
        .has_video = capture_time.instant().timestamp >= first_filisur_video.timestamp,
    };

    try user_frontend.imageVideoView(ctx.res.writer(), image_view_opts);

    // Cache for a week
    ctx.res.header("Cache-Control", "public, max-age=604800, immutable");

    ctx.res.body = ctx.res.buffer.written();
    ctx.res.content_type = .HTML;
    ctx.responded = true;
}
