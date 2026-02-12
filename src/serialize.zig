const std = @import("std");

pub fn walSerialize(comptime T: type, self: T, arena: std.mem.Allocator) ![]const u8 {
    // first pass: compute total size
    var size: usize = 0;
    inline for (std.meta.fields(T)) |field| {
        switch (@typeInfo(field.type)) {
            .bool => size += 1,
            .int => size += @sizeOf(field.type),
            .@"enum" => |e| size += @sizeOf(e.tag_type),
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) {
                    size += @sizeOf(u16) + @field(self, field.name).len;
                } else {
                    @compileError("unsupported field type: " ++ @typeName(field.type));
                }
            },
            else => @compileError("unsupported field type: " ++ @typeName(field.type)),
        }
    }

    const buf = try arena.alloc(u8, size);
    var offset: usize = 0;

    // second pass: write fields
    inline for (std.meta.fields(T)) |field| {
        const value = @field(self, field.name);
        switch (@typeInfo(field.type)) {
            .bool => {
                buf[offset] = @intFromBool(value);
                offset += 1;
            },
            .int => {
                const bytes = @sizeOf(field.type);
                @as(*align(1) field.type, @ptrCast(buf[offset..][0..bytes])).* = std.mem.nativeToLittle(field.type, value);
                offset += bytes;
            },
            .@"enum" => |e| {
                const bytes = @sizeOf(e.tag_type);
                @as(*align(1) e.tag_type, @ptrCast(buf[offset..][0..bytes])).* = std.mem.nativeToLittle(e.tag_type, @intFromEnum(value));
                offset += bytes;
            },
            .pointer => {
                const len: u16 = @intCast(value.len);
                @as(*align(1) u16, @ptrCast(buf[offset..][0..2])).* = std.mem.nativeToLittle(u16, len);
                offset += 2;
                @memcpy(buf[offset..][0..value.len], value);
                offset += value.len;
            },
            else => unreachable,
        }
    }

    return buf;
}

pub fn walDeserialize(comptime T: type, arena: std.mem.Allocator, payload: []const u8) !T {
    var result: T = undefined;
    var offset: usize = 0;

    inline for (std.meta.fields(T)) |field| {
        switch (@typeInfo(field.type)) {
            .bool => {
                @field(result, field.name) = payload[offset] != 0;
                offset += 1;
            },
            .int => {
                const bytes = @sizeOf(field.type);
                @field(result, field.name) = std.mem.littleToNative(field.type, @as(*align(1) const field.type, @ptrCast(payload[offset..][0..bytes])).*);
                offset += bytes;
            },
            .@"enum" => |e| {
                const bytes = @sizeOf(e.tag_type);
                const raw = std.mem.littleToNative(e.tag_type, @as(*align(1) const e.tag_type, @ptrCast(payload[offset..][0..bytes])).*);
                @field(result, field.name) = std.meta.intToEnum(field.type, raw) catch return error.InvalidEnumValue;
                offset += bytes;
            },
            .pointer => {
                const len = std.mem.littleToNative(u16, @as(*align(1) const u16, @ptrCast(payload[offset..][0..2])).*);
                offset += 2;
                @field(result, field.name) = try arena.dupe(u8, payload[offset..][0..len]);
                offset += len;
            },
            else => unreachable,
        }
    }

    return result;
}
