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
            if (lhs_char < rhs_char) {
                break;
            }
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

pub fn archiveFull(ctx: *tk.Context, env: *Env) !void {
    return archiveOverview(ctx, env, "");
}
pub fn archive(ctx: *tk.Context, db: *fr.Session, env: *Env, schedules: Schedules, path: []const u8) !void {
    // Dispatch to image view / archive overview depending on path
    if (path.len == Timestamp.time_fmt.len) {
        return archiveImage(ctx, db, env, schedules, path);
    } else if (path.len <= Timestamp.date_fmt.len) {
        return archiveOverview(ctx, env, path);
    }

    return error.NotFound;
}

fn archiveImage(ctx: *tk.Context, db: *fr.Session, env: *Env, schedules: Schedules, path: []const u8) !void {
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

// For non-cyptographic randomness
var prng: std.Random.DefaultPrng = .init(0);
var rand = prng.random();

fn archiveOverview(ctx: *tk.Context, env: *Env, path: []const u8) !void {
    const today: tk.time.Date = .today();

    var date_it = std.mem.splitScalar(u8, path, '-');
    var is_done = true;

    switch (path.len) {
        "YYYY-MM-DD".len => {
            const year = std.fmt.parseInt(u16, date_it.next() orelse return error.NotFound, 10) catch return error.NotFound;
            const month = std.fmt.parseInt(u8, date_it.next() orelse return error.NotFound, 10) catch return error.NotFound;
            const day = std.fmt.parseInt(u8, date_it.next() orelse return error.NotFound, 10) catch return error.NotFound;

            if (today.day == day and today.month == month and today.year == year) {
                // Still in progress
                is_done = false;
            }

            const dir_path = try std.fs.path.join(ctx.allocator, &.{ env.key(.WEBCAM_VIDEO_ARCHIVE), path });

            var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
            defer dir.close();

            var elements: std.ArrayList(user_frontend.ArchiveViewOptions.Element) = .empty;

            var entry_iter = dir.iterate();
            while (try entry_iter.next()) |entry| {
                if (entry.kind != .file or entry.name.len < Timestamp.time_fmt.len) continue;

                const file_name = entry.name[0..Timestamp.time_fmt.len];
                const file_time = Timestamp.parseSimpleTime(file_name) orelse continue;

                try elements.append(ctx.allocator, .{
                    .capture_count = 0, // Indivual images don't have a capture
                    .preview_image = file_name.*,
                    .time = file_time,
                });
            }

            user_frontend.ArchiveViewOptions.Element.sort(elements.items);
            try user_frontend.archiveView(ctx.res.writer(), .{
                .type = .day,
                .date = .{ .year = year, .month = month, .day = day },

                .elements = elements.items,
            });
        },
        "YYYY-MM".len => {
            const year = std.fmt.parseInt(u16, date_it.next() orelse return error.NotFound, 10) catch return error.NotFound;
            const month = std.fmt.parseInt(u8, date_it.next() orelse return error.NotFound, 10) catch return error.NotFound;

            if (today.month == month and today.year == year) {
                // Still in progress
                is_done = false;
            }

            var archive_dir = try std.fs.cwd().openDir(env.key(.WEBCAM_VIDEO_ARCHIVE), .{ .iterate = true });
            defer archive_dir.close();

            var elements: std.ArrayList(user_frontend.ArchiveViewOptions.Element) = .empty;
            var files: std.ArrayList([Timestamp.time_fmt.len]u8) = .empty;

            var dir_iter = archive_dir.iterate();
            while (try dir_iter.next()) |dir_entry| {
                if (dir_entry.kind != .directory or dir_entry.name.len < Timestamp.date_fmt.len) continue;

                const dir_name = dir_entry.name[0..Timestamp.date_fmt.len];
                const dir_time = Timestamp.parseSimpleDate(dir_name) orelse continue;
                if (dir_time.year != year or @intFromEnum(dir_time.month) != month) continue;

                var dir = try archive_dir.openDir(dir_name, .{ .iterate = true });
                defer dir.close();

                var file_iter = dir.iterate();
                while (try file_iter.next()) |file_entry| {
                    if (file_entry.kind != .file or file_entry.name.len < Timestamp.time_fmt.len) continue;

                    const file_name = file_entry.name[0..Timestamp.time_fmt.len];
                    if (!Timestamp.isValidSimpleTime(file_name)) continue;

                    try files.append(ctx.allocator, file_name.*);
                }

                const preview_file = files.items[rand.uintLessThan(usize, files.items.len)];
                defer files.clearRetainingCapacity();

                try elements.append(ctx.allocator, .{
                    .capture_count = @intCast(files.items.len),
                    .preview_image = preview_file,
                    .time = dir_time,
                });
            }

            user_frontend.ArchiveViewOptions.Element.sort(elements.items);
            try user_frontend.archiveView(ctx.res.writer(), .{
                .type = .month,
                .date = .{ .year = year, .month = month, .day = 0 },

                .elements = elements.items,
            });
        },
        "YYYY".len => {
            const year = std.fmt.parseInt(u16, date_it.next() orelse return error.NotFound, 10) catch return error.NotFound;

            if (today.year == year) {
                // Still in progress
                is_done = false;
            }

            var archive_dir = try std.fs.cwd().openDir(env.key(.WEBCAM_VIDEO_ARCHIVE), .{ .iterate = true });
            defer archive_dir.close();

            var elements: std.ArrayList(user_frontend.ArchiveViewOptions.Element) = .empty;
            var files: std.ArrayList([Timestamp.time_fmt.len]u8) = .empty;
            var month_dirs: std.AutoArrayHashMapUnmanaged(zeit.Month, std.ArrayList([Timestamp.date_fmt.len]u8)) = .empty;

            var dir_iter = archive_dir.iterate();
            while (try dir_iter.next()) |dir_entry| {
                if (dir_entry.kind != .directory or dir_entry.name.len < Timestamp.date_fmt.len) continue;

                const dir_name = dir_entry.name[0..Timestamp.date_fmt.len];
                const dir_time = Timestamp.parseSimpleDate(dir_name) orelse continue;
                if (dir_time.year != year) continue;

                const gop = try month_dirs.getOrPut(ctx.allocator, dir_time.month);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .empty;
                }

                try gop.value_ptr.append(ctx.allocator, dir_name.*);
            }

            for (month_dirs.keys(), month_dirs.values()) |month, dirs| {
                for (dirs.items) |dir_name| {
                    var dir = try archive_dir.openDir(&dir_name, .{ .iterate = true });
                    defer dir.close();

                    var file_iter = dir.iterate();
                    while (try file_iter.next()) |file_entry| {
                        if (file_entry.kind != .file or file_entry.name.len < Timestamp.time_fmt.len) continue;

                        const file_name = file_entry.name[0..Timestamp.time_fmt.len];
                        if (!Timestamp.isValidSimpleTime(file_name)) continue;

                        try files.append(ctx.allocator, file_name.*);
                    }
                }

                const preview_file = files.items[rand.uintLessThan(usize, files.items.len)];
                defer files.clearRetainingCapacity();

                try elements.append(ctx.allocator, .{
                    .capture_count = @intCast(files.items.len),
                    .preview_image = preview_file,
                    .time = .{ .year = year, .month = month, .day = 1 },
                });
            }

            user_frontend.ArchiveViewOptions.Element.sort(elements.items);
            try user_frontend.archiveView(ctx.res.writer(), .{
                .type = .year,
                .date = .{ .year = year, .month = 0, .day = 0 },

                .elements = elements.items,
            });
        },
        "".len => {
            var archive_dir = try std.fs.cwd().openDir(env.key(.WEBCAM_VIDEO_ARCHIVE), .{ .iterate = true });
            defer archive_dir.close();

            var elements: std.ArrayList(user_frontend.ArchiveViewOptions.Element) = .empty;
            var files: std.ArrayList([Timestamp.time_fmt.len]u8) = .empty;
            var year_dirs: std.AutoArrayHashMapUnmanaged(u16, std.ArrayList([Timestamp.date_fmt.len]u8)) = .empty;

            var dir_iter = archive_dir.iterate();
            while (try dir_iter.next()) |dir_entry| {
                if (dir_entry.kind != .directory or dir_entry.name.len < Timestamp.date_fmt.len) continue;

                const dir_name = dir_entry.name[0..Timestamp.date_fmt.len];
                const dir_time = Timestamp.parseSimpleDate(dir_name) orelse continue;

                const gop = try year_dirs.getOrPut(ctx.allocator, @intCast(dir_time.year));
                if (!gop.found_existing) {
                    gop.value_ptr.* = .empty;
                }

                try gop.value_ptr.append(ctx.allocator, dir_name.*);
            }

            for (year_dirs.keys(), year_dirs.values()) |year, dirs| {
                for (dirs.items) |dir_name| {
                    var dir = try archive_dir.openDir(&dir_name, .{ .iterate = true });
                    defer dir.close();

                    var file_iter = dir.iterate();
                    while (try file_iter.next()) |file_entry| {
                        if (file_entry.kind != .file or file_entry.name.len < Timestamp.time_fmt.len) continue;

                        const file_name = file_entry.name[0..Timestamp.time_fmt.len];
                        if (!Timestamp.isValidSimpleTime(file_name)) continue;

                        try files.append(ctx.allocator, file_name.*);
                    }
                }

                const preview_file = files.items[rand.uintLessThan(usize, files.items.len)];
                defer files.clearRetainingCapacity();

                try elements.append(ctx.allocator, .{
                    .capture_count = @intCast(files.items.len),
                    .preview_image = preview_file,
                    .time = .{ .year = year, .month = .jan, .day = 1 },
                });
            }

            user_frontend.ArchiveViewOptions.Element.sort(elements.items);
            try user_frontend.archiveView(ctx.res.writer(), .{
                .type = .full,
                .date = .{ .year = 0, .month = 0, .day = 0 },

                .elements = elements.items,
            });
        },
        else => return error.NotFound,
    }

    ctx.res.body = ctx.res.buffer.written();
    ctx.res.content_type = .HTML;
    ctx.responded = true;
}
