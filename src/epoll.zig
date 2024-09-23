const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const EventLoop = struct {
    epoll_fd: i32,
    // Unowned pointers
    handlers: std.ArrayList(*const EventHandler),
    shutdown: bool = false,

    const Handle = struct {
        fd: i32,
        // Unowned pointer
        handler: *const EventHandler,
        event_loop: *EventLoop,

        pub fn deinit(self: *const @This()) void {
            for (self.event_loop.handlers.items, 0..) |handler, i| {
                if (handler == self.handler) {
                    _ = self.event_loop.handlers.swapRemove(i);
                    break;
                }
            }

            posix.epoll_ctl(self.event_loop.epoll_fd, linux.EPOLL.CTL_DEL, self.fd, null) catch |err| {
                std.debug.panic("failed to unregister with epoll {any}", .{err});
            };

            if (self.handler.deinit) |f| {
                f(self.handler.data);
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator) !EventLoop {
        const epoll_fd = try posix.epoll_create1(0);

        return EventLoop{
            .epoll_fd = epoll_fd,
            .handlers = std.ArrayList(*const EventHandler).init(allocator),
        };
    }

    pub fn deinit(self: *EventLoop) void {
        std.posix.close(self.epoll_fd);
        for (self.handlers.items) |handler| {
            if (handler.deinit) |f| {
                f(handler.data);
            }
        }
        self.handlers.deinit();
    }

    // handler must be valid for duration of file descriptor
    pub fn register(self: *EventLoop, fd: i32, handler: *const EventHandler) !Handle {
        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .ptr = @intFromPtr(handler) },
        };

        try self.handlers.append(handler);
        errdefer _ = self.handlers.pop();

        try posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, fd, &event);

        return Handle{
            .event_loop = self,
            .fd = fd,
            .handler = handler,
        };
    }

    pub fn run(self: *EventLoop) !void {
        while (!self.shutdown) {
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
    deinit: ?*const fn (?*anyopaque) void,
};

const TcpEchoer = struct {
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    connection_data: ?*EventHandler,
    event_loop: ?*EventLoop,
    handle: ?EventLoop.Handle,

    pub fn init(allocator: std.mem.Allocator, connection: std.net.Server.Connection) !*TcpEchoer {
        const echoer = try allocator.create(TcpEchoer);
        errdefer allocator.destroy(echoer);

        echoer.* = .{
            .allocator = allocator,
            .connection = connection,
            .handle = null,
            .event_loop = null,
            .connection_data = null,
        };

        return echoer;
    }

    fn deinit(self: *TcpEchoer) void {
        self.connection.stream.close();

        if (self.connection_data) |connection_data| {
            self.allocator.destroy(connection_data);
        }

        self.allocator.destroy(self);
    }

    pub fn register(self: *TcpEchoer, event_loop: *EventLoop) !void {
        const connection_data = try self.allocator.create(EventHandler);
        errdefer self.allocator.destroy(connection_data);

        const opaque_deinit = struct {
            fn f(data: ?*anyopaque) void {
                const echoer: *TcpEchoer = @ptrCast(@alignCast(data));
                echoer.deinit();
            }
        }.f;
        connection_data.* = .{
            .data = self,
            .callback = TcpEchoer.echo,
            .deinit = opaque_deinit,
        };

        const event_loop_handle = try event_loop.register(self.connection.stream.handle, connection_data);
        self.event_loop = event_loop;
        self.handle = event_loop_handle;
        self.connection_data = connection_data;
    }

    pub fn echo(userdata: ?*anyopaque) !void {
        const self: *TcpEchoer = @ptrCast(@alignCast(userdata));

        std.debug.print("waiting\n", .{});
        var buf: [1024]u8 = undefined;

        const n = try self.connection.stream.read(&buf);

        if (n == 0) {
            self.handle.?.deinit();
            return error.ConnectionClosed;
        }

        if (std.mem.eql(u8, buf[0..n], "exit\n")) {
            self.event_loop.?.shutdown = true;
        }

        _ = try self.connection.stream.write(buf[0..n]);
    }
};

const TcpConnectionAcceptor = struct {
    allocator: std.mem.Allocator,
    server: *std.net.Server,
    event_loop: *EventLoop,

    fn acceptTCPConnection(userdata: ?*anyopaque) anyerror!void {
        const self: *TcpConnectionAcceptor = @ptrCast(@alignCast(userdata));
        // FIX: close connection
        const connection = try self.server.accept();

        const echoer = TcpEchoer.init(self.allocator, connection) catch |err| {
            connection.stream.close();
            return err;
        };
        errdefer echoer.deinit();

        try echoer.register(self.event_loop);
    }
};

pub fn do_epoll() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const server_addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 8000);
    var tcp_server = try server_addr.listen(.{
        .reuse_port = true,
        .reuse_address = true,
    });
    defer tcp_server.deinit();

    var event_loop = try EventLoop.init(allocator);
    defer event_loop.deinit();

    var tcp_connection_acceptor = TcpConnectionAcceptor{
        .allocator = allocator,
        .event_loop = &event_loop,
        .server = &tcp_server,
    };

    const listener_data = EventHandler{
        .data = &tcp_connection_acceptor,
        .callback = TcpConnectionAcceptor.acceptTCPConnection,
        .deinit = null,
    };

    const handle = try event_loop.register(tcp_server.stream.handle, &listener_data);
    defer handle.deinit();

    try event_loop.run();
}
