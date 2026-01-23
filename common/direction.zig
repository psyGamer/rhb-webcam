const std = @import("std");

/// Locational directory between which a train passing through Filisur can travel
pub const Direction = enum {
    chur,
    moritz,
    davos,
    filisur,

    pub const category_names: std.EnumArray(Direction, []const u8) = .init(.{
        .chur = "Chur",
        .moritz = "St. Moritz",
        .davos = "Davos Platz",
        .filisur = "Filisur",
    });
    pub const known_directions: std.StaticStringMap(Direction) = .initComptime(.{
        .{ "Chur", .chur },
        .{ "Chur GB", .chur },
        .{ "Landquart", .davos },
        .{ "Landquart GB", .chur },
        .{ "Davos Platz", .davos },
        .{ "Filisur", .filisur },
        .{ "Pontresina", .moritz },
        .{ "Samedan", .moritz },
        .{ "St. Moritz", .moritz },
        .{ "Tirano", .moritz },
        .{ "Zermatt", .chur },
    });
};
