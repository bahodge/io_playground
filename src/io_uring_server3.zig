const std = @import("std");
const assert = std.debug.assert;
const os = std.os;
const posix = std.posix;
const linux = os.linux;
const IOUring = linux.IoUring;
const io_uring_cqe = linux.io_uring_cqe;
const io_uring_sqe = linux.io_uring_sqe;

const Queue = @import("./queue.zig").Queue;

// Based off of tigerbeetle's IO module
const IO = struct {
    ring: IOUring,
    queue: Queue(Event),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) IO {
        const entries: u16 = 8;

        return IO{
            .ring = try IOUring.init(entries, 0),
            .queue = Queue(Event).new(),
            .allocator = allocator,
        };
    }

    const Event = struct {};
};
