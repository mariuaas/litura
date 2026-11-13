//! Anchor lifetimes across undo and session teardown: explicit disposal is terminal,
//! the anchors the engine creates for its own bookkeeping are invisible to clients, and
//! reclaiming history never touches public anchors (SPEC §1.4, §2.5).
const std = @import("std");
const litura = @import("litura");
const BufferEngine = litura.BufferEngine;
const types = litura.types;
const AnchorId = litura.anchors.AnchorId;
const allocator = std.testing.allocator;
const support = @import("support.zig");
const id = support.id;
const expectText = support.expectText;
const edit = support.edit;
const undo = support.undo;
const redo = support.redo;
const place = support.place;
const position = support.position;

fn expectDisposed(engine: *BufferEngine, anchor: AnchorId) !void {
    const info = try engine.queryAnchor(anchor);
    try std.testing.expectEqual(litura.anchors.HandleStatus.disposed, info.status);
    try std.testing.expectEqual(@as(?u32, null), info.position);
}

/// Every internal anchor in storage is invisible to every public entry point.
fn expectInternalInvisible(engine: *BufferEngine, session: u32) !void {
    var internal: usize = 0;
    var iter = engine.anchors_map.keyIterator();
    while (iter.next()) |key| {
        const anchor_id = AnchorId{ .value = key.* };
        if (!anchor_id.isInternal()) continue;
        internal += 1;
        try std.testing.expectError(error.KeyError, engine.queryAnchor(anchor_id));
        try std.testing.expectError(error.KeyError, engine.dropAnchor(anchor_id));
        try std.testing.expectError(error.InvalidArgument, engine.createSession(.{
            .id = id,
            .origin = engine.revision,
            .selections = &.{.{ .start = .{ .new = .{ .anchor = anchor_id } } }},
        }));
        var sampled = try engine.submit(
            .{ .id = id, .origin = engine.revision, .payload = .{ .interaction_mutation = .{
                .session_id = session,
                .origin = try engine.interactionRevision(session),
                .ops = &.{.{ .set_selections = .{ .selections = &.{
                    .{ .start = .{ .new = .{ .anchor = anchor_id } } },
                } } }},
            } } },
        );
        var expected: [64]u8 = undefined;
        const message = try std.fmt.bufPrint(
            &expected,
            "unknown anchor id: {d}",
            .{anchor_id.value},
        );
        try support.expectRejected(engine, &sampled, .invalid, message);
    }
    try std.testing.expect(internal > 0);
}

test "clearing a mark that a deletion killed does not block another client's undo" {
    var engine = try BufferEngine.initFromText(allocator, "abcdefgh", null);
    defer engine.deinit();
    _, const a_cursor = try support.caret(&engine, 0);
    const b, const b_cursor = try support.caret(&engine, 0);
    try place(&engine, b, b_cursor, 5, 2);
    const old_mark = (try support.mark(&engine, b)).?;

    // A deletes [1, 4), killing B's mark; B then clears it.
    try edit(&engine, &.{.{ .delete = .{ .start = 1, .end = 4 } }});
    try std.testing.expectEqual(@as(?u32, null), try position(&engine, old_mark));
    try place(&engine, b, b_cursor, 2, null);
    try expectDisposed(&engine, old_mark);

    // A's undo restores the text and does not bring the disposed mark back.
    try undo(&engine);
    try expectText(&engine, "abcdefgh");
    try expectDisposed(&engine, old_mark);
    try std.testing.expectEqual(@as(?AnchorId, null), try support.mark(&engine, b));
    try std.testing.expectEqual(@as(?u32, 5), try position(&engine, b_cursor));
    try std.testing.expectEqual(@as(?u32, 0), try position(&engine, a_cursor));

    // History remains usable in both directions.
    try redo(&engine);
    try expectText(&engine, "aefgh");
    try undo(&engine);
    try expectText(&engine, "abcdefgh");
    try expectDisposed(&engine, old_mark);
}

test "undo resurrects a dead mark that is still held, and skips one that was dropped" {
    var engine = try BufferEngine.initFromText(allocator, "abcdefgh", null);
    defer engine.deinit();
    const session, const cursor = try support.caret(&engine, 0);
    try place(&engine, session, cursor, 6, 2);
    const held_mark = (try support.mark(&engine, session)).?;
    const dropped = try engine.createAnchor(3, .weak);

    try edit(&engine, &.{.{ .delete = .{ .start = 1, .end = 5 } }});
    try engine.dropAnchor(dropped);
    try undo(&engine);
    try std.testing.expectEqual(@as(?u32, 2), try position(&engine, held_mark));
    try expectDisposed(&engine, dropped);
    try std.testing.expectEqual(@as(?AnchorId, held_mark), try support.mark(&engine, session));
}

