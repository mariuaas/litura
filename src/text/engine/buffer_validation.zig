//! Document-specific intent preflight, guard evaluation and rejection reports.

const std = @import("std");
const BufferEngine = @import("buffer_engine.zig").BufferEngine;
const views = @import("views.zig");

const anchors = @import("anchors.zig");
const types = @import("buffer_types.zig");

pub const max_guard_extent = 4_096;

const ResolvedPositionRef = struct {
    position: ?u32 = null,
    dead_anchor: ?anchors.AnchorId = null,
    reason: ?[]u8 = null,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.reason) |reason| allocator.free(reason);
        self.* = undefined;
    }
};

const ResolvedRange = struct {
    start: ?u32 = null,
    end: ?u32 = null,
    dead_anchor: ?anchors.AnchorId = null,
    reason: ?[]u8 = null,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.reason) |reason| allocator.free(reason);
        self.* = undefined;
    }
};

fn makeGuardPass(guard: types.Guard) types.GuardEval {
    return .{
        .guard = guard,
        .result = .{ .pass = {} },
    };
}

fn snapshotViewState(engine: *const BufferEngine, state: views.ViewState) !types.ViewStateSnapshot {
    return .{
        .kind = switch (state.kind) {
            .available => .available,
            .absent => .absent,
            .stale => .stale,
            .partial => .partial,
            .unavailable => .unavailable,
        },
        .revision = state.revision,
        .message = try engine.allocator.dupe(u8, state.message),
    };
}

fn makeGuardFail(
    engine: *const BufferEngine,
    guard: types.Guard,
    reason: []const u8,
    dead_anchor: ?anchors.AnchorId,
) !types.GuardEval {
    return .{
        .guard = guard,
        .result = .{ .fail = .{
            .reason = try engine.allocator.dupe(u8, reason),
            .dead_anchor = dead_anchor,
        } },
    };
}

fn makeGuardUnavailable(
    engine: *const BufferEngine,
    guard: types.Guard,
    missing_view: types.ViewClass,
    state: views.ViewState,
) !types.GuardEval {
    return .{
        .guard = guard,
        .result = .{ .unavailable = .{
            .missing_view = missing_view,
            .state = try snapshotViewState(engine, state),
        } },
    };
}

fn derivedIntentClass(intent: types.Intent) types.IntentClass {
    var current: types.IntentClass = .positional;
    for (intent.guards) |guard| {
        if (!guard.isRequired()) continue;
        const next = guard.intentClass();
        if (@intFromEnum(next) > @intFromEnum(current)) current = next;
    }
    return current;
}

fn interactionRevisionForPayloads(
    engine: *const BufferEngine,
    payloads: []const types.IntentPayload,
) ?u32 {
    for (payloads) |payload| {
        switch (payload) {
            .interaction_mutation => |interaction| return engine.interactionRevision(interaction.session_id) catch null,
            .composite => |composite| if (interactionRevisionForPayloads(engine, composite.parts)) |revision| return revision,
            else => {},
        }
    }
    return null;
}

fn interactionRevisionForIntent(engine: *const BufferEngine, intent: types.Intent) ?u32 {
    return switch (intent.payload) {
        .interaction_mutation => |payload| engine.interactionRevision(payload.session_id) catch null,
        .composite => |payload| interactionRevisionForPayloads(engine, payload.parts),
        else => null,
    };
}

pub fn validationReport(
    engine: *const BufferEngine,
    intent: types.Intent,
    verdict: types.ValidationVerdict,
    message: []const u8,
    per_guard: []types.GuardEval,
) !types.ValidationReport {
    return .{
        .intent = intent,
        .intent_class = derivedIntentClass(intent),
        .head_revision = engine.revision,
        .interaction_revision = interactionRevisionForIntent(engine, intent),
        .per_guard = per_guard,
        .verdict = verdict,
        .message = try engine.allocator.dupe(u8, message),
    };
}

