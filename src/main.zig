const std = @import("std");

const writer_out = std.io.getStdOut().writer();
const writer_err = std.io.getStdErr().writer();

const stdin_handle = std.io.getStdIn().handle;
const stdout_handle = std.io.getStdOut().handle;

fn slice(ptr: anytype) []@typeInfo(@TypeOf(ptr)).Pointer.child {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

fn msgOut(comptime fmt: []const u8, args: anytype) void {
    writer_out.print(fmt, args) catch |err| std.debug.print("{s}\n", .{err});
}

fn msgErr(comptime fmt: []const u8, args: anytype) void {
    writer_err.print(fmt, args) catch |err| std.debug.print("{s}\n", .{err});
}

fn epollAdd(epoll_fd: i32, fd: i32) !void {
    var event: std.os.epoll_event = .{ .events = std.os.EPOLLIN, .data = .{ .fd = fd } };
    try std.os.epoll_ctl(epoll_fd, std.os.EPOLL_CTL_ADD, fd, &event);
}

fn epollDel(epoll_fd: i32, fd: i32) void {
    std.os.epoll_ctl(epoll_fd, std.os.EPOLL_CTL_DEL, fd, null) catch unreachable;
}

fn usage() void {
    msgOut("Usage: {s} <ip> <port> [-r: relay client messages to other clients]\n", .{
        std.os.argv[0],
    });
}

pub fn main() !u8 {
    if (std.os.argv.len < 3) {
        usage();
        return 1;
    }

    const port = try std.fmt.parseUnsigned(u16, slice(std.os.argv[2]), 0);
    const addr = try std.net.Address.resolveIp(slice(std.os.argv[1]), port);
    const relay = std.os.argv.len >= 4 and std.mem.eql(u8, slice(std.os.argv[3]), "-r");

    var server = std.net.StreamServer.init(.{ .kernel_backlog = 5, .reuse_address = true });
    defer server.deinit();
    try server.listen(addr);
    const listener = server.sockfd.?;

    const epoll_fd = try std.os.epoll_create1(0);
    defer std.os.close(epoll_fd);
    try epollAdd(epoll_fd, listener);
    try epollAdd(epoll_fd, stdin_handle);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const Connections = std.AutoHashMap(std.os.socket_t, std.net.StreamServer.Connection);
    var connections = Connections.init(&gpa.allocator);

    var stdout_conn = std.mem.zeroes(std.net.StreamServer.Connection);
    stdout_conn.stream.handle = stdout_handle;

    // this lambda closes a connection completely
    var lambda = struct {
        epoll_fd: i32,
        connections: *Connections,

        fn closeConn(self: *@This(), fd: std.os.socket_t) void {
            _ = self.connections.remove(fd);
            epollDel(self.epoll_fd, fd);
            std.os.closeSocket(fd);
        }

        fn send(self: *@This(), msg: []const u8, conn: *std.net.StreamServer.Connection) void {
            _ = conn.stream.write(msg) catch |err| {
                msgErr("{d}: could not write buffer: {s}\n", .{conn.stream.handle, err});
                self.closeConn(conn.stream.handle);
            };
        }
    }{ .epoll_fd = epoll_fd, .connections = &connections };
    const closeConn = lambda.closeConn;
    const send = lambda.send;

    msgErr("Listening on {s}, relay: {b}\n", .{addr, relay});

    while (true) {
        var events: [1]std.os.epoll_event = undefined;
        var event = &events[0];
        _ = std.os.epoll_wait(epoll_fd, &events, -1);
        const fd = event.data.fd;

        if (fd == listener) {
            const new = server.accept() catch |err| {
                msgErr("S: could not accept client: {s}\n", .{err});
                continue;
            };
            epollAdd(epoll_fd, new.stream.handle) catch |err| {
                msgErr("S: could not add {d} to epoll: {s}\n", .{ new.stream.handle, err });
                std.os.closeSocket(new.stream.handle);
                continue;
            };
            connections.put(new.stream.handle, new) catch |err| {
                msgErr("S: could not register {d}: {s}\n", .{ new.stream.handle, err });
            };
            msgErr("S: accepted {d} = {s}\n", .{ new.stream.handle, new.address });
        } else {
            // client or stdin
            var buf: [1024]u8 = undefined;
            const len = std.os.read(fd, &buf) catch |err| {
                msgErr("{d}: read failed: {s}\n", .{ fd, err });
                closeConn(fd);
                continue;
            };

            if (len == 0) {
                msgErr("{d}: disconnected\n", .{fd});
                closeConn(fd);
                continue;
            }

            // send to stdout if from client
            if (fd != stdin_handle) {
                send(buf[0..len], &stdout_conn);
                if (!relay) continue;
            }

            // send to clients
            var it = connections.valueIterator();
            while (it.next()) |ent| {
                if (ent.stream.handle == fd) continue;
                send(buf[0..len], ent);
            }
        }
    }
    return 0;
}
