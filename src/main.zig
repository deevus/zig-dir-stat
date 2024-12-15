const std = @import("std");
const cli = @import("cli");
const fmt = @import("fmt.zig");
const fs = @import("fs.zig");

const ThreadPool = std.Thread.Pool;
const WaitGroup = std.Thread.WaitGroup;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ThreadSafeAllocator = std.heap.ThreadSafeAllocator;

var config = struct {
    path: []const u8 = ".",
}{};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    var r = try cli.AppRunner.init(arena.allocator());

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
    var arena = ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var thread_safe_allocator = ThreadSafeAllocator{
        .child_allocator = arena.allocator(),
    };

    const allocator = thread_safe_allocator.allocator();

    var thread_pool: ThreadPool = undefined;
    try thread_pool.init(.{ .allocator = allocator, .n_jobs = 8 });
    defer thread_pool.deinit();

    var wait_group: WaitGroup = undefined;
    wait_group.reset();

    var total_size = std.atomic.Value(usize).init(0);

    var root_context = DirTaskContext{
        .dir_path = config.path,
        .total_size = &total_size,
        .allocator = allocator,
        .wait_group = &wait_group,
        .thread_pool = &thread_pool,
    };

    wait_group.start();
    try thread_pool.spawn(processDirectoryTask, .{root_context});
    wait_group.wait();

    var std_out = std.io.getStdOut();
    var std_out_writer = std_out.writer().any();

    const total_size_bytes = root_context.total_size.load(.acquire);
    const total_size_human = try fmt.formatBytes(allocator, total_size_bytes);

    try std_out_writer.print("Total size: {s} ({d} bytes)\n", .{ total_size_human, total_size_bytes });
}

const DirTaskContext = struct {
    dir_path: []const u8,
    total_size: *std.atomic.Value(usize),
    allocator: Allocator,
    wait_group: *WaitGroup,
    thread_pool: *ThreadPool,

    pub fn forSubPath(self: @This(), sub_path: []const u8) !DirTaskContext {
        const dir_path = try std.fs.path.join(self.allocator, &[_][]const u8{
            self.dir_path,
            sub_path,
        });

        return DirTaskContext{
            .dir_path = dir_path,
            .total_size = self.total_size,
            .allocator = self.allocator,
            .wait_group = self.wait_group,
            .thread_pool = self.thread_pool,
        };
    }
};

fn readDirAllAlloc(allocator: Allocator, path: []const u8) !std.ArrayList(std.fs.Dir.Entry) {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    var entries = std.ArrayList(std.fs.Dir.Entry).init(allocator);

    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
        }

        entries.deinit();
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        try entries.append(.{
            .kind = entry.kind,
            .name = try allocator.dupe(u8, entry.name),
        });
    }

    return entries;
}

fn processDirectoryTask(context: DirTaskContext) void {
    defer context.wait_group.finish();

    const allocator = context.allocator;
    var total_size = context.total_size;
    const dir_path = context.dir_path;

    var entries = readDirAllAlloc(allocator, dir_path) catch return;
    defer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
        }

        entries.deinit();
    }

    var dir_size: usize = 0;
    for (entries.items) |entry| {
        if (entry.kind == .directory) {
            const sub_context = context.forSubPath(entry.name) catch continue;
            context.wait_group.start();
            context.thread_pool.spawn(processDirectoryTask, .{sub_context}) catch continue;
        } else {
            const file_size = fs.getFileSize(allocator, &[_][]const u8{
                dir_path,
                entry.name,
            }) catch continue;

            dir_size += file_size;
        }
    }

    // Update the total size atomically
    _ = total_size.fetchAdd(dir_size, .monotonic);
}
