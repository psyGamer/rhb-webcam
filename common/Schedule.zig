//! Parses and processes expected train schedules
const std = @import("std");

const Timestamp = @import("Timestamp.zig");

const Ast = std.zig.Ast;
const ZonGen = std.zig.ZonGen;
const Zoir = std.zig.Zoir;

const Schedule = @This();

/// Parsed 24h clock time
const Clock = struct {
    hour: u5, // 0-23
    minute: u6, // 0-59

    pub fn parse(zoir: Zoir, node_idx: Zoir.Node.Index) !Clock {
        const node = node_idx.get(zoir);
        const node_string = if (node == .string_literal) node.string_literal else return error.ParseZon;
        const sep_idx = std.mem.indexOfScalar(u8, node_string, ':') orelse return error.ParseZon;

        return .{
            .hour = try std.fmt.parseInt(u5, node_string[0..sep_idx], 10),
            .minute = try std.fmt.parseInt(u6, node_string[(sep_idx + 1)..], 10),
        };
    }
};

const Entry = struct {
    start_date: Timestamp,
    end_date: Timestamp,
    file_path: []const u8,

    pub fn parse(gpa: std.mem.Allocator, zoir: Zoir, node_idx: Zoir.Node.Index) !Entry {
        const node = node_idx.get(zoir);
        const node_struct = if (node == .struct_literal) node.struct_literal else return error.ParseZon;

        var result: Entry = undefined;
        var fields: std.StaticBitSet(std.meta.fields(Entry).len) = .initEmpty();
        for (node_struct.names, 0..node_struct.vals.len) |name_node, idx| {
            const value_node = node_struct.vals.at(@intCast(idx));
            const name = name_node.get(zoir);

            const field = std.meta.stringToEnum(std.meta.FieldEnum(Entry), name) orelse return error.UnknownField;
            fields.set(@intFromEnum(field));
            switch (field) {
                .start_date => result.start_date = try .parseZonISO8601(zoir, value_node),
                .end_date => result.end_date = try .parseZonISO8601(zoir, value_node),
                .file_path => result.file_path = try gpa.dupe(u8, switch (value_node.get(zoir)) {
                    .string_literal => |lit| lit,
                    else => return error.ParseZon,
                }),
            }
        }
        if (!fields.eql(.initFull())) return error.MissingField;
        return result;
    }
};

pub const Train = struct {
    const Information = struct {
        classifier: []const u8 = "",
        origin: []const u8 = "",
        destination: []const u8 = "",

        pub fn parse(gpa: std.mem.Allocator, zoir: Zoir, node_idx: Zoir.Node.Index) !Information {
            const node = node_idx.get(zoir);
            const node_struct = if (node == .struct_literal) node.struct_literal else return error.ParseZon;

            var result: Information = .{};
            errdefer {
                gpa.free(result.classifier);
                gpa.free(result.origin);
                gpa.free(result.destination);
            }

            var fields: std.StaticBitSet(std.meta.fields(Information).len) = .initEmpty();
            for (node_struct.names, 0..node_struct.vals.len) |name_node, idx| {
                const value_node = node_struct.vals.at(@intCast(idx));
                const name = name_node.get(zoir);

                const field = std.meta.stringToEnum(std.meta.FieldEnum(Information), name) orelse return error.UnknownField;
                fields.set(@intFromEnum(field));

                switch (field) {
                    inline else => |tag| {
                        @field(result, @tagName(tag)) = try gpa.dupe(u8, switch (value_node.get(zoir)) {
                            .string_literal => |lit| lit,
                            else => return error.ParseZon,
                        });
                    },
                }
            }
            if (!fields.eql(.initFull())) return error.MissingField;
            return result;
        }
    };

    number: u32,

    time: union(enum) {
        arrival_departure: struct { Clock, Clock },
        transit: Clock,
    },

    applicable_weekdays: std.StaticBitSet(7) = .initFull(),
    applicable_start_date: Timestamp = .{},
    applicable_end_date: Timestamp = .{},

    information: Information,

    pub fn parse(gpa: std.mem.Allocator, zoir: Zoir, node_idx: Zoir.Node.Index) !Train {
        const ParseFields = enum {
            number,

            arrival_time,
            departure_time,
            transit_time,

            applicable_weekdays,
            applicable_start_date,
            applicable_end_date,

            information,
        };

        const node = node_idx.get(zoir);
        const node_struct = if (node == .struct_literal) node.struct_literal else return error.ParseZon;

        var arrival_time: Clock = undefined;
        var departure_time: Clock = undefined;

        var result: Train = .{
            .number = undefined,
            .time = undefined,

            .information = .{},
        };
        errdefer result.deinit(gpa);

        var fields: std.EnumSet(ParseFields) = .initEmpty();
        for (node_struct.names, 0..node_struct.vals.len) |name_node, idx| {
            const value_node = node_struct.vals.at(@intCast(idx));
            const name = name_node.get(zoir);

            const field = std.meta.stringToEnum(ParseFields, name) orelse return error.UnknownField;
            fields.insert(field);
            switch (field) {
                .number => result.number = switch (value_node.get(zoir)) {
                    .int_literal => |lit| switch (lit) {
                        .small => |val| @intCast(val),
                        else => return error.ParseZon,
                    },
                    else => return error.ParseZon,
                },

                .arrival_time => if (fields.contains(.transit_time)) return error.ParseZon else {
                    arrival_time = try .parse(zoir, value_node);
                },
                .departure_time => if (fields.contains(.transit_time)) return error.ParseZon else {
                    departure_time = try .parse(zoir, value_node);
                },
                .transit_time => if (fields.contains(.arrival_time) or fields.contains(.departure_time)) return error.ParseZon else {
                    result.time = .{ .transit = try .parse(zoir, value_node) };
                },

                .applicable_weekdays => switch (value_node.get(zoir)) {
                    .string_literal => |lit| {
                        result.applicable_weekdays = .initEmpty();
                        for (lit) |day| {
                            if (day < '1' or day > '7') return error.ParseZon;
                            result.applicable_weekdays.set(day - '1');
                        }
                    },
                    else => return error.ParseZon,
                },
                .applicable_start_date => result.applicable_start_date = try .parseZonISO8601(zoir, value_node),
                .applicable_end_date => result.applicable_end_date = try .parseZonISO8601(zoir, value_node),

                .information => result.information = try .parse(gpa, zoir, value_node),
            }
        }

        if (!fields.contains(.number) or !fields.contains(.information)) {
            return error.MissingField;
        }

        if (fields.contains(.arrival_time) and fields.contains(.departure_time)) {
            result.time = .{ .arrival_departure = .{ arrival_time, departure_time } };
        } else if (!fields.contains(.transit_time)) {
            return error.MissingField;
        }

        return result;
    }

    pub fn deinit(train: Train, gpa: std.mem.Allocator) void {
        gpa.free(train.information.classifier);
        gpa.free(train.information.origin);
        gpa.free(train.information.destination);
    }
};

