const Timestamp = @import("Timestamp.zig");

pub const CategorizeFileEntry = struct { path: [Timestamp.fmt.len]u8, categorized: bool };
pub const CategorizeFileList = []const CategorizeFileEntry;
