//! Owning document state: revisions, sessions, guarded edits, shared history, and the
//! publication of every transition as a block.

const std = @import("std");
const log = std.log.scoped(.litura);

const piece_table = @import("piece_table.zig");
const anchors = @import("anchors.zig");
const queries = @import("queries.zig");
const views = @import("views.zig");

const types = @import("buffer_types.zig");
const events = @import("events.zig");
const validation = @import("buffer_validation.zig");
const evaluation = @import("buffer_eval.zig");
const interaction = @import("interaction.zig");
const session_state = @import("session.zig");

pub const Session = session_state.Session;

/// How intrinsic requests (anchor and session creation and disposal; SPEC §0.1) fail.
/// They are synchronous and carry no guards, so a failure is an error to the caller,
/// not a ValidationReport. Either way nothing is published, no sequence number is
/// consumed and no identity is issued.
pub const RequestError = error{
    /// Called from a view provider's notification.
    ReentrantMutation,
    OutOfMemory,
    /// A position beyond the end of the document.
    OutOfRange,
    /// A malformed request: an empty selection list, an endpoint other than `new`, an
    /// edit reference, or an anchor target that is not live.
    InvalidArgument,
    /// The request's origin is not the current document revision.
    StaleOrigin,
    /// The identifier names no session, or was never issued as a public anchor.
    KeyError,
    /// The anchor is a session endpoint; only its session releases it.
    AnchorOwned,
};
pub const Selection = session_state.Selection;

