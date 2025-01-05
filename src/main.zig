const std = @import("std");
const cli = @import("cli");
const fmt = @import("fmt.zig");
const fs = @import("fs.zig");
const squarified = @import("squarified");
const rl = @import("raylib");

const PathData = [:0]const u8;
const Squarify = squarified.Squarify(PathData);
const Node = squarified.Node(PathData);
const Tree = squarified.Tree(PathData);
const Rect = squarified.Rect;
const ThreadPool = std.Thread.Pool;
const WaitGroup = std.Thread.WaitGroup;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ThreadSafeAllocator = std.heap.ThreadSafeAllocator;
const Mutex = std.Thread.Mutex;

var config = struct {
    path: []const u8 = ".",
}{};

var mutex = Mutex{};

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

    var progress = std.Progress.start(.{
        .root_name = "Processing files and folders",
    });
    defer progress.end();

    const root_path = try std.fs.path.resolve(arena.allocator(), &[_][]const u8{config.path});
    const root_path_z = try arena.allocator().dupeZ(u8, root_path);

    var root_node = Node{
        .data = root_path_z,
        .value = 0,
    };

    var file_tree = Tree.init(allocator, &root_node);

    const root_context = DirTaskContext{
        .root_path = root_path,
        .dir_path = root_path,
        .allocator = allocator,
        .wait_group = &wait_group,
        .thread_pool = &thread_pool,
        .progress = &progress,
        .tree = &file_tree,
        .current_node = &root_node,
    };

    wait_group.start();
    try thread_pool.spawn(processDirectoryTask, .{root_context});
    wait_group.wait();

    var std_out = std.io.getStdOut();
    var std_out_writer = std_out.writer().any();

    const total_size_bytes: usize = @intFromFloat(addUpSizes(&root_node));
    const total_size_human = try fmt.formatBytes(allocator, total_size_bytes);

    try std_out_writer.print("Total size: {s} ({d} bytes)\n", .{ total_size_human, total_size_bytes });

    var sq = Squarify.init(arena.allocator());

    const window = Rect{
        .width = 1920,
        .height = 1080,
        .x = 0,
        .y = 0,
    };

    const res = (try sq.squarify(window, &root_node)).?;

    rl.initWindow(window.width, window.height, "");
    defer rl.closeWindow();

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.white);

        for (res.items) |result| {
            const rect = rl.Rectangle{
                .width = result.rect.width,
                .height = result.rect.height,
                .x = result.rect.x,
                .y = result.rect.y,
            };

            rl.drawRectangleRec(rect, rl.Color.green);
            rl.drawRectangleLinesEx(rect, 2.0, rl.Color.black);
        }
    }
}

fn addUpSizes(node: *Node) f32 {
    var total_size: f32 = 0;

    if (node.children) |children| for (children) |child| {
        total_size += addUpSizes(child);
    };

    node.value += total_size;
    return node.value;
}

const DirTaskContext = struct {
    root_path: []const u8,
    dir_path: []const u8,
    allocator: Allocator,
    wait_group: *WaitGroup,
    thread_pool: *ThreadPool,
    progress: *std.Progress.Node,
    tree: *Tree,
    current_node: *Node,

    pub fn forSubPath(self: @This(), sub_path: []const u8) !DirTaskContext {
        const dir_path = try std.fs.path.joinZ(self.allocator, &[_][]const u8{
            self.dir_path,
            sub_path,
        });

        mutex.lock();
        errdefer mutex.unlock();

        const new_node = try self.tree.addNode(self.current_node, 0, dir_path);
        mutex.unlock();

        return DirTaskContext{
            .root_path = self.root_path,
            .dir_path = dir_path,
            .allocator = self.allocator,
            .wait_group = self.wait_group,
            .thread_pool = self.thread_pool,
            .progress = self.progress,
            .tree = self.tree,
            .current_node = new_node,
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
        switch (entry.kind) {
            .file, .directory => {
                try entries.append(.{
                    .kind = entry.kind,
                    .name = try allocator.dupe(u8, entry.name),
                });
            },
            else => continue,
        }
    }

    return entries;
}

fn processDirectoryTask(context: DirTaskContext) void {
    var progress_node = context.progress.start(context.dir_path[context.root_path.len..], 0);
    defer progress_node.end();

    defer context.wait_group.finish();

    const allocator = context.allocator;
    const dir_path = context.dir_path;

    var entries = readDirAllAlloc(allocator, dir_path) catch return;
    defer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
        }

        entries.deinit();
    }

    progress_node.setEstimatedTotalItems(entries.items.len);

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

        progress_node.completeOne();
    }

    context.current_node.value = @floatFromInt(dir_size);
}
