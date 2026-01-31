const std = @import("std");
const tk = @import("tokamak");
const fr = @import("fridge");
const zeit = @import("zeit");

const user_frontend = @import("user-frontend");

const Timestamp = @import("common").Timestamp;
const Clock = @import("common").Schedule.Clock;
const Direction = @import("common").Direction;
const Locomotive = @import("common").Locomotive;

const Env = @import("main.zig").Env;
const Schedules = @import("main.zig").Schedules;

const DatabaseTrain = @import("database.zig").Train;
const DatabaseLocomotive = @import("database.zig").Locomotive;

pub fn latestImage(ctx: *tk.Context, env: *Env) !void {
    // Find the latest image
    var curr_date: tk.time.Date = .today();
    var curr_date_buf: ["YYYY-MM-DD".len]u8 = undefined;

    var curr_date_dir: std.fs.Dir = while (true) {
        const curr_date_str = std.fmt.bufPrint(&curr_date_buf, "{f}", .{curr_date}) catch unreachable;
        const curr_path = try std.fs.path.join(ctx.allocator, &.{ env.key(.WEBCAM_VIDEO_ARCHIVE), curr_date_str });

        break std.fs.cwd().openDir(curr_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                curr_date = curr_date.add(.day, -1);
                continue;
            },
            else => |e| return e,
        };
    };
    defer curr_date_dir.close();

    var last_file: [Timestamp.time_fmt.len]u8 = "0000-00-00_00-00-00".*;

    var file_iter = curr_date_dir.iterate();
    while (try file_iter.next()) |entry| {
        if (entry.kind != .file or entry.name.len < Timestamp.time_fmt.len) continue;

        const file = entry.name[0..Timestamp.time_fmt.len];
        if (!Timestamp.isValidSimpleTime(file)) continue;

        // Alphanumeric comparison
        for (file, last_file) |lhs_char, rhs_char| {
            if (lhs_char > rhs_char) {
                last_file = file.*;
                break;
            }
        }
    }

    const last_time = Timestamp.parseSimpleTime(&last_file) orelse {
        std.log.err("Found invalid latest file: '{s}'", .{&last_file});
        ctx.res.setStatus(.internal_server_error);
        ctx.responded = true;
        return;
    };

    try user_frontend.imageView(ctx.res.writer(), .{
        .title = "Aktuelle Aufnahme",
        .time = last_time,
        .path = last_file,
    });

    ctx.res.body = ctx.res.buffer.written();
    ctx.res.content_type = .HTML;
    ctx.responded = true;
}

pub fn archiveImage(ctx: *tk.Context, db: *fr.Session, env: *Env, schedules: Schedules, path: []const u8) !void {
    // Validate path exists
    const video_time = Timestamp.parseSimpleTime(path) orelse return;

    const day = path[0.."YYYY-MM-DD".len];

    const video_extension = ".mp4";
    var video_name: [Timestamp.time_fmt.len + video_extension.len]u8 = undefined;
    video_name[0..Timestamp.time_fmt.len].* = path[0..Timestamp.time_fmt.len].*;
    video_name[(video_name.len - video_extension.len)..][0..video_extension.len].* = video_extension.*;

    const video_path = try std.fs.path.join(ctx.allocator, &.{ env.key(.WEBCAM_VIDEO_ARCHIVE), day, &video_name });

    try std.fs.cwd().access(video_path, .{});

    // Setup template data
    var image_view_opts: user_frontend.ImageViewOptions = .{
        .title = "Archiv Aufnahme",
        .time = video_time,
        .path = path[0..Timestamp.time_fmt.len].*,
    };

    // Find associated trains
    find_trains: {
        const schedule = for (schedules) |s| {
            if (s.start_date.after(video_time) or s.end_date.before(video_time)) continue;
            break s;
        } else break :find_trains;

        const db_trains = try db.query(DatabaseTrain)
            .where("file", path)
            .findAll();
        std.log.info("DB Trains: {any}", .{db_trains});

        var trains: std.ArrayList(user_frontend.ImageViewOptions.Train) = .empty;

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
            if (train.applicable_start_date.year != default_date.year and train.applicable_start_date.after(video_time)) continue;
            if (train.applicable_end_date.year != default_date.year and train.applicable_end_date.before(video_time)) continue;
            if (!train.applicable_weekdays.contains(video_time.weekday())) continue;

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

    try user_frontend.imageView(ctx.res.writer(), image_view_opts);

    ctx.res.body = ctx.res.buffer.written();
    ctx.res.content_type = .HTML;
    ctx.responded = true;
}
