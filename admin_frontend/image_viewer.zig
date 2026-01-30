const std = @import("std");
const dvui = @import("dvui");

extern "video" fn image_init(id: u64, ptr: [*]const u8, len: usize) u32;
extern "video" fn image_width(id: u64) u32;
extern "video" fn image_height(id: u64) u32;
extern "video" fn image_cleanup_unused() void;

const InitOptions = struct {
    /// URL for the image
    source: []const u8,

    /// UV coordinates for the rendered region of the image
    uv: dvui.Rect = .{ .w = 1, .h = 1 },
};
pub fn imageViewer(src: std.builtin.SourceLocation, init_opts: InitOptions, opts: dvui.Options) dvui.RectScale {
    const box = dvui.box(src, .{}, opts.override(.{ .border = .all(0) }));
    defer box.deinit();

    const texture = dvui.dataGetPtrDefault(null, box.data().id, "texture", dvui.Texture, .{ .ptr = undefined, .width = 0, .height = 0 });
    const viewer_id = box.data().id.asU64();
    const texture_id = image_init(viewer_id, init_opts.source.ptr, init_opts.source.len);

    if (texture_id == 0) {
        dvui.spinner(@src(), .{ .gravity_x = 0.5, .gravity_y = 0.5 });
        return box.data().rectScale();
    }

    const texture_ptr: *anyopaque = @ptrFromInt(texture_id);
    if (texture.ptr != texture_ptr or texture.width == 0 or texture.height == 0) {
        texture.* = .{
            .ptr = texture_ptr,
            .width = image_width(viewer_id),
            .height = image_height(viewer_id),
        };
    }

    _ = dvui.image(@src(), .{
        .source = .{ .texture = texture.* },
        .shrink = .ratio,
        .uv = init_opts.uv,
    }, .{
        .min_size_content = .{
            .w = @as(f32, @floatFromInt(texture.width)) * (init_opts.uv.w - init_opts.uv.x),
            .h = @as(f32, @floatFromInt(texture.height)) * (init_opts.uv.h - init_opts.uv.y),
        },
        .corner_radius = opts.corner_radius,
        .border = opts.border,
        .expand = .ratio,
    });
    return box.data().rectScale();
}
pub fn imageTexture(id: dvui.Id, source: []const u8, texture: *dvui.Texture) bool {
    const viewer_id = id.asU64();
    const texture_id = image_init(viewer_id, source.ptr, source.len);

    if (texture_id == 0) {
        return false;
    }

    const texture_ptr: *anyopaque = @ptrFromInt(texture_id);
    if (texture.ptr != texture_ptr or texture.width == 0 or texture.height == 0) {
        texture.* = .{
            .ptr = texture_ptr,
            .width = image_width(viewer_id),
            .height = image_height(viewer_id),
        };
    }

    return true;
}

pub fn endOfFrame() void {
    // Perform cleanup at end of frame
    image_cleanup_unused();
}
