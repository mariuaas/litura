//! Helpers the behavioural tests share: submitting at head, history, and sessions with a
//! caret and an optional mark.
const std = @import("std");
const litura = @import("litura");
const BufferEngine = litura.BufferEngine;
const types = litura.types;
const events = litura.events;
const AnchorId = litura.anchors.AnchorId;

/// The identity of helper-built intents and requests. The engine never interprets
/// identities; tests of correlation supply their own.
pub const id = types.IntentId{ .value = 0 };

pub fn expectText(engine: *BufferEngine, expected: []const u8) !void {
    const text = try engine.getText();
    defer engine.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

pub fn position(engine: *BufferEngine, anchor: AnchorId) !?u32 {
    return (try engine.queryAnchor(anchor)).position;
}

/// Requires a committed transition and frees the result.
pub fn expectCommitted(engine: *BufferEngine, result: *types.SubmitResult) !void {
    defer result.deinit(engine.allocator);
    try std.testing.expect(result.* == .committed);
}

/// Requires a rejection with `verdict` and `message`, and frees the result.
pub fn expectRejected(
    engine: *BufferEngine,
    result: *types.SubmitResult,
    verdict: types.ValidationVerdict,
    message: []const u8,
) !void {
    defer result.deinit(engine.allocator);
    try std.testing.expect(result.* == .rejected);
    try std.testing.expectEqual(verdict, result.rejected.verdict);
    try std.testing.expectEqualStrings(message, result.rejected.message);
}

/// Submits buffer operations at head and returns the owned block.
pub fn editBlock(engine: *BufferEngine, ops: []const types.BufferOp) !events.Block {
    var result = try engine.submit(.{
        .id = id,
        .origin = engine.revision,
        .payload = .{ .buffer_mutation = .{ .ops = ops } },
    });
    errdefer result.deinit(engine.allocator);
    try std.testing.expect(result == .committed);
    return result.committed;
}

pub fn edit(engine: *BufferEngine, ops: []const types.BufferOp) !void {
    var block = try editBlock(engine, ops);
    block.deinit(engine.allocator);
}

pub fn undo(engine: *BufferEngine) !void {
    var result = try engine.submit(
        .{ .id = id, .origin = engine.revision, .payload = .{ .undo = .{} } },
    );
    try expectCommitted(engine, &result);
}

pub fn redo(engine: *BufferEngine) !void {
    var result = try engine.submit(
        .{ .id = id, .origin = engine.revision, .payload = .{ .redo = .{} } },
    );
    try expectCommitted(engine, &result);
}

/// Creates a session with one caret at `at`; returns the session and the caret anchor.
pub fn caret(engine: *BufferEngine, at: u32) !struct { u32, AnchorId } {
    var block = try engine.createSession(.{
        .id = id,
        .origin = engine.revision,
        .selections = &.{.{ .start = .{ .new = .{ .position = at } } }},
    });
    defer block.deinit(engine.allocator);
    const created = block.lifecycle.change.session_created;
    return .{ created.session, created.selections[0].start.anchor };
}

pub fn dropSession(engine: *BufferEngine, session: u32) !void {
    var block = try engine.dropSession(.{ .id = id, .session = session });
    block.deinit(engine.allocator);
}

/// A one-selection replacement that moves `cursor` to `at`, with a fresh mark at `mark`
/// or none. Any previous mark is released.
pub fn placeSpec(cursor: AnchorId, at: types.Target, fixed_at: ?types.Target) types.SelectionSpec {
    const point: types.Endpoint = .{ .move = .{ .anchor = cursor, .to = at } };
    const fixed = fixed_at orelse return .{ .start = point };
    return .{ .start = .{ .new = fixed }, .end = point, .active = .end };
}

/// Places a one-selection session's caret, with an optional mark, as an interaction-only
/// intent at head.
pub fn place(engine: *BufferEngine, session: u32, cursor: AnchorId, at: u32, fixed_at: ?u32) !void {
    const mark_target: ?types.Target = if (fixed_at) |value| .{ .position = value } else null;
    var result = try engine.submit(.{
        .id = id,
        .origin = engine.revision,
        .payload = .{ .interaction_mutation = .{
            .session_id = session,
            .origin = try engine.interactionRevision(session),
            .ops = &.{.{ .set_selections = .{ .selections = &.{
                placeSpec(cursor, .{ .position = at }, mark_target),
            } } }},
        } },
    });
    try expectCommitted(engine, &result);
}

/// The fixed endpoint of the session's first selection, or null for a caret.
pub fn mark(engine: *BufferEngine, session: u32) !?AnchorId {
    const values = try engine.querySelections(engine.allocator, session);
    defer engine.allocator.free(values);
    const first = values[0];
    if (first.isCaret()) return null;
    return if (first.active == .end) first.start.anchor else first.end.anchor;
}
