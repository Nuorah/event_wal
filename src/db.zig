const Wal = @import("wal.zig").Wal;
const std = @import("std");

pub fn Database(comptime EventData: type, comptime StoragesType: type, comptime wal_version: u8) type {
    return struct {
        wal: Wal(EventData, wal_version),

        pub fn init(arena: std.mem.Allocator, wal_path: []const u8) !@This() {
            return .{
                .wal = try Wal(EventData, wal_version).init(wal_path, arena),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.wal.deinit();
        }

        pub fn loadAllEvents(self: *@This(), allocator: std.mem.Allocator, arena: std.mem.Allocator, storages: StoragesType) !void {
            const events = try self.wal.readAllBinary(arena);
            for (events.items) |evt| {
                switch (evt.data) {
                    inline else => |payload| try payload.apply(allocator, storages),
                }
            }
        }

        pub fn appendEvent(self: *@This(), allocator: std.mem.Allocator, arena: std.mem.Allocator, data: EventData, storages: StoragesType) !void {
            // TODO Add validation
            try self.wal.appendBinary(arena, data);
            switch (data) {
                inline else => |payload| try payload.apply(allocator, storages),
            }
        }
    };
}
