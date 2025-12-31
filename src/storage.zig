const std = @import("std");

pub fn Storage(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        entities: std.AutoHashMap(K, V),
        mutex: std.Thread.Mutex = .{},

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .entities = std.AutoHashMap(K, V).init(allocator) };
        }

        pub fn deinit(self: *Self) void {
            self.entities.deinit();
        }
    };
}
