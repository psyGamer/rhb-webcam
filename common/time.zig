//! Tokamak's time utility
//! Source: https://github.com/cztomsik/tokamak/blob/main/src/time.zig

// https://www.youtube.com/watch?v=0s9F4QWAl-E
// https://onlinelibrary.wiley.com/doi/full/10.1002/spe.3172
// https://howardhinnant.github.io/date_algorithms.html
// https://en.wikipedia.org/wiki/Rata_Die
// https://research.swtch.com/leap
const std = @import("std");
const builtin = @import("builtin");

const RATA_MIN = date_to_rata(Date.MIN);
const RATA_MAX = date_to_rata(Date.MAX);
const RATA_TO_UNIX = 719468;
const EOD = 86_400 - 1;

fn compare(a: anytype, b: @TypeOf(a)) std.math.Order {
    if (std.meta.hasMethod(@TypeOf(a), "cmp")) {
        return a.cmp(b);
    }

    return std.math.order(a, b);
}

// TODO: Decide if we want to use std.debug.assert(), @panic() or just throw an error
fn checkRange(num: anytype, min: @TypeOf(num), max: @TypeOf(num)) void {
    if (compare(num, min) == .lt or compare(num, max) == .gt) {
        // TODO: fix later (we can't use {f} and {any} is also wrong)
        // std.log.warn("Value {} is not in range [{}, {}]", .{ num, min, max });
        std.log.warn("Value not in range", .{});
    }
}

const backend = if (builtin.cpu.arch == .wasm32) struct {
    pub extern "meta" fn get_timestamp() i64;
} else struct {
    pub const get_timestamp = std.time.timestamp;
};

pub const TimeUnit = enum { second, minute, hour, day, month, year };
pub const DateUnit = enum { day, month, year };

// https://www.youtube.com/watch?v=0s9F4QWAl-E&t=2120
pub fn isLeapYear(year: i32) bool {
    const d: i32 = if (@mod(year, 100) != 0) 4 else 16;
    return (year & (d - 1)) == 0;
}

// https://www.youtube.com/watch?v=0s9F4QWAl-E&t=2257
fn daysInMonth(year: i32, month: u8) u8 {
    if (month == 2) {
        return if (isLeapYear(year)) 29 else 28;
    }

    return 30 | (month ^ (month >> 3));
}

pub const Date = struct {
    year: i32,
    month: u8,
    day: u8,

    pub const MIN = Date.ymd(-1467999, 1, 1);
    pub const MAX = Date.ymd(1471744, 12, 31);

    pub fn cmp(a: Date, b: Date) std.math.Order {
        if (a.year != b.year) return compare(a.year, b.year);
        if (a.month != b.month) return compare(a.month, b.month);
        return compare(a.day, b.day);
    }

    pub fn parse(str: []const u8) !Date {
        var it = std.mem.splitScalar(u8, str, '-');
        return ymd(
            try std.fmt.parseInt(i32, it.next() orelse return error.Eof, 10),
            try std.fmt.parseInt(u8, it.next() orelse return error.Eof, 10),
            try std.fmt.parseInt(u8, it.next() orelse return error.Eof, 10),
        );
    }

    pub fn ymd(year: i32, month: u8, day: u8) Date {
        return .{
            .year = year,
            .month = month,
            .day = day,
        };
    }

    pub fn today() Date {
        return Time.now().date();
    }

    pub fn yesterday() Date {
        return today().add(.day, -1);
    }

    pub fn tomorrow() Date {
        return today().add(.day, 1);
    }

    pub fn startOf(unit: DateUnit) Date {
        return today().setStartOf(unit);
    }

    pub fn endOf(unit: DateUnit) Date {
        return today().setEndOf(unit);
    }

    pub fn setStartOf(self: Date, unit: DateUnit) Date {
        return switch (unit) {
            .day => self,
            .month => ymd(self.year, self.month, 1),
            .year => ymd(self.year, 1, 1),
        };
    }

    pub fn setEndOf(self: Date, unit: DateUnit) Date {
        return switch (unit) {
            .day => self,
            .month => ymd(self.year, self.month, daysInMonth(self.year, self.month)),
            .year => ymd(self.year, 12, 31),
        };
    }

    pub fn add(self: Date, part: DateUnit, amount: i64) Date {
        return switch (part) {
            .day => Time.unix(0).setDate(self).add(.days, amount).date(),
            .month => {
                const total_months = @as(i32, self.month) + @as(i32, @intCast(amount));
                const new_year = self.year + @divFloor(total_months - 1, 12);
                const new_month = @as(u8, @intCast(@mod(total_months - 1, 12) + 1));
                return ymd(
                    new_year,
                    new_month,
                    @min(self.day, daysInMonth(new_year, new_month)),
                );
            },
            .year => {
                const new_year = self.year + @as(i32, @intCast(amount));
                return ymd(
                    new_year,
                    self.month,
                    @min(self.day, daysInMonth(new_year, self.month)),
                );
            },
        };
    }

    pub fn dayOfWeek(self: Date) u8 {
        const rata_day = date_to_rata(self);
        return @intCast(@mod(rata_day + 3, 7));
    }

    pub fn monthName(self: Date) []const u8 {
        return switch (self.month) {
            1 => "Januar",
            2 => "Februar",
            3 => "März",
            4 => "April",
            5 => "Mai",
            6 => "Juni",
            7 => "Juli",
            8 => "August",
            9 => "September",
            10 => "Oktober",
            11 => "November",
            12 => "Dezember",
            else => unreachable,
        };
    }

    pub fn format(self: Date, writer: anytype) !void {
        try writer.print("{d}-{d:0>2}-{d:0>2}", .{
            @as(u32, @intCast(self.year)),
            self.month,
            self.day,
        });
    }
};

