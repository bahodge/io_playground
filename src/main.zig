const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const EventLoop = struct {
    epoll_fd: i32,
    shutdown: bool = false,

    const Handle = struct {
        epoll_fd: i32,
        fd: i32,

        pub fn deinit(self: *const @This()) void {
            posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, self.fd, null) catch |err| {
                std.debug.panic("failed to unregister with epoll {any}", .{err});
            };
        }
    };

    pub fn init() !EventLoop {
        const epoll_fd = try posix.epoll_create1(0);

        return EventLoop{
            .epoll_fd = epoll_fd,
        };
    }

    pub fn deinit(self: *EventLoop) void {
        std.posix.close(self.epoll_fd);
    }

    // handler must be valid for duration of file descriptor
    pub fn register(self: *EventLoop, fd: i32, handler: *const EventHandler) !Handle {
        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .ptr = @intFromPtr(handler) },
        };

        try posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, fd, &event);

        return Handle{
            .epoll_fd = self.epoll_fd,
            .fd = fd,
        };
    }

    pub fn run(self: *EventLoop) !void {
        while (true) {
            var events: [100]linux.epoll_event = undefined;
            // wait for events
            const num_fds = posix.epoll_wait(self.epoll_fd, &events, -1);
            for (events[0..num_fds]) |event| {
                const data: *const EventHandler = @ptrFromInt(event.data.ptr);
                data.callback(data.data) catch |err| {
                    std.log.err("failed to run callback: {any}", .{err});
                };
            }
        }
    }
};

const EpollCallback = *const fn (?*anyopaque) anyerror!void;

const EventHandler = struct {
    data: ?*anyopaque,
    callback: EpollCallback,
};

const TcpEchoer = struct {
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    handle: ?EventLoop.Handle,

    pub fn init(allocator: std.mem.Allocator, connection: std.net.Server.Connection) !*TcpEchoer {
        const echoer = try allocator.create(TcpEchoer);
        errdefer allocator.destroy(echoer);

        echoer.* = .{
            .allocator = allocator,
            .connection = connection,
            .handle = null,
        };

        return echoer;
    }

    fn deinit(self: *TcpEchoer) void {
        if (self.handle) |handle| {
            handle.deinit();
        }
        self.connection.stream.close();
        self.allocator.destroy(self);
    }

    pub fn register(self: *TcpEchoer, event_loop: *EventLoop) !void {
        const connection_data = try self.allocator.create(EventHandler);
        errdefer self.allocator.destroy(connection_data);
        connection_data.* = .{
            .data = self,
            .callback = TcpEchoer.echo,
        };

        const event_loop_handle = try event_loop.register(self.connection.stream.handle, connection_data);
        self.handle = event_loop_handle;
    }

    pub fn echo(userdata: ?*anyopaque) !void {
        const self: *TcpEchoer = @ptrCast(@alignCast(userdata));

        std.debug.print("waiting\n", .{});
        var buf: [1024]u8 = undefined;

        const n = try self.connection.stream.read(&buf);

        if (n == 0) {
            self.deinit();
            return error.ConnectionClosed;
        }

        _ = try self.connection.stream.write(buf[0..n]);
    }
};

const TcpConnectionAcceptor = struct {
    allocator: std.mem.Allocator,
    server: *std.net.Server,
    event_loop: *EventLoop,
    echoers: std.ArrayList(*TcpEchoer),

    pub fn deinit(self: *TcpConnectionAcceptor) void {
        for (self.echoers.items) |echoer| {
            echoer.deinit();
        }
    }

    fn acceptTCPConnection(userdata: ?*anyopaque) anyerror!void {
        const self: *TcpConnectionAcceptor = @ptrCast(@alignCast(userdata));
        // FIX: close connection
        const connection = try self.server.accept();

        const echoer = TcpEchoer.init(self.allocator, connection) catch |err| {
            connection.stream.close();
            return err;
        };
        errdefer echoer.deinit();

        try self.echoers.append(echoer);
        errdefer _ = self.echoers.pop();

        try echoer.register(self.event_loop);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const server_addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 8000);
    var tcp_server = try server_addr.listen(.{
        .reuse_port = true,
        .reuse_address = true,
    });
    defer tcp_server.deinit();

    var event_loop = try EventLoop.init();
    defer event_loop.deinit();

    var tcp_connection_acceptor = TcpConnectionAcceptor{
        .allocator = allocator,
        .event_loop = &event_loop,
        .server = &tcp_server,
        .echoers = std.ArrayList(*TcpEchoer).init(allocator),
    };

    const listener_data = EventHandler{
        .data = &tcp_connection_acceptor,
        .callback = TcpConnectionAcceptor.acceptTCPConnection,
    };

    const handle = try event_loop.register(tcp_server.stream.handle, &listener_data);
    defer handle.deinit();

    try event_loop.run();
}
