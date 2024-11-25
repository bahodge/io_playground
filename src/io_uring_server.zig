const std = @import("std");
const net = std.net;
const posix = std.posix;
const IoUring = std.os.linux.IoUring;

const Worker = struct {
    const Self = @This();

    ring: IoUring,
    allocator: std.mem.Allocator,
    sockets: std.ArrayList(posix.socket_t),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, ring: IoUring) Self {
        return Self{
            .ring = ring,
            .allocator = allocator,
            .sockets = std.ArrayList(posix.socket_t).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn run(self: *Self) void {
        while (true) {
            if (self.sockets.items.len == 0) std.time.sleep(100 * std.time.ns_per_ms);
            if (!self.mutex.tryLock()) continue;
            defer self.mutex.unlock();

            var cqes: [256]std.os.linux.io_uring_cqe = undefined;
            const done = self.ring.copy_cqes(&cqes, 0) catch unreachable;

            for (cqes[0..done]) |cqe| {
                if (cqe.err() != .SUCCESS) {
                    std.debug.print("there was an error {any}\n", .{cqe.err()});
                }
                std.debug.print("cqe {any}\n", .{cqe});
            }
        }
    }

    pub fn addSocket(self: *Self, socket: posix.socket_t) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // try to lock the sockets
        try self.sockets.append(socket);

        // register the event
        try self.ring.register_eventfd(socket);
    }

    fn removeSocket(self: *Self, socket: posix.socket_t) void {
        for (self.sockets.items, 0..) |s, i| {
            if (s == socket) {
                posix.close(socket);
                _ = self.sockets.swapRemove(i);
                return;
            }
        }
    }

    fn readFromConnection(self: *Self, socket: posix.socket_t) !void {
        var read_buffer: [1024]u8 = undefined;

        std.debug.print("{} about to read\n", .{socket});
        // const n = try posix.recv(socket, &read_buffer, 0);
        // var n = try posix.recv(socket, &read_buffer, std.os.linux.MSG.PEEK);
        // const n = try posix.read(socket, &read_buffer);
        _ = try self.ring.read(0, socket, &read_buffer, 0);
        _ = try self.ring.submit();

        // std.debug.print("{} done reading\n", .{socket});
        // if (n == 0) {
        //     // connection closed
        //     return error.EOF;
        // }
        //
        // // n = try posix.read(socket, &read_buffer);
        //
        // const stdout = std.io.getStdOut();
        //
        // _ = try self.ring.write(0, stdout.handle, read_buffer[0..n], 0);
        // _ = try self.ring.submit();

        // publish the message to the ring
        // std.debug.print("data: {s}\n", .{read_buffer[0..n]});
        // _ = try posix.write(socket, read_buffer[0..n]);

        // const stream = std.net.Stream{ .handle = socket };
        // var buf: [16]u8 = undefined;
        // while (true) {
        //     const read = try stream.read(&buf);
        //     if (read == 0) {
        //         return;
        //     }
        //
        //     try stream.writeAll(buf[0..read]);
        // }
    }
};

const Bus = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    ring: IoUring,

    pub fn init(allocator: std.mem.Allocator, ring: IoUring) Self {
        return Self{
            .allocator = allocator,
            .ring = ring,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn run(self: *Self) void {
        const entries_num: u16 = 16;

        // completion queue events (cqes)
        const cqes = self.allocator.alloc(std.os.linux.io_uring_cqe, entries_num) catch unreachable;
        defer self.allocator.free(cqes);

        var written: usize = 0;

        var cqesDone = self.ring.copy_cqes(cqes, 0) catch unreachable;
        while (cqesDone > 0) {

            // std.debug.print("submitted {d}\n", .{submitted});

            for (cqes[0..cqesDone]) |cqe| {
                std.debug.assert(cqe.err() == .SUCCESS);
                std.debug.assert(cqe.res >= 0);
                const n = @as(usize, @intCast(cqe.res));
                written += n;

                std.debug.print("cqe {any}\n", .{cqe});
                std.debug.print("written {}\n", .{written});
            }

            cqesDone = self.ring.copy_cqes(cqes, 0) catch unreachable;
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

    var sockets = std.ArrayList(posix.socket_t).init(ring_allocator);
    defer sockets.deinit();

    var worker_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = worker_gpa.deinit();
    const worker_allocator = worker_gpa.allocator();

    var worker = Worker.init(worker_allocator, ring);
    defer worker.deinit();

    const worker_thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    worker_thread.detach();

    // var bus_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer _ = bus_gpa.deinit();
    // const bus_allocator = bus_gpa.allocator();
    // var bus = Bus.init(bus_allocator, ring);
    // defer bus.deinit();
    // const bus_thread = try std.Thread.spawn(.{}, Bus.run, .{&bus});
    // bus_thread.detach();

    while (true) {
        var client_address: net.Address = undefined;
        var client_address_len: posix.socklen_t = @sizeOf(net.Address);
        const socket = posix.accept(listener, &client_address.any, &client_address_len, 0) catch |err| {
            std.debug.print("error accept: {}\n", .{err});
            continue;
        };
        std.debug.print("{} beeeeeep\n", .{client_address});
        std.debug.print("{} connected\n", .{client_address});

        // const timeout = posix.timeval{ .tv_sec = 2, .tv_usec = 500_000 };
        // try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(timeout));
        // try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(timeout));

        try worker.addSocket(socket);
    }
}

// fn worker(ring: *IoUring, sockets: *std.ArrayList(posix.socket_t), mutex: *std.Thread.Mutex) void {
//     _ = ring;
//
//     while (true) {
//         if (sockets.items.len == 0) std.time.sleep(100 * std.time.ns_per_ms);
//         if (!mutex.tryLock()) continue;
//         defer mutex.unlock();
//
//         for (sockets.items, 0..) |socket, idx| {
//             handleConnection(socket) catch |err| {
//                 std.log.debug("socket error closed {any}", .{err});
//                 posix.close(socket);
//                 std.log.debug("connection closed {d}", .{socket});
//                 _ = sockets.swapRemove(idx);
//                 break;
//             };
//             // read from socket
//             std.debug.print("socket {any}\n", .{socket});
//         }
//     }
// }

fn handleConnection(socket: posix.socket_t) !void {
    var read_buffer: [1024]u8 = undefined;

    const n = try posix.read(socket, &read_buffer);

    if (n == 0) {
        // remove this item from the array list
        // close this socket
        return error.EOF;
    }

    std.debug.print("data: {s}\n", .{read_buffer[0..n]});

    _ = try posix.write(socket, read_buffer[0..n]);

    // const stream = std.net.Stream{ .handle = socket };
    // var buf: [16]u8 = undefined;
    // while (true) {
    //     const read = try stream.read(&buf);
    //     if (read == 0) {
    //         return;
    //     }
    //
    //     try stream.writeAll(buf[0..read]);
    // }
}

pub fn main() !void {
    try listen();
}