pub fn validationReportForGuards(
    engine: *const BufferEngine,
    intent: types.Intent,
) !?types.ValidationReport {
    if (intent.guards.len == 0) return null;

    var per_guard = try std.ArrayListUnmanaged(types.GuardEval).initCapacity(engine.allocator, intent.guards.len);
    errdefer {
        for (per_guard.items) |*guard_eval| guard_eval.deinit(engine.allocator);
        per_guard.deinit(engine.allocator);
    }

    var failed_reason: ?[]const u8 = null;
    var anchor_dead = false;
    var unavailable_message: ?[]u8 = null;
    defer if (unavailable_message) |message| engine.allocator.free(message);

    for (intent.guards) |guard| {
        const guard_eval = try evaluateGuard(engine, guard);
        if (failed_reason == null and unavailable_message == null) {
            switch (guard_eval.result) {
                .pass => {},
                .fail => |fail| {
                    failed_reason = fail.reason;
                    anchor_dead = fail.dead_anchor != null;
                },
                .unavailable => |unavailable| {
                    unavailable_message = try std.fmt.allocPrint(
                        engine.allocator,
                        "{s} view is {s}",
                        .{ viewClassName(unavailable.missing_view), viewStateKindName(unavailable.state.kind) },
                    );
                },
            }
        }
        try per_guard.append(engine.allocator, guard_eval);
    }

    if (failed_reason == null and unavailable_message == null) {
        for (per_guard.items) |*guard_eval| guard_eval.deinit(engine.allocator);
        per_guard.deinit(engine.allocator);
        return null;
    }

    const owned_per_guard = try per_guard.toOwnedSlice(engine.allocator);
    errdefer {
        for (owned_per_guard) |*guard_eval| guard_eval.deinit(engine.allocator);
        engine.allocator.free(owned_per_guard);
    }

    return try validationReport(
        engine,
        intent,
        if (failed_reason != null)
            (if (anchor_dead) .anchor_dead else .invalid)
        else
            .degraded,
        if (failed_reason != null) failed_reason.? else unavailable_message.?,
        owned_per_guard,
    );
}

fn viewClassName(view_class: types.ViewClass) []const u8 {
    return switch (view_class) {
        .tokens => "tokens",
        .syntax => "syntax",
        .diagnostics => "diagnostics",
        .semantic_tokens => "semantic_tokens",
        .type_info => "type_info",
        .hover => "hover",
        .symbols => "symbols",
    };
}

fn viewStateKindName(kind: types.ViewStateKind) []const u8 {
    return switch (kind) {
        .available => "available",
        .absent => "absent",
        .stale => "stale",
        .partial => "partial",
        .unavailable => "unavailable",
    };
}

fn diagnosticOverlapsPosition(diagnostic: views.Diagnostic, position: u32) bool {
    if (diagnostic.start == diagnostic.end) return diagnostic.start == position;
    return diagnostic.start <= position and position < diagnostic.end;
}

fn semanticTokenContainsPosition(token: views.SemanticToken, position: u32) bool {
    if (token.start == token.end) return token.start == position;
    return token.start <= position and position < token.end;
}

