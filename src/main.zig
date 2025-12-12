const std = @import("std");

pub const std_options: std.Options = .{
    .log_level = .debug,
};

const Message = struct {
    op: Operation,
    db: []const u8,
    event: ?std.json.Value = null,
    since: ?i64 = null,
};

const Operation = enum {
    append,
    replay_all,
};

pub fn main() !void {
    std.log.info("Starting DB server", .{});

    const allocator = std.heap.c_allocator;

    // Check if systemd passed us a socket
    const listen_fds = std.posix.getenv("LISTEN_FDS");
    const listen_pid = std.posix.getenv("LISTEN_PID");

    var server: std.net.Server = undefined;

    if (listen_fds != null and listen_pid != null) {
        const SOCKET_PATH = "/run/db_server/db.sock";
        // Socket activation: systemd gave us the socket
        const our_pid = std.os.linux.getpid();
        const pid = try std.fmt.parseInt(i32, listen_pid.?, 10);

        if (pid != our_pid) {
            std.log.err("LISTEN_PID mismatch", .{});
            return error.InvalidListenPid;
        }

        const num_fds = try std.fmt.parseInt(u32, listen_fds.?, 10);
        if (num_fds != 1) {
            std.log.err("Expected 1 fd, got {}", .{num_fds});
            return error.InvalidListenFds;
        }

        // fd 3 is the socket systemd created
        const socket_fd: std.posix.socket_t = 3;
        std.log.info("Using systemd socket activation (fd=3)", .{});

        server = std.net.Server{
            .stream = .{ .handle = socket_fd },
            .listen_address = try std.net.Address.initUnix(SOCKET_PATH),
        };
    } else {
        const SOCKET_PATH = "./db.sock";
        // Manual mode: create socket ourselves (dev)
        std.log.info("No socket activation, creating socket manually", .{});

        std.fs.cwd().deleteFile(SOCKET_PATH) catch |err| {
            if (err != error.FileNotFound) {
                std.log.warn("Failed to delete old socket: {}", .{err});
            }
        };

        const address = try std.net.Address.initUnix(SOCKET_PATH);
        server = try address.listen(.{});
    }

    defer if (listen_fds == null) server.deinit();

    std.log.info("Ready to accept connections", .{});

    while (true) {
        var connection = try server.accept();

        var writer_buf: [8192]u8 = undefined;
        var writer_instance = connection.stream.writer(&writer_buf);
        const stream_writer = &writer_instance.interface;

        var reader_buf: [8192]u8 = undefined;
        var reader_instance = connection.stream.reader(&reader_buf);
        const stream_reader = reader_instance.interface();
        std.log.info("Client connected", .{});

        handleConnection(
            allocator,
            stream_writer,
            stream_reader,
        ) catch |err| {
            std.log.err("Error: {}", .{err});
        };

        connection.stream.close();
        std.log.info("Client disconnected", .{});
    }
}

fn handleConnection(allocator: std.mem.Allocator, stream_writer: *std.Io.Writer, stream_reader: *std.Io.Reader) !void {
    std.log.debug("Starting connection handler", .{});

    while (stream_reader.takeDelimiterInclusive('\n')) |line| {
        std.log.debug("Got line, length: {}", .{line.len});
        if (line.len == 0) continue;

        std.log.debug("Raw line: {s}", .{line});

        const parsed = std.json.parseFromSlice(
            Message,
            allocator,
            line,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            std.log.err("Failed to parse JSON: {}", .{err});
            sendError(stream_writer, "Invalid JSON") catch {};
            continue;
        };
        defer parsed.deinit();

        std.log.info("┌─ Message received", .{});
        std.log.info("│ Operation: {s}", .{@tagName(parsed.value.op)});
        std.log.info("│ Database:  {s}", .{parsed.value.db});
        std.log.info("└─", .{});

        handleMessage(allocator, stream_writer, parsed.value) catch |err| {
            std.log.err("Handler error: {}", .{err});
            sendError(stream_writer, "Handler failed") catch {};
        };

        std.log.debug("Back to waiting for next line", .{});
    } else |err| switch (err) {
        error.EndOfStream => {
            std.log.debug("EndOfStream received", .{});
        },
        error.StreamTooLong => return error.MessageTooLong,
        error.ReadFailed => return error.ReadFailed,
    }

    std.log.debug("Exiting connection handler", .{});
}

fn handleMessage(
    allocator: std.mem.Allocator,
    stream_writer: *std.Io.Writer,
    message: Message,
) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}.wal", .{message.db});
    const file = try std.fs.cwd().createFile(path, .{ .exclusive = false, .read = true, .truncate = false });
    defer file.close();

    switch (message.op) {
        .append => {
            const event = message.event orelse {
                try sendError(stream_writer, "Missing event");
                return;
            };

            std.log.info("→ Handling append to db: {s}", .{message.db});

            var writer_buf: [4096]u8 = undefined;
            var writer = file.writer(&writer_buf);

            try writer.seekTo(try writer.file.getEndPos());
            var allocating_writer: std.io.Writer.Allocating = .init(allocator);
            defer allocating_writer.deinit();

            var json_writer: std.json.Stringify = .{
                .writer = &allocating_writer.writer,
                .options = .{ .whitespace = .minified },
            };

            try json_writer.write(event);
            const json_bytes = allocating_writer.written();
            try writer.interface.writeAll(json_bytes);
            try writer.interface.writeByte('\n');
            try writer.interface.flush();

            try file.sync();

            try sendOk(stream_writer);
            try stream_writer.flush();
        },
        .replay_all => {
            std.log.info("→ Handling replay_all for db: {s}", .{message.db});
            var reader_buf: [4096]u8 = undefined;
            var file_reader = file.reader(&reader_buf);

            while (file_reader.interface.takeDelimiterInclusive('\n')) |line| {
                std.log.debug("Got line, length: {}", .{line.len});
                std.log.debug("line: {s}", .{line});
                try stream_writer.writeAll(line);
            } else |err| switch (err) {
                error.EndOfStream => {
                    std.log.debug("EndOfStream received", .{});
                },
                error.StreamTooLong => return error.MessageTooLong,
                error.ReadFailed => return error.ReadFailed,
            }
            try sendDone(stream_writer);
        },
    }
}

fn sendOk(stream_writer: *std.Io.Writer) !void {
    try stream_writer.writeAll("{\"status\":\"ok\"}\n");
    try stream_writer.flush();
}

fn sendError(writer: *std.Io.Writer, message: []const u8) !void {
    try writer.print("{{\"status\":\"error\",\"message\":\"{s}\"}}\n", .{message});
}

fn sendDone(writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"op\":\"done\"}\n");
}
