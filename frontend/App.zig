const std = @import("std");
const dvui = @import("dvui");

const videoPlayer = @import("VideoPlayerWidget.zig").videoPlayer;
const video = @import("video.zig");

var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_instance.allocator();

pub fn init(win: *dvui.Window) !void {
    // Apply theme preference
    win.themeSet(switch (win.backend.preferredColorScheme() orelse .light) {
        .light => dvui.Theme.builtin.adwaita_light,
        .dark => dvui.Theme.builtin.adwaita_dark,
    });
}

// Run as app is shutting down before dvui.Window.deinit()
pub fn deinit() void {}

var visible: bool = true;

pub fn frame() !dvui.App.Result {
    for (dvui.events()) |*event| {
        switch (event.evt) {
            .key => |key| {
                std.log.info("key {}", .{key});

                switch (key.code) {
                    .f10 => if (key.action == .down) {
                        dvui.toggleDebugWindow();
                        event.handled = true;
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    if (dvui.button(@src(), "Meow :3", .{}, .{})) {
        visible = !visible;
    }

    if (visible) {
        videoPlayer(@src(), .{ .source = "/example.mp4" }, .{});
    }

    // Perform cleanup at end of frame
    video.video_cleanup_unused();

    return .ok;
}