fn evaluateGuard(engine: *const BufferEngine, guard: types.Guard) !types.GuardEval {
    return switch (guard) {
        .anchor_liveness => |payload| blk: {
            const anchor = engine.anchors_map.get(payload.anchor.value) orelse {
                const reason = try std.fmt.allocPrint(engine.allocator, "unknown anchor id: {d}", .{payload.anchor.value});
                defer engine.allocator.free(reason);
                break :blk try makeGuardFail(engine, guard, reason, null);
            };
            if (anchor.status == .dead) {
                const reason = try std.fmt.allocPrint(engine.allocator, "anchor {d} is not live", .{payload.anchor.value});
                defer engine.allocator.free(reason);
                break :blk try makeGuardFail(engine, guard, reason, payload.anchor);
            }
            break :blk makeGuardPass(guard);
        },
        .range_ordering => |payload| blk: {
            var left = try resolveGuardPositionRef(engine, payload.a);
            defer left.deinit(engine.allocator);
            var right = try resolveGuardPositionRef(engine, payload.b);
            defer right.deinit(engine.allocator);

            const dead_anchor = left.dead_anchor orelse right.dead_anchor;
            if (left.reason) |reason| break :blk try makeGuardFail(engine, guard, reason, dead_anchor);
            if (right.reason) |reason| break :blk try makeGuardFail(engine, guard, reason, dead_anchor);
            if (dead_anchor) |anchor_id| {
                const reason = try std.fmt.allocPrint(engine.allocator, "anchor {d} is not live", .{anchor_id.value});
                defer engine.allocator.free(reason);
                break :blk try makeGuardFail(engine, guard, reason, anchor_id);
            }

            if (left.position.? <= right.position.?) {
                break :blk makeGuardPass(guard);
            }

            const reason = try std.fmt.allocPrint(engine.allocator, "range ordering failed: {d} > {d}", .{ left.position.?, right.position.? });
            defer engine.allocator.free(reason);
            break :blk try makeGuardFail(engine, guard, reason, null);
        },
        .slice_equality => |payload| blk: {
            var resolved = try resolveGuardRange(engine, payload.start, payload.end);
            defer resolved.deinit(engine.allocator);

            if (resolved.reason) |reason| break :blk try makeGuardFail(engine, guard, reason, resolved.dead_anchor);
            if (resolved.dead_anchor) |anchor_id| {
                const reason = try std.fmt.allocPrint(engine.allocator, "anchor {d} is not live", .{anchor_id.value});
                defer engine.allocator.free(reason);
                break :blk try makeGuardFail(engine, guard, reason, anchor_id);
            }

            const extent = resolved.end.? - resolved.start.?;
            if (payload.max_extent > max_guard_extent) {
                const reason = try std.fmt.allocPrint(
                    engine.allocator,
                    "guard max_extent {d} exceeds engine max_guard_extent {d}",
                    .{ payload.max_extent, max_guard_extent },
                );
                defer engine.allocator.free(reason);
                break :blk try makeGuardFail(engine, guard, reason, null);
            }
            if (extent > payload.max_extent) {
                const reason = try std.fmt.allocPrint(
                    engine.allocator,
                    "guard range extent {d} exceeds max_extent {d}",
                    .{ extent, payload.max_extent },
                );
                defer engine.allocator.free(reason);
                break :blk try makeGuardFail(engine, guard, reason, null);
            }

            const actual = try engine.table.getTextRange(resolved.start.?, resolved.end.?);
            defer engine.allocator.free(actual);
            if (std.mem.eql(u8, actual, payload.expected)) {
                break :blk makeGuardPass(guard);
            }

            break :blk try makeGuardFail(engine, guard, "slice equality failed", null);
        },
        .slice_hash => |payload| blk: {
            var resolved = try resolveGuardRange(engine, payload.start, payload.end);
            defer resolved.deinit(engine.allocator);

            if (resolved.reason) |reason| break :blk try makeGuardFail(engine, guard, reason, resolved.dead_anchor);
            if (resolved.dead_anchor) |anchor_id| {
                const reason = try std.fmt.allocPrint(engine.allocator, "anchor {d} is not live", .{anchor_id.value});
                defer engine.allocator.free(reason);
                break :blk try makeGuardFail(engine, guard, reason, anchor_id);
            }

            const extent = resolved.end.? - resolved.start.?;
            if (payload.max_extent > max_guard_extent) {
                const reason = try std.fmt.allocPrint(
                    engine.allocator,
                    "guard max_extent {d} exceeds engine max_guard_extent {d}",
                    .{ payload.max_extent, max_guard_extent },
                );
                defer engine.allocator.free(reason);
                break :blk try makeGuardFail(engine, guard, reason, null);
            }
            if (extent > payload.max_extent) {
                const reason = try std.fmt.allocPrint(
                    engine.allocator,
                    "guard range extent {d} exceeds max_extent {d}",
                    .{ extent, payload.max_extent },
                );
                defer engine.allocator.free(reason);
                break :blk try makeGuardFail(engine, guard, reason, null);
            }

            const digest = try xxh64Digest(engine, resolved.start.?, resolved.end.?);
            if (std.mem.eql(u8, digest[0..], payload.digest)) {
                break :blk makeGuardPass(guard);
            }

            break :blk try makeGuardFail(engine, guard, "slice hash failed", null);
        },
        .diagnostic_at => |payload| blk: {
            var resolved = try resolveGuardPositionRef(engine, payload.position);
            defer resolved.deinit(engine.allocator);

            if (resolved.reason) |reason| break :blk try makeGuardFail(engine, guard, reason, resolved.dead_anchor);
            if (resolved.dead_anchor) |anchor_id| {
                const reason = try std.fmt.allocPrint(engine.allocator, "anchor {d} is not live", .{anchor_id.value});
                defer engine.allocator.free(reason);
                break :blk try makeGuardFail(engine, guard, reason, anchor_id);
            }

            const state = engine.queryViewState("diagnostics");
            if (state.kind != .available) {
                break :blk try makeGuardUnavailable(engine, guard, .diagnostics, state);
            }

            const start = resolved.position.?;
            const end = if (start < engine.table.graphemeCount()) start + 1 else start;
            const diagnostics = try engine.queryDiagnosticList(start, end, null);
            defer engine.allocator.free(diagnostics);

            for (diagnostics) |diagnostic| {
                if (!diagnosticOverlapsPosition(diagnostic, start)) continue;
                if (payload.severity) |severity| {
                    if (diagnostic.severity != @intFromEnum(severity)) continue;
                }
                break :blk makeGuardPass(guard);
            }

            break :blk try makeGuardFail(engine, guard, "diagnostic guard failed", null);
        },
        .no_diagnostic_at => |payload| blk: {
            var resolved = try resolveGuardPositionRef(engine, payload.position);
            defer resolved.deinit(engine.allocator);

            if (resolved.reason) |reason| break :blk try makeGuardFail(engine, guard, reason, resolved.dead_anchor);
            if (resolved.dead_anchor) |anchor_id| {
                const reason = try std.fmt.allocPrint(engine.allocator, "anchor {d} is not live", .{anchor_id.value});
                defer engine.allocator.free(reason);
                break :blk try makeGuardFail(engine, guard, reason, anchor_id);
            }

            const state = engine.queryViewState("diagnostics");
            if (state.kind != .available) {
                break :blk try makeGuardUnavailable(engine, guard, .diagnostics, state);
            }

            const start = resolved.position.?;
            const end = if (start < engine.table.graphemeCount()) start + 1 else start;
            const diagnostics = try engine.queryDiagnosticList(start, end, null);
            defer engine.allocator.free(diagnostics);

            for (diagnostics) |diagnostic| {
                if (!diagnosticOverlapsPosition(diagnostic, start)) continue;
                if (payload.severity) |severity| {
                    if (diagnostic.severity != @intFromEnum(severity)) continue;
                }
                break :blk try makeGuardFail(engine, guard, "diagnostic guard failed", null);
            }

            break :blk makeGuardPass(guard);
        },
        .semantic_token_type_at => |payload| blk: {
            var resolved = try resolveGuardPositionRef(engine, payload.position);
            defer resolved.deinit(engine.allocator);

            if (resolved.reason) |reason| break :blk try makeGuardFail(engine, guard, reason, resolved.dead_anchor);
            if (resolved.dead_anchor) |anchor_id| {
                const reason = try std.fmt.allocPrint(engine.allocator, "anchor {d} is not live", .{anchor_id.value});
                defer engine.allocator.free(reason);
                break :blk try makeGuardFail(engine, guard, reason, anchor_id);
            }

            const state = engine.queryViewState("semantic_tokens");
            if (state.kind != .available) {
                break :blk try makeGuardUnavailable(engine, guard, .semantic_tokens, state);
            }

            const start = resolved.position.?;
            const end = if (start < engine.table.graphemeCount()) start + 1 else start;
            const tokens = try engine.querySemanticTokens(start, end, null);
            defer engine.allocator.free(tokens);

            for (tokens) |token| {
                if (!semanticTokenContainsPosition(token, start)) continue;
                if (std.mem.eql(u8, token.type_name, payload.type_name)) {
                    break :blk makeGuardPass(guard);
                }
                break :blk try makeGuardFail(engine, guard, "semantic token guard failed", null);
            }

            break :blk try makeGuardFail(engine, guard, "semantic token guard failed", null);
        },
    };
}

