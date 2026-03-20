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
            var replay_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer replay_arena.deinit(); // nukes all deserialized event data

            const events = try self.wal.readAllBinary(replay_arena.allocator());

            std.debug.print("Loading {d} events.\n", .{events.items.len});
            for (events.items) |evt| {
                switch (evt.data) {
                    // apply still uses self.allocator for the dupe into the hashmap
                    inline else => |payload| try payload.apply(self.allocator, storages),
                }
            }
            // replay_arena dies here
            // all the deserialized event payloads get freed in one shot
            // the duped strings in the hashmap survive because they're on self.allocator
        }

        pub fn appendEvent(self: *@This(), data: EventData, storages: *StoragesType) !void {
            try self.wal.appendBinary(self.allocator, data);
            switch (data) {
                inline else => |payload| try payload.apply(self.allocator, storages),
            }
        }

        pub fn appendEventAsync(self: *@This(), io: anytype, data: EventData, storages: *StoragesType) !void {
            try self.wal.appendBinaryAsync(self.allocator, io, data);
            switch (data) {
                inline else => |payload| try payload.apply(self.allocator, storages),
            }
        }
    };
}
