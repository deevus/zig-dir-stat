const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn formatBytes(allocator: Allocator, bytes: anytype) ![]const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB", "PB", "EB" };
    var value: f64 = @floatFromInt(bytes);
    var unit_index: usize = 0;

    while (value >= 1024 and unit_index < units.len - 1) {
        value /= 1024;
        unit_index += 1;
    }

    return try std.fmt.allocPrint(allocator, "{d:.1} {s}", .{
        value,
        units[unit_index],
    });
}

const testing = std.testing;

test "formatBytes produces correct output for given examples" {
    const cases = [_]struct {
        input: u64,
        expected: []const u8,
    }{
        .{ .input = 125_000, .expected = "122.1 KB" },
        .{ .input = 1_200_000, .expected = "1.1 MB" },
        .{ .input = 55_000_000_000, .expected = "51.2 GB" },
        .{ .input = 2_000_000_000_000, .expected = "1.8 TB" },
    };

    for (cases) |test_case| {
        const result = try formatBytes(testing.allocator, test_case.input);
        defer testing.allocator.free(result);

        try testing.expectEqualStrings(test_case.expected, result);
    }
}
