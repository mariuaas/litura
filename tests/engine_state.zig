//! Snapshots every observable part of a BufferEngine for failure-atomicity tests.
//! Capturing reads engine internals directly and allocates only through the caller's
//! allocator, so it works while the engine's own allocator is exhausted.
const std = @import("std");
const litura = @import("litura");
const BufferEngine = litura.BufferEngine;
const types = litura.types;
const nodes = litura.piece_table.nodes;

const AnchorState = struct {
    id: u32,
    position: u32,
    stickiness: litura.anchors.AnchorStickiness,
    status: litura.anchors.AnchorStatus,
    kind: litura.anchors.AnchorKind,
    refs: u32,
    touched: bool,
};

const RegisterState = struct {
    key: []const u8,
    value: litura.events.InteractionValue,
};

const SessionState = struct {
    id: u32,
    revision: u32,
    selections: []const litura.engine.Selection,
    registers: []const RegisterState,
};

const EntryState = struct {
    forward_revs: []const u32,
    inverse_ops: []const types.BufferOp,
    deletion_metas: []const types.DeletionMeta,
};

/// Owns its contents through an arena; release with deinit.
pub const State = struct {
    arena: std.heap.ArenaAllocator,
    text: []const u8,
    revision: u32,
    /// Identity boundaries and the sequence: a failure must issue and consume nothing.
    next_public_anchor_id: u32,
    next_session_id: u32,
    next_sequence: u64,
    add_buffer_bytes: usize,
    anchors: []const AnchorState,
    sessions: []const SessionState,
    undo: []const EntryState,
    redo: []const EntryState,
    /// Whether a view provider has been told about an edit since it last refreshed.
    provider_notified: bool,

    pub fn capture(
        gpa: std.mem.Allocator,
        engine: *const BufferEngine,
        provider: *const litura.views.StaticTokenProvider,
    ) !State {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const allocator = arena.allocator();

        var text: std.ArrayListUnmanaged(u8) = .empty;
        try collectText(allocator, &engine.table, engine.table.root, &text);

        var anchor_list: std.ArrayListUnmanaged(AnchorState) = .empty;
        var anchor_iter = engine.anchors_map.valueIterator();
        while (anchor_iter.next()) |anchor| try anchor_list.append(allocator, .{
            .id = anchor.id.value,
            .position = anchor.position,
            .stickiness = anchor.stickiness,
            .status = anchor.status,
            .kind = anchor.kind,
            .refs = anchor.refs,
            .touched = anchor.touched,
        });
        std.mem.sort(AnchorState, anchor_list.items, {}, struct {
            fn lessThan(_: void, a: AnchorState, b: AnchorState) bool {
                return a.id < b.id;
            }
        }.lessThan);

        var session_list: std.ArrayListUnmanaged(SessionState) = .empty;
        var session_iter = engine.sessions.valueIterator();
        while (session_iter.next()) |session| {
            const registers = try allocator.alloc(RegisterState, session.registers.count());
            for (session.registers.keys(), session.registers.values(), registers) |key, value, *copy| {
                copy.* = .{
                    .key = try allocator.dupe(u8, key),
                    .value = try value.dupe(allocator),
                };
            }
            try session_list.append(allocator, .{
                .id = session.id,
                .revision = session.revision,
                .selections = try allocator.dupe(litura.engine.Selection, session.selections),
                .registers = registers,
            });
        }
        std.mem.sort(SessionState, session_list.items, {}, struct {
            fn lessThan(_: void, a: SessionState, b: SessionState) bool {
                return a.id < b.id;
            }
        }.lessThan);

        // Allocate everything before moving the arena into the result.
        const undo = try copyHistory(allocator, engine.undo_stack.items);
        const redo = try copyHistory(allocator, engine.redo_stack.items);
        return .{
            .arena = arena,
            .text = text.items,
            .revision = engine.revision,
            .next_public_anchor_id = engine.next_public_anchor_id,
            .next_session_id = engine.next_session_id,
            .next_sequence = engine.next_sequence,
            .add_buffer_bytes = engine.table.add_buf.items.len,
            .anchors = anchor_list.items,
            .sessions = session_list.items,
            .undo = undo,
            .redo = redo,
            .provider_notified = provider.stale,
        };
    }

    pub fn deinit(self: *State) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn expectEqual(expected: *const State, actual: *const State) !void {
        try std.testing.expectEqualStrings(expected.text, actual.text);
        try std.testing.expectEqual(expected.revision, actual.revision);
        try std.testing.expectEqual(expected.next_public_anchor_id, actual.next_public_anchor_id);
        try std.testing.expectEqual(expected.next_session_id, actual.next_session_id);
        try std.testing.expectEqual(expected.next_sequence, actual.next_sequence);
        try std.testing.expectEqual(expected.add_buffer_bytes, actual.add_buffer_bytes);
        try std.testing.expectEqualDeep(expected.anchors, actual.anchors);
        try std.testing.expectEqualDeep(expected.sessions, actual.sessions);
        try std.testing.expectEqualDeep(expected.undo, actual.undo);
        try std.testing.expectEqualDeep(expected.redo, actual.redo);
        try std.testing.expectEqual(expected.provider_notified, actual.provider_notified);
    }
};

fn collectText(
    allocator: std.mem.Allocator,
    table: *const litura.piece_table.PieceTable,
    node: nodes.NodeRef,
    out: *std.ArrayListUnmanaged(u8),
) !void {
    switch (node) {
        .leaf => |leaf| for (leaf.pieces.items) |piece| {
            try out.appendSlice(allocator, table.pieceText(piece));
        },
        .internal => |internal| for (internal.children.items) |child| {
            try collectText(allocator, table, child, out);
        },
    }
}

fn copyHistory(allocator: std.mem.Allocator, entries: []const types.UndoEntry) ![]const EntryState {
    const copies = try allocator.alloc(EntryState, entries.len);
    for (entries, copies) |entry, *copy| {
        const inverse_ops = try allocator.alloc(types.BufferOp, entry.inverse_ops.len);
        for (entry.inverse_ops, inverse_ops) |op, *op_copy| op_copy.* = switch (op) {
            .insert => |ins| .{ .insert = .{
                .pos = ins.pos,
                .text = try allocator.dupe(u8, ins.text),
            } },
            .delete => op,
            .replace => |rep| .{ .replace = .{
                .start = rep.start,
                .end = rep.end,
                .text = try allocator.dupe(u8, rep.text),
            } },
        };
        const metas = try allocator.alloc(types.DeletionMeta, entry.deletion_metas.len);
        for (entry.deletion_metas, metas) |meta, *meta_copy| meta_copy.* = .{
            .op = meta.op,
            .target_anchor = meta.target_anchor,
            .inverse_text = try allocator.dupe(u8, meta.inverse_text),
            .dead_anchors = try allocator.dupe(types.DeadAnchorRecord, meta.dead_anchors),
        };
        copy.* = .{
            .forward_revs = try allocator.dupe(u32, entry.forward_revs),
            .inverse_ops = inverse_ops,
            .deletion_metas = metas,
        };
    }
    return copies;
}
