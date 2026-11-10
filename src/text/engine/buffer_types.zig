//! Borrowed intent payloads and owning edit, validation and evaluation results.

const std = @import("std");

pub const anchors = @import("anchors.zig");
pub const queries = @import("queries.zig");

pub const Insert = struct {
    pos: u32,
    text: []const u8,
};

pub const Delete = struct {
    start: u32,
    end: u32,
};

pub const Replace = struct {
    start: u32,
    end: u32,
    text: []const u8,
};

pub const BufferOp = union(enum) {
    insert: Insert,
    delete: Delete,
    replace: Replace,
};

pub const BufferMutation = struct {
    ops: []const BufferOp,
};

pub const Range = struct {
    start: u32,
    end: u32,
};

/// Owns affected_ranges, source and cause through the engine allocator.
/// Call deinit once; copying the record does not duplicate ownership.
pub const EditEvent = struct {
    old_revision: u32,
    new_revision: u32,
    affected_ranges: []const Range,
    edit_class: []const u8,
    source: []const u8,
    cause: []const u8,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.affected_ranges);
        allocator.free(self.source);
        allocator.free(self.cause);
        self.* = undefined;
    }
};

pub const DeadAnchorRecord = struct {
    anchor: anchors.AnchorId,
    offset: u32,
    stickiness: anchors.AnchorStickiness,
};

pub const DeletionMeta = struct {
    target_anchor: anchors.AnchorId,
    inverse_text: []u8,
    dead_anchors: []const DeadAnchorRecord,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.inverse_text);
        allocator.free(self.dead_anchors);
        self.* = undefined;
    }
};

pub const UndoEntry = struct {
    forward_revs: []const u32,
    inverse_ops: []const BufferOp,
    deletion_metas: []const DeletionMeta = &.{},

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.forward_revs);
        for (self.inverse_ops) |op| {
            switch (op) {
                .insert => |ins| allocator.free(ins.text),
                .replace => |rep| allocator.free(rep.text),
                else => {},
            }
        }
        allocator.free(self.inverse_ops);
        for (self.deletion_metas) |meta| {
            var owned = meta;
            owned.deinit(allocator);
        }
        if (self.deletion_metas.len > 0) allocator.free(self.deletion_metas);
        self.* = undefined;
    }
};

pub const MoveCursorAnchor = struct {
    cursor: anchors.AnchorId,
    position: u32,
};

pub const SetCursorSelection = struct {
    cursor: anchors.AnchorId,
    mark_position: ?u32,
};

pub const InteractionOp = union(enum) {
    move_cursor_anchor: MoveCursorAnchor,
    set_cursor_selection: SetCursorSelection,
};

pub const InteractionMutation = struct {
    session_id: u32,
    ops: []const InteractionOp,
    origin: ?u32 = null,
};

pub const InteractionResult = struct {
    session_id: u32,
    old_revision: u32,
    new_revision: u32,
};

pub const Composite = struct {
    parts: []const IntentPayload,
};

pub const Undo = struct {};
pub const Redo = struct {};

pub const IntentPayload = union(enum) {
    buffer_mutation: BufferMutation,
    interaction_mutation: InteractionMutation,
    composite: Composite,
    undo: Undo,
    redo: Redo,
};

pub const PositionRef = union(enum) {
    position: u32,
    anchor: anchors.AnchorId,
};

pub const AnchorLiveness = struct {
    anchor: anchors.AnchorId,
    required: bool = true,
};

pub const RangeOrdering = struct {
    a: PositionRef,
    b: PositionRef,
    required: bool = true,
};

pub const SliceEquality = struct {
    start: PositionRef,
    end: PositionRef,
    expected: []const u8,
    max_extent: u32,
    required: bool = true,
};

pub const SliceHash = struct {
    start: PositionRef,
    end: PositionRef,
    digest: []const u8,
    max_extent: u32,
    required: bool = true,
};

pub const DiagnosticSeverity = enum(u8) {
    @"error" = 0,
    warning = 1,
    info = 2,
    hint = 3,
};

pub const DiagnosticAt = struct {
    position: PositionRef,
    severity: ?DiagnosticSeverity = null,
    required: bool = true,
};

pub const NoDiagnosticAt = struct {
    position: PositionRef,
    severity: ?DiagnosticSeverity = null,
    required: bool = true,
};

pub const SemanticTokenTypeAt = struct {
    position: PositionRef,
    type_name: []const u8,
    required: bool = true,
};

pub const ViewClass = enum(u8) {
    tokens = 0,
    syntax = 1,
    diagnostics = 2,
    semantic_tokens = 3,
    type_info = 4,
    hover = 5,
    symbols = 6,
};

pub const ViewStateKind = enum(u8) {
    available = 0,
    absent = 1,
    stale = 2,
    partial = 3,
    unavailable = 4,
};

pub const IntentClass = enum(u8) {
    positional = 0,
    anchor_scoped = 1,
    structure_guarded = 2,
    content_guarded = 3,
    view_guarded = 4,
};

pub const ValidationVerdict = enum(u8) {
    valid = 0,
    invalid = 1,
    degraded = 2,
    stale = 3,
    anchor_dead = 4,
};

