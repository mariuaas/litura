//! Piece-tree transactions: the committed tree is never written, the candidate shares
//! untouched nodes with it, and repeated edits copy each committed node at most once.
const std = @import("std");
const litura = @import("litura");
const PieceTable = litura.piece_table.PieceTable;
const nodes = litura.piece_table.nodes;
const Summary = litura.summaries.Summary;
const tree_check = @import("tree_check.zig");
const allocator = std.testing.allocator;

const base_text = "The quick brown fox jumps over the lazy dog.\n" ** 24;

/// The content of one node, as committed: identity, summary and entries.
const NodeImage = struct {
    address: usize,
    summary: Summary,
    pieces: []const nodes.Piece,
    children: []const usize,
};

/// Records every node reachable from `root` by identity and content.
fn imageTree(arena: std.mem.Allocator, root: nodes.NodeRef) ![]const NodeImage {
    var images: std.ArrayListUnmanaged(NodeImage) = .empty;
    try imageNode(arena, root, &images);
    return images.items;
}

fn imageNode(
    arena: std.mem.Allocator,
    node: nodes.NodeRef,
    images: *std.ArrayListUnmanaged(NodeImage),
) !void {
    switch (node) {
        .leaf => |leaf| try images.append(arena, .{
            .address = @intFromPtr(leaf),
            .summary = leaf.summary,
            .pieces = try arena.dupe(nodes.Piece, leaf.pieces.items),
            .children = &.{},
        }),
        .internal => |internal| {
            const children = try arena.alloc(usize, internal.children.items.len);
            for (internal.children.items, children) |child, *address| address.* = switch (child) {
                .leaf => |leaf| @intFromPtr(leaf),
                .internal => |inner| @intFromPtr(inner),
            };
            try images.append(arena, .{
                .address = @intFromPtr(internal),
                .summary = internal.summary,
                .pieces = &.{},
                .children = children,
            });
            for (internal.children.items) |child| try imageNode(arena, child, images);
        },
    }
}

fn fragmented(table: *PieceTable) !void {
    try table.initFromText(base_text);
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    for (0..120) |_| try table.insert(random.uintAtMost(u32, table.graphemeCount()), "x");
}

/// Applies one edit inside the caller's open transaction.
fn edit(table: *PieceTable, start: u32, end: u32, text: []const u8) !void {
    try table.applySplice(try table.planReplace(start, end, text), text);
}

/// Edits that together split, borrow, merge and resegment.
fn editHeavily(table: *PieceTable) !void {
    const mid = table.graphemeCount() / 2;
    try edit(table, mid, mid, "0123456789" ** 120);
    try edit(table, 10, table.graphemeCount() - 400, "");
    try edit(table, 3, 3, "e");
    try edit(table, 4, 4, "\u{0301}");
    try edit(table, 1, 2, "replacement");
}

test "a transaction never writes committed node content, and abort restores the committed tree" {
    var table = try PieceTable.init(allocator);
    defer table.deinit();
    try fragmented(&table);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const committed_root = table.root;
    const before = try imageTree(arena.allocator(), committed_root);

    table.begin();
    try editHeavily(&table);
    // The candidate differs; the committed tree, still reachable from the recorded root,
    // is identical node for node.
    try std.testing.expect(table.graphemeCount() != committed_root.summary().graphemes);
    const still_committed = try imageTree(arena.allocator(), table.transaction.?.committed_root);
    try std.testing.expectEqualDeep(before, still_committed);
    try std.testing.expect(table.transaction.?.copied > 0);

    table.abort();
    try std.testing.expectEqual(committed_root, table.root);
    try std.testing.expectEqualDeep(before, try imageTree(arena.allocator(), table.root));
    try tree_check.expectValidTree(allocator, &table);
}

test "commit publishes the same tree as separate transactions and frees what it replaced" {
    var together = try PieceTable.init(allocator);
    defer together.deinit();
    try fragmented(&together);
    together.begin();
    try editHeavily(&together);
    together.commit();
    try tree_check.expectValidTree(allocator, &together);

    // Each public edit runs as its own transaction.
    var separate = try PieceTable.init(allocator);
    defer separate.deinit();
    try fragmented(&separate);
    const mid = separate.graphemeCount() / 2;
    try separate.insert(mid, "0123456789" ** 120);
    try separate.delete(10, separate.graphemeCount() - 400);
    try separate.insert(3, "e");
    try separate.insert(4, "\u{0301}");
    try separate.replace(1, 2, "replacement");
    try tree_check.expectValidTree(allocator, &separate);

    const expected = try separate.getText();
    defer allocator.free(expected);
    const actual = try together.getText();
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    // std.testing.allocator reports any node commit failed to free, or freed twice.
}

test "the candidate shares untouched nodes with the committed tree" {
    var table = try PieceTable.init(allocator);
    defer table.deinit();
    try fragmented(&table);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const committed = try imageTree(arena.allocator(), table.root);

    table.begin();
    try edit(&table, 0, 0, "x");
    const candidate = try imageTree(arena.allocator(), table.root);
    var shared: usize = 0;
    for (candidate) |node| {
        for (committed) |original| {
            if (node.address == original.address) shared += 1;
        }
    }
    // Only the root-to-leaf path was copied; everything else is shared.
    try std.testing.expectEqual(table.transaction.?.copied, committed.len - shared);
    table.abort();
}

test "repeated edits in one transaction copy each committed node at most once" {
    var table = try PieceTable.init(allocator);
    defer table.deinit();
    try fragmented(&table);
    const position = table.graphemeCount() / 2;

    table.begin();
    try edit(&table, position, position, "a");
    const after_first = table.transaction.?.copied;
    try std.testing.expect(after_first > 0);
    for (0..200) |_| try edit(&table, position, position, "a");
    // The path is owned after the first edit; splits create nodes but copy nothing.
    try std.testing.expectEqual(after_first, table.transaction.?.copied);
    table.commit();
    try tree_check.expectValidTree(allocator, &table);
}

test "replacing the document fails without touching the current one" {
    // Method: fail every allocation from the nth onward, for every n, until it succeeds.
    var fail_after: usize = 0;
    while (true) : (fail_after += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        var table = try PieceTable.init(failing.allocator());
        defer table.deinit();
        try fragmented(&table);
        const before = try table.getText();
        defer failing.allocator().free(before);

        failing.fail_index = failing.alloc_index + fail_after;
        const outcome = table.initFromText("replacement text\n" ** 40);
        failing.fail_index = std.math.maxInt(usize);
        try tree_check.expectValidTree(allocator, &table);
        const after = try table.getText();
        defer failing.allocator().free(after);
        if (outcome) |_| {
            try std.testing.expectEqualStrings("replacement text\n" ** 40, after);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqualStrings(before, after);
        }
    }
}
