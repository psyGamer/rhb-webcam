const std = @import("std");
const dvui = @import("dvui");

pub extern "video" fn video_init(id: u64) u32;
pub extern "video" fn video_width(id: u64) u32;
pub extern "video" fn video_height(id: u64) u32;
pub extern "video" fn video_play(id: u64) void;
pub extern "video" fn video_pause(id: u64) void;
pub extern "video" fn video_is_paused(id: u64) bool;
pub extern "video" fn video_set_position(id: u64, position: f32) void;
pub extern "video" fn video_get_position(id: u64) f32;
pub extern "video" fn video_get_duration(id: u64) f32;
pub extern "video" fn video_set_speed(id: u64, speed: f32) void;
pub extern "video" fn video_get_speed(id: u64) f32;
pub extern "video" fn video_cleanup_unused() void;

const InitOptions = struct {
    source: []const u8,
};
pub fn videoPlayer(src: std.builtin.SourceLocation, init_opts: InitOptions, opts: dvui.Options) void {
    _ = init_opts; // autofix

    const box = dvui.box(src, .{}, opts);
    defer box.deinit();

    const texture = dvui.dataGetPtrDefault(null, box.data().id, "texture", dvui.Texture, .{ .ptr = undefined, .width = 0, .height = 0 });

    const player_id = box.data().id.asU64();
    const texture_id = video_init(player_id);

    if (texture_id == 0) {
        dvui.spinner(@src(), .{ .gravity_x = 0.5, .gravity_y = 0.5 });
        return;
    }

    const texture_ptr: *anyopaque = @ptrFromInt(texture_id);
    if (texture.ptr != texture_ptr or texture.width == 0 or texture.height == 0) {
        texture.* = .{
            .ptr = texture_ptr,
            .width = video_width(player_id),
            .height = video_height(player_id),
        };
    }

    const image = dvui.image(@src(), .{ .source = .{ .texture = texture.* }, .shrink = .both }, .{});
    const image_rect = image.rectScale().rectToPhysical(image.rect);

    dvui.label(@src(), "Rect {f}", .{image_rect}, .{});

    const bar_size = 48;
    var floating: dvui.FloatingWidget = undefined;
    floating.init(@src(), .{ .mouse_events = true }, .{ .rect = .{ .x = image_rect.x, .y = image_rect.y + image_rect.h - bar_size, .w = image_rect.w, .h = bar_size } });
    defer floating.deinit();

    const bar_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = true, .expand = .both });
    defer bar_box.deinit();

    if (video_is_paused(player_id)) {
        if (dvui.buttonIcon(@src(), "Play", dvui.entypo.controller_play, .{}, .{}, .{ .color_fill = .transparent, .min_size_content = .{ .w = bar_size, .h = bar_size }, .margin = .all(0) })) {
            video_play(player_id);
        }
    } else {
        if (dvui.buttonIcon(@src(), "Pause", dvui.entypo.controller_pause, .{}, .{}, .{ .color_fill = .transparent, .min_size_content = .{ .w = bar_size, .h = bar_size }, .margin = .all(0) })) {
            video_pause(player_id);
        }
    }

    const speeds = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 10.0, 15.0 };
    const speeds_text = comptime b: {
        var names: [speeds.len][]const u8 = undefined;
        for (speeds, &names) |speed, *name| {
            name.* = std.fmt.comptimePrint("{:.0}x", .{speed});
        }
        break :b names;
    };

    const font = opts.fontGet().withWeight(.bold);
    const position = video_get_position(player_id);
    const duration = video_get_duration(player_id);

    var fraction = position / duration;
    if (dvui.slider(@src(), .{ .fraction = &fraction }, .{ .expand = .horizontal, .gravity_y = 0.5 })) {
        video_set_position(player_id, fraction * duration);
    }

    if (duration < std.time.s_per_hour)
        dvui.label(@src(), "{:.0}:{:0>2.0} / {:.0}:{:0>2.0}", .{ @divFloor(position, std.time.s_per_min), @mod(position, std.time.s_per_min), @divFloor(duration, std.time.s_per_min), @mod(duration, std.time.s_per_min) }, .{ .font = font, .gravity_y = 0.5 })
    else
        dvui.label(@src(), "{:.0}:{:0>2.0}:{:0>2.0} / {:.0}:{:0>2.0}:{:0>2.0}", .{ @divFloor(position, std.time.s_per_hour), @mod(@divFloor(position, std.time.s_per_min), 60), @mod(position, std.time.s_per_min), @divFloor(duration, std.time.s_per_hour), @mod(@divFloor(duration, std.time.s_per_min), 60), @mod(duration, std.time.s_per_min) }, .{ .font = font, .gravity_y = 0.5 });

    const speed = video_get_speed(player_id);
    var speed_idx = for (&speeds, 0..) |target_speed, idx| {
        if (std.math.approxEqAbs(f32, speed, target_speed, 0.1)) {
            break idx;
        }
    } else 0;

    if (dvui.dropdown(@src(), &speeds_text, &speed_idx, .{ .gravity_y = 0.5 })) {
        video_set_speed(player_id, speeds[speed_idx]);
    }
}

pub fn endOfFrame() void {
    // Perform cleanup at end of frame
    video_cleanup_unused();
}
