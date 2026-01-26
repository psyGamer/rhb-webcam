//! Parsed timestamp, accurate to the second
const std = @import("std");
const zeit = @import("zeit");

pub const Weekday = enum(u3) {
    mon = 0,
    tue = 1,
    wed = 2,
    thu = 3,
    fri = 4,
    sat = 5,
    sun = 6,
};

const Timestamp = @This();

year: i32 = 1970,
month: zeit.Month = .jan,
day: u5 = 1, // 1-31
hour: u5 = 0, // 0-23
minute: u6 = 0, // 0-59
second: u6 = 0, // 0-60
offset: i32 = 0, // offset from UTC in seconds

/// Simple human readable and alphabetically sortable timestamp format
pub const time_fmt: []const u8 = "YYYY-MM-DD_hh-mm-ss";
/// Simple human readable and alphabetically sortable date format
pub const date_fmt: []const u8 = "YYYY-MM-DD";

/// Creates a UTC Instant for this time
pub fn instant(self: Timestamp) zeit.Instant {
    const days = zeit.daysFromCivil(.{
        .year = self.year,
        .month = self.month,
        .day = self.day,
    });

    return .{
        .timestamp = @as(i128, days) * std.time.ns_per_day +
            @as(i128, self.hour) * std.time.ns_per_hour +
            @as(i128, self.minute) * std.time.ns_per_min +
            @as(i128, self.second) * std.time.ns_per_s +
            @as(i128, self.offset) * std.time.ns_per_s,
        .timezone = &zeit.utc,
    };
}
/// Calculates the respective weekday of this time
pub fn weekday(self: Timestamp) Weekday {
    const days = zeit.daysFromCivil(.{
        .year = self.year,
        .month = self.month,
        .day = self.day,
    });

    // The date 1970-01-01 was a thursday
    return @enumFromInt(@mod(days + @intFromEnum(Weekday.thu), 7));
}

pub fn compare(self: Timestamp, time: Timestamp) zeit.TimeComparison {
    const self_instant = self.instant();
    const time_instant = time.instant();

    if (self_instant.timestamp > time_instant.timestamp) {
        return .after;
    } else if (self_instant.timestamp < time_instant.timestamp) {
        return .before;
    } else {
        return .equal;
    }
}

pub fn after(self: Timestamp, time: Timestamp) bool {
    const self_instant = self.instant();
    const time_instant = time.instant();
    return self_instant.timestamp > time_instant.timestamp;
}
pub fn before(self: Timestamp, time: Timestamp) bool {
    const self_instant = self.instant();
    const time_instant = time.instant();
    return self_instant.timestamp < time_instant.timestamp;
}
pub fn eql(self: Timestamp, time: Timestamp) bool {
    const self_instant = self.instant();
    const time_instant = time.instant();
    return self_instant.timestamp == time_instant.timestamp;
}

/// Validate that the input string matches the expected "simple timestamp" format
pub fn isValidSimpleTime(str: []const u8) bool {
    if (str.len != time_fmt.len) return false;

    inline for (time_fmt, 0..) |fmt_char, fmt_idx| {
        if (fmt_char == '-') {
            if (str[fmt_idx] != '-') return false;
        } else if (fmt_char == '_') {
            if (str[fmt_idx] != '_') return false;
        } else {
            if (str[fmt_idx] < '0' or str[fmt_idx] > '9') return false;
        }
    }

    return true;
}
/// Validate that the input string matches the expected "simple timestamp" format
pub fn isValidSimpleDate(str: []const u8) bool {
    if (str.len != date_fmt.len) return false;

    inline for (date_fmt, 0..) |fmt_char, fmt_idx| {
        if (fmt_char == '-') {
            if (str[fmt_idx] != '-') return false;
        } else {
            if (str[fmt_idx] < '0' or str[fmt_idx] > '9') return false;
        }
    }

    return true;
}

/// Attempts to parse the input string from the "simple timestamp" format
pub fn parseSimpleTime(str: []const u8) ?Timestamp {
    if (str.len != time_fmt.len) return null;

    var curr_num: u16 = 0;
    var result: Timestamp = undefined;
    inline for (time_fmt, 0..) |fmt_char, fmt_idx| {
        if (fmt_char == '-') {
            if (str[fmt_idx] != '-') return null;

            switch (time_fmt[fmt_idx - 1]) {
                'Y' => result.year = curr_num,
                'M' => result.month = @enumFromInt(curr_num),
                'h' => result.hour = @intCast(curr_num),
                'm' => result.minute = @intCast(curr_num),
                else => unreachable,
            }
            curr_num = 0;
        } else if (fmt_char == '_') {
            if (str[fmt_idx] != '_') return null;

            result.day = @intCast(curr_num);
            curr_num = 0;
        } else {
            if (str[fmt_idx] < '0' or str[fmt_idx] > '9') return null;

            curr_num *= 10;
            curr_num += str[fmt_idx] - '0';
        }
    }
    result.second = @intCast(curr_num);

    return result;
}

/// Attempts to parse the input ZON node as an ISO8601 timestamp
pub fn parseZonISO8601(zoir: std.zig.Zoir, node_idx: std.zig.Zoir.Node.Index) !Timestamp {
    const node = node_idx.get(zoir);
    const node_string = if (node == .string_literal) node.string_literal else return error.ParseZon;

    const time = try zeit.Time.fromISO8601(node_string);
    return .{ .year = time.year, .month = time.month, .day = time.day, .hour = time.hour, .minute = time.minute, .second = time.second, .offset = time.offset };
}
