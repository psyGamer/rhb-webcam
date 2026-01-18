//! Helper functions for dealing with YYYY-MM-DD_HH-MM-SS timestamps

const Timestamp = @This();

year: u16,
month: u8,
day: u8,

hours: u8,
minutes: u8,
seconds: u8,

pub const fmt: []const u8 = "YYYY-MM-DD_hh-mm-ss";

/// Validate that the input string matches the expected timestamp format
pub fn isValid(str: []const u8) bool {
    if (str.len != fmt.len) return false;

    inline for (fmt, 0..) |fmt_char, fmt_idx| {
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

pub fn parse(str: []const u8) ?Timestamp {
    if (str.len != fmt.len) return null;

    var curr_num: u16 = 0;
    var result: Timestamp = undefined;
    inline for (fmt, 0..) |fmt_char, fmt_idx| {
        if (fmt_char == '-') {
            if (str[fmt_idx] != '-') return null;

            switch (fmt[fmt_idx - 1]) {
                'Y' => result.year = curr_num,
                'M' => result.month = @intCast(curr_num),
                'h' => result.hours = @intCast(curr_num),
                'm' => result.minutes = @intCast(curr_num),
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
    result.seconds = @intCast(curr_num);

    return result;
}