fn resolveGuardRange(
    engine: *const BufferEngine,
    start_ref: types.PositionRef,
    end_ref: types.PositionRef,
) !ResolvedRange {
    var start = try resolveGuardPositionRef(engine, start_ref);
    defer start.deinit(engine.allocator);
    var end = try resolveGuardPositionRef(engine, end_ref);
    defer end.deinit(engine.allocator);

    const dead_anchor = start.dead_anchor orelse end.dead_anchor;
    if (start.reason) |reason| {
        return .{ .dead_anchor = dead_anchor, .reason = try engine.allocator.dupe(u8, reason) };
    }
    if (end.reason) |reason| {
        return .{ .dead_anchor = dead_anchor, .reason = try engine.allocator.dupe(u8, reason) };
    }
    if (dead_anchor != null) {
        return .{ .dead_anchor = dead_anchor };
    }
    if (start.position.? > end.position.?) {
        return .{ .reason = try std.fmt.allocPrint(engine.allocator, "range start {d} is greater than end {d}", .{ start.position.?, end.position.? }) };
    }

    return .{ .start = start.position.?, .end = end.position.? };
}

fn resolveGuardPositionRef(
    engine: *const BufferEngine,
    ref: types.PositionRef,
) !ResolvedPositionRef {
    return switch (ref) {
        .position => |position| blk: {
            if (position > engine.table.graphemeCount()) {
                break :blk .{ .reason = try std.fmt.allocPrint(engine.allocator, "position {d} out of range", .{position}) };
            }
            break :blk .{ .position = position };
        },
        .anchor => |anchor_id| blk: {
            const anchor = engine.anchors_map.get(anchor_id.value) orelse {
                break :blk .{ .reason = try std.fmt.allocPrint(engine.allocator, "unknown anchor id: {d}", .{anchor_id.value}) };
            };
            if (anchor.status == .dead) {
                break :blk .{ .dead_anchor = anchor_id };
            }
            break :blk .{ .position = anchor.position };
        },
    };
}

