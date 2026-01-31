const std = @import("std");

const image_view = @import("image_view.zig");

pub const ImageViewOptions = image_view.Options;
pub fn imageView(writer: *std.Io.Writer, options: ImageViewOptions) !void {
    try render(writer, image_view.render, .{ writer, options });
}

inline fn render(writer: *std.Io.Writer, page_render: anytype, page_args: anytype) !void {
    try writer.writeAll(
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
        \\        <h1>Filisur Webcam Archiv</h1>
        \\        <nav>
        \\            <details class="archive">
        \\                <summary>Archiv</summary>
        \\                <div>
        \\                    <a href="/archiv/2026-01-21">Tagesarchiv</a>
        \\                    <a href="/archiv/2026-01">Monatsarchiv</a>
        \\                    <a href="/archiv/2026">Jahresarchiv</a>
        \\                    <a href="/archiv">Langzeitarchiv</a>
        \\                </div>
        \\            </details>
        \\            <a href="/search">Suche</a>
        \\        </nav>
        \\    </header>
    );

    try @call(.always_inline, page_render, page_args);

    try writer.writeAll(
        \\</body>
        \\</html>
    );
}
