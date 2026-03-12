const std = @import("std");

pub fn walSerialize(comptime T: type, self: T, arena: std.mem.Allocator) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    inline for (std.meta.fields(T)) |field| {
        try serializeValue(field.type, @field(self, field.name), w);
    }

    return aw.written();
}

fn serializeValue(comptime T: type, value: T, w: *std.Io.Writer) !void {
    switch (@typeInfo(T)) {
        .bool => try w.writeByte(@intFromBool(value)),
        .int => try w.writeInt(T, value, .little),
        .@"enum" => |e| {
            const IntType = std.meta.Int(.unsigned, @sizeOf(e.tag_type) * 8);
            try w.writeInt(IntType, @intFromEnum(value), .little);
        },
        .optional => |opt| {
            if (value) |val| {
                try w.writeByte(1);
                try serializeValue(opt.child, val, w);
            } else {
                try w.writeByte(0);
            }
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                try w.writeInt(u16, @intCast(value.len), .little);
                try w.writeAll(value);
            } else {
                @compileError("unsupported field type: " ++ @typeName(T));
            }
        },
        else => @compileError("unsupported field type: " ++ @typeName(T)),
    }
}

pub fn walDeserialize(comptime T: type, arena: std.mem.Allocator, payload: []const u8) !T {
    var stream = std.io.fixedBufferStream(payload);
    const r = stream.reader();
    return deserializeStruct(T, arena, r);
}

fn deserializeStruct(comptime T: type, arena: std.mem.Allocator, r: anytype) !T {
    var result: T = undefined;
    inline for (std.meta.fields(T)) |field| {
        @field(result, field.name) = try deserializeValue(field.type, arena, r);
    }
    return result;
}

fn deserializeValue(comptime T: type, arena: std.mem.Allocator, r: anytype) !T {
    switch (@typeInfo(T)) {
        .bool => return (try r.readByte()) != 0,
        .int => return r.readInt(T, .little),
        .@"enum" => |e| {
            const IntType = std.meta.Int(.unsigned, @sizeOf(e.tag_type) * 8);
            const raw = try r.readInt(IntType, .little);
            return std.meta.intToEnum(T, raw) catch error.InvalidEnumValue;
        },
        .optional => |opt| {
            const present = try r.readByte();
            if (present == 0) return null;
            return try deserializeValue(opt.child, arena, r);
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                const len = try r.readInt(u16, .little);
                const s = try arena.alloc(u8, len);
                try r.readNoEof(s);
                return s;
            } else {
                @compileError("unsupported field type: " ++ @typeName(T));
            }
        },
        else => @compileError("unsupported field type: " ++ @typeName(T)),
    }
}
