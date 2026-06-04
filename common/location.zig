const std = @import("std");

pub const Location = enum {
    filisur,
    landwasser,
    landquart,
    brusio,
    alpgr,
    livestream,

    pub const names: std.EnumArray(Location, []const u8) = .init(.{
        .filisur = "Filisur",
        .landwasser = "Landwasser",
        .landquart = "Landquart",
        .brusio = "Brusio",
        .alpgr = "Alp Grüm",
        .livestream = "Livestream",
    });
};
