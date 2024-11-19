const std = @import("std");
const net = std.net;
const posix = std.posix;

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

    while (true) {
        var client_address: net.Address = undefined;
        var client_address_len: posix.socklen_t = @sizeOf(net.Address);
        const socket = posix.accept(listener, &client_address.any, &client_address_len, 0) catch |err| {
            // Rare that this happens, but in later parts we'll
            // see examples where it does.
            std.debug.print("error accept: {}\n", .{err});
            continue;
        };
        // defer posix.close(socket);

        std.debug.print("{} connected\n", .{client_address});

        // const timeout = posix.timeval{ .tv_sec = 2, .tv_usec = 500_000 };
        // try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(timeout));
        // try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(timeout));

        // you can have a handle connection here
        // we've changed everything from this point on
        // const stream = std.net.Stream{ .handle = socket };
        const th = try std.Thread.spawn(.{}, handleConnection, .{socket});
        th.detach();
        // try handleConnection(stream);
    }
}

fn handleConnection(socket: posix.socket_t) !void {
    defer posix.close(socket);

    const stream = std.net.Stream{ .handle = socket };
    defer std.log.debug("connection closed {d}", .{socket});
    var buf: [16]u8 = undefined;
    while (true) {
        const read = try stream.read(&buf);
        if (read == 0) {
            return;
        }

        try stream.writeAll(buf[0..read]);
    }
}

pub fn run() !void {
    try listen();
}