fn xxh64Digest(engine: *const BufferEngine, start: u32, end: u32) ![8]u8 {
    const text = try engine.table.getTextRange(start, end);
    defer engine.allocator.free(text);
    return std.mem.toBytes(std.hash.XxHash64.hash(0, text));
}

pub fn validationReportForStaleBufferOrigin(
    engine: *const BufferEngine,
    intent: types.Intent,
) !?types.ValidationReport {
    const origin = intent.origin orelse return null;
    if (origin == engine.revision) return null;

    const message = try std.fmt.allocPrint(
        engine.allocator,
        "buffer revision {d} is stale; current revision is {d}",
        .{ origin, engine.revision },
    );
    defer engine.allocator.free(message);
    return try validationReport(engine, intent, .stale, message, try engine.allocator.alloc(types.GuardEval, 0));
}

pub fn validationReportForStaleInteractionOrigin(
    engine: *const BufferEngine,
    intent: types.Intent,
    payload: types.InteractionMutation,
) !?types.ValidationReport {
    const origin = payload.origin orelse return null;
    const current_revision = engine.interactionRevision(payload.session_id) catch {
        const message = try std.fmt.allocPrint(engine.allocator, "unknown session id: {d}", .{payload.session_id});
        defer engine.allocator.free(message);
        return try validationReport(engine, intent, .invalid, message, try engine.allocator.alloc(types.GuardEval, 0));
    };
    if (origin == current_revision) return null;

    const message = try std.fmt.allocPrint(
        engine.allocator,
        "interaction revision {d} is stale; current revision is {d}",
        .{ origin, current_revision },
    );
    defer engine.allocator.free(message);
    return try validationReport(engine, intent, .stale, message, try engine.allocator.alloc(types.GuardEval, 0));
}

fn validateSimulatedRangeMessage(
    allocator: std.mem.Allocator,
    start: u32,
    end: u32,
    length: u32,
) !?[]u8 {
    if (start > end) return try std.fmt.allocPrint(allocator, "range start {d} is greater than end {d}", .{ start, end });
    if (end > length) return try std.fmt.allocPrint(allocator, "range end {d} out of range", .{end});
    return null;
}

fn countGraphemes(engine: *const BufferEngine, text: []const u8) u32 {
    var count: u32 = 0;
    var iter = engine.table.seg.iterator(text);
    while (iter.next() != null) count += 1;
    return count;
}

pub fn validateBufferOpsAgainstLength(
    engine: *const BufferEngine,
    ops: []const types.BufferOp,
    initial_length: u32,
) !?[]u8 {
    var length = initial_length;
    if (ops.len == 0) return try engine.allocator.dupe(u8, "apply requires at least one operation");

    for (ops) |op| {
        switch (op) {
            .insert => |ins| {
                if (ins.pos > length) return try std.fmt.allocPrint(engine.allocator, "position {d} out of range", .{ins.pos});
                length += countGraphemes(engine, ins.text);
            },
            .delete => |del| {
                if (try validateSimulatedRangeMessage(engine.allocator, del.start, del.end, length)) |message| return message;
                length -= del.end - del.start;
            },
            .replace => |rep| {
                if (try validateSimulatedRangeMessage(engine.allocator, rep.start, rep.end, length)) |message| return message;
                length = length - (rep.end - rep.start) + countGraphemes(engine, rep.text);
            },
        }
    }

    return null;
}

