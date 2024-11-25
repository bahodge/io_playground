const std = @import("std");
const IoUring = std.os.linux.IoUring;

// const EventLoopState = enum { init, ready, processing };
const EventLoop = struct {
    allocator: std.mem.Allocator,
    ring: IoUring,

    pub fn init(allocator: std.mem.Allocator, entries: u16) !EventLoop {
        return EventLoop{
            .allocator = allocator,
            .ring = try IoUring.init(entries, 0),
        };
    }

    pub fn deinit(self: *EventLoop) void {
        _ = self;
    }

    pub fn run(self: *EventLoop) void {
        _ = self;
    }
};

const Callback = *const fn (?*anyopaque) anyerror!void;

const Event = struct {
    data: ?*anyopaque,
    callback: Callback,
};

const Worker = struct {
    event_loop: *EventLoop,

    pub fn handle(self: *Worker) !void {
        const ring = self.event_loop.ring;

        // var buf: [1024]u8 = undefined;
        const stdout = std.io.getStdOut();

        _ = try ring.write(0, stdout.handle, "hello\n", 0);

        // _ = try ring.write(0, 5, &buf, 0);
    }
};

pub fn main() !void {
    // initialize the event loop
    var event_loop_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = event_loop_gpa.deinit();
    const event_loop_allocator = event_loop_gpa.allocator();

    var event_loop = try EventLoop.init(event_loop_allocator, 32);
    defer event_loop.deinit();

    event_loop.run();
}