test "dropping a session whose mark is dead does not block undo" {
    var engine = try BufferEngine.initFromText(allocator, "abcdefgh", null);
    defer engine.deinit();
    const session, const cursor = try support.caret(&engine, 0);
    try place(&engine, session, cursor, 6, 2);
    const mark = (try support.mark(&engine, session)).?;

    try edit(&engine, &.{.{ .delete = .{ .start = 1, .end = 4 } }});
    try support.dropSession(&engine, session);
    try undo(&engine);
    try expectText(&engine, "abcdefgh");
    try expectDisposed(&engine, mark);
    try expectDisposed(&engine, cursor);
}

test "undo targets and edit result anchors are invisible to clients" {
    var engine = try BufferEngine.initFromText(allocator, "abcdefgh", null);
    defer engine.deinit();
    const session, _ = try support.caret(&engine, 0);
    const weak = try engine.createAnchor(2, .weak);
    // The deletion records `weak` and creates an internal undo target.
    try edit(&engine, &.{.{ .delete = .{ .start = 1, .end = 4 } }});
    try expectInternalInvisible(&engine, session);

    // Guards treat a guessed internal id as unknown.
    const target = engine.undo_stack.items[0].deletion_metas[0].target_anchor;
    var guarded = try engine.submit(.{
        .id = id,
        .origin = engine.revision,
        .guards = &.{.{ .anchor_liveness = .{ .anchor = target } }},
        .payload = .{
            .buffer_mutation = .{ .ops = &.{.{ .insert = .{ .pos = 0, .text = "x" } }} },
        },
    });
    defer guarded.deinit(allocator);
    try std.testing.expect(guarded == .rejected);
    try std.testing.expectEqual(@as(u32, 1), engine.revision);

    try undo(&engine);
    try std.testing.expectEqual(@as(?u32, 2), try position(&engine, weak));
}

test "an edit reference's start anchor killed by a later operation does not break undo" {
    var engine = try BufferEngine.initFromText(allocator, "abcdef", null);
    defer engine.deinit();
    const session, const cursor = try support.caret(&engine, 0);
    const anchor_count = engine.anchors_map.count();

    // Operation 0's Weak start lies strictly inside operation 1's deletion.
    var result = try engine.submit(.{
        .id = id,
        .origin = engine.revision,
        .payload = .{ .composite = .{ .parts = &.{
            .{ .buffer_mutation = .{ .ops = &.{
                .{ .insert = .{ .pos = 3, .text = "XY" } },
                .{ .delete = .{ .start = 2, .end = 6 } },
            } } },
            .{ .interaction_mutation = .{
                .session_id = session,
                .origin = try engine.interactionRevision(session),
                .ops = &.{.{ .set_selections = .{ .selections = &.{
                    support.placeSpec(cursor, .{ .edit = .{ .op = 1 } }, null),
                } } }},
            } },
        } } },
    });
    try support.expectCommitted(&engine, &result);
    try expectText(&engine, "abef");
    // The killed start anchor was transaction-scoped: history does not record it, so
    // the deletion needs no undo target and nothing outlives the transaction.
    try std.testing.expectEqual(anchor_count, engine.anchors_map.count());
    try std.testing.expectEqual(@as(usize, 0), engine.undo_stack.items[0].deletion_metas.len);

    try undo(&engine);
    try expectText(&engine, "abcdef");
    try std.testing.expectEqual(anchor_count, engine.anchors_map.count());
    try redo(&engine);
    try expectText(&engine, "abef");
}

test "undo of one entry whose second deletion covers the first's undo target" {
    var engine = try BufferEngine.initFromText(allocator, "abcdefgh", null);
    defer engine.deinit();
    const inner = try engine.createAnchor(5, .weak);
    const outer = try engine.createAnchor(7, .weak);

    // Deleting [4, 6) kills `inner` and leaves its undo target at 4. Deleting [2, 6) of
    // "abcdgh" then kills that target and `outer` (at 5).
    try edit(&engine, &.{
        .{ .delete = .{ .start = 4, .end = 6 } },
        .{ .delete = .{ .start = 2, .end = 6 } },
    });
    try expectText(&engine, "ab");
    try undo(&engine);
    try expectText(&engine, "abcdefgh");
    try std.testing.expectEqual(@as(?u32, 5), try position(&engine, inner));
    try std.testing.expectEqual(@as(?u32, 7), try position(&engine, outer));

    // Redo records the deletions afresh, so the round trip repeats.
    try redo(&engine);
    try expectText(&engine, "ab");
    try undo(&engine);
    try std.testing.expectEqual(@as(?u32, 5), try position(&engine, inner));
    try std.testing.expectEqual(@as(?u32, 7), try position(&engine, outer));
}

