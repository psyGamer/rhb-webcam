pub extern "video" fn video_init(id: u64) u32;
pub extern "video" fn video_width(id: u64) u32;
pub extern "video" fn video_height(id: u64) u32;
pub extern "video" fn video_play(id: u64) void;
pub extern "video" fn video_pause(id: u64) void;
pub extern "video" fn video_cleanup_unused() void;
