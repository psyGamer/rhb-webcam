const std = @import("std");

pub const Category = enum {
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

pub const category_names: std.EnumArray(Category, []const u8) = .init(.{
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

number: u32,
category: Category,