test "dropping a session releases every endpoint, live or dead" {
    var engine = try BufferEngine.initFromText(allocator, "abcdef", null);
    defer engine.deinit();
    var block = try engine.createSession(.{ .id = id, .origin = engine.revision, .selections = &.{
        .{
            .start = .{ .new = .{ .position = 3 } },
            .end = .{ .new = .{ .position = 1 } },
            .active = .start,
        },
        .{ .start = .{ .new = .{ .position = 5 } } },
    } });
    defer block.deinit(allocator);
    const created = block.lifecycle.change.session_created;
    try edit(&engine, &.{.{ .delete = .{ .start = 0, .end = 2 } }});
    try std.testing.expectEqual(
        @as(?u32, null),
        try position(&engine, created.selections[0].end.anchor),
    );

    try support.dropSession(&engine, created.session);
    for (created.selections) |selection| {
        try expectDisposed(&engine, selection.start.anchor);
        try expectDisposed(&engine, selection.end.anchor);
    }
    try std.testing.expectError(error.KeyError, engine.interactionRevision(created.session));
    try std.testing.expectError(
        error.KeyError,
        engine.dropSession(.{ .id = id, .session = created.session }),
    );
    try undo(&engine);
    try expectText(&engine, "abcdef");
}

/// Recomputes every undo target's references from the reachable history and checks the
/// engine's counts against them: no target is missing, none is orphaned, and no
/// transaction-scoped anchor outlives its transaction.
fn expectHistoryInvariant(engine: *BufferEngine) !void {
    var expected = std.AutoHashMap(u32, u32).init(allocator);
    defer expected.deinit();
    for ([_][]const types.UndoEntry{ engine.undo_stack.items, engine.redo_stack.items }) |stack| {
        for (stack) |entry| for (entry.deletion_metas) |meta| {
            const owner = try expected.getOrPutValue(meta.target_anchor.value, 0);
            owner.value_ptr.* += 1;
            for (meta.dead_anchors) |record| {
                if (record.kind != .undo_target) continue;
                const named = try expected.getOrPutValue(record.anchor.value, 0);
                named.value_ptr.* += 1;
            }
        };
    }
    var iter = engine.anchors_map.valueIterator();
    var targets: usize = 0;
    while (iter.next()) |anchor| switch (anchor.kind) {
        .client, .endpoint => {},
        .transient => return error.TestUnexpectedResult,
        .undo_target => {
            targets += 1;
            try std.testing.expectEqual(expected.get(anchor.id.value) orelse 0, anchor.refs);
        },
    };
    try std.testing.expectEqual(expected.count(), targets);
}

test "handles distinguish live, dead, disposed and never-issued identifiers" {
    var engine = try BufferEngine.initFromText(allocator, "abcdef", null);
    defer engine.deinit();
    const live = try engine.createAnchor(1, .sticky);
    const dead = try engine.createAnchor(3, .weak);
    const disposed = try engine.createAnchor(5, .weak);
    try edit(&engine, &.{.{ .delete = .{ .start = 2, .end = 4 } }});
    try engine.dropAnchor(disposed);

    try std.testing.expectEqual(
        litura.anchors.HandleStatus.live,
        (try engine.queryAnchor(live)).status,
    );
    try std.testing.expectEqual(
        litura.anchors.HandleStatus.dead,
        (try engine.queryAnchor(dead)).status,
    );
    try expectDisposed(&engine, disposed);
    // Dropping a disposed handle again is a no-op; never-issued identifiers stay errors.
    try engine.dropAnchor(disposed);
    const unissued = AnchorId{ .value = engine.next_public_anchor_id };
    try std.testing.expectError(error.KeyError, engine.queryAnchor(unissued));
    try std.testing.expectError(error.KeyError, engine.dropAnchor(unissued));
    try std.testing.expectError(error.KeyError, engine.queryAnchor(.{ .value = 0 }));
    const session, _ = try support.caret(&engine, 0);
    try expectInternalInvisible(&engine, session);
}

