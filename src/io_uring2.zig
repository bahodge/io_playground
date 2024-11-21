const std = @import("std");
const IoUring = std.os.linux.IoUring;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const entries_num: u16 = 16;

    var ring = try IoUring.init(entries_num, 0);
    defer ring.deinit();

    var cqes = try allocator.alloc(std.os.linux.io_uring_cqe, entries_num);
    defer allocator.free(cqes);

    std.debug.print("hello world\n", .{});
}
