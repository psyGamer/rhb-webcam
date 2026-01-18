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

    control_bar: union(enum) {
        /// Don't display the media control bar
        hide: void,
        /// Automatically hide the media control bar when not using it
        /// Given value is the timeout in micro-seconds
        auto_hide: u32,
        /// Alawys display the media control bar
        show: void,
    } = .{ .auto_hide = 3 * std.time.us_per_s },
};
pub fn videoPlayer(src: std.builtin.SourceLocation, init_opts: InitOptions, opts: dvui.Options) void {
    const box = dvui.box(src, .{}, opts);
    defer box.deinit();

    const texture = dvui.dataGetPtrDefault(null, box.data().id, "texture", dvui.Texture, .{ .ptr = undefined, .width = 0, .height = 0 });

    var has_motion = false;
    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, box.data())) {
            continue;
        }

        if (e.evt == .mouse and e.evt.mouse.action == .motion) {
            has_motion = true;
            break;
        }
    }

    const fade_time = 0.25;
    const fade_speed: comptime_int = fade_time * std.time.us_per_s;
    const fade = calc_fade: {
        if (init_opts.control_bar == .hide) break :calc_fade 0.0;
        if (init_opts.control_bar == .show) break :calc_fade 1.0;

        const fade_out_init_anim: dvui.Animation = .{ .end_time = @intCast(init_opts.control_bar.auto_hide + fade_speed), .start_val = @as(f32, @floatFromInt(init_opts.control_bar.auto_hide)) / std.time.us_per_s + fade_time, .end_val = 0.0 };

        if (dvui.animationGet(box.data().id, "control_fade_in")) |anim| {
            dvui.animation(box.data().id, "control_fade_out", fade_out_init_anim);
            break :calc_fade anim.value();
        }

        const fade_out = if (dvui.animationGet(box.data().id, "control_fade_out")) |anim| anim.value() else 0.0;
        const fade_alpha = @min(fade_time, @max(0.0, fade_out)) / fade_time;

        if (has_motion) {
            if (fade_alpha < 1.0) {
                const fade_in = 1.0 - fade_alpha;
                dvui.animation(box.data().id, "control_fade_in", .{ .end_time = @intFromFloat(fade_in * fade_speed), .start_val = fade_out, .end_val = fade_in });
            } else {
                dvui.animation(box.data().id, "control_fade_out", fade_out_init_anim);
            }
        }

        break :calc_fade fade_alpha;
    };

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

        if (init_opts.control_bar == .auto_hide) {
            const fade_out_init_anim: dvui.Animation = .{ .end_time = @intCast(init_opts.control_bar.auto_hide + fade_speed), .start_val = @as(f32, @floatFromInt((init_opts.control_bar.auto_hide + fade_speed))) / std.time.us_per_s, .end_val = 0.0 };
            dvui.animation(box.data().id, "control_fade_out", fade_out_init_anim);
        }
    }

    const image = dvui.image(@src(), .{ .source = .{ .texture = texture.* }, .shrink = .both }, .{ .corner_radius = opts.corner_radius });
    const image_rs = image.rectScale();
    const image_rect = image_rs.r.scale(1.0 / image_rs.s, dvui.Rect.Physical);

    const bar_size = 32;
    const bar_margin = 6;
    const bar_padding = 6;

    const prev_alpha = dvui.alpha(fade);
    defer dvui.alphaSet(prev_alpha);

    var floating: dvui.FloatingWidget = undefined;
    floating.init(@src(), .{ .mouse_events = true }, .{ .rect = .{ .x = image_rect.x, .y = image_rect.y + image_rect.h - bar_size, .w = image_rect.w, .h = bar_size + bar_margin * 2 } });
    defer floating.deinit();

    const bar_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = true, .expand = .both, .padding = .all(0), .corner_radius = opts.corner_radius });
    defer bar_box.deinit();

    const button_opts: dvui.Options = .{ .color_fill = .transparent, .min_size_content = .{ .w = bar_size, .h = bar_size }, .gravity_y = 0.5, .padding = .all(0), .margin = .all(bar_margin) };
    if (video_is_paused(player_id)) {
        if (dvui.buttonIcon(@src(), "Play", dvui.entypo.controller_play, .{}, .{}, button_opts)) {
            video_play(player_id);
        }
    } else {
        if (dvui.buttonIcon(@src(), "Pause", dvui.entypo.controller_pause, .{}, .{}, button_opts)) {
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
    if (dvui.slider(@src(), .{ .fraction = &fraction }, .{ .expand = .horizontal, .gravity_y = 0.5, .padding = .all(0), .margin = .{ .w = bar_margin } })) {
        video_set_position(player_id, fraction * duration);
    }

    const label_opts: dvui.Options = .{ .font = font, .gravity_y = 0.5, .padding = .all(0) };
    if (duration < std.time.s_per_hour)
        dvui.label(@src(), "{:.0}:{:0>2.0} / {:.0}:{:0>2.0}", .{ @divFloor(position, std.time.s_per_min), @mod(position, std.time.s_per_min), @divFloor(duration, std.time.s_per_min), @mod(duration, std.time.s_per_min) }, label_opts)
    else
        dvui.label(@src(), "{:.0}:{:0>2.0}:{:0>2.0} / {:.0}:{:0>2.0}:{:0>2.0}", .{ @divFloor(position, std.time.s_per_hour), @mod(@divFloor(position, std.time.s_per_min), 60), @mod(position, std.time.s_per_min), @divFloor(duration, std.time.s_per_hour), @mod(@divFloor(duration, std.time.s_per_min), 60), @mod(duration, std.time.s_per_min) }, label_opts);

    const speed = video_get_speed(player_id);
    var speed_idx = for (&speeds, 0..) |target_speed, idx| {
        if (std.math.approxEqAbs(f32, speed, target_speed, 0.1)) {
            break idx;
        }
    } else 0;

    if (dvui.dropdown(@src(), &speeds_text, &speed_idx, .{ .font = font, .gravity_y = 0.5, .padding = .all(bar_padding), .margin = .all(bar_margin) })) {
        video_set_speed(player_id, speeds[speed_idx]);
    }
}

pub fn endOfFrame() void {
    // Perform cleanup at end of frame
    video_cleanup_unused();
}
