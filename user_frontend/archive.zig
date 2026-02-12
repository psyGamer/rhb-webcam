const std = @import("std");
const Date = @import("common").time.Date;
const Timestamp = @import("common").Timestamp;
const Location = @import("common").Location;

pub const Options = struct {
    pub const Element = struct {
        capture_count: u32,

        preview_image: [Timestamp.time_fmt.len]u8,

        time: Timestamp,

        pub fn sort(elements: []Element) void {
            std.mem.sort(Element, elements, {}, lessThan);
        }

        fn lessThan(_: void, lhs: Element, rhs: Element) bool {
            return lhs.time.before(rhs.time);
        }
    };

    type: enum { full, year, month, day },
    date: Date,
    location: Location,

    elements: []const Element,
};

pub fn render(writer: *std.Io.Writer, opts: Options) !void {
    try writer.writeAll(
        \\    <div class="main">
        \\        <div class="title">
        \\
    );

    switch (opts.type) {
        .day => try writer.print(
            \\            <h2 class="heading">Tagesarchiv vom {d:0>2}. {s} {d}</h2>
        , .{ opts.date.day, opts.date.monthName(), opts.date.year }),
        .month => try writer.print(
            \\            <h2 class="heading">Monatsarchiv {s} {d}</h2>
        , .{ opts.date.monthName(), opts.date.year }),
        .year => try writer.print(
            \\            <h2 class="heading">Jahresarchiv {d}</h2>
        , .{opts.date.year}),
        .full => try writer.print(
            \\            <h2 class="heading">Langzeitarchiv</h2>
        , .{}),
    }

    try writer.writeAll(
        \\
        \\        </div>
        \\
        \\        <div class="preview-grid card-box">
        \\
    );

    for (opts.elements) |elem| {
        switch (opts.type) {
            .day => try writer.print(
                \\            <a class="preview card" href="/{s}/archive/{f}">
            , .{ @tagName(opts.location), elem.time }),
            .month => try writer.print(
                \\            <a class="preview card" href="/{s}/archive/{d}-{d:0>2}-{d:0>2}">
            , .{ @tagName(opts.location), elem.time.year, @intFromEnum(elem.time.month), elem.time.day }),
            .year => try writer.print(
                \\            <a class="preview card" href="/{s}/archive/{d}-{d:0>2}">
            , .{ @tagName(opts.location), elem.time.year, @intFromEnum(elem.time.month) }),
            .full => try writer.print(
                \\            <a class="preview card" href="/{s}/archive/{d}">
            , .{ @tagName(opts.location), elem.time.year }),
        }

        try writer.print(
            \\
            \\                <img src="/{s}/image/{s}">
            \\
            \\                <div class="overlay {s}">
            \\
        , .{ @tagName(opts.location), &elem.preview_image, if (opts.type == .day) "top" else "both" });

        switch (opts.type) {
            .day => try writer.print(
                \\                    <b class="preview-title">{d:0>2}:{d:0>2}:{d:0>2}</b>
            , .{ elem.time.hour, elem.time.minute, elem.time.second }),
            .month => try writer.print(
                \\                    <b class="preview-title">{d:0>2}. {s} {d}</b>
                \\                    <span class="capture-count">{d} Aufnahmen</span>
            , .{ elem.time.day, elem.time.monthName(), elem.time.year, elem.capture_count }),
            .year => try writer.print(
                \\                    <b class="preview-title">{s} {d}</b>
                \\                    <span class="capture-count">{d} Aufnahmen</span>
            , .{ elem.time.monthName(), elem.time.year, elem.capture_count }),
            .full => try writer.print(
                \\                    <b class="preview-title">{d}</b>
                \\                    <span class="capture-count">{d} Aufnahmen</span>
            , .{ elem.time.year, elem.capture_count }),
        }

        try writer.writeAll(
            \\
            \\                </div>
            \\            </a>
            \\
        );
    }

    try writer.print(
        \\    </div>
        \\
    , .{});
}
