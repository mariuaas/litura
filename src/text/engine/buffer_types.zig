//! Borrowed intent and request payloads, and owning validation and evaluation results.

const std = @import("std");

pub const anchors = @import("anchors.zig");
pub const queries = @import("queries.zig");
pub const events = @import("events.zig");

pub const IntentId = events.IntentId;
pub const Source = events.Source;
pub const InteractionValue = events.InteractionValue;
pub const Edge = events.Edge;

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

pub const DeadAnchorRecord = struct {
    anchor: anchors.AnchorId,
    offset: u32,
    stickiness: anchors.AnchorStickiness,
    /// Public anchors may be disposed of before undo reaches the record, which then
    /// skips them; an internal one missing means the history is corrupt.
    kind: anchors.AnchorKind = .client,
};

pub const DeletionMeta = struct {
    /// Index in the undo entry's inverse_ops of the operation that restores this
    /// deletion. Offsets describe the text right after that operation, so replay
    /// resurrects the anchors immediately after it, before any later operation.
    op: u32,
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

/// Which edge of a buffer operation's inserted text an EditRef designates.
pub const EditEdge = Edge;

/// Symbolic reference to the realized result of a buffer operation in the same
/// Composite (SPEC §2.6.1). `op` indexes the composite's buffer operations in order.
/// `.end` resolves like a Sticky anchor at the end of the inserted text, `.start` like a
/// Weak anchor at its start; both are carried through later operations.
pub const EditRef = struct {
    op: u32,
    edge: EditEdge = .end,
};

/// Where an endpoint goes (SPEC §2.6.1). Every target samples a position: none creates
/// a relationship with what it names.
pub const Target = union(enum) {
    /// Coordinate-bearing: valid only at the intent's document origin.
    position: u32,
    /// The realized result of a buffer operation; composites only.
    edit: EditRef,
    /// The current position of a live public anchor; anchor-scoped.
    anchor: anchors.AnchorId,
};

pub const Move = struct {
    anchor: anchors.AnchorId,
    to: Target,
};

/// How a selection endpoint relates to the session's current endpoints.
pub const Endpoint = union(enum) {
    /// An endpoint the session owns, with its identity, position and status unchanged.
    keep: anchors.AnchorId,
    /// An endpoint the session owns, keeping its identity at a new position. Must be live.
    move: Move,
    /// A fresh endpoint anchor.
    new: Target,
};

/// One selection in a replacement list. A null `end` makes a caret: one anchor serves
/// as both endpoints.
pub const SelectionSpec = struct {
    start: Endpoint,
    end: ?Endpoint = null,
    active: Edge = .end,
};

/// Replaces a session's selection list. Every endpoint and target is resolved against
/// the same state, before any of them takes effect; endpoints the list omits are
/// released afterwards.
pub const SetSelections = struct {
    selections: []const SelectionSpec,
};

pub const WriteRegister = struct {
    key: []const u8,
    value: InteractionValue,
};

pub const ClearRegister = struct {
    key: []const u8,
};

pub const InteractionOp = union(enum) {
    set_selections: SetSelections,
    write_register: WriteRegister,
    clear_register: ClearRegister,
};

/// Operations on one session, applied in order. `origin` is the interaction revision
/// the client observed (SPEC §4.2). It is required: the mutation is rejected as stale
/// unless it equals the session's current revision, so there is no way to change a
/// session without stating which state the change was computed against.
pub const InteractionMutation = struct {
    session_id: u32,
    origin: u32,
    ops: []const InteractionOp,
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

/// Borrows payload slices, text, guards, source and label for synchronous submission.
/// Keep all referenced storage alive through the call; this record does not free it,
/// and no result refers to it afterwards.
pub const Intent = struct {
    id: IntentId,
    payload: IntentPayload,
    source: Source = .user_input,
    /// A descriptive name for the transition, echoed in its block; not causal.
    label: ?[]const u8 = null,
    /// The document revision the intent was computed against (SPEC §4.2). Required: a
    /// request built against the current document states `engine.revision`. Buffer
    /// operations, undo, redo and position-bearing interaction targets are rejected as
    /// stale unless it is current; anchor-scoped interaction mutations do not depend
    /// on it (SPEC §2.6).
    origin: u32,
    guards: []const Guard = &.{},
};

/// Creates a session (an intrinsic request). Every endpoint must be `new`, with a
/// position or anchor target. Borrowed for the call.
pub const SessionCreation = struct {
    id: IntentId,
    selections: []const SelectionSpec,
    /// The document revision the positions were computed against; it must be current.
    origin: u32,
};

/// Drops a session and releases its endpoints and registers (an intrinsic request).
pub const SessionDrop = struct {
    id: IntentId,
    session: u32,
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

/// Owns its copy of the guard and its result.
pub const GuardEval = struct {
    guard: Guard,
    result: GuardResult,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        freeGuard(allocator, self.guard);
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

/// A copy of `guard` that owns its strings, for a report that outlives the intent.
pub fn dupeGuard(allocator: std.mem.Allocator, guard: Guard) !Guard {
    return switch (guard) {
        .anchor_liveness, .range_ordering, .diagnostic_at, .no_diagnostic_at => guard,
        .slice_equality => |payload| blk: {
            var copy = payload;
            copy.expected = try allocator.dupe(u8, payload.expected);
            break :blk .{ .slice_equality = copy };
        },
        .slice_hash => |payload| blk: {
            var copy = payload;
            copy.digest = try allocator.dupe(u8, payload.digest);
            break :blk .{ .slice_hash = copy };
        },
        .semantic_token_type_at => |payload| blk: {
            var copy = payload;
            copy.type_name = try allocator.dupe(u8, payload.type_name);
            break :blk .{ .semantic_token_type_at = copy };
        },
    };
}

/// Frees a guard made by dupeGuard.
pub fn freeGuard(allocator: std.mem.Allocator, guard: Guard) void {
    switch (guard) {
        .anchor_liveness, .range_ordering, .diagnostic_at, .no_diagnostic_at => {},
        .slice_equality => |payload| allocator.free(payload.expected),
        .slice_hash => |payload| allocator.free(payload.digest),
        .semantic_token_type_at => |payload| allocator.free(payload.type_name),
    }
}

/// A rejection, owning everything it holds: the guards and results, and the message. It
/// identifies the intent instead of copying it, so it stays valid after the caller frees
/// the intent's memory. Call deinit with the engine allocator, on exactly one copy.
pub const ValidationReport = struct {
    intent: IntentId,
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

/// The outcome of one submission: the committed transition's block, or the report of
/// a rejection, which publishes nothing. Owned through the engine allocator: deinit
/// the result, or take the payload out and deinit that instead, but not both.
pub const SubmitResult = union(enum) {
    committed: events.Block,
    rejected: ValidationReport,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .committed => |*block| block.deinit(allocator),
            .rejected => |*report| report.deinit(allocator),
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

/// How the engine treats coordinate-bearing intents whose origin is behind head
/// (SPEC §6.2). Under neither policy are stale coordinates applied to text the client
/// did not observe.
pub const RebasePolicy = union(enum) {
    /// Stale coordinates are rejected as `Stale` and never interpreted.
    reject,
    /// Coordinates are rebased across at most `window` revisions; older origins are
    /// rejected as unavailable.
    rebase: struct { window: u32 },
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

/// How an engine orders intents (SPEC §6.1). A `queued` engine sequences pending
/// intents by priority and registration order. A `synchronous` engine applies each
/// submission when it is made, in call order, and accepts no priority: ordering among
/// submissions belongs to the host that makes them.
pub const Sequencing = enum { queued, synchronous };

pub const EngineCapabilities = struct {
    protocol_version: []const u8,
    supported_views: []const []const u8,
    symbol_capabilities: ?SymbolCapabilities = null,
    summary_registry: []const []const u8,
    supported_group_modes: []const []const u8,
    apply_policies: []const []const u8,
    program_carriers: []const ProgramCarrierProfile,
    rebase_policy: RebasePolicy,
    sequencing: Sequencing,
    limits: EngineLimits,
};
