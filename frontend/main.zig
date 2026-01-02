const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

const App = @import("App.zig");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 800.0, .h = 600.0 },
            .min_size = .{ .w = 250.0, .h = 350.0 },
            .title = "DVUI App Example",
            .window_init_options = .{
                // Could set a default theme here
                // .theme = dvui.Theme.builtin.dracula,
            },
        },
    },
    .initFn = App.init,
    .deinitFn = App.deinit,
    .frameFn = App.frame,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;

pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};