pub fn validateBufferOpsIntoLength(
    engine: *const BufferEngine,
    ops: []const types.BufferOp,
    working_length: *u32,
) !?[]u8 {
    if (ops.len == 0) return try engine.allocator.dupe(u8, "apply requires at least one operation");

    for (ops) |op| {
        switch (op) {
            .insert => |ins| {
                if (ins.pos > working_length.*) return try std.fmt.allocPrint(engine.allocator, "position {d} out of range", .{ins.pos});
                working_length.* += countGraphemes(engine, ins.text);
            },
            .delete => |del| {
                if (try validateSimulatedRangeMessage(engine.allocator, del.start, del.end, working_length.*)) |message| return message;
                working_length.* -= del.end - del.start;
            },
            .replace => |rep| {
                if (try validateSimulatedRangeMessage(engine.allocator, rep.start, rep.end, working_length.*)) |message| return message;
                working_length.* = working_length.* - (rep.end - rep.start) + countGraphemes(engine, rep.text);
            },
        }
    }

    return null;
}

fn validateInteractionCursor(
    engine: *const BufferEngine,
    session_id: u32,
    cursor_anchor: anchors.AnchorId,
) !void {
    if (engine.sessions.get(session_id)) |sess| {
        for (sess.interaction.cursors.items) |cursor| {
            if (cursor.anchor.value == cursor_anchor.value) return;
        }
    }
    return error.KeyError;
}

pub fn validateInteractionMutation(
    engine: *const BufferEngine,
    payload: types.InteractionMutation,
    max_position: u32,
) !?[]u8 {
    if (payload.ops.len == 0) return try engine.allocator.dupe(u8, "interaction mutation requires at least one operation");

    for (payload.ops) |op| {
        switch (op) {
            .move_cursor_anchor => |move| {
                validateInteractionCursor(engine, payload.session_id, move.cursor) catch {
                    return try std.fmt.allocPrint(
                        engine.allocator,
                        "cursor {d} is not part of session {d}",
                        .{ move.cursor.value, payload.session_id },
                    );
                };
                if (move.position > max_position) return try std.fmt.allocPrint(engine.allocator, "position {d} out of range", .{move.position});
            },
            .set_cursor_selection => |selection| {
                validateInteractionCursor(engine, payload.session_id, selection.cursor) catch {
                    return try std.fmt.allocPrint(
                        engine.allocator,
                        "cursor {d} is not part of session {d}",
                        .{ selection.cursor.value, payload.session_id },
                    );
                };
                if (selection.mark_position) |mark_position| {
                    if (mark_position > max_position) return try std.fmt.allocPrint(engine.allocator, "position {d} out of range", .{mark_position});
                }
            },
        }
    }

    return null;
}

pub fn flattenCompositeParts(
    allocator: std.mem.Allocator,
    payloads: []const types.IntentPayload,
) ![]types.IntentPayload {
    var parts = std.ArrayListUnmanaged(types.IntentPayload).empty;
    errdefer parts.deinit(allocator);

    for (payloads) |payload| {
        switch (payload) {
            .composite => |composite| {
                const nested = try flattenCompositeParts(allocator, composite.parts);
                defer allocator.free(nested);
                try parts.appendSlice(allocator, nested);
            },
            else => try parts.append(allocator, payload),
        }
    }

    return parts.toOwnedSlice(allocator);
}

fn testProviderDeinitNoop(_: *anyopaque, _: std.mem.Allocator) void {}

test "guard validation passes for live guards" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "hello world", null);
    defer engine.deinit();

    const left = try engine.createAnchor(1, .sticky);
    const right = try engine.createAnchor(4, .sticky);
    const digest = try xxh64Digest(&engine, 0, 5);

    const guards = [_]types.Guard{
        .{ .anchor_liveness = .{ .anchor = left } },
        .{ .range_ordering = .{ .a = .{ .anchor = left }, .b = .{ .anchor = right } } },
        .{ .slice_equality = .{ .start = .{ .position = 0 }, .end = .{ .position = 5 }, .expected = "hello", .max_extent = 8 } },
        .{ .slice_hash = .{ .start = .{ .position = 0 }, .end = .{ .position = 5 }, .digest = digest[0..], .max_extent = 8 } },
    };

    const intent = types.Intent{ .payload = .{ .buffer_mutation = .{ .ops = &.{} } }, .guards = &guards };
    try std.testing.expectEqual(@as(?types.ValidationReport, null), try validationReportForGuards(&engine, intent));
}

