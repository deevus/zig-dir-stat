const std = @import("std");
const cli = @import("cli");
const jdz_allocator = @import("jdz_allocator");
const ThreadPool = @import("ThreadPool.zig");

var config = struct {
    path: []const u8 = ".",
}{};

var jdz: jdz_allocator.JdzAllocator(.{}) = undefined;
var allocator: std.mem.Allocator = undefined;

pub fn main() !void {
    jdz = jdz_allocator.JdzAllocator(.{}).init();
    allocator = jdz.allocator();

    var thread_pool = ThreadPool.init(.{
        .max_threads = 8,
    });
    defer thread_pool.deinit();

    var r = try cli.AppRunner.init(allocator);

    const app = cli.App{
        .command = cli.Command{
            .name = "dir-stat",
            .description = .{
                .one_line = "Prints statistics about a directory",
            },
            .options = &[_]cli.Option{
                cli.Option{
                    .short_alias = 'p',
                    .long_name = "path",
                    .help = "The path to the directory",
                    .value_ref = r.mkRef(&config.path),
                },
            },
            .target = cli.CommandTarget{
                .action = cli.CommandAction{
                    .exec = start,
                },
            },
        },
    };

    return r.run(&app);
}

fn start() !void {
    defer jdz.deinit();

    var dir = try std.fs.cwd().openDir(config.path, .{ .iterate = true });
    defer dir.close();

    var fs_iterator = try dir.walk(allocator);
    defer fs_iterator.deinit();

    var results = std.StringHashMap(usize).init(allocator);
    defer {
        var key_iterator = results.keyIterator();
        while (key_iterator.next()) |key| {
            allocator.free(key.*);
        }
        results.deinit();
    }

    while (try fs_iterator.next()) |entry| {
        switch (entry.kind) {
            .file => {
                var file = try entry.dir.openFile(entry.basename, .{ .mode = .read_only });
                defer file.close();

                var buffer: [4096]u8 = undefined;
                const path = try entry.dir.realpath(".", &buffer);

                const stat = try file.stat();
                const result = try results.getOrPut(path);

                if (result.found_existing) {
                    result.value_ptr.* += stat.size;
                } else {
                    result.key_ptr.* = try allocator.dupe(u8, path);
                    result.value_ptr.* = stat.size;
                }
            },
            else => continue,
        }
    }

    var results_iterator = results.iterator();

    while (results_iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const value: usize = entry.value_ptr.*;

        std.debug.print("{s}, size: {d} bytes\n", .{ key, value });
    }
}
