const std = @import("std");
const epoll = @import("./epoll.zig");
const EventLoop = @import("./event_loop.zig");
const boop = @import("./boop.zig");

// const SignalHandler = struct {
//     fd: i32,
//
//     fn init() !SignalHandler {
//         var sig_mask = std.posix.empty_sigset;
//         std.os.linux.sigaddset(&sig_mask, std.posix.SIG.INT);
//         std.posix.sigprocmask(std.posix.SIG.BLOCK, &sig_mask, null);
//         const fd = try std.posix.signalfd(-1, &sig_mask, 0);
//
//         return .{
//             .fd = fd,
//         };
//     }
//
//     fn deinit(self: *SignalHandler) void {
//         std.posix.close(self.fd);
//     }
//
//     fn handler(_: *SignalHandler) EventLoop.EventHandler {
//         return EventLoop.EventHandler{
//             .data = null,
//             .callback = struct {
//                 fn f(_: ?*anyopaque) EventLoop.HandlerAction {
//                     return .shutdown;
//                 }
//             }.f,
//             .deinit = null,
//         };
//     }
// };

pub fn main() !void {
    try boop.run();

    // try epoll.do_epoll();

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
