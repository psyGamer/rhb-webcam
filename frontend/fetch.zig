//! Utility for performing fetch-requests to the webserver
const std = @import("std");
const dvui = @import("dvui");

const FetchCallback = fn (userdata: *anyopaque, status: std.http.Status, data: []const u8) void;

fn allocUserData(comptime T: type, allocator: std.mem.Allocator, callback: fn (data: *T, status: std.http.Status, data: []const u8) void) (if (@sizeOf(T) == 0) (*anyopaque) else (std.mem.Allocator.Error!*T)) {
    if (@sizeOf(T) == 0) {
        // Avoid allocations by just returning the callback function pointer
        return @ptrFromInt(@intFromPtr(&callback) + @sizeOf(*const FetchCallback));
    }

    std.debug.assert(@alignOf(*const FetchCallback) <= @alignOf(usize) and @alignOf(T) <= @alignOf(usize));

    const data = try allocator.alignedAlloc(u8, .of(usize), @sizeOf(*const FetchCallback) + @sizeOf(T));
    const ptr: **const FetchCallback = @ptrCast(data[0..@sizeOf(*const FetchCallback)]);
    ptr.* = @ptrCast(&callback);

    return @ptrCast(@alignCast(data[@sizeOf(*const FetchCallback)..]));
}
fn freeUserData(comptime T: type, allocator: std.mem.Allocator, context: *T) void {
    if (@sizeOf(T) == 0) {
        // No allocation was ever made
        return;
    }

    const ptr: [*]const u8 = @ptrFromInt(@intFromPtr(context) - @sizeOf(*const FetchCallback));
    const data: []align(@alignOf(usize)) const u8 = @alignCast(ptr[0 .. @sizeOf(*const FetchCallback) + @sizeOf(T)]);

    allocator.free(data);
}

// `userdata` must have been created with `allocUserData`
extern "meta" fn url_fetch(ptr: [*]const u8, len: usize, userdata: *anyopaque) void;
export fn url_callback(userdata: *anyopaque, status: u16, data: [*]const u8, len: usize) void {
    const callback: **const FetchCallback = @ptrFromInt(@intFromPtr(userdata) - @sizeOf(*const FetchCallback));
    callback.*(userdata, @enumFromInt(status), data[0..len]);
}

/// Perform a raw web-request to the target URL
pub fn fetch(url: []const u8, callback: FetchCallback) void {
    url_fetch(url.ptr, url.len, allocUserData(void, undefined, callback));
}

pub fn JsonResult(comptime T: type) type {
    return std.json.ParseError(std.json.Scanner)!std.json.Parsed(T);
}

/// Perform a web-request to the target URL and try to parse the response as JSON data
pub fn fetchJsonObject(comptime T: type, url: []const u8, comptime callback: fn (value: JsonResult(T), window: *dvui.Window) void) !void {
    const Context = struct {
        window: *dvui.Window,

        pub fn cb(ctx: *@This(), status: std.http.Status, data: []const u8) void {
            defer freeUserData(@This(), ctx.window.gpa, ctx);

            if (status != .ok) return;
            const value = std.json.parseFromSlice(T, ctx.window.gpa, data, .{ .allocate = .alloc_always });
            callback(value, ctx.window);
        }
    };

    const ctx = try allocUserData(Context, dvui.currentWindow().gpa, Context.cb);
    ctx.* = .{ .window = dvui.currentWindow() };

    url_fetch(url.ptr, url.len, ctx);
}