pub const ViewStateSnapshot = struct {
    kind: ViewStateKind,
    revision: ?u32,
    message: []u8 = "",

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const Guard = union(enum) {
    anchor_liveness: AnchorLiveness,
    range_ordering: RangeOrdering,
    slice_equality: SliceEquality,
    slice_hash: SliceHash,
    diagnostic_at: DiagnosticAt,
    no_diagnostic_at: NoDiagnosticAt,
    semantic_token_type_at: SemanticTokenTypeAt,

    pub fn isRequired(self: @This()) bool {
        return switch (self) {
            .anchor_liveness => |payload| payload.required,
            .range_ordering => |payload| payload.required,
            .slice_equality => |payload| payload.required,
            .slice_hash => |payload| payload.required,
            .diagnostic_at => |payload| payload.required,
            .no_diagnostic_at => |payload| payload.required,
            .semantic_token_type_at => |payload| payload.required,
        };
    }

    pub fn requiredView(self: @This()) ?ViewClass {
        return switch (self) {
            .diagnostic_at, .no_diagnostic_at => .diagnostics,
            .semantic_token_type_at => .semantic_tokens,
            else => null,
        };
    }

    pub fn intentClass(self: @This()) IntentClass {
        return switch (self) {
            .anchor_liveness => .anchor_scoped,
            .range_ordering => .structure_guarded,
            .slice_equality, .slice_hash => .content_guarded,
            .diagnostic_at, .no_diagnostic_at, .semantic_token_type_at => .view_guarded,
        };
    }
};

/// Borrows payload slices, text, guards, source and cause for synchronous submission.
/// Keep all referenced storage alive through the call; this record does not free it.
pub const Intent = struct {
    payload: IntentPayload,
    source: []const u8 = "user",
    cause: []const u8 = "direct",
    origin: ?u32 = null,
    guards: []const Guard = &.{},
};

pub const GuardFail = struct {
    reason: []u8,
    dead_anchor: ?anchors.AnchorId = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
        self.* = undefined;
    }
};

pub const GuardUnavailable = struct {
    missing_view: ViewClass,
    state: ViewStateSnapshot,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.state.deinit(allocator);
        self.* = undefined;
    }
};

pub const GuardResult = union(enum) {
    pass: void,
    fail: GuardFail,
    unavailable: GuardUnavailable,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .pass => {},
            .fail => |*fail| fail.deinit(allocator),
            .unavailable => |*unavailable| unavailable.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const GuardEval = struct {
    guard: Guard,
    result: GuardResult,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

/// Owns per_guard results and message, but borrows the original intent and its inputs.
/// Call deinit with the engine allocator; it does not free the intent.
pub const ValidationReport = struct {
    intent: Intent,
    intent_class: IntentClass,
    head_revision: u32,
    interaction_revision: ?u32,
    per_guard: []GuardEval,
    verdict: ValidationVerdict,
    message: []u8,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.per_guard) |*guard_eval| guard_eval.deinit(allocator);
        allocator.free(self.per_guard);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const SubmitResult = union(enum) {
    edit_event: EditEvent,
    interaction_result: InteractionResult,
    validation_report: ValidationReport,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .edit_event => |*event| event.deinit(allocator),
            .interaction_result => {},
            .validation_report => |*report| report.deinit(allocator),
        }
        self.* = undefined;
    }
};

/// Owns text and search_match payloads; deinit releases them with the engine allocator.
/// The intent variant is borrowed and requires caller-managed backing storage.
pub const EvalValue = union(enum) {
    none: void,
    text: []u8,
    intent: Intent,
    count: u32,
    search_match: queries.SearchMatch,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .none => {},
            .intent => {},
            .count => {},
            .text => |text| allocator.free(text),
            .search_match => |*match| match.deinit(allocator),
        }
        self.* = undefined;
    }
};

/// Borrows callback state for the synchronous evaluation call.
/// The view pointer is valid only during run and casts to evaluation.View.
/// Only metered view operations consume fuel; arbitrary callback work is unbounded.
pub const EvalProgram = struct {
    ptr: ?*anyopaque = null,
    run: *const fn (ptr: ?*anyopaque, view: *anyopaque) anyerror!EvalValue,
};

pub const EvalRequest = struct {
    revision: u32,
    program: EvalProgram,
    start: u32 = 0,
    end: ?u32 = null,
    lookahead: u32 = 0,
    fuel: u32 = 1,
    session_id: ?u32 = null,
    interaction_revision: ?u32 = null,
};

pub const EvalResult = struct {
    value: EvalValue,
    fuel_remaining: u32,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

pub const EvalIncomplete = struct {
    partial: ?EvalValue,
    fuel_remaining: u32,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.partial) |*partial| partial.deinit(allocator);
        self.* = undefined;
    }
};

pub const EvalError = struct {
    reason: []u8,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
        self.* = undefined;
    }
};

pub const BufferEvalOutcome = union(enum) {
    result: EvalResult,
    incomplete: EvalIncomplete,
    err: EvalError,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .result => |*result| result.deinit(allocator),
            .incomplete => |*incomplete| incomplete.deinit(allocator),
            .err => |*eval_error| eval_error.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const ProgramCarrierProfile = struct {
    kind: []const u8,
    version: []const u8,
    deterministic: bool,
    fuel_model: []const u8,
    max_program_size: ?u32,
    notes: ?[]const u8,
};

pub const EngineLimits = struct {
    max_fuel: u32,
    max_lookahead: u32,
    lookahead_penalty_lambda: u32,
    max_guard_extent: u32,
    max_intent_group_size: ?u32,
};

pub const SymbolCapabilities = struct {
    definition: bool,
    references: bool,
    rename: bool,
};

pub const EngineCapabilities = struct {
    protocol_version: []const u8,
    supported_views: []const []const u8,
    symbol_capabilities: ?SymbolCapabilities = null,
    summary_registry: []const []const u8,
    supported_group_modes: []const []const u8,
    apply_policies: []const []const u8,
    program_carriers: []const ProgramCarrierProfile,
    limits: EngineLimits,
};
