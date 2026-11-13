//! Fuel-bounded native callbacks over a revision-checked document view.

const std = @import("std");
const BufferEngine = @import("buffer_engine.zig").BufferEngine;

const piece_table = @import("piece_table.zig");
const anchors = @import("anchors.zig");
const queries = @import("queries.zig");
const types = @import("buffer_types.zig");

pub const max_eval_fuel = 10_000;
pub const max_lookahead = 4_096;

const engine_supported_views = [_][]const u8{ "text", "anchors", "summaries" };
const engine_summary_registry = [_][]const u8{ "graphemes", "bytes", "newlines", "word-runs", "bracket-depth" };
const engine_apply_policies = [_][]const u8{"Strict"};
const engine_group_modes = [_][]const u8{};
const engine_program_carriers = [_]types.ProgramCarrierProfile{.{
    .kind = "zig-callback",
    .version = "v1",
    .deterministic = false,
    .fuel_model = "PrototypeOperationCount",
    .max_program_size = null,
    .notes = "Prototype callback carrier over EvalView",
}};

pub const EvalFailure = error{ FuelExhausted, EvalBounds, InvalidEvalRange };

pub const FuelMeter = struct {
    remaining: u32,

    pub fn charge(self: *@This(), amount: u32) EvalFailure!void {
        if (self.remaining < amount) {
            self.remaining = 0;
            return error.FuelExhausted;
        }
        self.remaining -= amount;
    }
};

fn validateRangeMessage(allocator: std.mem.Allocator, start: u32, end: u32, length: u32) !?[]u8 {
    if (start > end) return try std.fmt.allocPrint(allocator, "range start {d} is greater than end {d}", .{ start, end });
    if (end > length) return try std.fmt.allocPrint(allocator, "range end {d} out of range", .{end});
    return null;
}

/// Borrows a table cursor and fuel meter for one evaluation callback.
/// Operations charge fuel and enforce the selected grapheme bounds; no state may escape the call.
pub const CursorView = struct {
    cursor: piece_table.GraphemeCursor,
    meter: *FuelMeter,
    min_position: u32,
    max_position: u32,

    pub fn isValid(self: *@This()) !bool {
        try self.meter.charge(1);
        return self.cursor.valid and self.min_position <= self.cursor.position and self.cursor.position < self.max_position;
    }

    pub fn current(self: *@This()) ![]const u8 {
        try self.meter.charge(1);
        if (!self.cursor.valid or self.cursor.position < self.min_position or self.cursor.position >= self.max_position) {
            return error.EvalBounds;
        }
        return try self.cursor.current();
    }

    pub fn position(self: *@This()) !u32 {
        try self.meter.charge(1);
        return self.cursor.position;
    }

    pub fn advance(self: *@This()) !bool {
        try self.meter.charge(1);
        if (!self.cursor.valid) return false;
        if (self.cursor.position + 1 >= self.max_position) return false;
        return self.cursor.advance();
    }

    pub fn retreat(self: *@This()) !bool {
        try self.meter.charge(1);
        if (!self.cursor.valid) return false;
        if (self.cursor.position <= self.min_position) return false;
        return self.cursor.retreat();
    }
};

/// Borrows the engine and fuel meter for one callback. Text/search results are owned
/// by the caller through the engine allocator. Bounds and offsets use graphemes.
pub const View = struct {
    engine: *const BufferEngine,
    meter: *FuelMeter,
    min_position: u32,
    max_position: u32,

    fn checkPosition(self: *const @This(), position: u32, allow_end: bool) EvalFailure!void {
        const upper = if (allow_end) self.max_position else self.max_position -| 1;
        if (position < self.min_position or position > upper) return error.EvalBounds;
    }

    fn checkRange(self: *const @This(), start: u32, end: u32) EvalFailure!void {
        if (start < self.min_position or end > self.max_position) return error.EvalBounds;
        if (start > end) return error.InvalidEvalRange;
    }

    pub fn queryAnchor(self: *@This(), anchor_id: anchors.AnchorId) !queries.AnchorInfo {
        try self.meter.charge(1);
        const info = try self.engine.queryAnchor(anchor_id);
        if (info.position) |position| {
            if (position < self.min_position or position > self.max_position) return error.EvalBounds;
        }
        return info;
    }

    pub fn queryPosition(self: *@This(), pos: u32) !queries.PositionInfo {
        try self.meter.charge(1);
        try self.checkPosition(pos, true);
        return try self.engine.queryPosition(pos);
    }

    pub fn graphemeCount(self: *@This()) !u32 {
        try self.meter.charge(1);
        return self.engine.graphemeCount();
    }

    pub fn graphemeCursor(self: *@This(), position: u32) !CursorView {
        try self.meter.charge(1);
        try self.checkPosition(position, true);
        return .{
            .cursor = try self.engine.graphemeCursor(position),
            .meter = self.meter,
            .min_position = self.min_position,
            .max_position = self.max_position,
        };
    }

    pub fn getText(self: *@This(), start: ?u32, end: ?u32) ![]u8 {
        try self.meter.charge(1);
        const resolved_start = start orelse self.min_position;
        const resolved_end = end orelse self.max_position;
        try self.checkRange(resolved_start, resolved_end);
        return try self.engine.getTextRange(resolved_start, resolved_end);
    }

    pub fn findNext(self: *@This(), query: []const u8, start: u32) !?queries.SearchMatch {
        try self.meter.charge(1);
        const resolved_start = if (start == 0) self.min_position else start;
        try self.checkPosition(resolved_start, true);

        var match = (try self.engine.findNext(query, resolved_start)) orelse return null;
        if (match.start < self.min_position or match.end > self.max_position) {
            match.deinit(self.engine.allocator);
            return null;
        }
        return match;
    }
};

