const std = @import("std");
const dvui = @import("dvui");

const videoPlayer = @import("video_player.zig").videoPlayer;

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

    var scaler = dvui.scale(@src(), .{ .scale = &dvui.currentWindow().content_scale, .pinch_zoom = .global }, .{ .rect = .cast(dvui.windowRect()) });
    scaler.deinit();

    if (dvui.button(@src(), "Meow :3", .{}, .{})) {
        visible = !visible;
    }

    if (visible) {
        videoPlayer(@src(), .{ .source = "/example.mp4" }, .{ .background = true, .style = .content, .min_size_content = .{ .w = 500, .h = 500 }, .corner_radius = .all(5) });
    }

    @import("video_player.zig").endOfFrame();

    return .ok;
}
