const std = @import("std");
const time = @import("time.zig");

pub const Category = enum {
    none,

    // Shunting
    Tm_22_1,
    Tm_22_2,
    Tm_22_3,
    Tm_22_4,
    Tm_22_5,
    Ge_22_1,
    Ge_33_1,
    Gmf_44_1,
    Geaf_22_1,

    // Service
    Xm_22_1,
    Xm_22_2,
    Xm_22_3,
    Xmf_44_1,
    Xmf_66_1,
    Xm_24_1,
    Gmf_44_2,

    // Locomotive
    Ge_44_1,
    Ge_44_2,
    Ge_44_3,
    Gem_44_1,

    // Tram
    ABe_812_1,
    ABe_416_1,
    ABe_416_2,
};

number: u32,
category: Category,

towed: bool,

/// Human-readable names for locomotive categorizes
pub const category_names: std.EnumArray(Category, []const u8) = .init(.{
    .none = "Kategorie auswählen...",

    .Tm_22_1 = "Tm 2/2 (Nr. 62)",
    .Tm_22_2 = "Tm 2/2 (Nr. 81-84)",
    .Tm_22_3 = "Tmf 2/2 (Nr. 85-90)",
    .Tm_22_4 = "Tm 2/2 (Nr. 95-98)",
    .Tm_22_5 = "Tm 2/2 (Nr. 111-120)",
    .Ge_22_1 = "Ge 2/2 «Esele»",
    .Ge_33_1 = "Ge 3/3",
    .Gmf_44_1 = "Gmf 4/4 I",
    .Geaf_22_1 = "Geaf 2/2",

    .Xm_22_1 = "Xm 2/2 (Nr. 9916)",
    .Xm_22_2 = "Xm 2/2 (Nr. 9917)",
    .Xm_22_3 = "Xmf 2/2 (Nr. 9921)",
    .Xmf_44_1 = "Xmf 4/4",
    .Xmf_66_1 = "Xmf 6/6",
    .Xm_24_1 = "Xm 2/4",
    .Gmf_44_2 = "Gmf 4/4 II",

    .Ge_44_1 = "Ge 4/4 I",
    .Ge_44_2 = "Ge 4/4 II",
    .Ge_44_3 = "Ge 4/4 III",

    .Gem_44_1 = "Gem 4/4 «Zweikraftlok»",

    .ABe_812_1 = "ABe 8/12 «ZTZ Allegra»",
    .ABe_416_1 = "ABe 4/16 «STZ Allegra»",
    .ABe_416_2 = "ABe 4/16 «Capricorn»",
});

/// Generic number range with inclusive start and exclusive end
const Range = struct {
    start: u32,
    end: u32,

    pub const empty: Range = .{ .start = 0, .end = 0 };

    pub fn single(number: u32) Range {
        return .{ .start = number, .end = number + 1 };
    }
    pub fn inclusive(start: u32, end: u32) Range {
        return .{ .start = start, .end = end + 1 };
    }
};
/// Maps categoritzes onto the range of numbers they represent
pub const category_ranges: std.EnumArray(Category, Range) = .init(.{
    .none = .empty,

    .Tm_22_1 = .single(62),
    .Tm_22_2 = .inclusive(81, 84),
    .Tm_22_3 = .inclusive(85, 90),
    .Tm_22_4 = .inclusive(95, 98),
    .Tm_22_5 = .inclusive(111, 120),
    .Ge_22_1 = .inclusive(161, 162),
    .Ge_33_1 = .inclusive(214, 215),
    .Gmf_44_1 = .inclusive(242, 242),
    .Geaf_22_1 = .inclusive(20601, 20606),

    .Xm_22_1 = .single(9916),
    .Xm_22_2 = .single(9917),
    .Xm_22_3 = .single(9921),
    .Xmf_44_1 = .inclusive(24403, 24404),
    .Xmf_66_1 = .inclusive(24401, 24402),
    .Xm_24_1 = .inclusive(27401, 27404),
    .Gmf_44_2 = .inclusive(23401, 23404),

    .Ge_44_1 = .inclusive(601, 610),
    .Ge_44_2 = .inclusive(611, 633),
    .Ge_44_3 = .inclusive(641, 653),

    .Gem_44_1 = .inclusive(801, 802),

    .ABe_812_1 = .inclusive(3501, 3515),
    .ABe_416_1 = .inclusive(3101, 3105),
    .ABe_416_2 = .inclusive(3111, 3172),
});

/// Attempts to assiciate a category with a locomotive number
/// A result of `null` implies that the specified locomotive number is not known
pub fn getCategory(number: u32) ?Category {
    for (category_ranges.values, 0..) |range, category_idx| {
        if (number >= range.start and number < range.end) {
            return @enumFromInt(category_idx);
        }
    }

    return null;
}

const default_variant: std.EnumArray(Category, []const u8) = .init(.{
    .none = "",

    .Tm_22_1 = "Oxydrot",
    .Tm_22_2 = "Gelb mit Kran (alt)",
    .Tm_22_3 = "Orange",
    .Tm_22_4 = "Gelb mit Kran (neu)",
    .Tm_22_5 = "Orange",
    .Ge_22_1 = "Orange",
    .Ge_33_1 = "Orange",
    .Gmf_44_1 = "Gelb",
    .Geaf_22_1 = "Orange",

    .Xm_22_1 = "Gelb",
    .Xm_22_2 = "Gelb",
    .Xm_22_3 = "Gelb",
    .Xmf_44_1 = "Gelb",
    .Xmf_66_1 = "Gelb",
    .Xm_24_1 = "Gelb",
    .Gmf_44_2 = "Gelb",

    .Ge_44_1 = "Rot",
    .Ge_44_2 = "Rot",
    .Ge_44_3 = "Rot",

    .Gem_44_1 = "Rot",

    .ABe_812_1 = "Rot",
    .ABe_416_1 = "Rot",
    .ABe_416_2 = "Rot",
});

/// Provides a human-readable string for the special variant (i.e. non-default) which was present at the specified date
pub fn getSpecialVariantName(number: u32, date: time.Date) ?[]const u8 {
    _ = date; // There hasn't been a change _yet_ so currently not needed
    return switch (number) {
        // Ge 2/2 «Esele»
        161 => "Braun",

        // Ge 4/4 II
        611 => "GRÜN & CHROM",
        612 => "Elektropartner",
        618 => "RhB groß",
        622 => "Hakone",
        623 => "Glacier Express",
        626 => "Alpine Classic - Pullman",
        630 => "Ihre Werbung",
        631 => "Südostschweiz",
        633 => "RTR",

        // Ge 4/4 III
        641 => "COOP",
        644 => "Weltrekord",
        645 => "RTR",
        646 => "BüGa",
        648 => "Watson",
        649 => "Skimarathon",
        652 => "Hockey Club Davos",

        // ABe 8/12 «Allegra»
        3514 => "Ahnenzug",

        // ABe 4/16 «Capricorn»
        3133 => "Champagner",

        else => null,
    };
}
/// Provides a human-readable string for the variant which was present at the specified date
pub fn getVariantName(number: u32, date: time.Date) []const u8 {
    return getSpecialVariantName(number, date) orelse default_variant.get(getCategory(number) orelse return "");
}
