const std = @import("std");
const tk = @import("tokamak");
const fr = @import("fridge");
const builtin = @import("builtin");

const Timestamp = @import("common").Timestamp;
const Direction = @import("common").Direction;

const Env = @import("main.zig").Env;

pub const Pool = fr.Pool(fr.SQLite3);

pub const Train = struct {
    pub const sql_table_name = "trains";

    id: usize,

    number: u32,
    file: []const u8,

    from_direction: ?[]const u8,
    to_direction: ?[]const u8,
};
pub const Locomotive = struct {
    pub const sql_table_name = "locomotives";

    train_id: usize,

    number: u32,
    category: []const u8,

    position: u32,
    towed: bool,
};

pub const FilisurCapture = struct {
    pub const sql_table_name = "filisur_capture";

    file: []const u8,
};
pub const LivestreamCapture = struct {
    pub const sql_table_name = "livestream_capture";

    file: []const u8,
    location: []const u8,
};
pub const LandwasserCapture = struct {
    pub const sql_table_name = "landwasser_capture";

    file: []const u8,
};
pub const LandquartCapture = struct {
    pub const sql_table_name = "landquart_capture";

    file: []const u8,
};
pub const BrusioCapture = struct {
    pub const sql_table_name = "brusio_capture";

    file: []const u8,
};

pub const Analytics = struct {
    pub const sql_table_name = "analytics";

    id: usize,

    path: []const u8,
    method: []const u8,
    status: u16,
    date: []const u8,

    address: ?[]const u8,
    user_agent: ?[]const u8,
};

pub const NotificationSubscription = struct {
    pub const sql_table_name = "notification_subscriptions";

    endpoint: []const u8,
    p256dh: []const u8,
    auth: []const u8,
};
pub const NotificationWebcam = struct {
    pub const sql_table_name = "notification_webcams";

    endpoint: []const u8,
    webcam: []const u8,
};

pub const struct_sqlite3 = opaque {};
pub const sqlite3 = struct_sqlite3;
pub extern fn sqlite3_open_v2(filename: [*c]const u8, ppDb: [*c]?*sqlite3, flags: c_int, zVfs: [*c]const u8) c_int;

/// Load the appropriate database from disk
pub fn load(pool: *Pool, allocator: std.mem.Allocator, env: *Env) !void {
    const filepath = try allocator.dupeZ(u8, env.key(if (builtin.mode == .Debug) .DATABASE_DEV_PATH else .DATABASE_PROD_PATH));
    defer allocator.free(filepath);

    const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
    const SQLITE_OPEN_CREATE: c_int = 0x00000004;
    const SQLITE_OPEN_NOMUTEX: c_int = 0x00008000;
    const SQLITE_OPEN_EXRESCODE: c_int = 0x02000000;

    const conn_opts: fr.SQLite3.Options = .{
        .filename = filepath,
        .flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_EXRESCODE,
    };
    const pool_opts: fr.PoolOptions = .{};

    pool.* = try .init(allocator, pool_opts, conn_opts);
    errdefer pool.deinit();

    // Setup all pooled connections
    // Creating them on-demand only causes issues
    var conns: [pool_opts.max_count]fr.Connection = undefined;
    for (&conns) |*conn| {
        conn.* = try pool.getConnection();

        // Properly configure connection
        try conn.execAll(
            \\PRAGMA journal_mode = WAL;
            \\PRAGMA synchronous = NORMAL;
            \\PRAGMA foreign_keys = ON;
        );
    }
    // Release back into pool for later usage
    for (conns) |conn| {
        conn.deinit();
    }

    var db = try pool.getSession(allocator);
    defer db.deinit();

    // Setup tables
    const max_dir_name = comptime b: {
        var max = 0;
        for (std.meta.fieldNames(Direction)) |name| {
            max = @max(max, name.len);
        }
        break :b max;
    };
    const all_dirs = comptime b: {
        var txt: []const u8 = "";
        for (std.meta.fieldNames(Direction), 0..) |name, idx| {
            if (idx > 0) txt = txt ++ ", ";
            txt = txt ++ "'" ++ name ++ "'";
        }
        break :b txt;
    };

    try db.exec(std.fmt.comptimePrint(
        \\CREATE TABLE IF NOT EXISTS {s}(
        \\    id INTEGER PRIMARY KEY,
        \\
        \\    number INTEGER NOT NULL,
        \\    file   VARCHAR({d}) NOT NULL,
        \\
        \\    from_direction VARCHAR({d}) CHECK(from_direction IN ({s})),
        \\    to_direction   VARCHAR({d}) CHECK(to_direction   IN ({s}))
        \\);
    , .{ Train.sql_table_name, Timestamp.time_fmt.len, max_dir_name, all_dirs, max_dir_name, all_dirs }), .{});
    try db.exec(std.fmt.comptimePrint(
        \\CREATE TABLE IF NOT EXISTS {s}(
        \\    train_id INTEGER NOT NULL,
        \\
        \\    number   INTEGER NOT NULL DEFAULT 0,
        \\    category TEXT NOT NULL,
        \\
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    towed    BOOLEAN NOT NULL DEFAULT 0,
        \\
        \\    FOREIGN KEY(train_id) REFERENCES {s}(id) ON DELETE CASCADE
        \\);
    , .{ Locomotive.sql_table_name, Train.sql_table_name }), .{});

    inline for (&.{ FilisurCapture, LandwasserCapture, LandquartCapture, BrusioCapture }) |Capture| {
        try db.exec(std.fmt.comptimePrint(
            \\CREATE TABLE IF NOT EXISTS {s}(
            \\    file VARCHAR({d}) PRIMARY KEY
            \\);
        , .{ Capture.sql_table_name, Timestamp.time_fmt.len }), .{});
    }
    try db.exec(std.fmt.comptimePrint(
        \\CREATE TABLE IF NOT EXISTS {s}(
        \\    file     VARCHAR({d}) PRIMARY KEY,
        \\    location TEXT
        \\);
    , .{ LivestreamCapture.sql_table_name, Timestamp.time_fmt.len }), .{});

    const max_method_name = comptime b: {
        var max = 0;
        for (std.meta.fieldNames(std.http.Method)) |name| {
            max = @max(max, name.len);
        }
        break :b max;
    };
    try db.exec(std.fmt.comptimePrint(
        \\CREATE TABLE IF NOT EXISTS {s}(
        \\    id INTEGER PRIMARY KEY,
        \\
        \\    path   TEXT NOT NULL,
        \\    method VARCHAR({d}) NOT NULL,
        \\    status INTEGER NOT NULL,
        \\
        \\    time DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\
        \\    address TEXT,
        \\    user_agent TEXT
        \\);
    , .{ Analytics.sql_table_name, max_method_name }), .{});

    try db.exec(std.fmt.comptimePrint(
        \\CREATE TABLE IF NOT EXISTS {s}(
        \\    endpoint TEXT PRIMARY KEY,
        \\    p256dh   TEXT NOT NULL,
        \\    auth     TEXT NOT NULL
        \\);
    , .{NotificationSubscription.sql_table_name}), .{});
    try db.exec(std.fmt.comptimePrint(
        \\CREATE TABLE IF NOT EXISTS {s}(
        \\    endpoint TEXT REFERENCES {s}(endpoint) ON DELETE CASCADE,
        \\    webcam   TEXT NOT NULL,
        \\
        \\    PRIMARY KEY (endpoint, webcam)
        \\);
    , .{ NotificationWebcam.sql_table_name, NotificationSubscription.sql_table_name }), .{});
}
