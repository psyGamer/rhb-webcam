const Timestamp = @import("Timestamp.zig");
const Train = @import("Schedule.zig").Train;

pub const CategorizeFileEntry = struct { path: [Timestamp.fmt.len]u8, categorized: bool };
pub const CategorizeFileList = []const CategorizeFileEntry;

pub const TrainList = []const Train;
