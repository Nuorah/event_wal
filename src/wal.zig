const std = @import("std");

pub fn Wal(comptime T: type) type {
    return struct {
        const Self = @This();

        file: std.fs.File,

        pub fn init(path: []const u8) !Self {
            const file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| {
                if (err == error.FileNotFound) {
                    const new_file = try std.fs.cwd().createFile(path, .{});
                    new_file.close();
                    return .{ .file = try std.fs.cwd().openFile(path, .{ .mode = .read_write }) };
                }
                return err;
            };
            return .{ .file = file };
        }

        pub fn deinit(self: *Self) void {
            self.file.close();
        }

        pub fn append(self: *Self, arena: std.mem.Allocator, item: T) !void {
            var writer_buffer: [4096]u8 = undefined;
            var writer = self.file.writer(&writer_buffer);
            try writer.seekTo(try self.file.getEndPos());

            var alloc_writer: std.io.Writer.Allocating = .init(arena);
            defer alloc_writer.deinit();

            var json_writer: std.json.Stringify = .{
                .writer = &alloc_writer.writer,
                .options = .{ .whitespace = .minified },
            };

            try json_writer.write(item);
            try writer.interface.writeAll(alloc_writer.written());
            try writer.interface.writeByte('\n');
            try writer.interface.flush();
            try self.file.sync();
        }

        pub fn reader(self: *Self, buffer: []u8) std.fs.File.Reader {
            return self.file.reader(buffer);
        }
    };
}
