const std = @import("std");
const tk = @import("tokamak");
const fr = @import("fridge");

const Env = @import("main.zig").Env;
const Schedules = @import("main.zig").Schedules;
const TrainAllocationPool = @import("main.zig").TrainAllocationPool;

const DatabaseTrain = @import("database.zig").Train;
const DatabaseLocomotive = @import("database.zig").Locomotive;

const Timestamp = @import("common").Timestamp;
const Direction = @import("common").Direction;
const Train = @import("common").Schedule.Train;
const Locomotive = @import("common").Locomotive;

const api = @import("common").api;
const Suggestion = api.Suggestion;

pub const routes: []const tk.Route = &.{
    .get("/file-list?", handleFileList),
    .get("/suggestions?", handleSuggestions),
    .get("/train-info?", handleTrainInfo),

    .put("/update?", handleUpdate),
    .delete("/delete?", handleDelete),
};

fn handleFileList(arena: std.mem.Allocator, db: *fr.Session, env: *Env, query: struct { day: []const u8, includeCategorized: bool = false }) !api.CategorizeFileList {
    if (!Timestamp.isValidSimpleDate(query.day)) return error.BadRequest;

    const dir_path = try std.fs.path.join(arena, &.{ env.key(.WEBCAM_VIDEO_ARCHIVE), query.day });
    var day_dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer day_dir.close();

    var entries: std.ArrayList(api.CategorizeFileEntry) = .empty;

    var file_iter = day_dir.iterate();
    while (try file_iter.next()) |entry| {
        if (entry.kind != .file) continue;

        if (entry.name.len < Timestamp.time_fmt.len) continue;
        const file = entry.name[0..Timestamp.time_fmt.len];
        if (!Timestamp.isValidSimpleTime(file)) continue;

        const db_trains = try db.query(DatabaseTrain)
            .where("file", file)
            .findAll();
        const descs = try arena.alloc(api.TrainDescription, db_trains.len);

        for (db_trains, descs) |train, *desc| {
            const db_locos = try db.query(DatabaseLocomotive)
                .where("train_id", train.id)
                .findAll();

            const locos = try arena.alloc(Locomotive, db_locos.len);

            for (db_locos) |loco| {
                locos[loco.position] = .{
                    .number = loco.number,
                    .category = std.meta.stringToEnum(Locomotive.Category, loco.category).?,
                    .towed = loco.towed,
                };
            }

            desc.* = .{
                .number = train.number,

                .shunting = train.from_direction == null and train.to_direction == null,
                .from_direction = if (train.from_direction) |from| std.meta.stringToEnum(Direction, from).? else .filisur,
                .to_direction = if (train.to_direction) |to| std.meta.stringToEnum(Direction, to).? else .filisur,

                .locomotives = locos,
            };
        }

        try entries.append(arena, .{ .path = file.*, .descs = descs });
    }

    std.mem.sort(api.CategorizeFileEntry, entries.items, {}, struct {
        pub fn lessThan(_: void, lhs: api.CategorizeFileEntry, rhs: api.CategorizeFileEntry) bool {
            for (lhs.path, rhs.path) |lhs_char, rhs_char| {
                if (lhs_char < rhs_char) return true;
                if (lhs_char > rhs_char) return false;
            }
            return false;
        }
    }.lessThan);

    return entries.items;
}

