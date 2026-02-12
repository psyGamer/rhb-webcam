const std = @import("std");
const builtin = @import("builtin");
const runtime_safety = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

const tk = @import("tokamak");
const fr = @import("fridge");
const dotenv = @import("dotenv");

const Schedule = @import("common").Schedule;
const TrainAllocation = @import("common").TrainAllocation;
const Location = @import("common").Location;

const db = @import("database.zig");

const static = @import("static.zig");
const assetDirectory = static.assetDirectory;
const staticFile = static.staticFile;

const cdnHandler = @import("cdn.zig").handler;

const requireAuth = @import("auth.zig").requireAuth;

const CacheStorage = @import("cache.zig").Storage;
const withCache = @import("cache.zig").withCache;

const latest_view = @import("public/latest.zig");
const capture_view = @import("public/capture.zig");
const archiveView = @import("public/archive.zig").archive;

pub const std_options: std.Options = .{
    .logFn = @import("logging.zig").logFn,
    .log_level = .debug,
    .fmt_max_depth = 10,
};

const user_dist_dir = "user-dist/";
const admin_dist_dir = "admin-dist/";

const routes: []const tk.Route = &.{
    // Default to Filisur webcam (probably most popular)
    .get("/", tk.redirect("/filisur")),

    // Views
    .provide(db.Pool.getSession, &.{
        .group("/" ++ @tagName(Location.filisur), &.{
            // Archive
            .group("/archive", archiveView(.filisur)),
            // CDN
            .get("/image/:path", cdnHandler(.filisur, .image)),
            .get("/video/:path", cdnHandler(.filisur, .video)),
            // View
            .get("/", latest_view.filisurLatest),
            .get("/:path", capture_view.filisurCapture),
        }),
    }),

    // Static
    .get("/style.css", if (builtin.mode == .Debug)
        staticFile("../user_frontend/style.css", .never)
    else
        staticFile(user_dist_dir ++ "style.css", .{ .timeout = 3600 })),

    // Admin
    requireAuth(.{ .realm = "Admin", .validate = validateAdminLogin }, &.{.group("/admin", &.{
        // DVUI views (all point to index.html, due to client-side routing)
        .get("/categorize", staticFile(admin_dist_dir ++ "index.html", .{ .timeout = 3600 })),
        // DVUI assets
        .get("/web.wasm", staticFile(admin_dist_dir ++ "web.wasm", .immutable)),
        .get("/web.js", staticFile(admin_dist_dir ++ "web.js", .immutable)),
        .get("/video.js", staticFile(admin_dist_dir ++ "video.js", .immutable)),
        .get("/meta.js", staticFile(admin_dist_dir ++ "meta.js", .immutable)),
        // API
        .provide(db.Pool.getSession, &.{
            .group("/api", @import("categorize.zig").routes),
        }),
    })}),
};

pub const Env = dotenv.Env(enum {
    /// Preview images for videos from the Filisur webcam
    WEBCAM_FILISUR_IMAGE,
    /// Images from the Landwasser webcam
    WEBCAM_LANDWASSER_IMAGE,
    /// Images from the Landquart webcam
    WEBCAM_LANDQUART_IMAGE,
    /// Image sequences from the Brusio webcam
    WEBCAM_BRUSIO_IMAGE,

    /// Videos from the filisur webcam
    WEBCAM_FILISUR_VIDEO,

    /// Deleted images / videos from the Filisur webcam
    DELETED_FILISUR_ARCHIVE,
    /// Deleted images from the Brusio webcam
    DELETED_BRUSIO_ARCHIVE,

    /// Directory for archiving original locomotive allocation PDFs
    LOCOMOTIVE_ALLOCATIONS_ARCHIVE,
    /// Directory for storing parsed JSON files for the locomotive allocations
    LOCOMOTIVE_ALLOCATIONS_STORAGE,

    /// File containing all valid credentials for logging into the categorizaion view
    ADMIN_CREDENTIALS_PATH,

    /// File storing the website database
    DATABASE_DEV_PATH,
    DATABASE_PROD_PATH,
});

/// Collection of parsed train schedules
pub const Schedules = []const Schedule;
/// Collection of parsed train allocations
pub const TrainAllocations = []const TrainAllocation;

