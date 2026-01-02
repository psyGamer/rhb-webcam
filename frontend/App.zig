const std = @import("std");
const dvui = @import("dvui");

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

pub fn frame() !dvui.App.Result {
    for (dvui.events()) |*event| {
        switch (event.evt) {
            .key => |key| {
                std.log.info("key {}", .{key});

                switch (key.code) {
                    .f12 => if (key.action == .down) {
                        dvui.toggleDebugWindow();
                        event.handled = true;
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    _ = dvui.button(@src(), "Meow :3", .{}, .{});

    return .ok;
}
