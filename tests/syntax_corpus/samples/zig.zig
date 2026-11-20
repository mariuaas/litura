//! Zig: multiline strings, labelled blocks, comptime, error unions, tagged unions. Ünïcode ✓
const std = @import("std");

/// A shape, with a tagged union payload.
pub const Shape = union(enum) {
    circle: f64,
    rect: struct { width: f64, height: f64 },
    named: []const u8,

    pub fn area(self: Shape) f64 {
        return switch (self) {
            .circle => |r| std.math.pi * r * r,
            .rect => |r| r.width * r.height,
            .named => |name| @floatFromInt(name.len),
        };
    }
};

const banner =
    \\a multiline string
    \\with "quotes" and \\backslashes — ünïcode
;

fn Stack(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn push(self: *Self, value: T) error{Full}!void {
            if (self.len == capacity) return error.Full;
            self.items[self.len] = value;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.items[self.len];
        }
    };
}

pub fn main() !void {
    var stack: Stack(u32, 8) = .{};
    inline for (.{ 1, 2, 3 }) |value| try stack.push(value);
    const total = blk: {
        var sum: u32 = 0;
        while (stack.pop()) |value| : (sum += 0) sum += value;
        break :blk sum;
    };
    const shapes = [_]Shape{ .{ .circle = 1.5 }, .{ .rect = .{ .width = 2, .height = 3 } }, .{ .named = "é" } };
    var area: f64 = 0;
    for (shapes, 0..) |shape, index| {
        if (index % 2 == 0) area += shape.area() else continue;
    }
    const c: u8 = 'x';
    std.debug.print("{s} {d} {d:.2} {c} {x}\n", .{ banner, total, area, c, 0xFF_FF });
    comptime std.debug.assert(@sizeOf(u32) == 4);
    defer {}
    errdefer |err| std.log.err("{t}", .{err});
}
