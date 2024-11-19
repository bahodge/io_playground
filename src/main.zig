const std = @import("std");
const epoll = @import("./epoll.zig");
const epoll2 = @import("./epoll2.zig");
const EventLoop = @import("./event_loop.zig");
const boop = @import("./boop.zig");

pub fn main() !void {
    // try boop.run();
    //
    // try epoll.run();

    // try epoll2.run();

    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer {
    //     if (gpa.deinit() != .ok) {
    //         std.process.exit(1);
    //     }
    // }
    // const alloc = gpa.allocator();
    // var event_loop = try EventLoop.init(alloc);
    // defer event_loop.deinit();
    //
    // var signal_handler = try SignalHandler.init();
    // defer signal_handler.deinit();
    // try event_loop.register(signal_handler.fd, signal_handler.handler());
    //
    // try event_loop.run();
}