pub const Time = struct {
    epoch: i64,

    pub fn unix(epoch: i64) Time {
        return .{ .epoch = epoch };
    }

    pub fn now() Time {
        return unix(backend.get_timestamp());
    }

    pub fn today() Time {
        return unix(0).setDate(.today());
    }

    pub fn tomorrow() Time {
        return unix(0).setDate(.tomorrow());
    }

    pub fn startOf(unit: TimeUnit) Time {
        return Time.now().setStartOf(unit);
    }

    pub fn endOf(unit: TimeUnit) Time {
        return Time.now().setEndOf(unit);
    }

    pub fn second(self: Time) u32 {
        return @intCast(@mod(self.total(.seconds), 60));
    }

    pub fn setSecond(self: Time, sec: u32) Time {
        return self.add(.seconds, @as(i64, sec) - self.second());
    }

    pub fn minute(self: Time) u32 {
        return @intCast(@mod(self.total(.minutes), 60));
    }

    pub fn setMinute(self: Time, min: u32) Time {
        return self.add(.minutes, @as(i64, min) - self.minute());
    }

    pub fn hour(self: Time) u32 {
        return @intCast(@mod(self.total(.hours), 24));
    }

    pub fn setHour(self: Time, hr: u32) Time {
        return self.add(.hours, @as(i64, hr) - self.hour());
    }

    pub fn date(self: Time) Date {
        return rata_to_date(@divTrunc(self.epoch, std.time.s_per_day) + RATA_TO_UNIX);
    }

    pub fn setDate(self: Time, dat: Date) Time {
        var res: i64 = @mod(self.epoch, std.time.s_per_day);
        res += (date_to_rata(dat) - RATA_TO_UNIX) * std.time.s_per_day;
        return unix(res);
    }

    pub fn setStartOf(self: Time, unit: TimeUnit) Time {
        // TODO: continue :label?
        return switch (unit) {
            .second => self,
            .minute => self.setSecond(0),
            .hour => self.setSecond(0).setMinute(0),
            .day => self.setSecond(0).setMinute(0).setHour(0),
            .month => {
                const d = self.date();
                return unix(0).setDate(.ymd(d.year, d.month, 1));
            },
            .year => {
                const d = self.date();
                return unix(0).setDate(.ymd(d.year, 1, 1));
            },
        };
    }

    // TODO: rename to startOfNext?
    pub fn next(self: Time, unit: enum { second, minute, hour, day }) Time {
        return switch (unit) {
            .second => self.add(.seconds, 1),
            .minute => self.setSecond(0).add(.minutes, 1),
            .hour => self.setSecond(0).setMinute(0).add(.hours, 1),
            .day => self.setSecond(0).setMinute(0).setHour(0).add(.hours, 24),
        };
    }

    pub fn setEndOf(self: Time, unit: TimeUnit) Time {
        // TODO: continue :label?
        return switch (unit) {
            .second => self,
            .minute => self.setSecond(59),
            .hour => self.setSecond(59).setMinute(59),
            .day => self.setSecond(59).setMinute(59).setHour(23),
            .month => {
                const d = self.date();
                return unix(EOD).setDate(.ymd(d.year, d.month, daysInMonth(d.year, d.month)));
            },
            .year => {
                const d = self.date();
                return unix(EOD).setDate(.ymd(d.year, 12, 31));
            },
        };
    }

    pub fn add(self: Time, part: enum { seconds, minutes, hours, days, months, years }, amount: i64) Time {
        const n = switch (part) {
            .seconds => amount,
            .minutes => amount * std.time.s_per_min,
            .hours => amount * std.time.s_per_hour,
            .days => amount * std.time.s_per_day,
            .months => return self.setDate(self.date().add(.month, amount)),
            .years => return self.setDate(self.date().add(.year, amount)),
        };

        return .{ .epoch = self.epoch + n };
    }

    fn total(self: Time, part: enum { seconds, minutes, hours }) i64 {
        return switch (part) {
            .seconds => self.epoch,
            .minutes => @divTrunc(self.epoch, std.time.s_per_min),
            .hours => @divTrunc(self.epoch, std.time.s_per_hour),
        };
    }

    pub fn format(self: Time, writer: anytype) !void {
        try writer.print("{f} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
            self.date(),
            self.hour(),
            self.minute(),
            self.second(),
        });
    }
};

