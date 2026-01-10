const std = @import("std");
const dvui = @import("dvui");

const videoPlayer = @import("video_player.zig").videoPlayer;

const Categorize = @import("view/Categorize.zig");

pub extern "meta" fn window_get_path() [*:0]const u8;
pub extern "meta" fn window_get_search() [*:0]const u8;
pub extern "meta" fn window_set_url(ptr: [*]const u8, len: usize) void;

var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_instance.allocator();

var current_view: union(enum) {
    root: void,
    categorize: Categorize,
} = .root;

pub fn init(win: *dvui.Window) !void {
    // Apply theme preference
    win.themeSet(switch (win.backend.preferredColorScheme() orelse .light) {
        .light => dvui.Theme.builtin.adwaita_light,
        .dark => dvui.Theme.builtin.adwaita_dark,
    });

    const path = std.mem.span(window_get_path());
    const search = std.mem.span(window_get_search());
    const query = if (std.mem.indexOfScalar(u8, search, '?')) |idx| search[(idx + 1)..] else search;

    if (std.mem.eql(u8, path, Categorize.route)) {
        current_view = .{ .categorize = .init(query) };
    }
}

// Run as app is shutting down before dvui.Window.deinit()
pub fn deinit() void {}

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

    switch (current_view) {
        .root => {}, // TODO,
        .categorize => |*view| view.frame(),
    }

    @import("video_player.zig").endOfFrame();

    return .ok;
}