fn handleSuggestions(ctx: tk.Context, arena: std.mem.Allocator, schedules: Schedules, pool: *TrainAllocationPool, env: *Env, query: struct { day: tk.time.Date }) !api.SuggestionList {
    const curr_timestamp: Timestamp = .{
        .day = @intCast(query.day.day),
        .month = @enumFromInt(query.day.month),
        .year = query.day.year,
        .hour = 12, // Middle of the day to avoid any issues
    };

    const schedule = for (schedules) |s| {
        if (s.start_date.after(curr_timestamp) or s.end_date.before(curr_timestamp)) continue;
        break s;
    } else return &.{};

    const train_allocations = try pool.get(ctx.server.allocator, env, query.day);

    var suggestions: std.ArrayList(Suggestion) = try .initCapacity(arena, schedule.trains.len * 2);

    const default_date: Timestamp = .{};
    for (schedule.trains) |train| {
        if (train.applicable_start_date.year != default_date.year and train.applicable_start_date.after(curr_timestamp)) continue;
        if (train.applicable_end_date.year != default_date.year and train.applicable_end_date.before(curr_timestamp)) continue;
        if (!train.applicable_weekdays.contains(curr_timestamp.weekday())) continue;

        const min_time, const max_time = switch (train.time) {
            .arrival_departure => |time| time,
            .transit => |time| .{ time, time },
        };
        const locomotives = for (train_allocations) |alloc| {
            if (alloc.number != train.number) continue;
            if (alloc.departure_time.cmp(min_time) == .gt) continue;
            if (alloc.arrival_time.cmp(max_time) == .lt) continue;

            break alloc.locomotives;
        } else &.{};

        switch (train.time) {
            .arrival_departure => |time| {
                const arrival_time, const departure_time = time;

                suggestions.appendAssumeCapacity(.{
                    .number = train.number,
                    .time = arrival_time,
                    .type = .arrival,

                    .classifier = train.information.classifier,
                    .origin = train.information.origin,
                    .destination = "Filisur",

                    .locomotives = locomotives,
                });
                suggestions.appendAssumeCapacity(.{
                    .number = train.number,
                    .time = departure_time,
                    .type = .departure,

                    .classifier = train.information.classifier,
                    .origin = "Filisur",
                    .destination = train.information.destination,

                    .locomotives = locomotives,
                });
            },
            .transit => |time| {
                suggestions.appendAssumeCapacity(.{
                    .number = train.number,
                    .time = time,
                    // Slight hack for the train to/from Davos Platz to be properly recognized
                    .type = if (std.mem.eql(u8, train.information.origin, "Filisur"))
                        .departure
                    else if (std.mem.eql(u8, train.information.destination, "Filisur"))
                        .arrival
                    else
                        .transit,

                    .classifier = train.information.classifier,
                    .origin = train.information.origin,
                    .destination = train.information.destination,

                    .locomotives = locomotives,
                });
            },
        }
    }

    std.mem.sort(Suggestion, suggestions.items, {}, struct {
        pub fn lessThan(_: void, lhs: Suggestion, rhs: Suggestion) bool {
            if (lhs.time.hour < rhs.time.hour) return true;
            if (lhs.time.hour > rhs.time.hour) return false;
            return lhs.time.minute < rhs.time.minute;
        }
    }.lessThan);

    return suggestions.items;
}

fn handleTrainInfo(ctx: tk.Context, pool: *TrainAllocationPool, env: *Env, query: struct { day: tk.time.Date, number: u32 }) !?api.TrainDescription {
    const train_allocations = try pool.get(ctx.server.allocator, env, query.day);

    for (train_allocations) |alloc| {
        if (alloc.number == query.number) {
            return .{
                .number = alloc.number,

                .shunting = false,
                .from_direction = .filisur,
                .to_direction = .filisur,

                .locomotives = alloc.locomotives,
            };
        }
    }

    return null;
}

fn handleUpdate(arena: std.mem.Allocator, db: *fr.Session, env: *Env, query: struct { file: []const u8 }, data: []const api.TrainDescription) !void {
    if (!Timestamp.isValidSimpleTime(query.file)) return;

    // Validate the path actually exists
    const day = query.file[0.."YYYY-MM-DD".len];

    const video_extension = ".mp4";
    var video_name: [Timestamp.time_fmt.len + video_extension.len]u8 = undefined;
    video_name[0..Timestamp.time_fmt.len].* = query.file[0..Timestamp.time_fmt.len].*;
    video_name[(video_name.len - video_extension.len)..][0..video_extension.len].* = video_extension.*;

    const video_path = try std.fs.path.join(arena, &.{ env.key(.WEBCAM_VIDEO_ARCHIVE), day, &video_name });
    try std.fs.cwd().access(video_path, .{});

    // Validate train descriptions
    if (data.len == 0) return error.BadRequest;
    for (data) |desc| {
        if (desc.from_direction == desc.to_direction and !desc.shunting) return error.BadRequest;
        var all_towed = true;
        for (desc.locomotives) |loco| {
            if (!loco.towed) all_towed = false;
            if (loco.number == 0 and loco.category != .none) continue;
            if (loco.number != 0 and Locomotive.getCategory(loco.number) == loco.category) continue;
            return error.BadRequest;
        }
        if (all_towed) return error.BadRequest;
    }

    // Clear existing trains
    try db.query(DatabaseTrain)
        .where("file", query.file)
        .delete()
        .exec();

    // Insert new data
    for (data) |desc| {
        const train_id = try db.insert(DatabaseTrain, .{
            .number = desc.number,
            .file = query.file,

            .from_direction = if (desc.shunting) null else @as([]const u8, @tagName(desc.from_direction)),
            .to_direction = if (desc.shunting) null else @as([]const u8, @tagName(desc.to_direction)),
        });

        for (desc.locomotives, 0..) |loco, idx| {
            try db.query(DatabaseLocomotive)
                .insert(.{
                    .train_id = train_id,

                    .number = loco.number,
                    .category = @tagName(loco.category),

                    .position = @as(u32, @intCast(idx)),
                    .towed = loco.towed,
                })
                .exec();
        }
    }
}

fn handleDelete(db: *fr.Session, query: struct { file: []const u8 }) !void {
    // Clear existing trains
    try db.query(DatabaseTrain)
        .where("file", query.file)
        .delete()
        .exec();
}
