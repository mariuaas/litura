//! Structural invariants of a piece table, recomputed from its pieces rather than
//! trusted from its cached summaries.
const std = @import("std");
const litura = @import("litura");
const PieceTable = litura.piece_table.PieceTable;
const nodes = litura.piece_table.nodes;
const Summary = litura.summaries.Summary;

/// Checks summaries, fan-out, uniform leaf depth, that every piece boundary is a
/// grapheme boundary of the whole text (SPEC §1.3), and that no transaction bookkeeping
/// survives outside a transaction.
pub fn expectValidTree(gpa: std.mem.Allocator, table: *const PieceTable) !void {
    try std.testing.expect(table.transaction == null);
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(gpa);
    var piece_ends: std.ArrayListUnmanaged(usize) = .empty;
    defer piece_ends.deinit(gpa);
    var leaf_depth: ?usize = null;
    _ = try checkNode(gpa, table, table.root, true, 0, &leaf_depth, &text, &piece_ends);

    var boundaries = std.AutoHashMap(usize, void).init(gpa);
    defer boundaries.deinit();
    try boundaries.put(0, {});
    var iter = litura.segmentation.graphemeIterator(text.items);
    var offset: usize = 0;
    while (iter.next()) |cluster| {
        offset += cluster.len;
        try boundaries.put(offset, {});
    }
    for (piece_ends.items) |end| try std.testing.expect(boundaries.contains(end));
}

fn checkNode(
    gpa: std.mem.Allocator,
    table: *const PieceTable,
    node: nodes.NodeRef,
    is_root: bool,
    depth: usize,
    leaf_depth: *?usize,
    text: *std.ArrayListUnmanaged(u8),
    piece_ends: *std.ArrayListUnmanaged(usize),
) !Summary {
    try std.testing.expectEqualDeep(nodes.Ownership{}, node.ownership().*);
    var acc = Summary.empty;
    switch (node) {
        .leaf => |leaf| {
            if (leaf_depth.*) |expected| {
                try std.testing.expectEqual(expected, depth);
            } else {
                leaf_depth.* = depth;
            }
            try std.testing.expect(leaf.pieces.items.len <= nodes.max_leaf_pieces);
            if (!is_root) try std.testing.expect(leaf.pieces.items.len > 0);
            for (leaf.pieces.items) |piece| {
                const piece_text = table.pieceText(piece);
                try std.testing.expect(piece_text.len > 0);
                try std.testing.expectEqualDeep(
                    Summary.fromText(&table.seg, piece_text),
                    piece.summary,
                );
                try text.appendSlice(gpa, piece_text);
                try piece_ends.append(gpa, text.items.len);
                acc = Summary.merge(acc, piece.summary);
            }
            try std.testing.expectEqualDeep(acc, leaf.summary);
        },
        .internal => |internal| {
            try std.testing.expect(internal.children.items.len > 0);
            try std.testing.expect(internal.children.items.len <= nodes.max_internal_fanout);
            for (internal.children.items) |child| {
                const child_depth = depth + 1;
                const child_summary =
                    try checkNode(
                        gpa,
                        table,
                        child,
                        false,
                        child_depth,
                        leaf_depth,
                        text,
                        piece_ends,
                    );
                acc = Summary.merge(acc, child_summary);
            }
            try std.testing.expectEqualDeep(acc, internal.summary);
        },
    }
    return acc;
}
