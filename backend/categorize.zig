const std = @import("std");
const tk = @import("tokamak");

const Env = @import("main.zig").Env;
const Schedules = @import("main.zig").Schedules;
const TrainAllocationPool = @import("main.zig").TrainAllocationPool;

const Timestamp = @import("common").Timestamp;
const Train = @import("common").Schedule.Train;

const api = @import("common").api;
const Suggestion = api.Suggestion;

pub const routes: []const tk.Route = &.{
    .get("/file-list?", handleFileList),
    .get("/suggestions?", handleSuggestions),
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

    const train_allocations = pool.get(ctx.server.allocator, env, query.day) catch |err| {
        if (@errorReturnTrace()) |t| {
            std.debug.dumpStackTrace(t.*);
        }
        return err;
    };

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
