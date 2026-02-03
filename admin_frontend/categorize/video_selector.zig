const std = @import("std");
const dvui = @import("dvui");

const imageViewer = @import("../image_viewer.zig").imageViewer;
const imageTexture = @import("../image_viewer.zig").imageTexture;

const Timestamp = @import("common").Timestamp;
const api = @import("common").api;

const InitOptions = struct {
    videos: api.CategorizeFileList,
    selected: *usize,
    show_categorized: bool,

    scroll_to_current: bool = false,
};
pub fn videoSelector(src: std.builtin.SourceLocation, init_opts: InitOptions, opts: dvui.Options) bool {
    const scroll = dvui.scrollArea(src, .{}, opts);
    defer scroll.deinit();

    var updated = false;
    for (init_opts.videos, 0..) |video, idx| {
        if (!init_opts.show_categorized and video.descs.len > 0) continue;

        const state: State =
            if (idx == init_opts.selected.*)
                .selected
            else if (video.descs.len > 0)
                .categorized
            else
                .none;

        var preview_rect: dvui.Rect = undefined;
        if (videoPreview(@src(), &video.path, state, &preview_rect, .{
            .id_extra = idx,
            .margin = .all(5),
            .corner_radius = .all(15),
        })) {
            init_opts.selected.* = idx;
            updated = true;
        }

        if (init_opts.scroll_to_current and state == .selected) {
            scroll.si.scrollToOffset(.vertical, preview_rect.y + preview_rect.h / 2.0 - scroll.data().rect.h / 2.0);
        }
    }
    return updated;
}

const source_aspect_ratio = 11.0 / 9.0; // The webcam has a fixed 704x576 resolution. If that ever changes we're fucked, but that probably won't happen any time soon
const target_aspect_ratio = 16.0 / 9.0; // Cut off sky from preview and fit to common 16:9 ratio
const preview_width = 250.0;
const preview_height = preview_width / target_aspect_ratio;
const banner_height = 70.0;

const State = enum { none, categorized, selected };
pub fn videoPreview(src: std.builtin.SourceLocation, source: []const u8, state: State, rect: *dvui.Rect, opts: dvui.Options) bool {
    const ts = Timestamp.parseSimpleTime(source) orelse return false;

    const max_border: f32 = 10.0;

    var overlay: dvui.OverlayWidget = undefined;
    overlay.init(src, opts.override(.{
        .min_size_content = .{ .w = preview_width, .h = preview_height },
        .max_size_content = .{ .w = preview_width, .h = preview_height },
    }));
    defer {
        rect.* = overlay.data().rect;
        overlay.deinit();
    }

    var hover = false;
    const click = dvui.clicked(overlay.data(), .{ .hovered = &hover });

    const border: f32 = if (hover) 10 else if (state == .categorized or state == .selected) 5 else 0;
    const color: dvui.Color = if (hover or state == .selected) opts.themeGet().color(.highlight, .fill) else if (state == .categorized) .{ .r = 0x9b, .g = 0xe6, .b = 0x46 } else .transparent;

    const overlay_opts = &overlay.data().options;
    overlay_opts.padding = .all(border);
    overlay_opts.margin = .all(max_border - border);
    overlay_opts.corner_radius = if (opts.corner_radius) |rad| rad.plus(.all(border)) else null;
    overlay_opts.background = true;
    overlay_opts.color_fill = color;

    overlay.drawBackground();

    const lifo = dvui.currentWindow().lifo();
    const image_url = std.fmt.allocPrint(lifo, "/thumbnail/{s}", .{source}) catch "";
    defer lifo.free(image_url);

    const content_box = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = preview_width, .h = preview_height },

        .corner_radius = opts.corner_radius,
    });

    const image_texture = dvui.dataGetPtrDefault(null, overlay.data().id, "texture", dvui.Texture, .{ .ptr = undefined, .width = 0, .height = 0 });
    if (imageTexture(overlay.data().id, image_url, image_texture)) {
        _ = dvui.image(@src(), .{
            .source = .{ .texture = image_texture.* },
            .uv = .{ .x = 0, .y = 1.0 - source_aspect_ratio / target_aspect_ratio, .w = 1, .h = source_aspect_ratio / target_aspect_ratio },
        }, .{
            .min_size_content = .{ .w = preview_width, .h = preview_height },
            .corner_radius = opts.corner_radius,
        });
    } else {
        dvui.spinner(@src(), .{ .gravity_x = 0.5, .gravity_y = 0.5 });
    }

    // Vertical gradient from black to transparent
    var path_top: dvui.Path.Builder = .init(lifo);
    defer path_top.deinit();
    var path_bottom: dvui.Path.Builder = .init(lifo);
    defer path_bottom.deinit();

    const content_rs = content_box.data().rectScale();
    const corner_radius = (opts.corner_radius orelse dvui.Rect.all(0)).scale(content_rs.s, dvui.Rect.Physical);
    const half_height = content_rs.s * (banner_height / 2);
    path_top.addRect(.{ .x = content_rs.r.x, .y = content_rs.r.y, .w = content_rs.r.w, .h = half_height }, .{ .x = corner_radius.x, .y = corner_radius.y });
    path_bottom.addRect(.{ .x = content_rs.r.x, .y = content_rs.r.y + half_height, .w = content_rs.r.w, .h = half_height }, .{ .w = corner_radius.w, .h = corner_radius.h });

    var top_triangles = path_top.build().fillConvexTriangles(lifo, .{ .color = dvui.Color.black.opacity(0.5) }) catch dvui.Triangles.empty;
    defer top_triangles.deinit(lifo);
    var bottom_triangles = path_bottom.build().fillConvexTriangles(lifo, .{ .color = dvui.Color.black.opacity(0.5) }) catch dvui.Triangles.empty;
    defer bottom_triangles.deinit(lifo);

    for (bottom_triangles.vertexes) |*v| {
        const t = std.math.clamp((v.pos.y - content_rs.r.y - half_height) / half_height, 0, 1);
        const fade: u8 = std.math.maxInt(u8) - @as(u8, @intFromFloat(std.math.maxInt(u8) * t));
        v.col = v.col.multiply(.{ .r = fade, .g = fade, .b = fade, .a = fade });
    }

    dvui.renderTriangles(top_triangles, null) catch |err| {
        dvui.logError(@src(), err, "Could not render top gradient triangles", .{});
    };
    dvui.renderTriangles(bottom_triangles, null) catch |err| {
        dvui.logError(@src(), err, "Could not render bottom gradient triangles", .{});
    };

    content_box.deinit();

    dvui.label(@src(), "{d}. {s} {d} {d:0>2}:{d:0>2}:{d:0>2}", .{ ts.day, ts.monthName(), ts.year, ts.hour, ts.minute, ts.second }, .{ .margin = .all(5), .gravity_x = 0.5, .font = opts.fontGet().withWeight(.bold) });

    return click;
}
