const Timestamp = @import("Timestamp.zig");
const Schedule = @import("Schedule.zig");
const TrainAllocation = @import("TrainAllocation.zig");
const Locomotive = @import("Locomotive.zig");

const Train = Schedule.Train;
const Clock = Schedule.Clock;

pub const CategorizeFileEntry = struct { path: [Timestamp.fmt.len]u8, categorized: bool };
pub const CategorizeFileList = []const CategorizeFileEntry;

/// Suggestion for a specific train on a desired day
pub const Suggestion = struct {
    pub const Type = enum { arrival, departure, transit };

    number: u32,
    time: Clock,
    type: Type,

    classifier: []const u8,
    origin: []const u8,
    destination: []const u8,

    locomotives: []const TrainAllocation.Locomotive,
};
pub const SuggestionList = []const Suggestion;

/// Describes a single specific train in detail
pub const TrainDescription = struct {
    pub const Direction = enum { chur, moritz, davos, filisur };

    number: u32,

    shunting: bool = false,
    from_direction: Direction,
    to_direction: Direction,

    locomotives: []const Locomotive,
};
