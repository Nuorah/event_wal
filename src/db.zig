const Wal = @import("wal.zig").Wal;
const std = @import("std");

pub fn Database(comptime EventData: type, comptime StoragesType: type, comptime wal_version: u8) type {
    return struct {
        wal: Wal(EventData, wal_version),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, path: []const u8) !@This() {
            return .{
                .allocator = allocator,
                .wal = try Wal(EventData, wal_version).init(path, allocator),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.wal.deinit();
        }

        pub fn loadAllEvents(self: *@This(), storages: *StoragesType) !void {
            const events = try self.wal.readAllBinary(self.allocator);
            for (events.items) |evt| {
                switch (evt.data) {
                    inline else => |payload| try payload.apply(self.allocator, storages),
                }
            }
        }

        pub fn appendEvent(self: *@This(), data: EventData, storages: *StoragesType) !void {
            try self.wal.appendBinary(self.allocator, data);
            switch (data) {
                inline else => |payload| try payload.apply(self.allocator, storages),
            }
        }
    };
}
