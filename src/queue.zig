const std = @import("std");

// very simple queue to help manage events
pub fn Queue(comptime T: type) type {
    return struct {
        pub const Node = struct {
            data: T,
            next: ?*Node = null,
        };

        const Self = @This();
        head: ?*Node,
        count: u32,

        pub fn new() Self {
            return Self{
                .head = null,
                .count = 0,
            };
        }

        pub fn enqueue(self: *Self, new_node: *Node) void {
            defer self.count += 1;
            if (self.head == null) {
                self.head = new_node;
                return;
            }

            var current = self.head;

            while (current) |node| {
                if (node.next == null) {
                    node.next = new_node;
                    return;
                }
                current = node.next;
            }
        }

        pub fn dequeue(self: *Self) ?*Node {
            if (self.head == null) return null;
            const node = self.head.?;
            if (node.next) |next_node| {
                self.head = next_node;
            }

            self.count -= 1;
            node.next = null;
            return node;
        }

        pub fn print(self: Self) void {
            var current = self.head;
            var pos: u32 = 0;
            while (current) |node| {
                std.debug.print("pos: {d}, data: {any}\n", .{ pos, node.data });
                current = node.next;
                pos += 1;
            }
        }
    };
}

test "queue" {
    const Q = Queue(u32);
    var q = Q.new();
    var a = Q.Node{ .data = 1 };
    var b = Q.Node{ .data = 2 };
    var c = Q.Node{ .data = 3 };

    q.enqueue(&a);
    q.enqueue(&b);
    q.enqueue(&c);
    try std.testing.expectEqual(3, q.count);
    q.print();

    const a_dequeued = q.dequeue();
    std.debug.print("queue {any}\n", .{q});
    try std.testing.expect(a_dequeued.?.data == a.data);

    try std.testing.expectEqual(2, q.count);

    q.print();
}
