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

/// Bookkeeping for a piece-table transaction. All fields are clear outside one.
/// Recording a node in a list writes only these fields, so it never allocates.
pub const Ownership = struct {
    /// Created by the active transaction, which may write it in place.
    owned: bool = false,
    /// A committed node the active transaction copied instead of writing.
    replaced: bool = false,
    /// Set only while committing: reachable from the published root.
    reachable: bool = false,
    /// Next node in the transaction's created list (owned nodes) or replaced list.
    next: ?NodeRef = null,
};

pub const Leaf = struct {
    pieces: std.ArrayListUnmanaged(Piece) = .empty,
    summary: Summary = Summary.empty,
    ownership: Ownership = .{},
};

pub const Internal = struct {
    children: std.ArrayListUnmanaged(NodeRef) = .empty,
    summary: Summary = Summary.empty,
    ownership: Ownership = .{},
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

    pub fn ownership(self: NodeRef) *Ownership {
        return switch (self) {
            .leaf => |n| &n.ownership,
            .internal => |n| &n.ownership,
        };
    }

    /// Frees this node's own list and struct, never its children.
    pub fn destroyShallow(self: NodeRef, allocator: std.mem.Allocator) void {
        switch (self) {
            .leaf => |n| {
                n.pieces.deinit(allocator);
                allocator.destroy(n);
            },
            .internal => |n| {
                n.children.deinit(allocator);
                allocator.destroy(n);
            },
        }
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