/// Owns text, anchors, sessions, history, paths and registered provider lifetimes.
/// Use the init allocator for owned results. Do not shallow-copy a live engine.
/// Keep its address stable while cursors or provider callbacks borrow it; serialize access.
pub const BufferEngine = struct {
    allocator: std.mem.Allocator,
    table: piece_table.PieceTable,
    revision: u32 = 0,
    path: ?[]const u8 = null,
    saved_revision: u32 = 0,

    anchors_map: std.AutoHashMapUnmanaged(u32, anchors.Anchor) = .empty,
    /// Issuance boundary of public anchor identities: every public identifier below it
    /// was published, by a receipt or a block, and was never reused (SPEC §1.4).
    next_public_anchor_id: u32 = 1,
    next_internal_anchor_id: u32 = 0,

    sessions: std.AutoHashMapUnmanaged(u32, Session) = .empty,
    next_session_id: u32 = 1,
    /// The sequence number of the next published block (SPEC §7).
    next_sequence: u64 = 0,

    undo_stack: std.ArrayListUnmanaged(types.UndoEntry) = .empty,
    redo_stack: std.ArrayListUnmanaged(types.UndoEntry) = .empty,

    view_providers: std.StringHashMapUnmanaged(views.ViewProvider) = .empty,
    /// Set while view providers are being notified; every state-changing entry point
    /// (submit, save, provider registration, anchor and session requests) is refused.
    notifying: bool = false,
    capability_supported_views_storage: [10][]const u8 = undefined,

    /// A committed buffer transaction's results, moved out of its PendingMutation.
    const Commit = struct {
        old_revision: u32,
        new_revision: u32,
        splices: []events.RealizedSplice,
        undo_entry: types.UndoEntry,
    };

    const Splice = piece_table.PieceTable.Splice;

    /// Every buffer operation is a replacement of [start, end) with text.
    const RequestedEdit = struct {
        start: u32,
        end: u32,
        text: []const u8,
    };

    /// Buffer and interaction parts of a Composite, in order. Borrows the intent's payloads.
    const CompositeParts = struct {
        buffer_ops: std.ArrayListUnmanaged(types.BufferOp) = .empty,
        interactions: std.ArrayListUnmanaged(types.InteractionMutation) = .empty,
        has_edit_refs: bool = false,

        fn deinit(self: *CompositeParts, allocator: std.mem.Allocator) void {
            self.buffer_ops.deinit(allocator);
            self.interactions.deinit(allocator);
            self.* = undefined;
        }
    };

    const EditAnchors = interaction.EditAnchors;

    /// What a transition applies, and which history its buffer operations go to.
    const Plan = struct {
        ops: []const types.BufferOp = &.{},
        interactions: []const types.InteractionMutation = &.{},
        edit_refs: bool = false,
        history: History = .record,
        /// For undo and redo: the deletion records of the entry being applied.
        resurrect: []const types.DeletionMeta = &.{},

        const History = enum {
            /// A new edit: recorded for undo, and the redo branch is discarded.
            record,
            /// Applying an undo entry, recorded for redo.
            undo,
            /// Applying a redo entry, recorded for undo.
            redo,
        };
    };

    /// Byte offsets of grapheme boundaries in a splice's old and new region text.
    const SpliceBoundaries = struct {
        old: []u32,
        new: []u32,

        fn init(
            engine: *const BufferEngine,
            splice: Splice,
            inserted: []const u8,
            old_text: []const u8,
        ) !SpliceBoundaries {
            const new_text = try std.mem.concat(engine.allocator, u8, &.{
                old_text[0..splice.left_context_bytes],
                inserted,
                old_text[old_text.len - splice.right_context_bytes ..],
            });
            defer engine.allocator.free(new_text);
            const old = try engine.table.seg.graphemeToByteMap(engine.allocator, old_text);
            errdefer engine.allocator.free(old);
            return .{
                .old = old,
                .new = try engine.table.seg.graphemeToByteMap(engine.allocator, new_text),
            };
        }

        fn deinit(self: *SpliceBoundaries, allocator: std.mem.Allocator) void {
            allocator.free(self.old);
            allocator.free(self.new);
            self.* = undefined;
        }
    };

    /// Buffer operations applied to the text but not yet committed as a revision.
    /// Grapheme deltas are not additive (SPEC §1.4), so a payload is validated exactly by
    /// applying it; a rejection rolls the applied prefix back before anything is observable.
    const PendingMutation = struct {
        anchors_before: std.AutoHashMapUnmanaged(u32, anchors.Anchor),
        inverse_ops: std.ArrayListUnmanaged(types.BufferOp) = .empty,
        splices: std.ArrayListUnmanaged(events.RealizedSplice) = .empty,
        deletion_metas: std.ArrayListUnmanaged(types.DeletionMeta) = .empty,

        fn deinit(self: *PendingMutation, allocator: std.mem.Allocator) void {
            self.anchors_before.deinit(allocator);
            for (self.inverse_ops.items) |op| freeOpText(allocator, op);
            self.inverse_ops.deinit(allocator);
            self.splices.deinit(allocator);
            for (self.deletion_metas.items) |*meta| meta.deinit(allocator);
            self.deletion_metas.deinit(allocator);
            self.* = undefined;
        }
    };

    const PendingResult = union(enum) {
        applied: PendingMutation,
        /// Owned message; nothing was applied.
        rejected: []u8,
    };

    /// Validates and applies each operation against the text produced by the previous
    /// ones. On rejection or error, the applied prefix is rolled back.
    /// Creates an empty owning engine. Release it with deinit.
    pub fn init(allocator: std.mem.Allocator) !BufferEngine {
        return .{
            .allocator = allocator,
            .table = try piece_table.PieceTable.init(allocator),
        };
    }

    /// Copies text and an optional path. The caller retains its input buffers.
    /// On error, everything allocated so far is released.
    pub fn initFromText(
        allocator: std.mem.Allocator,
        text: []const u8,
        path: ?[]const u8,
    ) !BufferEngine {
        var engine = try init(allocator);
        errdefer engine.deinit();
        try engine.table.initFromText(text);
        if (path) |p| {
            engine.path = try allocator.dupe(u8, p);
        }
        return engine;
    }

    pub const max_file_bytes: usize = 64 * 1024 * 1024;
    pub const large_file_bytes: usize = 16 * 1024 * 1024;

    /// Synchronously loads UTF-8 bytes, retaining an owned path. Missing files create
    /// an empty document; files larger than max_file_bytes are rejected.
    pub fn fromFile(allocator: std.mem.Allocator, path: []const u8) !BufferEngine {
        const io = std.Io.Threaded.global_single_threaded.io();
        const text = std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            allocator,
            .limited(max_file_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound => return initFromText(allocator, "", path),
            else => return err,
        };
        defer allocator.free(text);

        const engine = try initFromText(allocator, text, path);
        if (text.len >= large_file_bytes) {
            log.info("buffer open large file: path=\"{s}\" bytes={} graphemes={} lines={}", .{
                path,
                text.len,
                engine.graphemeCount(),
                engine.lineCount(),
            });
        } else {
            log.debug("buffer open: path=\"{s}\" bytes={} graphemes={} lines={}", .{
                path,
                text.len,
                engine.graphemeCount(),
                engine.lineCount(),
            });
        }
        return engine;
    }

    pub fn deinit(self: *BufferEngine) void {
        if (self.path) |p| self.allocator.free(p);
        var provider_iter = self.view_providers.valueIterator();
        var index: usize = 0;
        while (provider_iter.next()) |provider| : (index += 1) {
            if (self.firstRegistration(index, provider.ptr)) provider.deinit(self.allocator);
        }
        self.view_providers.deinit(self.allocator);

        for (self.undo_stack.items) |*ev| ev.deinit(self.allocator);
        self.undo_stack.deinit(self.allocator);

        for (self.redo_stack.items) |*ev| ev.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);

        var sess_iter = self.sessions.valueIterator();
        while (sess_iter.next()) |sess| sess.deinit(self.allocator);
        self.sessions.deinit(self.allocator);

        self.anchors_map.deinit(self.allocator);
        self.table.deinit();
        self.* = undefined;
    }

    pub fn dirty(self: *const BufferEngine) bool {
        return self.revision != self.saved_revision;
    }

    pub fn canUndo(self: *const BufferEngine) bool {
        return self.undo_stack.items.len > 0;
    }

    pub fn canRedo(self: *const BufferEngine) bool {
        return self.redo_stack.items.len > 0;
    }

    /// Synchronously writes the whole document, then marks its revision saved. A supplied
    /// path becomes the stored path only once the write succeeds; on error the stored
    /// path and saved revision are unchanged. The write itself is not an atomic file
    /// replacement (docs/known-issues.md).
    pub fn save(self: *BufferEngine, path: ?[]const u8) !void {
        if (self.notifying) return error.ReentrantMutation;
        const new_path = if (path) |requested| try self.allocator.dupe(u8, requested) else null;
        errdefer if (new_path) |owned| self.allocator.free(owned);
        const resolved_path = new_path orelse self.path orelse return error.InvalidArgument;
        const text = try self.getText();
        defer self.allocator.free(text);

        const io = std.Io.Threaded.global_single_threaded.io();
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = resolved_path,
            .data = text,
        });
        if (new_path) |owned| {
            if (self.path) |existing| self.allocator.free(existing);
            self.path = owned;
        }
        self.saved_revision = self.revision;

        if (text.len >= large_file_bytes) {
            log.info("buffer save large file: path=\"{s}\" bytes={} graphemes={} lines={}", .{
                resolved_path,
                text.len,
                self.graphemeCount(),
                self.lineCount(),
            });
        } else {
            log.debug("buffer save: path=\"{s}\" bytes={} graphemes={} lines={}", .{
                resolved_path,
                text.len,
                self.graphemeCount(),
                self.lineCount(),
            });
        }
    }

    pub fn registerViewProvider(self: *BufferEngine, provider: views.ViewProvider) !void {
        try self.registerViewProviders(&.{provider});
    }

    fn rollbackRegisteredViews(self: *BufferEngine, registered_views: []const []const u8) void {
        for (registered_views) |view| {
            _ = self.view_providers.fetchRemove(view);
        }
    }

    /// Registers a batch after conflict preflight. On failure, registration rolls back
    /// and the caller retains provider ownership; names and implementations must stay alive.
    pub fn registerViewProviders(self: *BufferEngine, providers: []const views.ViewProvider) !void {
        if (self.notifying) return error.ReentrantMutation;
        if (providers.len == 0) return error.InvalidArgument;

        var pending_views: std.ArrayListUnmanaged([]const u8) = .empty;
        defer pending_views.deinit(self.allocator);

        for (providers) |provider| {
            const provider_views = provider.views();
            if (provider_views.len == 0) return error.InvalidArgument;
            for (provider_views) |view| {
                if (self.view_providers.contains(view)) return error.AlreadyExists;
                for (pending_views.items) |pending| {
                    if (std.mem.eql(u8, pending, view)) return error.AlreadyExists;
                }
                try pending_views.append(self.allocator, view);
            }
        }

        var registered_count: usize = 0;
        errdefer self.rollbackRegisteredViews(pending_views.items[0..registered_count]);

        for (providers) |provider| {
            for (provider.views()) |view| {
                try self.view_providers.put(self.allocator, view, provider);
                registered_count += 1;
            }
        }
    }

    pub fn queryViewState(self: *const BufferEngine, view: []const u8) views.ViewState {
        const provider = self.view_providers.get(view) orelse return views.ViewState.absent(
            view,
            self.revision,
        );
        return provider.stateFor(view, self.revision);
    }

    pub fn refreshView(self: *BufferEngine, view: []const u8) views.ViewState {
        const provider = self.view_providers.get(view) orelse return views.ViewState.absent(
            view,
            self.revision,
        );
        return provider.refresh(@ptrCast(self));
    }

    /// Creates an anchor in capacity the caller reserved. Does not allocate or fail.
    /// A public identifier taken here is issued only if the caller publishes it.
    fn insertReservedAnchor(
        self: *BufferEngine,
        position: u32,
        stickiness: anchors.AnchorStickiness,
        kind: anchors.AnchorKind,
    ) anchors.AnchorId {
        const id = self.takeAnchorId(kind);
        self.anchors_map.putAssumeCapacityNoClobber(id.value, .{
            .id = id,
            .position = position,
            .stickiness = stickiness,
            .kind = kind,
            .refs = @intFromBool(kind == .undo_target),
        });
        return id;
    }

    /// Takes the next identifier of the kind's namespace. A public identifier is issued
    /// only if the caller publishes it; preparation that is abandoned must restore
    /// `next_public_anchor_id` (see interaction.Prepared.abort).
    pub fn takeAnchorId(self: *BufferEngine, kind: anchors.AnchorKind) anchors.AnchorId {
        if (kind.isPublic()) {
            std.debug.assert(self.next_public_anchor_id < anchors.internal_bit);
            defer self.next_public_anchor_id += 1;
            return .{ .value = self.next_public_anchor_id };
        }
        std.debug.assert(self.next_internal_anchor_id < anchors.internal_bit);
        defer self.next_internal_anchor_id += 1;
        return .{ .value = anchors.internal_bit | self.next_internal_anchor_id };
    }

    /// Removes an anchor, if it still exists. Disposal is terminal, so an anchor a client
    /// already dropped is already in its final state. Does not allocate or fail.
    fn releaseAnchor(self: *BufferEngine, anchor: anchors.AnchorId) void {
        _ = self.anchors_map.remove(anchor.value);
    }

    /// Whether the registration at `index` is the first, in iteration order, of the
    /// provider implementation `identity`. A provider serving several views is
    /// registered once per view; this visits it once without allocating, at a cost
    /// quadratic in the (small) number of registrations. Compares pointers only, so it
    /// is safe while earlier providers are being destroyed.
    fn firstRegistration(self: *const BufferEngine, index: usize, identity: *anyopaque) bool {
        var iter = self.view_providers.valueIterator();
        var position: usize = 0;
        while (iter.next()) |other| : (position += 1) {
            if (position == index) return true;
            if (other.ptr == identity) return false;
        }
        return true;
    }

    /// Hands a published block to each distinct provider once, borrowed for the call.
    /// Runs last, after the whole transition is published. Does not allocate. A
    /// provider that tries to change engine state from its callback is refused with
    /// error.ReentrantMutation.
    fn notifyViewProviders(self: *BufferEngine, block: *const events.Block) void {
        self.notifying = true;
        defer self.notifying = false;
        var iter = self.view_providers.valueIterator();
        var index: usize = 0;
        while (iter.next()) |provider| : (index += 1) {
            if (!self.firstRegistration(index, provider.ptr)) continue;
            provider.onBufferEvent(@ptrCast(self), @ptrCast(@constCast(block)));
        }
    }

    fn takeSequence(self: *BufferEngine) u64 {
        defer self.next_sequence += 1;
        return self.next_sequence;
    }

    /// Validates origins and guards, then applies the intent as one transition.
    /// Returns the published block, owned by the caller, or a rejection report; a
    /// rejection or error, including allocation failure, leaves no observable effect
    /// and consumes no sequence number. Returns error.ReentrantMutation when called
    /// from a view provider's notification, and error.CorruptHistory when an undo or
    /// redo entry cannot be applied (it then stays in place).
    pub fn submit(self: *BufferEngine, intent: types.Intent) !types.SubmitResult {
        if (self.notifying) return error.ReentrantMutation;
        switch (intent.payload) {
            .buffer_mutation => |payload| {
                if (try self.preflight(intent, true)) |report| return .{ .rejected = report };
                if (payload.ops.len == 0) {
                    return self.invalidMessage(intent, "apply requires at least one operation");
                }
                return self.submitTransition(intent, .{ .ops = payload.ops });
            },
            .interaction_mutation => |payload| {
                if (try validation.validationReportForStaleInteractionOrigin(
                    self,
                    intent,
                    payload,
                )) |report| {
                    return .{ .rejected = report };
                }
                // Positions are document coordinates: they need a current document origin.
                const positional = validation.interactionHasPositions(payload);
                if (try self.preflight(intent, positional)) |report| return .{ .rejected = report };
                return self.submitTransition(intent, .{ .interactions = &.{payload} });
            },
            .composite => |payload| return self.submitComposite(intent, payload),
            .undo => return self.submitHistory(intent, .undo),
            .redo => return self.submitHistory(intent, .redo),
        }
    }

    /// The document-origin check, when requested, then the guards.
    fn preflight(
        self: *BufferEngine,
        intent: types.Intent,
        check_origin: bool,
    ) !?types.ValidationReport {
        if (check_origin) {
            const stale = try validation.validationReportForStaleBufferOrigin(self, intent);
            if (stale) |report| return report;
        }
        return validation.validationReportForGuards(self, intent);
    }

    fn submitComposite(
        self: *BufferEngine,
        intent: types.Intent,
        payload: types.Composite,
    ) !types.SubmitResult {
        if (try self.preflight(intent, true)) |report| return .{ .rejected = report };
        const flat_parts = try validation.flattenCompositeParts(self.allocator, payload.parts);
        defer self.allocator.free(flat_parts);
        var parts: CompositeParts = .{};
        defer parts.deinit(self.allocator);
        if (try self.collectCompositeParts(
            intent,
            flat_parts,
            &parts,
        )) |rejection| return rejection;
        return self.submitTransition(intent, .{
            .ops = parts.buffer_ops.items,
            .interactions = parts.interactions.items,
            .edit_refs = parts.has_edit_refs,
        });
    }

    fn submitHistory(
        self: *BufferEngine,
        intent: types.Intent,
        direction: enum { undo, redo },
    ) !types.SubmitResult {
        if (try self.preflight(intent, true)) |report| return .{ .rejected = report };
        const from = if (direction == .undo) &self.undo_stack else &self.redo_stack;
        if (from.items.len == 0) {
            const message = if (direction == .undo) "nothing to undo" else "nothing to redo";
            return self.invalidMessage(intent, message);
        }
        // Popping keeps the capacity that restoring the entry on failure needs.
        var entry = from.pop().?;
        errdefer from.appendAssumeCapacity(entry);
        const result = try self.submitTransition(intent, .{
            .ops = entry.inverse_ops,
            .history = if (direction == .undo) .undo else .redo,
            .resurrect = entry.deletion_metas,
        });
        entry.deinit(self.allocator);
        return result;
    }

    /// Applies an intent's buffer operations, then prepares its interaction mutations
    /// against the result, then builds the owned block. Everything that can fail happens
    /// before publication, so a rejection or error leaves no effect; publication installs
    /// everything without allocating, and providers then receive the complete block.
    fn submitTransition(self: *BufferEngine, intent: types.Intent, plan: Plan) !types.SubmitResult {
        const edit_anchors: ?[]EditAnchors = if (plan.edit_refs)
            try self.allocator.alloc(EditAnchors, plan.ops.len)
        else
            null;
        defer if (edit_anchors) |slice| self.allocator.free(slice);

        var pending: ?PendingMutation = null;
        errdefer if (pending) |*applied| self.rollbackPending(applied);
        if (plan.ops.len > 0) {
            pending = switch (try self.applyOpsPending(plan.ops, edit_anchors, plan.resurrect)) {
                .applied => |applied| applied,
                .rejected => |message| {
                    if (plan.history == .record) return self.invalidReport(intent, message);
                    // History holds operations that applied before; they must apply again.
                    self.allocator.free(message);
                    return error.CorruptHistory;
                },
            };
        }

        var prepared = interaction.Prepared.init(self);
        defer prepared.deinit(self.allocator);
        errdefer prepared.abort(self);
        const context = interaction.Context{
            .length = self.table.graphemeCount(),
            .edits = edit_anchors,
            .document_revision = self.revision + @intFromBool(pending != null),
        };
        for (plan.interactions) |payload| {
            if (try prepared.applyMutation(self, payload, context)) |message| {
                prepared.abort(self);
                if (pending) |*applied| self.rollbackPending(applied);
                pending = null;
                return self.invalidReport(intent, message);
            }
        }
        // Edit result anchors are scoped to the transaction; rollback would restore the
        // snapshot taken before they existed.
        if (edit_anchors) |by_op| for (by_op) |edit| {
            self.releaseAnchor(edit.start);
            self.releaseAnchor(edit.end);
        };

        // Build every owned part of the result before publishing anything.
        const effects = if (pending) |*applied| try self.endpointEffects(applied) else &.{};
        var effects_owned = true;
        defer if (effects_owned) self.allocator.free(effects);
        const interaction_events = try prepared.finish(self, context.document_revision);
        var events_owned = true;
        defer if (events_owned) {
            for (interaction_events) |*event| event.deinit(self.allocator);
            self.allocator.free(interaction_events);
        };
        const source = try intent.source.dupe(self.allocator);
        errdefer source.free(self.allocator);
        const label = if (intent.label) |text| try self.allocator.dupe(u8, text) else null;
        errdefer if (label) |text| self.allocator.free(text);
        try self.anchors_map.ensureUnusedCapacity(self.allocator, prepared.newAnchorCount());
        const history = switch (plan.history) {
            .record, .redo => &self.undo_stack,
            .undo => &self.redo_stack,
        };
        var commit: ?Commit = null;
        if (pending) |*applied| {
            try history.ensureUnusedCapacity(self.allocator, 1);
            // The last fallible step; it commits the text and advances the revision.
            commit = try self.commitPending(applied);
            pending = null;
        }

        // Publication: nothing below allocates or fails.
        var edit: ?events.EditEvent = null;
        if (commit) |committed| {
            history.appendAssumeCapacity(committed.undo_entry);
            if (plan.history == .record) self.discardRedo();
            edit = .{
                .old_revision = committed.old_revision,
                .new_revision = committed.new_revision,
                .edit_class = editClass(plan.ops),
                .splices = committed.splices,
                .endpoint_effects = effects,
            };
            effects_owned = false;
        }
        prepared.publish(self);
        self.clearTouched();
        events_owned = false;
        const block = events.Block{ .transition = .{
            .sequence = self.takeSequence(),
            .intent = intent.id,
            .source = source,
            .label = label,
            .edit = edit,
            .interactions = interaction_events,
        } };
        self.notifyViewProviders(&block);
        return .{ .committed = block };
    }

    /// The session endpoints the applied operations touched (see rebaseAnchorsForSplice
    /// and resurrectDeletionMetas), with their values before and after, ordered by
    /// session and anchor. Every other endpoint follows the splices' shift rule.
    fn endpointEffects(
        self: *const BufferEngine,
        pending: *const PendingMutation,
    ) ![]events.EndpointEffect {
        var effects: std.ArrayListUnmanaged(events.EndpointEffect) = .empty;
        errdefer effects.deinit(self.allocator);
        var iter = self.sessions.valueIterator();
        while (iter.next()) |session| for (session.selections) |selection| {
            const ends = [_]anchors.AnchorId{ selection.start, selection.end };
            for (ends[0 .. @as(usize, 2) - @intFromBool(selection.isCaret())]) |id| {
                const now = self.anchors_map.get(id.value).?;
                if (!now.touched) continue;
                const before = pending.anchors_before.get(id.value).?;
                try effects.append(self.allocator, .{
                    .session = session.id,
                    .anchor = id,
                    .old = if (before.status == .live) before.position else null,
                    .new = if (now.status == .live) now.position else null,
                });
            }
        };
        std.mem.sort(events.EndpointEffect, effects.items, {}, struct {
            fn lessThan(_: void, a: events.EndpointEffect, b: events.EndpointEffect) bool {
                if (a.session != b.session) return a.session < b.session;
                return a.anchor.value < b.anchor.value;
            }
        }.lessThan);
        return effects.toOwnedSlice(self.allocator);
    }

    /// Ends a transition's effect tracking. Does not allocate.
    fn clearTouched(self: *BufferEngine) void {
        var iter = self.sessions.valueIterator();
        while (iter.next()) |session| for (session.selections) |selection| {
            self.anchors_map.getPtr(selection.start.value).?.touched = false;
            self.anchors_map.getPtr(selection.end.value).?.touched = false;
        };
    }

    /// Checks structure, interaction CAS and edit reference indices against the
    /// pre-application snapshot, collecting the parts. Returns a rejection report, if any.
    fn collectCompositeParts(
        self: *BufferEngine,
        intent: types.Intent,
        flat_parts: []const types.IntentPayload,
        parts: *CompositeParts,
    ) !?types.SubmitResult {
        var seen_interaction = false;
        for (flat_parts) |part| {
            switch (part) {
                .buffer_mutation => |buffer| {
                    if (seen_interaction) {
                        return try self.invalidMessage(
                            intent,
                            "buffer mutations must precede interaction mutations in a composite",
                        );
                    }
                    if (buffer.ops.len == 0) {
                        return try self.invalidMessage(
                            intent,
                            "apply requires at least one operation",
                        );
                    }
                    try parts.buffer_ops.appendSlice(self.allocator, buffer.ops);
                },
                .interaction_mutation => |mutation| {
                    seen_interaction = true;
                    const stale = try validation.validationReportForStaleInteractionOrigin(
                        self,
                        intent,
                        mutation,
                    );
                    if (stale) |report| return .{ .rejected = report };
                    try parts.interactions.append(self.allocator, mutation);
                },
                else => {
                    return try self.invalidMessage(
                        intent,
                        "composite only supports buffer and interaction mutations",
                    );
                },
            }
        }

        if (parts.buffer_ops.items.len == 0 and parts.interactions.items.len == 0) {
            return try self.invalidMessage(
                intent,
                "composite intent requires at least one payload",
            );
        }
        for (parts.interactions.items) |mutation| {
            if (!validation.interactionHasEditRefs(mutation)) continue;
            parts.has_edit_refs = true;
            if (validation.editRefOutOfRange(mutation, parts.buffer_ops.items.len)) |op| {
                return try self.invalidReport(
                    intent,
                    try std.fmt.allocPrint(
                        self.allocator,
                        "edit reference to buffer operation {d} is out of range",
                        .{op},
                    ),
                );
            }
        }
        return null;
    }

    /// Reports a borrowed message; the report owns a copy.
    fn invalidMessage(
        self: *BufferEngine,
        intent: types.Intent,
        message: []const u8,
    ) !types.SubmitResult {
        return self.invalidReport(intent, try self.allocator.dupe(u8, message));
    }

    /// Takes ownership of message.
    fn invalidReport(self: *BufferEngine, intent: types.Intent, message: []u8) !types.SubmitResult {
        defer self.allocator.free(message);
        return .{
            .rejected = try validation.validationReport(
                self,
                intent,
                .invalid,
                message,
                try self.allocator.alloc(types.GuardEval, 0),
            ),
        };
    }

    /// A new edit makes the redo branch unreachable (SPEC §2.5.6). Its records stop
    /// referring to anything: public anchors they name lose only their resurrection path
    /// and stay with their owners, while undo targets nothing else needs are released.
    /// Does not allocate.
    fn discardRedo(self: *BufferEngine) void {
        for (self.redo_stack.items) |*entry| {
            for (entry.deletion_metas) |meta| {
                for (meta.dead_anchors) |record| {
                    if (record.kind == .undo_target) self.unreferenceUndoTarget(record.anchor);
                }
                self.unreferenceUndoTarget(meta.target_anchor);
            }
            entry.deinit(self.allocator);
        }
        self.redo_stack.clearRetainingCapacity();
    }

    /// Drops one reference to an undo target and releases it at zero. Every reference is
    /// counted when it is created, so the target must exist.
    fn unreferenceUndoTarget(self: *BufferEngine, target: anchors.AnchorId) void {
        const anchor = self.anchors_map.getPtr(target.value).?;
        std.debug.assert(anchor.kind == .undo_target);
        std.debug.assert(anchor.refs > 0);
        anchor.refs -= 1;
        if (anchor.refs == 0) self.releaseAnchor(target);
    }

    /// The anchor `anchor_id` names, if it exists and is visible to clients. Undo targets
    /// and transaction-scoped anchors are engine resources: every public lookup treats
    /// them as nonexistent, even when a caller guesses their identifier.
    pub fn publicAnchor(self: *const BufferEngine, anchor_id: anchors.AnchorId) ?anchors.Anchor {
        if (anchor_id.isInternal()) return null;
        const anchor = self.anchors_map.get(anchor_id.value) orelse return null;
        std.debug.assert(anchor.kind.isPublic());
        return anchor;
    }

    /// Whether `anchor_id` was issued as a public anchor and has since been disposed.
    /// Public identities are issued only at publication and never reused, so an issued
    /// identifier without storage can only have been disposed.
    fn isDisposed(self: *const BufferEngine, anchor_id: anchors.AnchorId) bool {
        if (anchor_id.isInternal()) return false;
        if (anchor_id.value == 0 or anchor_id.value >= self.next_public_anchor_id) return false;
        return !self.anchors_map.contains(anchor_id.value);
    }

    pub fn createAnchor(
        self: *BufferEngine,
        position: u32,
        stickiness: anchors.AnchorStickiness,
    ) RequestError!anchors.AnchorId {
        if (self.notifying) return error.ReentrantMutation;
        if (position > self.table.graphemeCount()) return error.OutOfRange;
        return self.insertAnchor(position, stickiness, .client);
    }

    /// Creates an anchor of any kind. Callers check notification and bounds.
    fn insertAnchor(
        self: *BufferEngine,
        position: u32,
        stickiness: anchors.AnchorStickiness,
        kind: anchors.AnchorKind,
    ) !anchors.AnchorId {
        try self.anchors_map.ensureUnusedCapacity(self.allocator, 1);
        return self.insertReservedAnchor(position, stickiness, kind);
    }

    /// Disposes of a client anchor. Disposal is terminal: undo never resurrects it, and
    /// its identifier is never reused (SPEC §1.4). Dropping a disposed handle succeeds
    /// and changes nothing. A session endpoint is refused with error.AnchorOwned; an
    /// identifier that was never issued as a public anchor, with error.KeyError.
    pub fn dropAnchor(self: *BufferEngine, anchor_id: anchors.AnchorId) RequestError!void {
        if (self.notifying) return error.ReentrantMutation;
        if (self.isDisposed(anchor_id)) return;
        const anchor = self.publicAnchor(anchor_id) orelse return error.KeyError;
        if (anchor.kind == .endpoint) return error.AnchorOwned;
        self.releaseAnchor(anchor_id);
    }

    /// Reports a public handle as live, dead or disposed (SPEC §1.4). An identifier that
    /// was never issued as a public anchor, including every internal one, is rejected
    /// with error.KeyError.
    pub fn queryAnchor(self: *const BufferEngine, anchor_id: anchors.AnchorId) !queries.AnchorInfo {
        if (self.publicAnchor(anchor_id)) |anchor| {
            return .{
                .id = anchor.id,
                .position = if (anchor.status == .live) anchor.position else null,
                .stickiness = anchor.stickiness,
                .status = switch (anchor.status) {
                    .live => .live,
                    .dead => .dead,
                },
            };
        }
        if (self.isDisposed(anchor_id)) {
            return .{ .id = anchor_id, .position = null, .stickiness = null, .status = .disposed };
        }
        return error.KeyError;
    }

    /// Creates a session (an intrinsic request; SPEC §2.6) and publishes a lifecycle
    /// block, which the caller owns and from which it learns the session and endpoint
    /// identities. Advances no revision. Every endpoint must be `new`, with a position or
    /// anchor target; anything else, a position out of range or an anchor that is not
    /// live is rejected with error.InvalidArgument, and an origin other than the current
    /// revision with error.StaleOrigin. On error nothing changed and no identity was
    /// issued.
    pub fn createSession(
        self: *BufferEngine,
        request: types.SessionCreation,
    ) RequestError!events.Block {
        if (self.notifying) return error.ReentrantMutation;
        if (request.origin != self.revision) return error.StaleOrigin;
        for (request.selections) |spec| {
            if (spec.start != .new) return error.InvalidArgument;
            if (spec.end) |end| if (end != .new) return error.InvalidArgument;
        }

        var prepared = interaction.Prepared.init(self);
        defer prepared.deinit(self.allocator);
        errdefer prepared.abort(self);
        const session_id = self.next_session_id;
        const context = interaction.Context{
            .length = self.table.graphemeCount(),
            .document_revision = self.revision,
        };
        if (try prepared.createSession(self, session_id, request.selections, context)) |message| {
            defer self.allocator.free(message);
            log.debug("rejected session creation: {s}", .{message});
            return error.InvalidArgument;
        }
        // A new session has no interaction event: its lifecycle block states its selections.
        self.allocator.free(try prepared.finish(self, self.revision));
        const values = try prepared.selectionValues(self, session_id);
        errdefer self.allocator.free(values);
        try self.sessions.ensureUnusedCapacity(self.allocator, 1);
        try self.anchors_map.ensureUnusedCapacity(self.allocator, prepared.newAnchorCount());

        // Publication: nothing below allocates or fails.
        prepared.publish(self);
        self.next_session_id += 1;
        const block = events.Block{ .lifecycle = .{
            .sequence = self.takeSequence(),
            .request = request.id,
            .change = .{ .session_created = .{
                .session = session_id,
                .document_revision = self.revision,
                .selections = values,
            } },
        } };
        self.notifyViewProviders(&block);
        return block;
    }

    /// Drops a session (an intrinsic request), releasing its endpoints and registers,
    /// and publishes a lifecycle block, which the caller owns. Released endpoints are
    /// disposed: undo never revives them. An unknown session is rejected with
    /// error.KeyError and nothing changes. Does not allocate.
    pub fn dropSession(self: *BufferEngine, request: types.SessionDrop) RequestError!events.Block {
        if (self.notifying) return error.ReentrantMutation;
        var removed = self.sessions.fetchRemove(request.session) orelse return error.KeyError;
        for (removed.value.selections) |selection| {
            self.releaseAnchor(selection.start);
            self.releaseAnchor(selection.end);
        }
        const revision = removed.value.revision;
        removed.value.deinit(self.allocator);
        const block = events.Block{ .lifecycle = .{
            .sequence = self.takeSequence(),
            .request = request.id,
            .change = .{ .session_dropped = .{
                .session = request.session,
                .interaction_revision = revision,
            } },
        } };
        self.notifyViewProviders(&block);
        return block;
    }

    pub fn interactionRevision(self: *const BufferEngine, session_id: u32) !u32 {
        const session = self.sessions.getPtr(session_id) orelse return error.KeyError;
        return session.revision;
    }

    /// The session's selections as values at the current revision. The caller frees
    /// the slice with `allocator`. An unknown session is rejected with error.KeyError.
    pub fn querySelections(
        self: *const BufferEngine,
        allocator: std.mem.Allocator,
        session_id: u32,
    ) ![]events.SelectionValue {
        const session = self.sessions.getPtr(session_id) orelse return error.KeyError;
        return self.selectionValues(allocator, session.selections);
    }

    fn selectionValues(
        self: *const BufferEngine,
        allocator: std.mem.Allocator,
        list: []const Selection,
    ) ![]events.SelectionValue {
        const values = try allocator.alloc(events.SelectionValue, list.len);
        for (list, values) |selection, *value| value.* = .{
            .start = self.endpointValue(selection.start),
            .end = self.endpointValue(selection.end),
            .active = selection.active,
        };
        return values;
    }

    fn endpointValue(self: *const BufferEngine, id: anchors.AnchorId) events.EndpointValue {
        const endpoint = self.anchors_map.get(id.value).?;
        return .{
            .anchor = id,
            .position = if (endpoint.status == .live) endpoint.position else null,
        };
    }

    /// A register's value, borrowed until the session next changes; null when unset. An
    /// unknown session is rejected with error.KeyError.
    pub fn queryRegister(
        self: *const BufferEngine,
        session_id: u32,
        key: []const u8,
    ) !?events.InteractionValue {
        const session = self.sessions.getPtr(session_id) orelse return error.KeyError;
        return session.registers.get(key);
    }

    /// The state the stream explains, with the sequence number an observer resumes
    /// from. The caller owns the snapshot and frees it with `allocator`.
    pub fn snapshot(self: *const BufferEngine, allocator: std.mem.Allocator) !events.Snapshot {
        const sessions = try allocator.alloc(events.SessionSnapshot, self.sessions.count());
        var filled: usize = 0;
        errdefer {
            // Release what was filled, then the array once: deinit would free a prefix.
            for (sessions[0..filled]) |session| freeSessionSnapshot(allocator, session);
            allocator.free(sessions);
        }
        var iter = self.sessions.valueIterator();
        while (iter.next()) |session| : (filled += 1) {
            const selections = try self.selectionValues(allocator, session.selections);
            errdefer allocator.free(selections);
            sessions[filled] = .{
                .id = session.id,
                .interaction_revision = session.revision,
                .selections = selections,
                .registers = try registerEntries(allocator, session.registers),
            };
        }
        const result = events.Snapshot{
            .next_sequence = self.next_sequence,
            .document_revision = self.revision,
            .sessions = sessions,
        };
        std.mem.sort(events.SessionSnapshot, result.sessions, {}, struct {
            fn lessThan(_: void, a: events.SessionSnapshot, b: events.SessionSnapshot) bool {
                return a.id < b.id;
            }
        }.lessThan);
        return result;
    }

    fn freeSessionSnapshot(allocator: std.mem.Allocator, session: events.SessionSnapshot) void {
        allocator.free(session.selections);
        for (session.registers) |entry| {
            allocator.free(entry.key);
            entry.value.free(allocator);
        }
        allocator.free(session.registers);
    }

    fn registerEntries(
        allocator: std.mem.Allocator,
        registers: session_state.Registers,
    ) ![]events.RegisterEntry {
        const entries = try allocator.alloc(events.RegisterEntry, registers.count());
        var filled: usize = 0;
        errdefer {
            for (entries[0..filled]) |entry| {
                allocator.free(entry.key);
                entry.value.free(allocator);
            }
            allocator.free(entries);
        }
        var iter = registers.iterator();
        while (iter.next()) |entry| : (filled += 1) {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            entries[filled] = .{ .key = key, .value = try entry.value_ptr.dupe(allocator) };
        }
        return entries;
    }

    fn countGraphemes(self: *const BufferEngine, text: []const u8) u32 {
        var count: u32 = 0;
        var iter = self.table.seg.iterator(text);
        while (iter.next() != null) count += 1;
        return count;
    }

    fn requestedEdit(op: types.BufferOp) RequestedEdit {
        return switch (op) {
            .insert => |ins| .{ .start = ins.pos, .end = ins.pos, .text = ins.text },
            .delete => |del| .{ .start = del.start, .end = del.end, .text = "" },
            .replace => |rep| .{ .start = rep.start, .end = rep.end, .text = rep.text },
        };
    }

    /// Takes ownership of old_text, the exact text of the splice's old range.
    fn inverseForSplice(self: *const BufferEngine, splice: Splice, old_text: []u8) types.BufferOp {
        if (old_text.len == 0) {
            self.allocator.free(old_text);
            return .{ .delete = .{ .start = splice.start, .end = splice.new_end } };
        }
        if (splice.new_end == splice.start) return .{
            .insert = .{ .pos = splice.start, .text = old_text },
        };
        return .{ .replace = .{ .start = splice.start, .end = splice.new_end, .text = old_text } };
    }

    /// SPEC §1.4 replacement rebasing over byte offsets, so it stays additive when
    /// grapheme counts are not. Null means the anchor dies.
    fn rebaseByte(
        offset: u32,
        deleted_start: u32,
        deleted_end: u32,
        inserted_len: u32,
        stickiness: anchors.AnchorStickiness,
    ) ?u32 {
        if (offset < deleted_start) return offset;
        if (offset > deleted_end) return offset - (deleted_end - deleted_start) + inserted_len;
        if (stickiness == .sticky) return deleted_start + inserted_len;
        if (offset > deleted_start and offset < deleted_end) return null;
        return deleted_start;
    }

    /// Projects a byte offset to a grapheme boundary index: weak rounds down, sticky up.
    fn projectToBoundary(
        bounds: []const u32,
        offset: u32,
        stickiness: anchors.AnchorStickiness,
    ) u32 {
        var lo: usize = 0;
        var hi: usize = bounds.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (bounds[mid] < offset) lo = mid + 1 else hi = mid;
        }
        if (lo < bounds.len and bounds[lo] == offset) return @intCast(lo);
        return @intCast(if (stickiness == .sticky) lo else lo - 1);
    }

    /// Maps a position inside [splice.start, splice.old_end]. Aligned splices need no
    /// boundaries: the region is exactly the requested range.
    fn spliceRegionPosition(
        splice: Splice,
        boundaries: ?SpliceBoundaries,
        inserted_len: usize,
        position: u32,
        stickiness: anchors.AnchorStickiness,
    ) ?u32 {
        const bounds = boundaries orelse {
            if (stickiness == .sticky) return splice.new_end;
            if (position > splice.start and position < splice.old_end) return null;
            return splice.start;
        };
        const old_len = bounds.old[bounds.old.len - 1];
        const byte = rebaseByte(
            bounds.old[position - splice.start],
            splice.left_context_bytes,
            old_len - splice.right_context_bytes,
            @intCast(inserted_len),
            stickiness,
        ) orelse return null;
        return splice.start + projectToBoundary(bounds.new, byte, stickiness);
    }

    /// Rebases anchors across one realized splice. Resegmentation never kills an anchor;
    /// only weak anchors strictly inside the requested deletion die. Passive rebasing does
    /// not advance interaction revisions; the edit event is its notification (SPEC §2.6).
    /// Session endpoints inside the closed splice region are marked as touched.
    fn rebaseAnchorsForSplice(
        self: *BufferEngine,
        splice: Splice,
        inserted: []const u8,
        old_text: []const u8,
    ) !void {
        // Built on first use: long resegmentations rarely contain anchors.
        var boundaries: ?SpliceBoundaries = null;
        defer if (boundaries) |*b| b.deinit(self.allocator);

        var iter = self.anchors_map.valueIterator();
        while (iter.next()) |anchor| {
            if (anchor.status == .dead) continue;
            const next = if (anchor.position < splice.start)
                anchor.position
            else if (anchor.position > splice.old_end)
                anchor.position - splice.old_end + splice.new_end
            else blk: {
                // The splice alone does not determine this anchor's fate: the edit event
                // reports a session endpoint here explicitly.
                if (anchor.kind == .endpoint) anchor.touched = true;
                if (boundaries == null and !splice.isAligned()) {
                    boundaries = try SpliceBoundaries.init(self, splice, inserted, old_text);
                }
                break :blk spliceRegionPosition(
                    splice,
                    boundaries,
                    inserted.len,
                    anchor.position,
                    anchor.stickiness,
                );
            };
            if (next) |position| {
                anchor.position = position;
            } else {
                anchor.status = .dead;
            }
        }
    }

    fn restoredText(inverse_op: types.BufferOp) []const u8 {
        return switch (inverse_op) {
            .insert => |ins| ins.text,
            .replace => |rep| rep.text,
            .delete => "",
        };
    }

    /// Records weak anchors strictly inside the requested deletion [start, end). Offsets
    /// are relative to region_start, which survives the edit and is where undo restores
    /// the splice's old text.
    fn captureDeletionMeta(
        self: *BufferEngine,
        op: u32,
        start: u32,
        end: u32,
        region_start: u32,
        inverse_op: types.BufferOp,
    ) !?types.DeletionMeta {
        if (start == end) return null;

        var dead_anchors = std.ArrayListUnmanaged(types.DeadAnchorRecord).empty;
        errdefer dead_anchors.deinit(self.allocator);

        var iter = self.anchors_map.valueIterator();
        while (iter.next()) |anchor| {
            if (anchor.status == .dead) continue;
            if (anchor.position <= start or anchor.position >= end) continue;
            if (anchor.stickiness != .weak) continue;
            // Transaction-scoped anchors are gone before any undo could resurrect them.
            if (anchor.kind == .transient) continue;

            try dead_anchors.append(self.allocator, .{
                .anchor = anchor.id,
                .offset = anchor.position - region_start,
                .stickiness = anchor.stickiness,
                .kind = anchor.kind,
            });
        }

        if (dead_anchors.items.len == 0) return null;
        // The records keep the undo targets they name alive. Counting after the last
        // fallible append leaves nothing to undo on failure; rollback restores the rest.
        for (dead_anchors.items) |record| {
            if (record.kind == .undo_target) self.anchors_map.getPtr(
                record.anchor.value,
            ).?.refs += 1;
        }

        const target_anchor = try self.insertAnchor(region_start, .weak, .undo_target);
        errdefer self.releaseAnchor(target_anchor);

        const inverse_text = try self.allocator.dupe(u8, restoredText(inverse_op));
        errdefer self.allocator.free(inverse_text);

        return .{
            .op = op,
            .target_anchor = target_anchor,
            .inverse_text = inverse_text,
            .dead_anchors = try dead_anchors.toOwnedSlice(self.allocator),
        };
    }

    /// Revives the anchors that the deletion undone by inverse operation `op` killed,
    /// relative to its undo target, and releases the target.
    fn resurrectDeletionMetas(
        self: *BufferEngine,
        deletion_metas: []const types.DeletionMeta,
        op: usize,
    ) !void {
        for (deletion_metas) |meta| {
            if (meta.op != op) continue;
            // The engine owns undo targets, so a missing or dead one is a bookkeeping bug.
            const target_anchor = self.anchors_map.get(meta.target_anchor.value) orelse {
                return error.CorruptHistory;
            };
            if (target_anchor.status == .dead) return error.CorruptHistory;
            const target_position = target_anchor.position;

            for (meta.dead_anchors) |record| {
                const anchor = self.anchors_map.getPtr(record.anchor.value) orelse {
                    // Its owner disposed of it, which is terminal (SPEC §1.4). Internal
                    // anchors live while a record names them, so absence is a bug.
                    if (record.kind.isPublic()) continue;
                    return error.CorruptHistory;
                };
                if (anchor.status != .dead) return error.CorruptHistory;
                anchor.position = target_position + record.offset;
                anchor.stickiness = record.stickiness;
                anchor.status = .live;
                if (anchor.kind == .endpoint) anchor.touched = true;
                // This record is consumed. A revived target whose own entry is gone is
                // no longer needed by anything.
                if (record.kind == .undo_target) self.unreferenceUndoTarget(record.anchor);
            }

            // The entry owning this target is being applied, so nothing else refers to it:
            // a record naming it would require it to be dead.
            if (target_anchor.refs != 1) return error.CorruptHistory;
            self.releaseAnchor(meta.target_anchor);
        }
    }

    fn editClass(ops: []const types.BufferOp) events.EditClass {
        std.debug.assert(ops.len > 0);
        const tag = std.meta.activeTag(ops[0]);
        for (ops[1..]) |op| {
            if (std.meta.activeTag(op) != tag) return .mixed;
        }
        return switch (tag) {
            .insert => .insert,
            .delete => .delete,
            .replace => .replace,
        };
    }

    fn freeOpText(allocator: std.mem.Allocator, op: types.BufferOp) void {
        switch (op) {
            .insert => |ins| allocator.free(ins.text),
            .replace => |rep| allocator.free(rep.text),
            .delete => {},
        }
    }

    /// When `edits` is supplied, the result anchors of every operation are recorded in it.
    /// Applies `ops` provisionally. When they are an undo entry's inverse operations,
    /// `resurrect` holds its deletion records, replayed after the operations they follow.
    fn applyOpsPending(
        self: *BufferEngine,
        ops: []const types.BufferOp,
        edits: ?[]EditAnchors,
        resurrect: []const types.DeletionMeta,
    ) !PendingResult {
        if (ops.len == 0) return .{
            .rejected = try self.allocator.dupe(u8, "apply requires at least one operation"),
        };
        var pending: PendingMutation = .{
            .anchors_before = try self.anchors_map.clone(self.allocator),
        };
        self.table.begin();
        errdefer self.rollbackPending(&pending);
        for (ops, 0..) |op, index| {
            const result_anchors = if (edits) |slice| &slice[index] else null;
            if (try self.applyPendingOp(&pending, op, result_anchors)) |message| {
                self.rollbackPending(&pending);
                return .{ .rejected = message };
            }
            // Resurrection only changes anchors, which rollback restores.
            try self.resurrectDeletionMetas(resurrect, index);
        }
        return .{ .applied = pending };
    }

    fn applyPendingOp(
        self: *BufferEngine,
        pending: *PendingMutation,
        op: types.BufferOp,
        edit_anchors: ?*EditAnchors,
    ) !?[]u8 {
        if (try validation.bufferOpMessage(self, op)) |message| return message;
        try pending.inverse_ops.ensureUnusedCapacity(self.allocator, 1);
        try pending.splices.ensureUnusedCapacity(self.allocator, 1);

        const edit = requestedEdit(op);
        const splice = try self.table.planReplace(edit.start, edit.end, edit.text);
        const inverse = self.inverseForSplice(
            splice,
            try self.table.getTextRange(splice.start, splice.old_end),
        );
        var inverse_owned = true;
        defer if (inverse_owned) freeOpText(self.allocator, inverse);

        // The hidden target anchor joins the anchor map; the snapshot removes it on rollback.
        const op_index: u32 = @intCast(pending.inverse_ops.items.len);
        if (try self.captureDeletionMeta(
            op_index,
            edit.start,
            edit.end,
            splice.start,
            inverse,
        )) |meta| {
            errdefer {
                var owned = meta;
                owned.deinit(self.allocator);
            }
            try pending.deletion_metas.append(self.allocator, meta);
        }

        try self.table.applySplice(splice, edit.text);
        pending.inverse_ops.appendAssumeCapacity(inverse);
        inverse_owned = false;
        pending.splices.appendAssumeCapacity(
            .{ .start = splice.start, .old_end = splice.old_end, .new_end = splice.new_end },
        );
        try self.rebaseAnchorsForSplice(splice, edit.text, restoredText(inverse));
        if (edit_anchors) |result| {
            // Created after this operation's own rebasing, so only later operations move them.
            const edges = try self.insertedEdges(splice, edit.text, restoredText(inverse));
            result.* = .{
                .start = try self.insertAnchor(edges.start, .weak, .transient),
                .end = try self.insertAnchor(edges.end, .sticky, .transient),
            };
        }
        return null;
    }

    /// The start (Weak) and end (Sticky) of an operation's inserted text, projected onto
    /// the boundaries that operation produced (SPEC §1.4).
    fn insertedEdges(
        self: *const BufferEngine,
        splice: Splice,
        inserted: []const u8,
        old_text: []const u8,
    ) !struct { start: u32, end: u32 } {
        if (splice.isAligned()) return .{ .start = splice.start, .end = splice.new_end };
        var bounds = try SpliceBoundaries.init(self, splice, inserted, old_text);
        defer bounds.deinit(self.allocator);
        const start_byte = splice.left_context_bytes;
        return .{
            .start = splice.start + projectToBoundary(bounds.new, start_byte, .weak),
            .end = splice.start + projectToBoundary(
                bounds.new,
                start_byte + @as(u32, @intCast(inserted.len)),
                .sticky,
            ),
        };
    }

    /// Discards the candidate tree and restores the anchors from the snapshot. Neither
    /// step allocates, so rollback succeeds even when the allocator is exhausted. Anchor
    /// ids consumed by rolled-back hidden anchors are not reused.
    fn rollbackPending(self: *BufferEngine, pending: *PendingMutation) void {
        self.table.abort();
        std.mem.swap(
            std.AutoHashMapUnmanaged(u32, anchors.Anchor),
            &self.anchors_map,
            &pending.anchors_before,
        );
        pending.deinit(self.allocator);
    }

    /// Moves a buffer transaction's results out of `pending`, then commits the text and
    /// advances the revision. On error nothing is committed and `pending` still owns
    /// what it did not hand over, so the caller rolls it back as usual.
    fn commitPending(self: *BufferEngine, pending: *PendingMutation) !Commit {
        const forward_revs = try self.allocator.alloc(u32, 1);
        errdefer self.allocator.free(forward_revs);
        const splices = try pending.splices.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(splices);
        // Undo replays the inverses in reverse; number each record by its replay position.
        const op_count = pending.inverse_ops.items.len;
        for (pending.deletion_metas.items) |*meta| meta.op = @intCast(op_count - 1 - meta.op);
        const deletion_metas: []const types.DeletionMeta = if (pending.deletion_metas.items.len > 0)
            try pending.deletion_metas.toOwnedSlice(self.allocator)
        else
            &.{};
        errdefer if (deletion_metas.len > 0) {
            for (deletion_metas) |meta| {
                var owned = meta;
                owned.deinit(self.allocator);
            }
            self.allocator.free(deletion_metas);
        };
        // Last fallible step: afterwards pending no longer owns the inverses.
        const inverse_ops = try pending.inverse_ops.toOwnedSlice(self.allocator);
        std.mem.reverse(types.BufferOp, inverse_ops);
        pending.deinit(self.allocator);

        self.table.commit();
        const old_revision = self.revision;
        self.revision += 1;
        forward_revs[0] = self.revision;
        return .{
            .old_revision = old_revision,
            .new_revision = self.revision,
            .splices = splices,
            .undo_entry = .{
                .forward_revs = forward_revs,
                .inverse_ops = inverse_ops,
                .deletion_metas = deletion_metas,
            },
        };
    }

    pub fn graphemeCount(self: *const BufferEngine) u32 {
        return self.table.graphemeCount();
    }

    pub fn byteCount(self: *const BufferEngine) u32 {
        return self.table.byteCount();
    }

    pub fn wordCount(self: *const BufferEngine) u32 {
        return self.table.wordCount();
    }

    pub fn lineCount(self: *const BufferEngine) u32 {
        return self.table.lineCount();
    }

    pub fn graphemeCursor(self: *const BufferEngine, position: u32) !piece_table.GraphemeCursor {
        return try self.table.graphemeCursor(position);
    }

    pub fn positionToLineCol(self: *const BufferEngine, position: u32) !piece_table.LineCol {
        return try self.table.positionToLineCol(position);
    }

    pub fn lineColToPosition(self: *const BufferEngine, line: u32, col: u32) !u32 {
        return try self.table.lineColToPosition(line, col);
    }

    pub fn lineStart(self: *const BufferEngine, line: u32) !u32 {
        return try self.table.lineStart(line);
    }

    pub fn lineEnd(self: *const BufferEngine, line: u32, include_newline: bool) !u32 {
        return try self.table.lineEnd(line, include_newline);
    }

    pub fn matchBracketAt(
        self: *const BufferEngine,
        pos: u32,
    ) !?piece_table.PieceTable.BracketMatch {
        return try self.table.matchBracketAt(pos);
    }

    /// Copies all UTF-8 text through the engine allocator; the caller frees the slice.
    pub fn getText(self: *const BufferEngine) ![]u8 {
        return try self.table.getText();
    }

    /// Copies the half-open grapheme range through the engine allocator; caller frees it.
    pub fn getTextRange(self: *const BufferEngine, start: u32, end: u32) ![]u8 {
        return try self.table.getTextRange(start, end);
    }

    fn searchMatchFromPosition(
        self: *const BufferEngine,
        query: []const u8,
        position: u32,
    ) !queries.SearchMatch {
        return .{
            .start = position,
            .end = position + self.countGraphemes(query),
            .text = try self.allocator.dupe(u8, query),
        };
    }

    pub fn findNext(
        self: *const BufferEngine,
        query: []const u8,
        start: u32,
    ) !?queries.SearchMatch {
        if (query.len == 0) return error.InvalidArgument;
        const position = (try self.table.findNext(query, start)) orelse return null;
        return try self.searchMatchFromPosition(query, position);
    }

    pub fn findPrevious(
        self: *const BufferEngine,
        query: []const u8,
        start: ?u32,
    ) !?queries.SearchMatch {
        if (query.len == 0) return error.InvalidArgument;
        const position = (try self.table.findPrevious(query, start)) orelse return null;
        return try self.searchMatchFromPosition(query, position);
    }

    pub fn queryPosition(self: *const BufferEngine, pos: u32) !queries.PositionInfo {
        const lc = try self.table.positionToLineCol(pos);
        return .{
            .position = pos,
            .line = lc.line,
            .col = lc.col,
            .line_start = try self.table.lineStart(lc.line),
            .line_end = try self.table.lineEnd(lc.line, false),
            .line_end_with_newline = try self.table.lineEnd(lc.line, true),
        };
    }

    pub fn queryLine(self: *const BufferEngine, line: u32) !queries.LineInfo {
        const start = try self.table.lineStart(line);
        const end = try self.table.lineEnd(line, false);
        const end_with_newline = try self.table.lineEnd(line, true);
        return .{
            .line = line,
            .start = start,
            .end = end,
            .end_with_newline = end_with_newline,
            .text = try self.table.getTextRange(start, end),
        };
    }

    pub fn queryVisibleLines(
        self: *const BufferEngine,
        start_line: u32,
        count: u32,
    ) ![]queries.LineInfo {
        if (count == 0) return &[_]queries.LineInfo{};
        const line_count = self.table.lineCount();
        if (start_line > line_count) return error.OutOfRange;

        const end_line = @min(start_line + count, line_count);
        if (start_line == end_line) return &[_]queries.LineInfo{};

        const start = try self.table.lineStart(start_line);
        const end = try self.table.lineStart(end_line);
        const text = try self.table.getTextRange(start, end);
        defer self.allocator.free(text);

        var lines = try std.ArrayList(queries.LineInfo).initCapacity(
            self.allocator,
            end_line - start_line,
        );
        errdefer {
            for (lines.items) |*li| li.deinit(self.allocator);
            lines.deinit(self.allocator);
        }

        var cursor: u32 = start;
        var iter = std.mem.splitScalar(u8, text, '\n');
        var offset: u32 = 0;

        while (iter.next()) |line_text| {
            if (offset >= end_line - start_line) break;

            const line = start_line + offset;

            // Re-segment to get exact grapheme count for this line
            var text_len: u32 = 0;
            var seg_iter = self.table.seg.iterator(line_text);
            while (seg_iter.next() != null) {
                text_len += 1;
            }

            const line_end = cursor + text_len;
            const end_with_newline = line_end + if (line + 1 < line_count) @as(u32, 1) else @as(
                u32,
                0,
            );

            try lines.append(self.allocator, .{
                .line = line,
                .start = cursor,
                .end = line_end,
                .end_with_newline = end_with_newline,
                .text = try self.allocator.dupe(u8, line_text),
            });

            cursor = end_with_newline;
            offset += 1;
        }

        return lines.toOwnedSlice(self.allocator);
    }

    /// Copies bounded visible rows using grapheme columns and a total grapheme budget.
    /// Call RegionInfo.deinit with the engine allocator. No document state is changed.
    pub fn queryRegion(
        self: *const BufferEngine,
        start_line: u32,
        count: u32,
        horizontal_col: u32,
        max_graphemes_per_row: u32,
        max_total_graphemes: u32,
    ) !queries.RegionInfo {
        const line_count = self.table.lineCount();
        if (start_line > line_count) return error.OutOfRange;

        const end_line = @min(start_line +| count, line_count);
        var rows = try std.ArrayList(queries.RegionLineInfo).initCapacity(
            self.allocator,
            end_line - start_line,
        );
        errdefer {
            for (rows.items) |*row| row.deinit(self.allocator);
            rows.deinit(self.allocator);
        }

        var remaining = max_total_graphemes;
        var budget_exhausted = false;
        var line = start_line;
        while (line < end_line) : (line += 1) {
            const full_start = try self.table.lineStart(line);
            const full_end = try self.table.lineEnd(line, false);
            const end_with_newline = try self.table.lineEnd(line, true);
            const line_len = full_end - full_start;
            const slice_start = full_start + @min(horizontal_col, line_len);
            const requested_len = @min(max_graphemes_per_row, full_end - slice_start);
            const slice_len = @min(requested_len, remaining);
            const slice_end = slice_start + slice_len;
            if (requested_len > slice_len) budget_exhausted = true;
            if (remaining >= slice_len) {
                remaining -= slice_len;
            } else {
                remaining = 0;
            }

            const text = try self.table.getTextRange(slice_start, slice_end);
            rows.append(self.allocator, .{
                .line = line,
                .full_start = full_start,
                .full_end = full_end,
                .end_with_newline = end_with_newline,
                .slice_start = slice_start,
                .slice_end = slice_end,
                .horizontal_col = horizontal_col,
                .truncated_left = slice_start > full_start,
                .truncated_right = slice_end < full_end,
                .text = text,
            }) catch |err| {
                self.allocator.free(text);
                return err;
            };
        }

        return .{
            .revision = self.revision,
            .line_count = line_count,
            .start_line = start_line,
            .horizontal_col = horizontal_col,
            .max_graphemes_per_row = max_graphemes_per_row,
            .budget_exhausted = budget_exhausted,
            .rows = try rows.toOwnedSlice(self.allocator),
        };
    }

    pub fn queryTokenSpans(
        self: *BufferEngine,
        start: u32,
        end: u32,
        revision: ?u32,
    ) ![]const views.TokenSpan {
        const requested_revision = revision orelse self.revision;
        if (requested_revision != self.revision) return error.InvalidArgument;
        if (start > end) return error.InvalidRange;
        if (end > self.graphemeCount()) return error.OutOfRange;

        const provider = self.view_providers.get("tokens") orelse return try self.allocator.alloc(
            views.TokenSpan,
            0,
        );
        var state = provider.stateFor("tokens", self.revision);
        if (state.kind == .stale) {
            state = provider.refresh(@ptrCast(self));
        }
        if (state.kind != .available and state.kind != .partial) {
            return try self.allocator.alloc(views.TokenSpan, 0);
        }
        return try provider.tokenSpans(self.allocator, @ptrCast(self), start, end, self.revision);
    }

    pub fn queryDiagnosticList(
        self: *const BufferEngine,
        start: ?u32,
        end: ?u32,
        revision: ?u32,
    ) ![]const views.Diagnostic {
        const requested_revision = revision orelse self.revision;
        if (requested_revision != self.revision) return error.InvalidArgument;
        if (start) |s| if (s > self.graphemeCount()) return error.OutOfRange;
        if (end) |e| if (e > self.graphemeCount()) return error.OutOfRange;
        if (start != null and end != null and start.? > end.?) return error.InvalidRange;

        const provider = self.view_providers.get(
            "diagnostics",
        ) orelse return try self.allocator.alloc(
            views.Diagnostic,
            0,
        );
        var state = provider.stateFor("diagnostics", self.revision);
        if (state.kind == .stale) state = provider.refresh(@ptrCast(@constCast(self)));
        if (state.kind != .available and state.kind != .partial) return try self.allocator.alloc(
            views.Diagnostic,
            0,
        );
        return try provider.diagnosticList(
            self.allocator,
            @ptrCast(@constCast(self)),
            start,
            end,
            self.revision,
        );
    }

    pub fn querySemanticTokens(
        self: *const BufferEngine,
        start: u32,
        end: u32,
        revision: ?u32,
    ) ![]const views.SemanticToken {
        const requested_revision = revision orelse self.revision;
        if (requested_revision != self.revision) return error.InvalidArgument;
        if (start > end) return error.InvalidRange;
        if (end > self.graphemeCount()) return error.OutOfRange;

        const provider = self.view_providers.get(
            "semantic_tokens",
        ) orelse return try self.allocator.alloc(
            views.SemanticToken,
            0,
        );
        var state = provider.stateFor("semantic_tokens", self.revision);
        if (state.kind == .stale) state = provider.refresh(@ptrCast(@constCast(self)));
        if (state.kind != .available and state.kind != .partial) return try self.allocator.alloc(
            views.SemanticToken,
            0,
        );
        return try provider.semanticTokens(
            self.allocator,
            @ptrCast(@constCast(self)),
            start,
            end,
            self.revision,
        );
    }

    pub fn queryEnclosingSyntaxNode(
        self: *BufferEngine,
        position: u32,
        revision: ?u32,
    ) !?views.SyntaxNodeInfo {
        const requested_revision = revision orelse self.revision;
        if (requested_revision != self.revision) return error.InvalidArgument;
        try self.table.validatePosition(position);

        const provider = self.view_providers.get("syntax") orelse return null;
        var state = provider.stateFor("syntax", self.revision);
        if (state.kind == .stale) {
            state = provider.refresh(@ptrCast(self));
        }
        if (state.kind != .available and state.kind != .partial) {
            return null;
        }
        return provider.enclosingNode(@ptrCast(self), position, self.revision);
    }

    pub fn querySyntaxNodeInfo(
        self: *BufferEngine,
        ref: views.SyntaxNodeRef,
    ) !views.SyntaxNodeInfo {
        if (ref.revision != self.revision) return error.InvalidArgument;
        const provider = self.view_providers.get("syntax") orelse return error.KeyError;
        return provider.nodeInfo(@ptrCast(self), ref);
    }

    pub fn queryTypeAt(self: *BufferEngine, position: u32, revision: ?u32) !?views.TypeInfo {
        const requested_revision = revision orelse self.revision;
        if (requested_revision != self.revision) return error.InvalidArgument;
        try self.table.validatePosition(position);

        const provider = self.view_providers.get("type_info") orelse return null;
        var state = provider.stateFor("type_info", self.revision);
        if (state.kind == .stale) {
            state = provider.refresh(@ptrCast(self));
        }
        if (state.kind != .available and state.kind != .partial) {
            return null;
        }
        return try provider.typeAt(@ptrCast(self), position, self.revision);
    }

    pub fn queryHover(self: *BufferEngine, position: u32, revision: ?u32) !?views.HoverInfo {
        const requested_revision = revision orelse self.revision;
        if (requested_revision != self.revision) return error.InvalidArgument;
        try self.table.validatePosition(position);

        const provider = self.view_providers.get("hover") orelse return null;
        var state = provider.stateFor("hover", self.revision);
        if (state.kind == .stale) {
            state = provider.refresh(@ptrCast(self));
        }
        if (state.kind != .available and state.kind != .partial) {
            return null;
        }
        return try provider.hoverAt(@ptrCast(self), position, self.revision);
    }

    pub fn queryDefinition(
        self: *BufferEngine,
        position: u32,
        revision: ?u32,
    ) !views.DefinitionResult {
        const requested_revision = revision orelse self.revision;
        if (requested_revision != self.revision) return error.InvalidArgument;
        try self.table.validatePosition(position);

        const provider = self.view_providers.get("symbols") orelse return .not_supported;
        var state = provider.stateFor("symbols", self.revision);
        if (state.kind == .stale) state = provider.refresh(@ptrCast(self));
        if (state.kind != .available and state.kind != .partial) return .none;
        return try provider.definition(@ptrCast(self), position, self.revision);
    }

    pub fn queryReferences(
        self: *BufferEngine,
        position: u32,
        revision: ?u32,
    ) !views.ReferencesResult {
        const requested_revision = revision orelse self.revision;
        if (requested_revision != self.revision) return error.InvalidArgument;
        try self.table.validatePosition(position);

        const provider = self.view_providers.get("symbols") orelse return .not_supported;
        var state = provider.stateFor("symbols", self.revision);
        if (state.kind == .stale) state = provider.refresh(@ptrCast(self));
        if (state.kind != .available and state.kind != .partial) return .{ .locations = &.{} };
        return try provider.references(@ptrCast(self), position, self.revision);
    }

    pub fn queryRenamePrepare(
        self: *BufferEngine,
        position: u32,
        revision: ?u32,
    ) !views.RenamePrepareResult {
        const requested_revision = revision orelse self.revision;
        if (requested_revision != self.revision) return error.InvalidArgument;
        try self.table.validatePosition(position);

        const provider = self.view_providers.get("symbols") orelse return .not_supported;
        var state = provider.stateFor("symbols", self.revision);
        if (state.kind == .stale) state = provider.refresh(@ptrCast(self));
        if (state.kind != .available and state.kind != .partial) return .none;
        return try provider.renamePrepare(@ptrCast(self), position, self.revision);
    }

    pub fn hasViewProvider(self: *const BufferEngine, view: []const u8) bool {
        return self.view_providers.contains(view);
    }

    pub fn viewProviderName(self: *const BufferEngine, view: []const u8) ?[]const u8 {
        const provider = self.view_providers.get(view) orelse return null;
        return provider.name();
    }

    /// Returns borrowed capability metadata. supported_views uses engine-owned scratch
    /// storage and is overwritten by the next queryCapabilities call.
    pub fn queryCapabilities(self: *BufferEngine) types.EngineCapabilities {
        var capabilities = evaluation.queryCapabilities();
        var len: usize = 0;
        self.capability_supported_views_storage[len] = "text";
        len += 1;
        self.capability_supported_views_storage[len] = "anchors";
        len += 1;
        self.capability_supported_views_storage[len] = "summaries";
        len += 1;

        for ([_][]const u8{
            "tokens",
            "syntax",
            "diagnostics",
            "semantic_tokens",
            "type_info",
            "hover",
            "symbols",
        }) |view| {
            if (self.hasViewProvider(view)) {
                self.capability_supported_views_storage[len] = view;
                len += 1;
            }
        }
        if (self.hasViewProvider("symbols")) {
            capabilities.symbol_capabilities = self.view_providers.get(
                "symbols",
            ).?.symbolCapabilities();
        }
        capabilities.supported_views = self.capability_supported_views_storage[0..len];
        return capabilities;
    }

    /// Runs a native callback against the current revision. The returned outcome owns
    /// its result/error data through the engine allocator; call deinit on it.
    pub fn bufferEval(
        self: *const BufferEngine,
        request: types.EvalRequest,
    ) !types.BufferEvalOutcome {
        return try evaluation.bufferEval(self, request);
    }
};