pub fn castView(view: *anyopaque) *View {
    return @ptrCast(@alignCast(view));
}

fn makeEvalError(allocator: std.mem.Allocator, reason: []const u8) !types.BufferEvalOutcome {
    return .{ .err = .{ .reason = try allocator.dupe(u8, reason) } };
}

pub fn queryCapabilities() types.EngineCapabilities {
    return .{
        .protocol_version = "0.1-prototype",
        .supported_views = engine_supported_views[0..],
        .symbol_capabilities = null,
        .summary_registry = engine_summary_registry[0..],
        .supported_group_modes = engine_group_modes[0..],
        .apply_policies = engine_apply_policies[0..],
        .program_carriers = engine_program_carriers[0..],
        // Litura retains no splice history: every stale origin is rejected.
        .rebase_policy = .reject,
        // `submit` applies each intent when it is called; Intent has no priority.
        .sequencing = .synchronous,
        .limits = .{
            .max_fuel = max_eval_fuel,
            .max_lookahead = max_lookahead,
            .lookahead_penalty_lambda = 1,
            .max_guard_extent = @import("buffer_validation.zig").max_guard_extent,
            .max_intent_group_size = null,
        },
    };
}

pub fn bufferEval(
    engine: *const BufferEngine,
    request: types.EvalRequest,
) !types.BufferEvalOutcome {
    if (request.interaction_revision != null and request.session_id == null) {
        return try makeEvalError(engine.allocator, "interaction_revision requires session_id");
    }
    if (request.revision != engine.revision) {
        const reason = try std.fmt.allocPrint(engine.allocator, "revision {d} is unavailable; current revision is {d}", .{ request.revision, engine.revision });
        defer engine.allocator.free(reason);
        return try makeEvalError(engine.allocator, reason);
    }
    if (request.session_id) |session_id| {
        if (!engine.sessions.contains(session_id)) {
            const reason = try std.fmt.allocPrint(engine.allocator, "unknown session id: {d}", .{session_id});
            defer engine.allocator.free(reason);
            return try makeEvalError(engine.allocator, reason);
        }
        if (request.interaction_revision) |interaction_revision| {
            const current = try engine.interactionRevision(session_id);
            if (interaction_revision != current) {
                const reason = try std.fmt.allocPrint(
                    engine.allocator,
                    "interaction revision {d} is unavailable; current revision is {d}",
                    .{ interaction_revision, current },
                );
                defer engine.allocator.free(reason);
                return try makeEvalError(engine.allocator, reason);
            }
        }
    }
    if (request.lookahead > max_lookahead) {
        const reason = try std.fmt.allocPrint(
            engine.allocator,
            "lookahead {d} exceeds max_lookahead {d}",
            .{ request.lookahead, max_lookahead },
        );
        defer engine.allocator.free(reason);
        return try makeEvalError(engine.allocator, reason);
    }
    if (request.fuel == 0) {
        return .{ .incomplete = .{ .partial = null, .fuel_remaining = 0 } };
    }
    if (request.fuel > max_eval_fuel) {
        const reason = try std.fmt.allocPrint(engine.allocator, "fuel {d} exceeds max_fuel {d}", .{ request.fuel, max_eval_fuel });
        defer engine.allocator.free(reason);
        return try makeEvalError(engine.allocator, reason);
    }

    const end = request.end orelse engine.graphemeCount();
    if (try validateRangeMessage(engine.allocator, request.start, end, engine.graphemeCount())) |message| {
        defer engine.allocator.free(message);
        return try makeEvalError(engine.allocator, message);
    }

    var meter = FuelMeter{ .remaining = request.fuel };
    var view = View{
        .engine = engine,
        .meter = &meter,
        .min_position = request.start,
        .max_position = @min(engine.graphemeCount(), end +| request.lookahead),
    };

    const value = request.program.run(request.program.ptr, @ptrCast(&view)) catch |err| switch (err) {
        error.FuelExhausted => return .{ .incomplete = .{ .partial = null, .fuel_remaining = 0 } },
        else => return try makeEvalError(engine.allocator, @errorName(err)),
    };

    return .{ .result = .{ .value = value, .fuel_remaining = meter.remaining } };
}
