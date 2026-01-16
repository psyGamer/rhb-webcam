//! Helper functions for dealing with YYYY-MM-DD_HH-MM-SS timestamps

year: u16,
month: u8,
day: u8,

hours: u8,
minutes: u8,
seconds: u8,

pub const fmt: []const u8 = "YYYY-MM-DD_HH-MM-SS";

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
