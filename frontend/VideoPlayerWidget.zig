const std = @import("std");
const dvui = @import("dvui");

const video = @import("video.zig");

const VideoPlayerWidget = @This();

texture: dvui.Texture = .{ .ptr = undefined, .width = 0, .height = 0 },

const InitOptions = struct {
    source: []const u8,
};
pub fn videoPlayer(src: std.builtin.SourceLocation, init_opts: InitOptions, opts: dvui.Options) void {
    _ = init_opts; // autofix

    const box = dvui.box(src, .{}, opts);
    defer box.deinit();

    const self = dvui.dataGetPtrDefault(null, box.data().id, "self", VideoPlayerWidget, .{});

    const player_id = box.data().id.asU64();
    const texture_id = video.video_init(player_id);

    if (texture_id != 0) {
        const texture_ptr: *anyopaque = @ptrFromInt(texture_id);
        if (self.texture.ptr != texture_ptr or self.texture.width == 0 or self.texture.height == 0) {
            self.texture = .{
                .ptr = texture_ptr,
                .width = video.video_width(player_id),
                .height = video.video_height(player_id),
            };
        }

        dvui.labelNoFmt(@src(), ":3", .{}, .{});
        _ = dvui.image(@src(), .{ .source = .{ .texture = self.texture } }, .{ .min_size_content = .{ .w = 500, .h = 500 } });
        dvui.labelNoFmt(@src(), ":3", .{}, .{});
    }
}

pub fn init(self: *VideoPlayerWidget, src: std.builtin.SourceLocation, init_opts: InitOptions, opts: dvui.Options) void {
    self.* = .{};

    const gpa = dvui.currentWindow().lifo();
    const text = std.fmt.allocPrint(gpa, "clicks {d}", .{self.counter}) catch "";
    defer gpa.free(text);

    if (dvui.button(src, text, .{}, .{})) {
        self.counter += 1;
    }
    _ = init_opts; // autofix
    _ = opts; // autofix
}
pub fn deinit(self: *VideoPlayerWidget) void {
    _ = self; // autofix
}
