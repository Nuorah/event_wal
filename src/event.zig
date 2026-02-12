pub fn Event(comptime T: type) type {
    if (@typeInfo(T) != .@"union") {
        @compileError("Event data must be a tagged union, got " ++ @typeName(T));
    }
    if (@typeInfo(T).@"union".tag_type == null) {
        @compileError("Event data union must be tagged, " ++ @typeName(T) ++ " has no tag");
    }

    return struct {
        timestamp: i64,
        data: T,
    };
}
