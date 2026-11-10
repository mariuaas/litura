//! Piece-table tree storage and summary recomputation.

const std = @import("std");
const summaries = @import("summaries.zig");

const Summary = summaries.Summary;

pub const Error = error{
    OutOfRange,
    InvalidRange,
};

pub const PieceTableError = Error || std.mem.Allocator.Error;

pub const Source = enum {
    original,
    add,
};

pub const Piece = struct {
    source: Source,
    offset: usize,
    len: usize,
    summary: Summary,
};

pub const max_internal_fanout = 4;
pub const min_internal_fanout = 2;
pub const max_leaf_pieces = 6;
pub const min_leaf_pieces = 2;
pub const piece_grapheme_chunk = 512;

pub const Leaf = struct {
    pieces: std.ArrayListUnmanaged(Piece) = .empty,
    summary: Summary = Summary.empty,
};

pub const Internal = struct {
    children: std.ArrayListUnmanaged(NodeRef) = .empty,
    summary: Summary = Summary.empty,
};

pub const NodeRef = union(enum) {
    leaf: *Leaf,
    internal: *Internal,

    pub fn summary(self: NodeRef) Summary {
        return switch (self) {
            .leaf => |n| n.summary,
            .internal => |n| n.summary,
        };
    }
};

pub fn recomputeNode(node: NodeRef) void {
    switch (node) {
        .leaf => |n| {
            var acc = Summary.empty;
            for (n.pieces.items) |piece| acc = Summary.merge(acc, piece.summary);
            n.summary = acc;
        },
        .internal => |n| {
            var acc = Summary.empty;
            for (n.children.items) |child| acc = Summary.merge(acc, child.summary());
            n.summary = acc;
        },
    }
}
