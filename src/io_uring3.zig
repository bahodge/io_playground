const std = @import("std");
const IoUring = std.os.linux.IoUring;

const WriterWorker = struct {
    ring: IoUring,
    id: []const u8,

    fn run(self: *WriterWorker) !void {
        const stdout = std.io.getStdOut();

        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        while (true) {
            std.time.sleep(1 * std.time.ns_per_s);

            const name = try std.fmt.allocPrint(allocator, "worker {}: working\n", .{self.id});
            defer allocator.free(name);

            _ = try self.ring.write(0, stdout.handle, name, 0);
        }
    }
};

const ReaderWorker = struct {
    ring: IoUring,
    id: []const u8,

    fn run(self: *WriterWorker) !void {
        const stdout = std.io.getStdOut();

        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        while (true) {
            std.time.sleep(1 * std.time.ns_per_s);

            const name = try std.fmt.allocPrint(allocator, "worker {}: working\n", .{self.id});
            defer allocator.free(name);

            _ = try self.ring.write(0, stdout.handle, name, 0);

            // completion queue events (cqes)
            const cqes = try allocator.alloc(std.os.linux.io_uring_cqe, 32);
            defer allocator.free(cqes);
        }
    }
};

pub fn main() !void {
    const stdout = std.io.getStdOut();
    const num_entries: u16 = 32;

    var ring = try IoUring.init(num_entries, 0);
    defer ring.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // completion queue events (cqes)
    const cqes = try allocator.alloc(std.os.linux.io_uring_cqe, num_entries);
    defer allocator.free(cqes);

    // connection receives some bytes and submits them for processing

    const str = "hello\n";
    _ = try ring.write(0, stdout.handle, str, 0);
    _ = try ring.write(0, stdout.handle, str, 0);
    _ = try ring.write(0, stdout.handle, str, 0);
    _ = try ring.write(0, stdout.handle, str, 0);
    _ = try ring.write(0, stdout.handle, str, 0);
    std.debug.print("submitting submition queue events\n", .{});
    _ = try ring.submit();

    std.time.sleep(1_000_000_000);

    std.debug.print("copying completion queue events\n", .{});
    const cqesDone = try ring.copy_cqes(cqes, 0);

    // std.debug.print("submitted {d}\n", .{submitted});
    // var written: usize = 0;

    for (cqes[0..cqesDone]) |cqe| {
        std.debug.assert(cqe.err() == .SUCCESS);
        std.debug.assert(cqe.res >= 0);

        std.debug.print("cqe {any}\n", .{cqe});
    }
}