/// Pool of parsed train allocations
pub const TrainAllocationPool = struct {
    const cache_size = 16;

    dates: [cache_size]tk.time.Date,
    allocations: [cache_size]TrainAllocations,

    curr_idx: std.math.IntFittingRange(0, cache_size - 1),

    pub const init: TrainAllocationPool = b: {
        var result: TrainAllocationPool = undefined;
        @memset(&result.dates, .{ .year = 1970, .month = 0, .day = 0 });
        @memset(&result.allocations, &.{});
        result.curr_idx = 0;
        break :b result;
    };

    pub fn get(pool: *TrainAllocationPool, gpa: std.mem.Allocator, env: *Env, date: tk.time.Date) !TrainAllocations {
        for (pool.dates, pool.allocations) |cache_date, cache_alloc| {
            if (date.cmp(cache_date) == .eq) return cache_alloc;
        }

        var dir = try std.fs.cwd().openDir(env.key(.LOCOMOTIVE_ALLOCATIONS_STORAGE), .{});
        defer dir.close();

        var buffer: ["YYYY_MM_DD.min.json".len]u8 = undefined;
        const file_path = std.fmt.bufPrint(&buffer, "{d}_{d:0>2}_{d:0>2}.min.json", .{ @as(u32, @intCast(date.year)), date.month, date.day }) catch unreachable;

        const file = dir.openFile(file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.err("Failed to find locomotive allocation table for {f}", .{date});
                return &.{};
            },
            else => |e| return e,
        };
        defer file.close();

        for (pool.allocations[pool.curr_idx]) |train| {
            train.deinit(gpa);
        }
        gpa.free(pool.allocations[pool.curr_idx]);

        defer pool.curr_idx = @intCast(@as(u5, pool.curr_idx + 1) % cache_size);

        std.log.info("Parseing locomotive allocations for {f}...", .{date});
        pool.dates[pool.curr_idx] = date;
        pool.allocations[pool.curr_idx] = try TrainAllocation.load(gpa, file);
        std.log.info("Parsed locomotive allocations for {f}", .{date});

        return pool.allocations[pool.curr_idx];
    }

    pub fn deinit(pool: TrainAllocationPool, gpa: std.mem.Allocator) void {
        for (pool.allocations) |allocations| {
            for (allocations) |train| {
                train.deinit(gpa);
            }
            gpa.free(allocations);
        }
    }
};

/// Military-grade secure credential storage pool
const CredentialStorage = std.StringArrayHashMapUnmanaged([]const u8);

pub fn main() !void {
    var debug_allocator: if (runtime_safety) std.heap.DebugAllocator(.{}) else void = if (runtime_safety) .init else {};
    defer if (runtime_safety) std.debug.assert(debug_allocator.deinit() == .ok);

    const allocator = if (runtime_safety) debug_allocator.allocator() else std.heap.smp_allocator;

    const should_free = runtime_safety; // The OS will clean up anyway

    // Load .env
    var env: Env = .init(allocator, false);
    defer env.deinit();

    try env.load(.{});

    // Load train schedules
    var schedules: Schedules = b: {
        var schedule_dir = try std.fs.cwd().openDir("schedule", .{});
        defer schedule_dir.close();

        break :b try Schedule.load(schedule_dir, allocator);
    };
    defer if (should_free) {
        for (schedules) |schedule| {
            for (schedule.trains) |train| {
                train.deinit(allocator);
            }
            allocator.free(schedule.trains);
        }
        allocator.free(schedules);
    };

    // Prepare train allocation pool
    var pool: TrainAllocationPool = .init;
    defer if (should_free) pool.deinit(allocator);

    // Load 'categorize' credentials
    var cred_storage, const cred_data = b: {
        const cred_file = try std.fs.cwd().openFile(env.key(.ADMIN_CREDENTIALS_PATH), .{});
        defer cred_file.close();

        const data = try cred_file.readToEndAlloc(allocator, std.math.maxInt(usize));
        errdefer allocator.free(data);

        var storage: CredentialStorage = .empty;

        var line_iter = std.mem.tokenizeAny(u8, data, "\r\n");
        while (line_iter.next()) |line| {
            const split_idx = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const username = line[0..split_idx];
            const password = line[(split_idx + 1)..];

            try storage.put(allocator, username, password);
        }

        break :b .{ storage, data };
    };
    defer if (should_free) {
        cred_storage.deinit(allocator);
        allocator.free(cred_data);
    };

    // Load database
    var db_pool: db.Pool = undefined;
    try db.load(&db_pool, allocator, &env);
    defer db_pool.deinit();

    // Setup storage for caching requests
    var req_strorage: CacheStorage = .empty;
    defer req_strorage.deinit(allocator);

    var injector: tk.Injector = .init(&.{ .ref(&env), .ref(&schedules), .ref(&pool), .ref(&cred_storage), .ref(&db_pool), .ref(&req_strorage) }, null);
    var server: tk.Server = try .init(allocator, &.{tk.logger(.{}, routes)}, .{
        .listen = .{ .hostname = "0.0.0.0", .port = 8000 },
        .injector = &injector,
    });
    defer server.deinit();

    std.log.info("Server running on http://localhost:8000", .{});
    try server.start();
}

fn validateAdminLogin(ctx: *tk.Context, username: []const u8, password: []const u8) bool {
    const cred = ctx.injector.get(CredentialStorage) catch return false;
    return std.mem.eql(u8, password, cred.get(username) orelse return false);
}
