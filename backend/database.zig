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

    id: u32,

    number: u32,
    file: []const u8,

    from: Direction,
    to: Direction,
};
pub const Locomotive = struct {
    pub const sql_table_name = "locomotives";

    id: u32,
    train_id: u32,

    number: u32,
    category: @import("common").Locomotive.Category,

    position: u32,
    towed: bool,
};

/// Load the appropriate database from disk
pub fn load(pool: *Pool, allocator: std.mem.Allocator, env: *Env) !void {
    const filepath = try allocator.dupeZ(u8, env.key(if (builtin.mode == .Debug) .DATABASE_DEV_PATH else .DATABASE_PROD_PATH));
    defer allocator.free(filepath);

    pool.* = try .init(allocator, .{}, .{ .filename = filepath });
    errdefer pool.deinit();

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
        \\    'id' INTEGER PRIMARY KEY,
        \\
        \\    'number' INTEGER NOT NULL,
        \\    'file'   VARCHAR({d}) NOT NULL,
        \\
        \\    'from' VARCHAR({d}) NOT NULL CHECK('from' IN ({s})),
        \\    'to'   VARCHAR({d}) NOT NULL CHECK('to'   IN ({s}))
        \\);
    , .{ Train.sql_table_name, Timestamp.fmt.len, max_dir_name, all_dirs, max_dir_name, all_dirs }), .{});
    try db.exec(std.fmt.comptimePrint(
        \\CREATE TABLE IF NOT EXISTS {s}(
        \\    'train_id' INTEGER NOT NULL,
        \\
        \\    'number'   INTEGER NOT NULL DEFAULT 0,
        \\    'category' TEXT NOT NULL,
        \\
        \\    'position' INTEGER NOT NULL DEFAULT 0,
        \\    'towed'    BOOLEAN NOT NULL DEFAULT 0,
        \\
        \\    FOREIGN KEY(train_id) REFERENCES {s}(id) ON DELETE CASCADE
        \\);
    , .{ Locomotive.sql_table_name, Train.sql_table_name }), .{});
}
