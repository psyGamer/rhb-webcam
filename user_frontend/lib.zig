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
        \\        <h1>{s} Webcam Archiv</h1>
        \\        <nav>
        \\            <details class="archive">
        \\                <summary>Archiv</summary>
        \\                <div>
        \\                    <a href="/{s}/archive/{d:0>4}-{d:0>2}-{d:0>2}">Tagesarchiv</a>
        \\                    <a href="/{s}/archive/{d:0>4}-{d:0>2}">Monatsarchiv</a>
        \\                    <a href="/{s}/archive/{d:0>4}">Jahresarchiv</a>
        \\                    <a href="/{s}/archive">Langzeitarchiv</a>
        \\                </div>
        \\            </details>
        \\            <!-- <a href="/search">Suche</a> -->
        \\        </nav>
        \\    </header>
    , .{ Location.names.get(location), @tagName(location), @as(u32, @intCast(today.year)), today.month, today.day, @tagName(location), @as(u32, @intCast(today.year)), today.month, @tagName(location), @as(u32, @intCast(today.year)), @tagName(location) });

    try @call(.always_inline, page_render, page_args);

    try writer.writeAll(
        \\</body>
        \\</html>
    );
}