// https://github.com/cassioneri/eaf/blob/1509faf37a0e0f59f5d4f11d0456fd0973c08f85/eaf/gregorian.hpp#L42
fn rata_to_date(N: i64) Date {
    checkRange(N, RATA_MIN, RATA_MAX);

    // Century.
    const N_1: i64 = 4 * N + 3;
    const C: i64 = quotient(N_1, 146097);
    const N_C: u32 = remainder(N_1, 146097) / 4;

    // Year.
    const N_2 = 4 * N_C + 3;
    const Z: u32 = N_2 / 1461;
    const N_Y: u32 = N_2 % 1461 / 4;
    const Y: i64 = 100 * C + Z;

    // Month and day.
    const N_3: u32 = 5 * N_Y + 461;
    const M: u32 = N_3 / 153;
    const D: u32 = N_3 % 153 / 5;

    // Map.
    const J: u32 = @intFromBool(M >= 13);

    return .{
        .year = @intCast(Y + J),
        .month = @intCast(M - 12 * J),
        .day = @intCast(D + 1),
    };
}

// https://github.com/cassioneri/eaf/blob/1509faf37a0e0f59f5d4f11d0456fd0973c08f85/eaf/gregorian.hpp#L88
fn date_to_rata(date: Date) i32 {
    checkRange(date, Date.MIN, Date.MAX);

    // Map.
    const J: u32 = @intFromBool(date.month <= 2);
    const Y: i32 = date.year - @as(i32, @intCast(J));
    const M: u32 = date.month + 12 * J;
    const D: u32 = date.day - 1;
    const C: i32 = @intCast(quotient(Y, 100));

    // Rata die.
    const y_star: i32 = @intCast(quotient(1461 * @as(i64, Y), 4) - C + quotient(C, 4)); // n_days in all prev. years
    const m_star: u32 = (153 * M - 457) / 5; // n_days in prev. months

    return y_star + @as(i32, @intCast(m_star)) + @as(i32, @intCast(D));
}

fn quotient(n: i64, d: u32) i64 {
    return if (n >= 0) @divTrunc(n, d) else @divTrunc((n + 1), d) - 1;
}

fn remainder(n: i64, d: u32) u32 {
    return @intCast(if (n >= 0) @mod(n, d) else (n + d) - d * quotient((n + d), d));
}
