//! Utility for performing fetch-requests to the webserver
const std = @import("std");
const dvui = @import("dvui");

/// Perform a raw GET web-request to the target URL
pub fn get(url: []const u8, comptime callback: fn (status: std.http.Status, data: []const u8) void) void {
    const cb = &struct {
        pub fn cb(_: void, status: std.http.Status, data: []const u8) void {
            callback(status, data);
        }
    }.cb;

    url_fetch(@intFromEnum(std.http.Method.GET), url.ptr, url.len, null, 0, allocUserData(void, {}, cb));
}
/// Perform a raw PUT web-request to the target URL
pub fn put(url: []const u8, body: []const u8) void {
    url_fetch(@intFromEnum(std.http.Method.PUT), url.ptr, url.len, body.ptr, body.len, allocUserData(void, {}, null));
}
/// Perform a raw DELETE web-request to the target URL
pub fn delete(url: []const u8, opt_callback: ?FetchCallback) void {
    const cb = if (opt_callback) |callback| &struct {
        pub fn cb(_: void, status: std.http.Status, data: []const u8) void {
            callback(status, data);
        }
    }.cb else null;

    url_fetch(@intFromEnum(std.http.Method.DELETE), url.ptr, url.len, null, 0, allocUserData(void, {}, cb));
}

pub fn JsonResult(comptime T: type) type {
    return std.json.ParseError(std.json.Scanner)!std.json.Parsed(T);
}
pub fn JsonResultLeaky(comptime T: type) type {
    return std.json.ParseError(std.json.Scanner)!T;
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

    const ctx = try allocUserData(Context, dvui.currentWindow().gpa, &Context.cb);
    ctx.* = .{ .window = dvui.currentWindow() };

    url_fetch(@intFromEnum(std.http.Method.GET), url.ptr, url.len, null, 0, ctx);
}
/// Perform a web-request to the target URL and try to parse the response as JSON data
/// The resulting JSON object will be allocated with the windows area allocator
pub fn fetchJsonObjectLeaky(comptime T: type, url: []const u8, comptime callback: fn (value: JsonResultLeaky(T), window: *dvui.Window) void) !void {
    const Context = struct {
        window: *dvui.Window,

        pub fn cb(ctx: *@This(), status: std.http.Status, data: []const u8) void {
            defer freeUserData(@This(), ctx.window.gpa, ctx);

            if (status != .ok) return;
            const value = std.json.parseFromSliceLeaky(T, ctx.window.arena(), data, .{});
            callback(value, ctx.window);
        }
    };

    const ctx = try allocUserData(Context, dvui.currentWindow().gpa, &Context.cb);
    ctx.* = .{ .window = dvui.currentWindow() };

    url_fetch(@intFromEnum(std.http.Method.GET), url.ptr, url.len, null, 0, ctx);
}

const FetchCallback = fn (userdata: *anyopaque, status: std.http.Status, data: []const u8) void;

fn allocUserData(comptime T: type, allocator: if (@sizeOf(T) == 0) void else std.mem.Allocator, comptime callback: ?*const fn (data: *T, status: std.http.Status, data: []const u8) void) (if (@sizeOf(T) == 0) (*anyopaque) else (std.mem.Allocator.Error!*T)) {
    if (@sizeOf(T) == 0) {
        const callback_ptr: *const ?*const FetchCallback = @ptrCast(&callback);
        // Avoid allocations by just returning the callback function pointer
        return @ptrFromInt(@intFromPtr(callback_ptr) + @sizeOf(*const FetchCallback));
    }

    std.debug.assert(@alignOf(*const FetchCallback) <= @alignOf(usize) and @alignOf(T) <= @alignOf(usize));

    const data = try allocator.alignedAlloc(u8, .of(usize), @sizeOf(*const FetchCallback) + @sizeOf(T));
    const ptr: *?*const FetchCallback = @ptrCast(data[0..@sizeOf(*const FetchCallback)]);
    ptr.* = @ptrCast(callback);

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
extern "meta" fn url_fetch(method: u8, url_ptr: [*]const u8, url_len: usize, body_ptr: ?[*]const u8, body_len: usize, userdata: *anyopaque) void;
export fn url_callback(userdata: *anyopaque, status: u16, data: [*]const u8, len: usize) void {
    const opt_callback: *const ?*const FetchCallback = @ptrFromInt(@intFromPtr(userdata) - @sizeOf(*const FetchCallback));
    if (opt_callback.*) |callback| {
        callback(userdata, @enumFromInt(status), data[0..len]);
    }
}