test "a session's endpoints cannot be dropped by a client" {
    var engine = try BufferEngine.initFromText(allocator, "abcdef", null);
    defer engine.deinit();
    const session, const cursor = try support.caret(&engine, 0);
    try place(&engine, session, cursor, 4, 1);
    const mark = (try support.mark(&engine, session)).?;
    try std.testing.expectError(error.AnchorOwned, engine.dropAnchor(mark));
    try std.testing.expectError(error.AnchorOwned, engine.dropAnchor(cursor));
    try std.testing.expectEqual(@as(?u32, 1), try position(&engine, mark));
}

test "a failed anchor creation issues no identifier" {
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var engine = try BufferEngine.initFromText(failing.allocator(), "abc", null);
    defer engine.deinit();
    const boundary = engine.next_public_anchor_id;
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, engine.createAnchor(1, .weak));
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(boundary, engine.next_public_anchor_id);
    const created = try engine.createAnchor(1, .weak);
    try std.testing.expectEqual(boundary, created.value);
}

test "discarding a redo branch releases its undo targets" {
    var engine = try BufferEngine.initFromText(allocator, "abcdefgh", null);
    defer engine.deinit();
    for (0..50) |_| {
        // Undoing the insertion kills the anchor inside it and records a redo target;
        // the next edit discards that redo branch.
        try edit(&engine, &.{.{ .insert = .{ .pos = 2, .text = "XYZ" } }});
        const inside = try engine.createAnchor(3, .weak);
        try undo(&engine);
        try std.testing.expect(engine.canRedo());
        try edit(&engine, &.{.{ .insert = .{ .pos = 0, .text = "!" } }});
        try std.testing.expect(!engine.canRedo());
        try std.testing.expectEqual(
            litura.anchors.HandleStatus.dead,
            (try engine.queryAnchor(inside)).status,
        );
        try engine.dropAnchor(inside);
        try expectHistoryInvariant(&engine);
    }
    var internal: usize = 0;
    var iter = engine.anchors_map.keyIterator();
    while (iter.next()) |key| internal += @intFromBool(key.* & litura.anchors.internal_bit != 0);
    try std.testing.expectEqual(@as(usize, 0), internal);
}

test "an edit that kills a discarded redo entry's target can still be undone" {
    var engine = try BufferEngine.initFromText(allocator, "abcdef", null);
    defer engine.deinit();
    try edit(&engine, &.{.{ .insert = .{ .pos = 2, .text = "XYZ" } }});
    const inside = try engine.createAnchor(3, .weak);
    // The redo entry's target sits at 2. Deleting [1, 3) kills it and records it for
    // this edit's own undo, in the same commit that discards the redo branch.
    try undo(&engine);
    try edit(&engine, &.{.{ .delete = .{ .start = 1, .end = 3 } }});
    try expectHistoryInvariant(&engine);
    try undo(&engine);
    try expectText(&engine, "abcdef");
    try expectHistoryInvariant(&engine);
    // The client anchor lost its resurrection path but still belongs to its creator.
    try std.testing.expectEqual(
        litura.anchors.HandleStatus.dead,
        (try engine.queryAnchor(inside)).status,
    );
    try redo(&engine);
    try undo(&engine);
    try expectHistoryInvariant(&engine);
}

test "repeated undo and redo survive mark disposal, teardown and redo discard" {
    var engine = try BufferEngine.initFromText(allocator, "abcdefghij", null);
    defer engine.deinit();
    for (0..10) |round| {
        const session, const cursor = try support.caret(&engine, 0);
        try place(&engine, session, cursor, 7, 3);
        try edit(&engine, &.{.{ .delete = .{ .start = 2, .end = 5 } }});
        // Clear the dead mark, or tear the whole session down.
        if (round % 2 == 0) try place(&engine, session, cursor, 2, null);
        if (round % 2 == 1) try support.dropSession(&engine, session);
        try undo(&engine);
        try redo(&engine);
        try undo(&engine);
        try expectText(&engine, "abcdefghij");
        try expectHistoryInvariant(&engine);
        // A new edit discards the redo branch; history must remain usable.
        try edit(&engine, &.{.{ .insert = .{ .pos = 0, .text = "-" } }});
        try undo(&engine);
        try expectHistoryInvariant(&engine);
        if (round % 2 == 0) try support.dropSession(&engine, session);
    }
}
