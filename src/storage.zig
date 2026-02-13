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

        pub fn get(self: *Self, key: K) ?V {
            return self.entities.get(key);
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            try self.entities.put(key, value);
        }

        pub fn update(
            self: *Self,
            key: K,
            comptime field: std.meta.FieldEnum(V),
            value: std.meta.fields(V)[@intFromEnum(field)].type,
        ) !void {
            const ptr = self.entities.getPtr(key) orelse return error.NotFound;
            @field(ptr, @tagName(field)) = value;
        }

        pub fn findBy(
            self: *Self,
            comptime field: std.meta.FieldEnum(V),
            value: std.meta.fields(V)[@intFromEnum(field)].type,
            allocator: std.mem.Allocator,
        ) !std.ArrayList(V) {
            var results: std.ArrayList(V) = .empty;
            var it = self.entities.valueIterator();
            while (it.next()) |entity| {
                if (@field(entity, @tagName(field)) == value) {
                    try results.append(allocator, entity.*);
                }
            }
            return results;
        }
    };
}
