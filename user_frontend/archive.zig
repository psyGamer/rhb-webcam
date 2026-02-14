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

    prev: ?[]const u8,
    next: ?[]const u8,

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

    if (opts.type != .full) {
        try writer.print(
            \\            <div class="capture-navigation">
            \\                <a class="icon-button {s}" href="/{s}/archive/{s}">
            \\                    <!-- Source: https://icongr.am/entypo/chevron-left.svg -->
            \\                    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 20 20" fill="currentColor">
            \\                        <g>
            \\                            <path d="M12.452 4.516c.446.436.481 1.043 0 1.576L8.705 10l3.747 3.908c.481.533.446 1.141 0 1.574-.445.436-1.197.408-1.615 0-.418-.406-4.502-4.695-4.502-4.695a1.095 1.095 0 0 1 0-1.576s4.084-4.287 4.502-4.695c.418-.409 1.17-.436 1.615 0z"/>
            \\                        </g>
            \\                    </svg>
            \\                </a>
            \\
        , .{ if (opts.prev == null) "disabled" else "", @tagName(opts.location), opts.prev orelse "" });
        switch (opts.type) {
            .day => try writer.print(
                \\                <a class="text-button" href="/{s}/archive/{d}-{d:0>2}">Übersicht <b>{s} {d}</b></a>
            , .{ @tagName(opts.location), opts.date.year, opts.date.month, opts.date.monthName(), opts.date.year }),
            .month => try writer.print(
                \\                <a class="text-button" href="/{s}/archive/{d}">Übersicht <b>Jahr {d}</b></a>
            , .{ @tagName(opts.location), opts.date.year, opts.date.year }),
            .year => try writer.print(
                \\                <a class="text-button" href="/{s}/archive">Übersicht <b>Alle Jahre</b></a>
            , .{@tagName(opts.location)}),
            .full => unreachable,
        }
        try writer.print(
            \\                <a class="icon-button {s}" href="/{s}/archive/{s}">
            \\                    <!-- Source: https://icongr.am/entypo/chevron-right.svg -->
            \\                    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 20 20" fill="currentColor">
            \\                        <g>
            \\                            <path d="M9.163 4.516c.418.408 4.502 4.695 4.502 4.695a1.095 1.095 0 0 1 0 1.576s-4.084 4.289-4.502 4.695c-.418.408-1.17.436-1.615 0-.446-.434-.481-1.041 0-1.574L11.295 10 7.548 6.092c-.481-.533-.446-1.141 0-1.576.445-.436 1.197-.409 1.615 0z"/>
            \\                        </g>
            \\                    </svg>
            \\                </a>
            \\            </div>
        , .{ if (opts.next == null) "disabled" else "", @tagName(opts.location), opts.next orelse "" });
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
                \\            <a class="preview card" href="/{s}/{f}">
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
            \\                <img src="/{s}/thumb/{s}">
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
