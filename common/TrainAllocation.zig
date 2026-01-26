const std = @import("std");
const Clock = @import("Schedule.zig").Clock;
const Locomotive = @import("Locomotive.zig");
const Direction = @import("direction.zig").Direction;

const TrainAllocation = @This();

number: u32,

departure_time: Clock,
arrival_time: Clock,

locomotives: []const Locomotive,

/// Load a parsed train allocation JSON file into memory
pub fn load(gpa: std.mem.Allocator, json_file: std.fs.File) ![]const TrainAllocation {
    const Data = struct {
        trains: []const struct {
            number: []const u8,

            departure_time: Clock,
            arrival_time: Clock,

            locomotives: []const struct {
                number: u32,
                role: ?[]const u8,
                position: u32,
            },
        },
    };

    var file_buffer: [4096]u8 = undefined;
    var file_reader = json_file.reader(&file_buffer);

    var json_reader: std.json.Reader = .init(gpa, &file_reader.interface);

    const data = try std.json.parseFromTokenSource(Data, gpa, &json_reader, .{ .ignore_unknown_fields = true });
    defer data.deinit();

    const trains = try gpa.alloc(TrainAllocation, data.value.trains.len);
    errdefer gpa.free(trains);

    for (data.value.trains, trains, 0..) |parsed_train, *train, train_idx| {
        errdefer for (trains[0..train_idx]) |alloced_train| {
            gpa.free(alloced_train.locomotives);
        };

        var locomotives = try gpa.alloc(Locomotive, parsed_train.locomotives.len);
        errdefer gpa.free(locomotives);

        for (parsed_train.locomotives) |parsed_loco| {
            if (parsed_loco.position >= locomotives.len) {
                std.log.err("Got locomotive {} at position {} for train '{s}', with only {} slots being availabel", .{ parsed_loco.number, parsed_loco.position, parsed_train.number, locomotives.len });
                gpa.free(locomotives);
                locomotives = &.{};
                break;
            }

            locomotives[parsed_loco.position] = .{
                .number = parsed_loco.number,
                .category = Locomotive.getCategory(parsed_loco.number) orelse b: {
                    std.log.err("Got unknown locomotive {} for train '{s}'", .{ parsed_loco.number, parsed_train.number });
                    break :b .none;
                },
                .towed = if (parsed_loco.role) |role| std.mem.eql(u8, role, "S") else false,
            };
        }

        train.* = .{
            .number = std.fmt.parseInt(u32, parsed_train.number, 10) catch std.math.maxInt(u32),

            .arrival_time = parsed_train.arrival_time,
            .departure_time = parsed_train.departure_time,

            .locomotives = locomotives,
        };
    }

    return trains;
}
pub fn deinit(self: TrainAllocation, gpa: std.mem.Allocator) void {
    gpa.free(self.locomotives);
}
