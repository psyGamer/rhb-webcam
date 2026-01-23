const Timestamp = @import("Timestamp.zig");
const Schedule = @import("Schedule.zig");

const Train = Schedule.Train;
const Clock = Schedule.Clock;

pub const CategorizeFileEntry = struct { path: [Timestamp.fmt.len]u8, categorized: bool };
pub const CategorizeFileList = []const CategorizeFileEntry;

pub const TrainList = []const Train;

pub const Suggestion = struct {
    number: u32,
    time: Clock,

    classifier: []const u8,
    origin: []const u8,
    destination: []const u8,
};
pub const SuggestionList = []const Suggestion;
