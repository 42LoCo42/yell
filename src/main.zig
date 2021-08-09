const std = @import("std");

const writer_out = std.io.getStdOut().writer();
const writer_err = std.io.getStdErr().writer();

const stdin_handle = std.io.getStdIn().handle;
const stdout_handle = std.io.getStdOut().handle;

fn msgOut(comptime fmt: []const u8, args: anytype) void {
    writer_out.print(fmt, args) catch |err| std.debug.print("{s}\n", .{err});
}

fn msgErr(comptime fmt: []const u8, args: anytype) void {
    writer_err.print(fmt, args) catch |err| std.debug.print("{s}\n", .{err});
}

fn lenOfSTP(ptr: anytype) usize {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return len;
}

fn epollAdd(epoll_fd: i32, fd: i32) !void {
    var event: std.os.epoll_event = .{ .events = std.os.EPOLLIN, .data = .{ .fd = fd } };
    try std.os.epoll_ctl(epoll_fd, std.os.EPOLL_CTL_ADD, fd, &event);
}

fn epollDel(epoll_fd: i32, fd: i32) void {
    std.os.epoll_ctl(epoll_fd, std.os.EPOLL_CTL_DEL, fd, null) catch unreachable;
}

pub fn main() !u8 {
    if (std.os.argv.len < 3) {
        usage();
        return 1;
    }

    const port = try std.fmt.parseUnsigned(u16, std.os.argv[2][0..lenOfSTP(std.os.argv[2])], 0);
    const addr = try std.net.Address.resolveIp(std.os.argv[1][0..lenOfSTP(std.os.argv[1])], port);

    msgErr("Listening on {s}\n", .{addr});

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
    const alloc = &gpa.allocator;
    var connections = std.AutoHashMap(std.os.socket_t, std.net.StreamServer.Connection).init(alloc);

    // append stdout as fake connection
    var stdout_conn = std.mem.zeroes(std.net.StreamServer.Connection);
    stdout_conn.stream.handle = stdout_handle;
    try connections.put(stdout_handle, stdout_conn);

    while (true) {
        var events: [1]std.os.epoll_event = undefined;
        var event = &events[0];
        _ = std.os.epoll_wait(epoll_fd, &events, -1);
        const fd = event.data.fd;

        if(fd == listener) {
            const new = server.accept() catch |err| {
                msgErr("S: could not accept client: {s}\n", .{err});
                continue;
            };
            epollAdd(epoll_fd, new.stream.handle) catch |err| {
                msgErr("S: could not add {d} to epoll: {s}\n", .{new.stream.handle, err});
                std.os.closeSocket(new.stream.handle);
                continue;
            };
            connections.put(new.stream.handle, new) catch |err| {
                msgErr("S: could not register {d}: {s}\n", .{new.stream.handle, err});
            };
        } else {
            // client or stdin
            var buf: [1024]u8 = undefined;
            const len = std.os.read(fd, &buf) catch |err| {
                msgErr("{d}: read failed: {s}\n", .{fd, err});
                _ = connections.remove(fd);
                epollDel(epoll_fd, fd);
                std.os.closeSocket(fd);
                continue;
            };

            if(len == 0) {
                msgErr("{d}: disconnected\n", .{fd});
                _ = connections.remove(fd);
                epollDel(epoll_fd, fd);
                std.os.closeSocket(fd);
                continue;
            }

            var it = connections.iterator();
            while(it.next()) |ent| {
                if(ent.key_ptr.* == fd) continue; // don't write to myself
                if(ent.key_ptr.* == stdout_handle and fd == stdin_handle) continue; // no serverside passthrough
                _ = ent.value_ptr.stream.write(buf[0..len]) catch |err| {
                    msgErr("{d}: could not write buffer: {s}\n", .{ent.key_ptr.*, err});
                    continue;
                };
            }
        }
    }
    return 0;
}

fn usage() void {
    msgOut("Usage: {s} <ip> <port>\n", .{
        std.os.argv[0],
    });
}