start_date: Timestamp,
end_date: Timestamp,

trains: []const Train,

/// Parses train schedules from a target directory, which contains an `index.zon`
pub fn load(schedule_dir: std.fs.Dir, gpa: std.mem.Allocator) ![]const Schedule {
    const index = parse_index: {
        const file = try schedule_dir.openFile("index.zon", .{});
        defer file.close();
        const src = try file.readToEndAllocOptions(gpa, std.math.maxInt(usize), null, .of(u8), 0);
        defer gpa.free(src);

        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(gpa);

        var ast: Ast = try .parse(gpa, src, .zon);
        defer ast.deinit(gpa);
        const zoir = try ZonGen.generate(gpa, ast, .{});
        defer zoir.deinit(gpa);

        const root = Zoir.Node.Index.root.get(zoir);
        const root_array = if (root == .array_literal) root.array_literal else return error.ParseZon;

        for (0..root_array.len) |idx| {
            const elem_node = root_array.at(@intCast(idx));
            try entries.append(gpa, try .parse(gpa, zoir, elem_node));
        }

        break :parse_index try entries.toOwnedSlice(gpa);
    };
    defer {
        for (index) |entry| {
            gpa.free(entry.file_path);
        }
        gpa.free(index);
    }

    const schedules = try gpa.alloc(Schedule, index.len);

    for (index, schedules, 0..) |entry, *schedule, entry_idx| {
        errdefer {
            for (schedules[0..entry_idx]) |alloced_schedule| {
                for (alloced_schedule.trains) |alloced_train| {
                    alloced_train.deinit(gpa);
                }
                gpa.free(schedule.trains);
            }
            gpa.free(schedules);
        }

        const file = try schedule_dir.openFile(entry.file_path, .{});
        defer file.close();
        const src = try file.readToEndAllocOptions(gpa, std.math.maxInt(usize), null, .of(u8), 0);
        defer gpa.free(src);

        var trains: std.ArrayList(Train) = .empty;
        defer trains.deinit(gpa);

        var ast: Ast = try .parse(gpa, src, .zon);
        defer ast.deinit(gpa);
        const zoir = try ZonGen.generate(gpa, ast, .{});
        defer zoir.deinit(gpa);

        const root = Zoir.Node.Index.root.get(zoir);
        const root_array = if (root == .array_literal) root.array_literal else return error.ParseZon;

        for (0..root_array.len) |train_idx| {
            errdefer {
                for (trains.items[0..train_idx]) |alloced_train| {
                    alloced_train.deinit(gpa);
                }
            }

            const elem_node = root_array.at(@intCast(train_idx));
            try trains.append(gpa, try .parse(gpa, zoir, elem_node));
        }
        errdefer {
            for (trains.items) |alloced_train| {
                alloced_train.deinit(gpa);
            }
        }

        schedule.* = .{
            .start_date = entry.start_date,
            .end_date = entry.end_date,
            .trains = try trains.toOwnedSlice(gpa),
        };
    }

    return schedules;
}
