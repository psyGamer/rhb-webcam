const std = @import("std");
const tk = @import("tokamak");
const fr = @import("fridge");
const zeit = @import("zeit");

const user_frontend = @import("user-frontend");

const Timestamp = @import("common").Timestamp;
const Clock = @import("common").Schedule.Clock;
const Direction = @import("common").Direction;
const Locomotive = @import("common").Locomotive;
const Location = @import("common").Location;

const Env = @import("../main.zig").Env;
const Schedules = @import("../main.zig").Schedules;

const DatabaseTrain = @import("../database.zig").Train;
const DatabaseLocomotive = @import("../database.zig").Locomotive;

pub fn archive(comptime location: Location) []const tk.Route {
    const Capture = switch (location) {
        .filisur => @import("../database.zig").FilisurCapture,
        .landwasser => @import("../database.zig").LandwasserCapture,
        .landquart => @import("../database.zig").LandquartCapture,
        .brusio => @import("../database.zig").BrusioCapture,
        .alpgr => @import("../database.zig").AlpGrCapture,
        .livestream => @import("../database.zig").LivestreamCapture,
    };

    const H = struct {
        pub fn handle(ctx: *tk.Context) anyerror!void {
            const db = try ctx.injector.get(*fr.Session);

            var it = std.mem.splitScalar(u8, ctx.params.get(0) orelse "", '-');
            const year = std.fmt.parseInt(u16, it.next() orelse "", 10) catch null;
            const month = std.fmt.parseInt(u8, it.next() orelse "", 10) catch null;
            const day = std.fmt.parseInt(u8, it.next() orelse "", 10) catch null;

            // Setup template data
            var archive_opts: user_frontend.ArchiveViewOptions = .{
                .type = if (day != null)
                    .day
                else if (month != null)
                    .month
                else if (year != null)
                    .year
                else
                    .full,
                .date = .{ .year = year orelse 0, .month = month orelse 0, .day = day orelse 0 },

                .location = location,
                .next = null,
                .prev = null,

                .elements = &.{},
            };

            const seq = try db.raw(std.fmt.comptimePrint(
                \\SELECT * FROM (
                \\    SELECT
                \\        date,
                \\        LAG(date)  OVER (ORDER BY date) AS prev_date,
                \\        LEAD(date) OVER (ORDER BY date) AS next_date
                \\    FROM (
                \\        SELECT DISTINCT SUBSTR(file, 1, ?) AS date
                \\        FROM {s}
                \\    )
                \\)
                \\WHERE date = ?
            , .{Capture.sql_table_name}), .{
                switch (archive_opts.type) {
                    .full => "".len,
                    .year => "YYYY".len,
                    .month => "YYYY-MM".len,
                    .day => "YYYY-MM-DD".len,
                },
                ctx.params.get(0) orelse "",
            })
                .fetchOne(struct { date: []const u8, prev_date: ?[]const u8, next_date: ?[]const u8 }) orelse return error.NotFound;

            archive_opts.next = seq.next_date;
            archive_opts.prev = seq.prev_date;

            if (year != null and month != null and day != null) {
                const captures = try db.raw("SELECT file FROM " ++ Capture.sql_table_name, .{})
                    .where("file LIKE ? || '%'", .{ctx.params.get(0).?})
                    .orderBy("file")
                    .fetchAll([]const u8);

                const elements = try ctx.allocator.alloc(user_frontend.ArchiveViewOptions.Element, captures.len);
                for (captures, elements) |capture, *element| {
                    if (capture.len != Timestamp.time_fmt.len) return error.InvalidTimestamp;

                    element.* = .{
                        .capture_count = 0,
                        .preview_image = capture[0..Timestamp.time_fmt.len].*,
                        .time = Timestamp.parseSimpleTime(capture) orelse return error.InvalidTimestamp,
                    };
                }

                archive_opts.elements = elements;
            } else {
                const prefix_len = switch (archive_opts.type) {
                    .full => "YYYY".len,
                    .year => "YYYY-MM".len,
                    .month => "YYYY-MM-DD".len,
                    .day => unreachable,
                };

                const entries = try db.raw(std.fmt.comptimePrint(
                    \\SELECT
                    \\    SUBSTR(file, 1, ?) as group_prefix,
                    \\    COUNT(*) AS capture_count,
                    \\    (
                    \\        SELECT file FROM {s} t2
                    \\        WHERE substr(t2.file, 1, ?) = substr(t1.file, 1, ?)
                    \\        ORDER BY RANDOM() 
                    \\        LIMIT 1
                    \\    ) AS file
                    \\FROM {s} t1
                    \\WHERE group_prefix LIKE ? || '%'
                    \\GROUP BY group_prefix
                    \\ORDER BY group_prefix
                , .{ Capture.sql_table_name, Capture.sql_table_name }), .{ prefix_len, prefix_len, prefix_len, ctx.params.get(0) orelse "" })
                    .fetchAll(struct { _: []const u8, amount: u32, file: []const u8 });

                const elements = try ctx.allocator.alloc(user_frontend.ArchiveViewOptions.Element, entries.len);
                for (entries, elements) |entry, *element| {
                    if (entry.file.len != Timestamp.time_fmt.len) return error.InvalidTimestamp;

                    element.* = .{
                        .capture_count = entry.amount,
                        .preview_image = entry.file[0..Timestamp.time_fmt.len].*,
                        .time = Timestamp.parseSimpleTime(entry.file) orelse return error.InvalidTimestamp,
                    };
                }

                archive_opts.elements = elements;
            }

            try user_frontend.archiveView(ctx.res.writer(), archive_opts);

            const today: tk.time.Date = .today();

            // Check if the current view is still "reciving updtes"
            const is_finished = b: {
                if (today.year != year orelse break :b false) break :b true;
                if (today.month != month orelse break :b false) break :b true;
                if (today.day != day orelse break :b false) break :b true;
                break :b false;
            };

            if (is_finished) {
                // Cache for a week
                ctx.res.header("Cache-Control", "public, max-age=604800, immutable");
            } else {
                switch (archive_opts.type) {
                    // Cache for 5 minutes
                    .day => ctx.res.header("Cache-Control", "public, max-age=300"),
                    // Cache for 1 hour
                    .month => ctx.res.header("Cache-Control", "public, max-age=3600"),
                    // Cache for 1 day
                    .year => ctx.res.header("Cache-Control", "public, max-age=86400"),
                    // Cache for 3 days
                    .full => ctx.res.header("Cache-Control", "public, max-age=259200"),
                }
            }

            ctx.res.body = ctx.res.buffer.written();
            ctx.res.content_type = .HTML;
            ctx.responded = true;
        }
    };

    return &.{
        .get("/", tk.Route{ .handler = &H.handle }),
        .get("/:path", tk.Route{ .handler = &H.handle }),
    };
}
