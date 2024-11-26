const std = @import("std");
const net = std.net;
const posix = std.posix;
const linux = std.os.linux;
const IoUring = linux.IoUring;
const io_uring_sqe = linux.io_uring_sqe;
const io_uring_cqe = linux.io_uring_cqe;

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

    pub fn close(self: *Connection) void {
        if (self.state == .closed) return;
        posix.close(self.socket);
        self.state = .closed;
    }
};

var conn_id: u32 = 1;

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
        var cqes: [256]linux.io_uring_cqe = undefined;
        var buf: [1024]u8 = undefined;

        main: while (true) {
            // wait for some connections before trying to do any work
            if (self.connections.items.len == 0) std.time.sleep(100 * std.time.ns_per_ms);
            if (!self.connections_mutex.tryLock()) continue;
            defer self.connections_mutex.unlock();

            // if there are any submitted or completed events, we should try to process all of those events
            // before trying to submitting/completing any more. If we can't process those events, then lets
            // collect some more events

            for (self.connections.items, 0..) |conn, i| {
                switch (conn.state) {
                    .waiting => continue,
                    .ready => {
                        const read_buf = IoUring.ReadBuffer{
                            .buffer = &buf,
                        };

                        // check if there is a message to be written to this connection
                        _ = try self.ring.read(@intFromPtr(conn), conn.socket, read_buf, 0);
                        _ = try self.ring.timeout(@intFromPtr(conn), &linux.kernel_timespec{ .tv_sec = 5, .tv_nsec = 0 }, 1, 0);
                        conn.state = .waiting;
                    },
                    .closed => {
                        // remove the connection and start again
                        conn.close();
                        _ = self.connections.swapRemove(i);
                        // self.removeConnection(conn.id);
                        continue :main;
                    },
                }
            }

            // submit all the events
            _ = try self.ring.submit();
            const done = try self.ring.copy_cqes(&cqes, 0);

            for (cqes[0..done], 0..) |cqe, i| {
                // NOTE: catchall for errors. If any error, just queue the conn for closing
                if (cqe.res < 0) {
                    std.debug.print("error cqe {any}\n", .{cqe});
                    const conn: *Connection = @ptrFromInt(cqe.user_data);
                    // std.debug.print("error cqe connection {any}\n", .{conn});
                    // _ = try posix.send(conn.socket, "bye", 0);
                    // conn.state = .closed;
                    conn.close();

                    continue;
                }

                if (cqe.user_data != 0) {
                    // i would really want this to be an "Event" that contains context, data and other helpful stuff
                    const conn: *Connection = @ptrFromInt(cqe.user_data);
                    // we don't care about this connection and we are going to drop it
                    if (conn.state == .closed) {
                        // std.debug.print("conn is closed {any}\n", .{conn.id});
                        continue;
                    }

                    // immediately swap states to ready to receive the next results
                    conn.state = .ready;

                    if (cqe.res > 0) {
                        // std.debug.print("cqe {any}\n", .{cqe});
                        // std.debug.print("conn {any}\n", .{conn});
                        std.debug.print("conn {d} cqe_idx: {d} buf {s}\n", .{ conn.id, i, buf[0..@intCast(cqe.res)] });
                    }
                }
                // find the matching connection and have the connection handle the event
                // std.debug.print("cqe done {any}\n", .{cqe});
            }
        }
    }

    pub fn addConnection(self: *Bus, socket: posix.socket_t) !void {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        const conn = try self.allocator.create(Connection);
        conn.* = Connection.new(conn_id, socket);
        conn_id += 1;
        try self.connections.append(conn);
    }

    pub fn removeConnection(self: *Bus, id: u32) void {
        // self.connections_mutex.lock();
        // defer self.connections_mutex.unlock();

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
    const cqes = try ring_allocator.alloc(linux.io_uring_cqe, entries_num);
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
