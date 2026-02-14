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
        \\            <!-- <details class="location-select">
        \\                <summary>{s}</summary>
        \\                <div>
        \\                    <a href="/{s}">{s}</a>
        \\                    <a href="/{s}">{s}</a>
        \\                    <a href="/{s}">{s}</a>
        \\                    <a href="/{s}">{s}</a>
        \\                </div>
        \\            </details> -->
        \\            Filisur Webcam Archiv
        \\        </h1>
        \\        <nav>
        \\            <a class="boxed-button" href="/filisur/archive">Archiv</a>
        \\            <!-- <a class="boxed-button" href="/search">Suche</a> -->
        \\
        \\            <a class="hamburger" onclick="showSideMenu(true)">
        \\                <!-- Source: https://icongr.am/entypo/menu.svg -->
        \\                <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 20 20" fill="currentColor">
        \\                    <g>
        \\                        <path d="M16.4 9H3.6c-.552 0-.6.447-.6 1 0 .553.048 1 .6 1h12.8c.552 0 .6-.447.6-1 0-.553-.048-1-.6-1zm0 4H3.6c-.552 0-.6.447-.6 1 0 .553.048 1 .6 1h12.8c.552 0 .6-.447.6-1 0-.553-.048-1-.6-1zM3.6 7h12.8c.552 0 .6-.447.6-1 0-.553-.048-1-.6-1H3.6c-.552 0-.6.447-.6 1 0 .553.048 1 .6 1z"/>
        \\                    </g>
        \\                </svg>
        \\            </a>
        \\        </nav>
        \\
        \\        <div class="side-menu" aria-pressed="false">
        \\            <a class="close" onclick="showSideMenu(false)">
        \\                <!-- Source: https://icongr.am/entypo/cross.svg -->
        \\                <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 20 20" fill="currentColor">
        \\                    <g>
        \\                        <path d="M14.348 14.849a1.2 1.2 0 0 1-1.697 0L10 11.819l-2.651 3.029a1.2 1.2 0 1 1-1.697-1.697l2.758-3.15-2.759-3.152a1.2 1.2 0 1 1 1.697-1.697L10 8.183l2.651-3.031a1.2 1.2 0 1 1 1.697 1.697l-2.758 3.152 2.758 3.15a1.2 1.2 0 0 1 0 1.698z"/>
        \\                    </g>
        \\                </svg>
        \\            </a>
        \\
        \\            <a class="boxed-button" href="/filisur/archive">Archiv</a>
        \\            <!-- <a class="boxed-button" href="/search">Suche</a> -->
        \\        </div>
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
        \\    <script>
        \\        const sideMenu = document.querySelector('.side-menu');
        \\
        \\        function showSideMenu(state) {
        \\            sideMenu.setAttribute('aria-pressed', state);
        \\        }
        \\    </script>
        \\</body>
        \\</html>
    );
}
