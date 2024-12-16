const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const unicode = std.unicode;

const Allocator = std.mem.Allocator;

pub fn getFileSize(allocator: Allocator, path: anytype) !usize {
    switch (builtin.os.tag) {
        .windows => {
            const file_path = try std.fs.path.joinZ(allocator, path);
            defer allocator.free(file_path);

            const file_path_utf16 = try unicode.utf8ToUtf16LeAllocZ(allocator, file_path);
            defer allocator.free(file_path_utf16);

            var find_data: windows.WIN32_FIND_DATAW = undefined;
            const handle = windows.kernel32.FindFirstFileW(file_path_utf16.ptr, &find_data);
            defer _ = windows.kernel32.FindClose(handle);

            if (handle == windows.INVALID_HANDLE_VALUE) {
                return error.InvalidHandle;
            }

            return @as(usize, find_data.nFileSizeHigh) << 32 | @as(usize, find_data.nFileSizeLow);
        },
        .macos => {
            const xattr = @cImport({
                @cInclude("sys/xattr.h");
            });

            const file_path = try std.fs.path.joinZ(allocator, path);
            defer allocator.free(file_path);

            var buf: [256]u8 = undefined;
            const len = xattr.getxattr(file_path.ptr, "com.apple.cloudkit.share", &buf, buf.len, 0, 0);

            if (len != -1) {
                return error.InvalidHandle;
            }

            var stat: std.c.Stat = undefined;
            _ = std.c.stat(file_path.ptr, &stat);

            if (stat.size < 0) {
                return error.InvalidHandle;
            }

            return @intCast(stat.size);
        },
        .linux => {
            const file_path = try std.fs.path.joinZ(allocator, path);
            defer allocator.free(file_path);

            var stat: std.c.Stat = undefined;
            _ = std.c.stat(file_path.ptr, &stat);

            if (stat.size < 0) {
                return error.InvalidHandle;
            }

            return @intCast(stat.size);
        },
        else => {
            const file_path = try std.fs.path.join(allocator, path);
            defer allocator.free(file_path);

            const file = try std.fs.cwd().openFile(file_path, .{ .mode = .read_only });
            defer file.close();

            const stat = try file.stat();

            return stat.size;
        },
    }
}
