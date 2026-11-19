//! Structural facts about a Tree-sitter tree, computed independently of the provider: a
//! recursive preorder walk of visible nodes through `child`, which assigns each node the
//! index a syntax reference's `id` means, and records its kind, parent, range and depth.
//! The provider answers the same questions with tree cursors and Tree-sitter's range
//! descent, which rely on the subtree summaries; the walk checks that the tree is coherent,
//! that its children can be traversed and number what the summaries say.
const std = @import("std");

pub const Error = error{
    /// The tree is structurally inconsistent: a child the parent reports cannot be
    /// reached, or the walk finds a different number of nodes than the summaries count.
    InconsistentTree,
} || std.mem.Allocator.Error;

pub const Table = struct {
    kind: [][]const u8,
    parent: []?u32,
    start: []u32,
    end: []u32,
    depth: []u32,
    named: []bool,

    /// Walks the tree under `root`; free with `deinit`.
    pub fn init(allocator: std.mem.Allocator, root: anytype) Error!Table {
        const count = root.descendantCount();
        var table: Table = .{
            .kind = try allocator.alloc([]const u8, count),
            .parent = try allocator.alloc(?u32, count),
            .start = try allocator.alloc(u32, count),
            .end = try allocator.alloc(u32, count),
            .depth = try allocator.alloc(u32, count),
            .named = try allocator.alloc(bool, count),
        };
        errdefer table.deinit(allocator);
        var next: u32 = 0;
        try table.visit(root, null, 0, &next);
        if (next != count) return error.InconsistentTree;
        return table;
    }

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.parent);
        allocator.free(self.start);
        allocator.free(self.end);
        allocator.free(self.depth);
        allocator.free(self.named);
        self.* = undefined;
    }

    fn visit(self: *Table, node: anytype, parent: ?u32, depth: u32, next: *u32) Error!void {
        const id = next.*;
        if (id >= self.kind.len) return error.InconsistentTree;
        next.* += 1;
        self.kind[id] = node.type();
        self.parent[id] = parent;
        self.start[id] = node.startByte();
        self.end[id] = node.endByte();
        self.depth[id] = depth;
        self.named[id] = node.isNamed();
        var index: u32 = 0;
        while (index < node.childCount()) : (index += 1) {
            const child = node.child(index);
            if (child.isNull()) return error.InconsistentTree;
            try self.visit(child, id, depth + 1, next);
        }
    }

    /// The deepest node containing the non-empty byte range `[start, end)`, preferring
    /// named nodes, or null if none contains it. Containing nodes nest, so the deepest
    /// is the smallest.
    pub fn enclosing(self: *const Table, start: u32, end: u32) ?u32 {
        std.debug.assert(start < end);
        var named: ?u32 = null;
        var any: ?u32 = null;
        for (self.start, self.end, 0..) |node_start, node_end, index| {
            if (node_start > start or node_end < end) continue;
            const id: u32 = @intCast(index);
            if (any == null or self.depth[id] > self.depth[any.?]) any = id;
            if (self.named[id] and (named == null or self.depth[id] > self.depth[named.?])) named = id;
        }
        return named orelse any;
    }
};