fn testProviderDeinitNoop(_: *anyopaque, _: std.mem.Allocator) void {}

test "rollbackRegisteredViews removes inserted views without freeing borrowed keys" {
    const Provider = struct {
        fn syntaxProvider(self: *@This()) views.ViewProvider {
            return .{ .ptr = self, .vtable = &syntax_vtable };
        }

        fn stateFor(_: *anyopaque, view: []const u8, revision: u32) views.ViewState {
            return .{ .view = view, .revision = revision, .kind = .available };
        }

        fn refresh(_: *anyopaque, engine: *anyopaque) views.ViewState {
            const typed_engine: *BufferEngine = @ptrCast(@alignCast(engine));
            return .{ .view = "syntax", .revision = typed_engine.revision, .kind = .available };
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
            _: ?u32,
            _: ?u32,
            _: u32,
        ) ![]const views.Diagnostic {
            return try allocator.alloc(views.Diagnostic, 0);
        }

        fn semanticTokens(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            _: *anyopaque,
            _: u32,
            _: u32,
            _: u32,
        ) ![]const views.SemanticToken {
            return try allocator.alloc(views.SemanticToken, 0);
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

        const syntax_vtable = views.ViewProvider.VTable{
            .name = "syntax-only",
            .views = &[_][]const u8{"syntax"},
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

    var provider = Provider{};
    const syntax_provider = provider.syntaxProvider();
    try engine.view_providers.put(engine.allocator, "syntax", syntax_provider);
    try std.testing.expect(engine.hasViewProvider("syntax"));

    engine.rollbackRegisteredViews(&.{"syntax"});
    try std.testing.expect(!engine.hasViewProvider("syntax"));
}

test "registerViewProviders rolls back partial registration when a later put fails" {
    const Provider = struct {
        fn syntaxProvider(self: *@This()) views.ViewProvider {
            return .{ .ptr = self, .vtable = &syntax_vtable };
        }

        fn tokensProvider(self: *@This()) views.ViewProvider {
            return .{ .ptr = self, .vtable = &tokens_vtable };
        }

        fn stateFor(_: *anyopaque, view: []const u8, revision: u32) views.ViewState {
            return .{ .view = view, .revision = revision, .kind = .available };
        }

        fn refresh(_: *anyopaque, engine: *anyopaque) views.ViewState {
            const typed_engine: *BufferEngine = @ptrCast(@alignCast(engine));
            return .{ .view = "syntax", .revision = typed_engine.revision, .kind = .available };
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
            _: ?u32,
            _: ?u32,
            _: u32,
        ) ![]const views.Diagnostic {
            return try allocator.alloc(views.Diagnostic, 0);
        }

        fn semanticTokens(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            _: *anyopaque,
            _: u32,
            _: u32,
            _: u32,
        ) ![]const views.SemanticToken {
            return try allocator.alloc(views.SemanticToken, 0);
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

        const syntax_vtable = views.ViewProvider.VTable{
            .name = "syntax-only",
            .views = &[_][]const u8{"syntax"},
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

        const tokens_vtable = views.ViewProvider.VTable{
            .name = "tokens-only",
            .views = &[_][]const u8{"tokens"},
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

    const PutLimiter = struct {
        puts_remaining: usize,

        fn put(
            self: *@This(),
            engine: *BufferEngine,
            view: []const u8,
            provider: views.ViewProvider,
        ) !void {
            if (self.puts_remaining == 0) return error.OutOfMemory;
            self.puts_remaining -= 1;
            try engine.view_providers.put(engine.allocator, view, provider);
        }
    };

    var engine = try BufferEngine.initFromText(std.testing.allocator, "abc", null);
    defer engine.deinit();

    var syntax_provider = Provider{};
    var tokens_provider = Provider{};
    const provider_list = [_]views.ViewProvider{
        syntax_provider.syntaxProvider(),
        tokens_provider.tokensProvider(),
    };

    var pending_views: std.ArrayListUnmanaged([]const u8) = .empty;
    defer pending_views.deinit(std.testing.allocator);
    for (provider_list) |provider| {
        for (provider.views()) |view| {
            try pending_views.append(std.testing.allocator, view);
        }
    }

    var limiter = PutLimiter{ .puts_remaining = 1 };

    const register_batch = struct {
        fn run(
            engine_ptr: *BufferEngine,
            put_limiter: *PutLimiter,
            providers: []const views.ViewProvider,
            views_in_order: []const []const u8,
        ) !void {
            var registered_count: usize = 0;
            errdefer engine_ptr.rollbackRegisteredViews(views_in_order[0..registered_count]);

            var view_index: usize = 0;
            for (providers) |provider| {
                for (provider.views()) |view| {
                    _ = view;
                    try put_limiter.put(engine_ptr, views_in_order[view_index], provider);
                    registered_count += 1;
                    view_index += 1;
                }
            }
        }
    }.run;

    try std.testing.expectError(
        error.OutOfMemory,
        register_batch(&engine, &limiter, &provider_list, pending_views.items),
    );
    try std.testing.expect(!engine.hasViewProvider("syntax"));
    try std.testing.expect(!engine.hasViewProvider("tokens"));
}
