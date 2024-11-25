const std = @import("std");
const IoUring = std.os.linux.IoUring;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut();

    const entries_num: u16 = 16;

    var ring = try IoUring.init(entries_num, 0);
    defer ring.deinit();

    // completion queue events (cqes)
    const cqes = try allocator.alloc(std.os.linux.io_uring_cqe, entries_num);
    defer allocator.free(cqes);

    const str = "hello\n";
    const iters = 10;
    for (0..iters) |_| {
        _ = try ring.write(0, stdout.handle, str, 0);
    }

    _ = try ring.submit_and_wait(iters);
    const cqesDone = try ring.copy_cqes(cqes, 0);

    // std.debug.print("submitted {d}\n", .{submitted});
    var written: usize = 0;

    for (cqes[0..cqesDone]) |cqe| {
        std.debug.assert(cqe.err() == .SUCCESS);
        std.debug.assert(cqe.res >= 0);
        const n = @as(usize, @intCast(cqe.res));
        written += n;

        // std.debug.print("cqe {any}\n", .{cqe});
    }

    std.debug.print("bytes written {any}\n", .{written});

    std.debug.assert(written == str.len * iters);
}