test "guard validation reports dead anchor" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "abcde", null);
    defer engine.deinit();

    const anchor_id = try engine.createAnchor(2, .weak);
    const ops = [_]types.BufferOp{.{ .delete = .{ .start = 1, .end = 4 } }};
    try engine.applyOps(&ops, "test", "direct");

    const guards = [_]types.Guard{
        .{ .anchor_liveness = .{ .anchor = anchor_id } },
    };
    const intent = types.Intent{ .payload = .{ .buffer_mutation = .{ .ops = &.{} } }, .guards = &guards };
    var report = (try validationReportForGuards(&engine, intent)).?;
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(types.ValidationVerdict.anchor_dead, report.verdict);
    try std.testing.expectEqualStrings("anchor 1 is not live", report.message);
    try std.testing.expectEqual(@as(usize, 1), report.per_guard.len);
    switch (report.per_guard[0].result) {
        .pass => return error.TestUnexpectedResult,
        .fail => |fail| try std.testing.expectEqual(anchor_id.value, fail.dead_anchor.?.value),
        .unavailable => return error.TestUnexpectedResult,
    }
}

test "guard validation rejects oversized slice extent" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "hello", null);
    defer engine.deinit();

    const guards = [_]types.Guard{
        .{ .slice_equality = .{ .start = .{ .position = 0 }, .end = .{ .position = 5 }, .expected = "hello", .max_extent = 2 } },
    };
    const intent = types.Intent{ .payload = .{ .buffer_mutation = .{ .ops = &.{} } }, .guards = &guards };
    var report = (try validationReportForGuards(&engine, intent)).?;
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(types.ValidationVerdict.invalid, report.verdict);
    try std.testing.expectEqualStrings("guard range extent 5 exceeds max_extent 2", report.message);
}

