pub const api = @import("api.zig");
pub const time = @import("time.zig");

pub const Timestamp = @import("Timestamp.zig");
pub const Schedule = @import("Schedule.zig");
pub const TrainAllocation = @import("TrainAllocation.zig");
pub const Locomotive = @import("Locomotive.zig");
pub const Direction = @import("direction.zig").Direction;

pub const full_train_classifier_names: @import("std").StaticStringMap([]const u8) = .initComptime(.{
    .{ "R 1", "Regio 1" },
    .{ "R 38", "Regio 38" },
    .{ "RE 38", "RegioExpress 38" },
    .{ "IR 38", "InterRegio 38" },
    .{ "GEX", "Glacier Express" },
    .{ "BEX", "Bernina Express" },
    .{ "G", "Güterzug" },
    .{ "D", "Dienstzug" },
});
