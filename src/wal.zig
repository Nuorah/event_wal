const std = @import("std");

const walSerialize = @import("serialize.zig").walSerialize;
const walDeserialize = @import("serialize.zig").walDeserialize;
const Event = @import("event.zig").Event;

pub fn Wal(comptime T: type, version: u8) type {
    return struct {
        const Self = @This();
        const MAGIC = [_]u8{ 'L', 'I', 'G', 'M', 'A' };
        const HEADER_SIZE = MAGIC.len + @sizeOf(u8);

        file: std.fs.File,
        write_offset: u64,

        pub fn init(path: []const u8, arena: std.mem.Allocator) !Self {
            const file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| {
                if (err == error.FileNotFound) {
                    const new_file = try std.fs.cwd().createFile(path, .{});
                    defer new_file.close();
                    var writer_buffer: [128]u8 = undefined;
                    var writer = new_file.writer(&writer_buffer);
                    var buf: [HEADER_SIZE]u8 = undefined;
                    @memcpy(buf[0..MAGIC.len], &MAGIC);
                    buf[MAGIC.len] = version;
                    try writer.interface.writeAll(&buf);
                    try writer.interface.flush();
                    try new_file.sync();
                    return .{
                        .file = try std.fs.cwd().openFile(path, .{ .mode = .read_write }),
                        .write_offset = try new_file.getEndPos(),
                    };
                }
                return err;
            };

            var header_buf: [HEADER_SIZE]u8 = undefined;
            var reader_buffer: [HEADER_SIZE]u8 = undefined;
            var reader = file.reader(&reader_buffer);
            const bytes_read = try reader.interface.readSliceShort(&header_buf);

            var writer_buffer: [128]u8 = undefined;
            var writer = file.writer(&writer_buffer);
            if (bytes_read == 0) {
                try writer.interface.writeAll(&MAGIC);
                try writer.interface.writeByte(version);
                try writer.interface.flush();
                try file.sync();
            } else if (bytes_read >= HEADER_SIZE and std.mem.eql(u8, header_buf[0..MAGIC.len], &MAGIC)) {
                if (header_buf[MAGIC.len] != version) {
                    // TODO: don't forget to write a migration path before bumping version
                    return error.VersionMismatch;
                }
            } else {
                // TODO: trigger migration from JSON to binary
                defer file.close();
                try migrateJsonToBinary(path, arena);
                return .{
                    .file = try std.fs.cwd().openFile(path, .{ .mode = .read_write }),
                    .write_offset = try file.getEndPos(),
                };
            }

            return .{ .file = file, .write_offset = try file.getEndPos() };
        }

        pub fn deinit(self: *Self) void {
            self.file.close();
        }

        fn migrateJsonToBinary(path: []const u8, arena: std.mem.Allocator) !void {
            // read old JSON file
            const old_file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
            defer old_file.close();

            var reader_buffer: [4096]u8 = undefined;
            var reader = old_file.reader(&reader_buffer);

            var events: std.ArrayList(Event(T)) = .empty;

            while (try reader.interface.takeDelimiter('\n')) |line| {
                if (line.len == 0) continue;
                const owned_line = try arena.dupe(u8, line);
                const parsed = try std.json.parseFromSliceLeaky(
                    Event(T),
                    arena,
                    owned_line,
                    .{ .ignore_unknown_fields = true },
                );
                // seconds → microseconds
                try events.append(arena, .{
                    .timestamp = parsed.timestamp * 1_000_000,
                    .data = parsed.data,
                });
            }

            // write to tmp file
            const tmp_path = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
            const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
            defer tmp_file.close();
            var writer_buffer: [128]u8 = undefined;
            var writer = tmp_file.writer(&writer_buffer);

            try writer.interface.writeAll(&MAGIC);
            try writer.interface.writeByte(version);
            try writer.interface.flush();
            try tmp_file.sync();

            // write each event as binary
            var tmp_wal: Self = .{ .file = tmp_file, .write_offset = try tmp_file.getEndPos() };
            for (events.items) |event| {
                try tmp_wal.appendBinaryWithTimestamp(arena, event.data, event.timestamp);
            }

            // atomic rename
            try std.fs.cwd().rename(tmp_path, path);
        }

        fn appendBinaryWithTimestamp(self: *Self, arena: std.mem.Allocator, data: T, timestamp: i64) !void {
            const payload = switch (data) {
                inline else => |p| try walSerialize(@TypeOf(p), p, arena),
            };

            const timestamp_size = @sizeOf(i64);
            const tag_size = @sizeOf(u16);
            const record_header_size = timestamp_size + tag_size;
            const content_len = record_header_size + payload.len;
            if (content_len > std.math.maxInt(u16)) return error.PayloadTooLarge;

            const content = try arena.alloc(u8, content_len);
            std.mem.writeInt(i64, content[0..8], timestamp, .little);
            std.mem.writeInt(u16, content[8..10], @intFromEnum(data), .little);
            @memcpy(content[10..], payload);

            const crc = std.hash.crc.Crc32.hash(content);

            // build one contiguous record: len(2) + content(N) + crc(4)
            const record_len = 2 + content_len + 4;
            const record = try arena.alloc(u8, record_len);
            std.mem.writeInt(u16, record[0..2], @intCast(content_len), .little);
            @memcpy(record[2..][0..content_len], content);
            std.mem.writeInt(u32, record[2 + content_len ..][0..4], crc, .little);

            var writer_buffer: [128]u8 = undefined;
            var writer = self.file.writer(&writer_buffer);
            try writer.seekTo(self.write_offset);
            try writer.interface.writeAll(record);
            try writer.interface.flush();
            try self.file.sync();

            self.write_offset += record_len;
        }

        pub fn appendBinaryWithTimestampAsync(
            self: *Self,
            arena: std.mem.Allocator,
            io: anytype,
            data: T,
            timestamp: i64,
        ) !void {
            const payload = switch (data) {
                inline else => |p| try walSerialize(@TypeOf(p), p, arena),
            };

            const timestamp_size = @sizeOf(i64);
            const tag_size = @sizeOf(u16);
            const record_header_size = timestamp_size + tag_size;
            const content_len = record_header_size + payload.len;
            if (content_len > std.math.maxInt(u16)) return error.PayloadTooLarge;

            const record_len = 2 + content_len + 4;
            const record = try arena.alloc(u8, record_len);

            // len
            std.mem.writeInt(u16, record[0..2], @intCast(content_len), .little);

            // content: timestamp + tag + payload
            std.mem.writeInt(i64, record[2..10], timestamp, .little);
            std.mem.writeInt(u16, record[10..12], @intFromEnum(data), .little);
            @memcpy(record[12..][0..payload.len], payload);

            // crc over content only
            const crc = std.hash.crc.Crc32.hash(record[2..][0..content_len]);
            std.mem.writeInt(u32, record[2 + content_len ..][0..4], crc, .little);

            // claim our slot BEFORE yielding
            const offset = self.write_offset;
            self.write_offset += record_len;

            // async write + fsync through io_uring, this yields
            _ = try io.do_write_synced(self.file.handle, record, offset);
        }

        pub fn appendBinary(self: *Self, arena: std.mem.Allocator, data: T) !void {
            try self.appendBinaryWithTimestamp(arena, data, std.time.microTimestamp());
        }

        pub fn appendBinaryAsync(self: *Self, allocator: std.mem.Allocator, io: anytype, data: T) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            try self.appendBinaryWithTimestampAsync(arena.allocator(), io, data, std.time.microTimestamp());
        }

        pub fn readAll(self: *Self, arena: std.mem.Allocator) !std.ArrayList(T) {
            var list: std.ArrayList(T) = .empty;
            var reader_buffer: [4096]u8 = undefined;
            var reader = self.file.reader(&reader_buffer);

            while (try reader.interface.takeDelimiter('\n')) |line| {
                if (line.len == 0) continue;
                const owned_line = try arena.dupe(u8, line);
                const parsed = try std.json.parseFromSliceLeaky(T, arena, owned_line, .{ .ignore_unknown_fields = true });
                try list.append(arena, parsed);
            }
            return list;
        }

        pub fn readAllBinary(self: *Self, arena: std.mem.Allocator) !std.ArrayList(Event(T)) {
            var list: std.ArrayList(Event(T)) = .empty;
            var reader_buffer: [4096]u8 = undefined;
            var reader = self.file.reader(&reader_buffer);

            _ = try reader.interface.take(HEADER_SIZE);

            while (true) {
                // read len
                const len_bytes = reader.interface.take(2) catch |err| {
                    if (err == error.EndOfStream) break;
                    return err;
                };
                const content_len = std.mem.readInt(u16, len_bytes[0..2], .little);

                // read content
                const content = try reader.interface.readAlloc(arena, content_len);

                // read and verify crc
                const crc_bytes = try reader.interface.take(4);
                const stored_crc = std.mem.readInt(u32, crc_bytes[0..4], .little);
                const computed_crc = std.hash.crc.Crc32.hash(content);
                if (stored_crc != computed_crc) return error.CrcMismatch;

                // parse timestamp
                const timestamp = std.mem.readInt(i64, content[0..8], .little);

                // parse tag and deserialize payload
                const tag_int = std.mem.readInt(u16, content[8..10], .little);
                const tag = std.meta.intToEnum(@typeInfo(T).@"union".tag_type.?, tag_int) catch return error.UnknownTag;
                const payload = content[10..];

                const data = switch (tag) {
                    inline else => |t| @unionInit(T, @tagName(t), try walDeserialize(@FieldType(T, @tagName(t)), arena, payload)),
                };

                try list.append(arena, .{ .timestamp = timestamp, .data = data });
            }

            return list;
        }
    };
}
