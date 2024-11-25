const std = @import("std");
const net = std.net;
const posix = std.posix;
const IoUring = std.os.linux.IoUring;

const ConnectionState = enum(u8) {
    ready,
    waiting,
    closed,
};

const Connection = struct {
    id: u32,
    socket: posix.socket_t,
    state: ConnectionState,

    pub fn new(id: u32, socket: posix.socket_t) Connection {
        return Connection{
            .id = id,
            .socket = socket,
            .state = .ready,
        };
    }

    pub fn tick(self: *Connection) !void {
        // if there is a
        _ = self;
    }

    pub fn close(self: *Connection) void {
        if (self.state == .closed) return;
        posix.close(self.socket);
        self.state = .closed;
    }
};

var conn_id: u32 = 10;

const Bus = struct {
    allocator: std.mem.Allocator,
    connections: std.ArrayList(*Connection),
    connections_mutex: std.Thread.Mutex,
    ring: IoUring,

    pub fn init(allocator: std.mem.Allocator) !Bus {
        return Bus{
            .allocator = allocator,
            .connections = std.ArrayList(*Connection).init(allocator),
            .connections_mutex = std.Thread.Mutex{},
            .ring = try IoUring.init(8, 0),
        };
    }

    pub fn deinit(self: *Bus) void {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        for (self.connections.items) |conn| {
            conn.close();
            self.allocator.destroy(conn);
        }

        self.connections.deinit();
        self.ring.deinit();
    }

    pub fn run(self: *Bus) !void {
        std.debug.print("bus is running!\n", .{});
        var cqes: [256]std.os.linux.io_uring_cqe = undefined;

        while (true) {
            // wait for some connections before trying to do any work
            if (self.connections.items.len == 0) std.time.sleep(100 * std.time.ns_per_ms);
            if (!self.connections_mutex.tryLock()) continue;
            defer self.connections_mutex.unlock();

            var buf: [1024]u8 = undefined;
            var read_buf = IoUring.ReadBuffer{
                .buffer = &buf,
            };
            read_buf.buffer = &buf;
            inner: for (self.connections.items) |conn| {
                switch (conn.state) {
                    .waiting => continue,
                    .ready => {
                        // var read_buf: [1024]u8 = undefined;
                        // check if there is data bound for this connection to be written
                        // read from this socket
                        var sqe = try self.ring.read(@intFromPtr(conn), conn.socket, read_buf, 0);
                        sqe.addr = @intFromPtr(&buf);
                        // conn.state = .waiting;
                    },
                    .closed => {
                        // NOTE: this isn't a super great way to handle closed connections, would probably be better
                        // to have a seperate loop prune closed connections
                        // self.removeConnection(conn.id);
                        break :inner;
                    },
                }
            }

            // submit all the events
            _ = try self.ring.submit();

            const done = try self.ring.copy_cqes(&cqes, 0);

            for (cqes[0..done]) |cqe| {
                if (cqe.res < 0) {
                    continue;
                }

                if (cqe.user_data != 0) {
                    for (self.connections.items) |conn| {
                        const ptr: *Connection = @ptrFromInt(cqe.user_data);
                        if (ptr == conn) {
                            std.debug.print("cqe {any}\n", .{cqe});
                            std.debug.print("conn {any}\n", .{conn});
                            std.debug.print("buf {s}\n", .{buf[0..@intCast(cqe.res)]});
                            break;
                        }
                    }
                }
                // find the matching connection and have the connection handle the event
                std.debug.print("cqe done {any}\n", .{cqe});
            }
        }
    }

    pub fn addConnection(self: *Bus, socket: posix.socket_t) !void {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        const conn = try self.allocator.create(Connection);
        conn.* = Connection.new(conn_id, socket);
        try self.connections.append(conn);
    }

    pub fn removeConnection(self: *Bus, id: u32) void {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        for (self.connections.items, 0..) |conn, idx| {
            if (conn.id != id) continue;
            // close the connection if it isn't closed
            conn.close();
            self.allocator.destroy(conn);
            _ = self.connections.swapRemove(idx);
            break;
        }
    }
};

fn listen() !void {
    const address = try std.net.Address.parseIp("127.0.0.1", 8000);
    std.log.debug("listening on {s}:{d}", .{ "127.0.0.1", 8000 });

    const socket_type: u32 = posix.SOCK.STREAM;
    const protocol = posix.IPPROTO.TCP;
    const listener = try posix.socket(address.any.family, socket_type, protocol);
    defer posix.close(listener);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, 128);

    var ring_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = ring_gpa.deinit();
    const ring_allocator = ring_gpa.allocator();

    const entries_num: u16 = 8;

    var ring = try IoUring.init(entries_num, 0);
    defer ring.deinit();

    // completion queue events (cqes)
    const cqes = try ring_allocator.alloc(std.os.linux.io_uring_cqe, entries_num);
    defer ring_allocator.free(cqes);

    var bus_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = bus_gpa.deinit();
    const bus_allocator = bus_gpa.allocator();

    var bus = try Bus.init(bus_allocator);
    defer bus.deinit();

    // spawn a thread where the bus will just tick away!
    const bus_thread = try std.Thread.spawn(.{}, Bus.run, .{&bus});
    bus_thread.detach();

    while (true) {
        var client_address: net.Address = undefined;
        var client_address_len: posix.socklen_t = @sizeOf(net.Address);
        const socket = posix.accept(listener, &client_address.any, &client_address_len, 0) catch |err| {
            std.debug.print("error accept: {}\n", .{err});
            continue;
        };
        std.debug.print("{} connected\n", .{client_address});

        try bus.addConnection(socket);

        // std.time.sleep(1 * std.time.ns_per_s);
        // break;
    }
}

pub fn main() !void {
    try listen();
}
