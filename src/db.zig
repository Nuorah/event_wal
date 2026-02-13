const Wal = @import("wal.zig");
const std = @import("std");

pub fn Database(comptime EventData: type, comptime StoragesType: type, comptime wal_version: u8) type {
    return struct {
        wal: Wal(EventData, wal_version),

        pub fn loadAllEvents(self: *@This(), allocator: std.mem.Allocator, storages: *StoragesType) !void {
            const events = try self.wal.readAllBinary(allocator);
            for (events.items) |evt| {
                switch (evt.data) {
                    inline else => |payload| try payload.apply(allocator, storages),
                }
            }
        }

        pub fn appendEvent(self: *@This(), allocator: std.mem.Allocator, data: EventData, storages: *StoragesType) !void {
            // TODO Add validation
            try self.wal.appendBinary(allocator, data);
            switch (data) {
                inline else => |payload| try payload.apply(allocator, storages),
            }
        }
    };
}