test "advisory view guard degrades without elevating intent class" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "abc", null);
    defer engine.deinit();

    const guards = [_]types.Guard{
        .{ .diagnostic_at = .{ .position = .{ .position = 0 }, .required = false } },
    };
    const intent = types.Intent{ .payload = .{ .buffer_mutation = .{ .ops = &.{} } }, .guards = &guards };
    var report = (try validationReportForGuards(&engine, intent)).?;
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(types.IntentClass.positional, report.intent_class);
    try std.testing.expectEqual(types.ValidationVerdict.degraded, report.verdict);
    switch (report.per_guard[0].result) {
        .unavailable => |unavailable| {
            try std.testing.expectEqual(types.ViewClass.diagnostics, unavailable.missing_view);
            try std.testing.expectEqual(types.ViewStateKind.absent, unavailable.state.kind);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "optional view guards evaluate against available diagnostics and semantic tokens" {
    const GuardProvider = struct {
        const token_modifiers = [_][]const u8{"declaration"};

        fn provider(_: *@This()) views.ViewProvider {
            return .{ .ptr = undefined, .vtable = &vtable };
        }

        fn stateFor(_: *anyopaque, view: []const u8, revision: u32) views.ViewState {
            if (std.mem.eql(u8, view, "diagnostics") or std.mem.eql(u8, view, "semantic_tokens")) {
                return .{ .view = view, .revision = revision, .kind = .available };
            }
            return views.ViewState.absent(view, revision);
        }

        fn refresh(_: *anyopaque, engine_ptr: *anyopaque) views.ViewState {
            const engine_ptr_typed: *BufferEngine = @ptrCast(@alignCast(engine_ptr));
            return .{ .view = "diagnostics", .revision = engine_ptr_typed.revision, .kind = .available };
        }

        fn onBufferEvent(_: *anyopaque, _: *anyopaque, _: *anyopaque) void {}

        fn tokenSpans(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            _: *anyopaque,
            _: u32,
            _: u32,
            _: u32,
        ) ![]const views.TokenSpan {
            return try allocator.alloc(views.TokenSpan, 0);
        }

        fn diagnosticList(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            _: *anyopaque,
            start: ?u32,
            end: ?u32,
            _: u32,
        ) ![]const views.Diagnostic {
            const diagnostics = try allocator.alloc(views.Diagnostic, 1);
            diagnostics[0] = .{
                .start = 0,
                .end = 1,
                .severity = @intFromEnum(types.DiagnosticSeverity.@"error"),
                .source = "test",
                .message = "problem",
            };
            if (start != null and end != null and !(diagnostics[0].start < end.? and start.? < diagnostics[0].end)) {
                allocator.free(diagnostics);
                return try allocator.alloc(views.Diagnostic, 0);
            }
            return diagnostics;
        }

        fn semanticTokens(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            _: *anyopaque,
            start: u32,
            end: u32,
            _: u32,
        ) ![]const views.SemanticToken {
            if (!(@max(@as(u32, 0), start) < @min(@as(u32, 1), end))) {
                return try allocator.alloc(views.SemanticToken, 0);
            }
            const tokens = try allocator.alloc(views.SemanticToken, 1);
            tokens[0] = .{
                .start = 0,
                .end = 1,
                .type_name = "variable",
                .modifiers = token_modifiers[0..],
            };
            return tokens;
        }

        fn enclosingNode(_: *anyopaque, _: *anyopaque, _: u32, _: u32) ?views.SyntaxNodeInfo {
            return null;
        }

        fn nodeInfo(
            _: *anyopaque,
            _: *anyopaque,
            _: views.SyntaxNodeRef,
        ) anyerror!views.SyntaxNodeInfo {
            return error.KeyError;
        }

        fn typeAt(_: *anyopaque, _: *anyopaque, _: u32, _: u32) anyerror!?views.TypeInfo {
            return null;
        }

        fn hoverAt(_: *anyopaque, _: *anyopaque, _: u32, _: u32) anyerror!?views.HoverInfo {
            return null;
        }

        fn symbolCapabilities(_: *anyopaque) ?types.SymbolCapabilities {
            return null;
        }

        fn definition(
            _: *anyopaque,
            _: *anyopaque,
            _: u32,
            _: u32,
        ) anyerror!views.DefinitionResult {
            return .not_supported;
        }

        fn references(
            _: *anyopaque,
            _: *anyopaque,
            _: u32,
            _: u32,
        ) anyerror!views.ReferencesResult {
            return .not_supported;
        }

        fn renamePrepare(
            _: *anyopaque,
            _: *anyopaque,
            _: u32,
            _: u32,
        ) anyerror!views.RenamePrepareResult {
            return .not_supported;
        }

        const vtable = views.ViewProvider.VTable{
            .name = "guard-provider",
            .views = &[_][]const u8{ "diagnostics", "semantic_tokens" },
            .deinitFn = testProviderDeinitNoop,
            .stateForFn = stateFor,
            .refreshFn = refresh,
            .onBufferEventFn = onBufferEvent,
            .tokenSpansFn = tokenSpans,
            .diagnosticListFn = diagnosticList,
            .semanticTokensFn = semanticTokens,
            .enclosingNodeFn = enclosingNode,
            .nodeInfoFn = nodeInfo,
            .typeAtFn = typeAt,
            .hoverAtFn = hoverAt,
            .symbolCapabilitiesFn = symbolCapabilities,
            .definitionFn = definition,
            .referencesFn = references,
            .renamePrepareFn = renamePrepare,
        };
    };

    var engine = try BufferEngine.initFromText(std.testing.allocator, "abc", null);
    defer engine.deinit();
    var provider = GuardProvider{};
    try engine.registerViewProvider(provider.provider());

    const passing = [_]types.Guard{
        .{ .diagnostic_at = .{ .position = .{ .position = 0 }, .severity = .@"error" } },
        .{ .semantic_token_type_at = .{ .position = .{ .position = 0 }, .type_name = "variable" } },
    };
    try std.testing.expectEqual(@as(?types.ValidationReport, null), try validationReportForGuards(&engine, .{
        .payload = .{ .buffer_mutation = .{ .ops = &.{} } },
        .guards = &passing,
    }));

    const failing = [_]types.Guard{
        .{ .no_diagnostic_at = .{ .position = .{ .position = 0 } } },
    };
    var report = (try validationReportForGuards(&engine, .{
        .payload = .{ .buffer_mutation = .{ .ops = &.{} } },
        .guards = &failing,
    })).?;
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(types.IntentClass.view_guarded, report.intent_class);
    try std.testing.expectEqual(types.ValidationVerdict.invalid, report.verdict);
}
