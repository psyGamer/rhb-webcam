const std = @import("std");

const Date = @import("common").time.Date;
const Location = @import("common").Location;
const Source = @import("source.zig").Source;

const image_video_view = @import("image_video.zig");
const archive_view = @import("archive.zig");

pub const ImageVideoViewOptions = image_video_view.Options;
pub fn imageVideoView(writer: *std.Io.Writer, options: ImageVideoViewOptions) !void {
    try render(writer, Source.location.get(options.source), image_video_view.render, .{ writer, options });
}

pub const ArchiveViewOptions = archive_view.Options;
pub fn archiveView(writer: *std.Io.Writer, options: ArchiveViewOptions) !void {
    try render(writer, options.location, archive_view.render, .{ writer, options });
}

inline fn render(writer: *std.Io.Writer, location: Location, page_render: anytype, page_args: anytype) !void {
    const today: Date = .today();
    _ = today; // autofix

    try writer.print(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\    <meta charset="UTF-8">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\
        \\    <link rel="stylesheet" href="/style.css">
        \\
        \\    <title>Filisur Webcam Archiv</title>
        \\</head>
        \\<body>
        \\    <header>
        \\        <h1>
        \\            <details class="location-select">
        \\                <summary>{s}</summary>
        \\                <div>
        \\                    <a href="/{s}">{s}</a>
        \\                    <a href="/{s}">{s}</a>
        \\                    <a href="/{s}">{s}</a>
        \\                    <a href="/{s}">{s}</a>
        \\                </div>
        \\            </details>
        \\            Webcam Archiv
        \\        </h1>
        \\        <nav>
        \\            <a class="boxed-button" href="/filisur/archive">Archiv</a>
        \\            <a class="boxed-button" href="/search">Suche</a>
        \\        </nav>
        \\    </header>
        \\
    , .{
        Location.names.get(location),
        @tagName(Location.filisur),
        Location.names.get(.filisur),
        @tagName(Location.landwasser),
        Location.names.get(.landwasser),
        @tagName(Location.landquart),
        Location.names.get(.landquart),
        @tagName(Location.brusio),
        Location.names.get(.brusio),
    });

    try @call(.always_inline, page_render, page_args);

    try writer.writeAll(
        \\</body>
        \\</html>
    );
}
