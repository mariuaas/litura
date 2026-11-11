//! Owning document state: revisions, sessions, guarded edits and shared history.

const std = @import("std");
const log = std.log.scoped(.litura);

const piece_table = @import("piece_table.zig");
const anchors = @import("anchors.zig");
const queries = @import("queries.zig");
const views = @import("views.zig");

const types = @import("buffer_types.zig");
const validation = @import("buffer_validation.zig");
const evaluation = @import("buffer_eval.zig");

pub const InteractionCursor = struct {
    anchor: anchors.AnchorId,
    mark: ?anchors.AnchorId = null,
};

pub const InteractionState = struct {
    cursors: std.ArrayListUnmanaged(InteractionCursor) = .empty,
    revision: u32 = 0,

    /// Releases the document and owned providers. All borrowed cursors/results expire.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.cursors.deinit(allocator);
        self.* = undefined;
    }
};

pub const Session = struct {
    id: u32,
    interaction: InteractionState = .{},

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.interaction.deinit(allocator);
        self.* = undefined;
    }
};

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
    next_anchor_id: u32 = 1,

    sessions: std.AutoHashMapUnmanaged(u32, Session) = .empty,
    next_session_id: u32 = 1,

    undo_stack: std.ArrayListUnmanaged(types.UndoEntry) = .empty,
    redo_stack: std.ArrayListUnmanaged(types.UndoEntry) = .empty,

    view_providers: std.StringHashMapUnmanaged(views.ViewProvider) = .empty,
    /// Set while view providers are being notified; mutation is rejected meanwhile.
    notifying: bool = false,
    capability_supported_views_storage: [10][]const u8 = undefined,

    const MutationCommit = struct {
        event: types.EditEvent,
        undo_entry: types.UndoEntry,

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.event.deinit(allocator);
            self.undo_entry.deinit(allocator);
            self.* = undefined;
        }
    };

    const Splice = piece_table.PieceTable.Splice;

    /// Providers already notified of an event. Reserved before publication, so
    /// notifying cannot fail after it.
    const ProviderSet = std.AutoHashMapUnmanaged(usize, void);

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

    /// Anchors carrying a buffer operation's realized result through later operations.
    const EditAnchors = struct {
        start: anchors.AnchorId,
        end: anchors.AnchorId,
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
        affected_ranges: std.ArrayListUnmanaged(types.Range) = .empty,
        deletion_metas: std.ArrayListUnmanaged(types.DeletionMeta) = .empty,

        fn deinit(self: *PendingMutation, allocator: std.mem.Allocator) void {
            self.anchors_before.deinit(allocator);
            for (self.inverse_ops.items) |op| freeOpText(allocator, op);
            self.inverse_ops.deinit(allocator);
            self.affected_ranges.deinit(allocator);
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
    /// Allocation-failure cleanup is incomplete; see docs/known-issues.md.
    pub fn initFromText(
        allocator: std.mem.Allocator,
        text: []const u8,
        path: ?[]const u8,
    ) !BufferEngine {
        var engine = try init(allocator);
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
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_bytes)) catch |err| switch (err) {
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
        var seen_providers = std.AutoHashMap(usize, void).init(self.allocator);
        defer seen_providers.deinit();
        var provider_iter = self.view_providers.valueIterator();
        while (provider_iter.next()) |provider| {
            const identity = @intFromPtr(provider.ptr);
            if (seen_providers.contains(identity)) continue;
            seen_providers.put(identity, {}) catch {};
            provider.deinit(self.allocator);
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

    /// Synchronously writes the whole document, then marks its revision saved.
    /// A supplied path replaces the stored path before I/O, including on I/O failure.
    pub fn save(self: *BufferEngine, path: ?[]const u8) !void {
        if (path) |new_path| {
            const owned = try self.allocator.dupe(u8, new_path);
            if (self.path) |existing| self.allocator.free(existing);
            self.path = owned;
        }

        const resolved_path = self.path orelse return error.InvalidArgument;
        const text = try self.getText();
        defer self.allocator.free(text);

        const io = std.Io.Threaded.global_single_threaded.io();
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = resolved_path,
            .data = text,
        });
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
        const provider = self.view_providers.get(view) orelse return views.ViewState.absent(view, self.revision);
        return provider.stateFor(view, self.revision);
    }

    pub fn refreshView(self: *BufferEngine, view: []const u8) views.ViewState {
        const provider = self.view_providers.get(view) orelse return views.ViewState.absent(view, self.revision);
        return provider.refresh(@ptrCast(self));
    }

    fn setSessionMarkPositionNoRevision(
        self: *BufferEngine,
        session_id: u32,
        cursor_anchor: anchors.AnchorId,
        mark_position: ?u32,
    ) !void {
        const cursor = try self.interactionCursorForAnchor(session_id, cursor_anchor);
        const old_mark = cursor.mark;

        if (mark_position) |pos| {
            const new_mark = try self.createAnchor(pos, .weak);
            cursor.mark = new_mark;
            if (old_mark) |mark| try self.dropAnchor(mark);
        } else {
            if (old_mark) |mark| try self.dropAnchor(mark);
            cursor.mark = null;
        }
    }

    fn applyInteractionMutation(
        self: *BufferEngine,
        payload: types.InteractionMutation,
    ) !types.InteractionResult {
        const session = self.sessions.getPtr(payload.session_id) orelse return error.KeyError;
        const old_revision = session.interaction.revision;

        for (payload.ops) |op| {
            switch (op) {
                .move_cursor_anchor => |move| try self.moveAnchor(move.cursor, move.position),
                .set_cursor_selection => |selection| try self.setSessionMarkPositionNoRevision(payload.session_id, selection.cursor, selection.mark_position),
                .place_cursor => |place| {
                    try self.moveAnchor(place.cursor, try concretePosition(place.at));
                    const mark = if (place.mark) |target| try concretePosition(target) else null;
                    try self.setSessionMarkPositionNoRevision(payload.session_id, place.cursor, mark);
                },
            }
        }

        session.interaction.revision += 1;
        return .{
            .session_id = payload.session_id,
            .old_revision = old_revision,
            .new_revision = session.interaction.revision,
        };
    }

    /// Edit references must have been resolved by the enclosing composite.
    fn concretePosition(target: types.InteractionTarget) !u32 {
        return switch (target) {
            .position => |position| position,
            .edit => error.InvalidArgument,
        };
    }

    /// Notifies each distinct provider once, as the last step of a submission, after
    /// every part of it (including a composite's interaction part) is published. `seen`
    /// must be empty with capacity for every registered provider. A provider that tries
    /// to mutate the engine from its callback is refused with error.ReentrantMutation.
    fn notifyViewProviders(self: *BufferEngine, event: *const types.EditEvent, seen: *ProviderSet) void {
        self.notifying = true;
        defer self.notifying = false;
        var iter = self.view_providers.valueIterator();
        while (iter.next()) |provider| {
            const identity = @intFromPtr(provider.ptr);
            if (seen.contains(identity)) continue;
            seen.putAssumeCapacity(identity, {});
            provider.onBufferEvent(@ptrCast(self), @ptrCast(@constCast(event)));
        }
    }

    /// Validates origins and guards, then applies the intent synchronously.
    /// Rejections are owning validation reports and leave no observable effect, as do
    /// errors, including allocation failure. Returns error.ReentrantMutation when called
    /// from a view provider's notification.
    pub fn submit(self: *BufferEngine, intent: types.Intent) !types.SubmitResult {
        if (self.notifying) return error.ReentrantMutation;
        switch (intent.payload) {
            .buffer_mutation => |payload| {
                if (try validation.validationReportForStaleBufferOrigin(self, intent)) |report| {
                    return .{ .validation_report = report };
                }
                if (try validation.validationReportForGuards(self, intent)) |report| {
                    return .{ .validation_report = report };
                }
                var pending = switch (try self.applyOpsPending(payload.ops, null)) {
                    .applied => |applied| applied,
                    .rejected => |message| return self.invalidReport(intent, message),
                };
                var providers: ProviderSet = .empty;
                defer providers.deinit(self.allocator);
                const event = try self.finishCommit(
                    &pending,
                    payload.ops,
                    intent.source,
                    intent.cause,
                    &self.undo_stack,
                    &providers,
                );
                self.discardRedo();
                self.notifyViewProviders(&event, &providers);
                return .{ .edit_event = event };
            },
            .interaction_mutation => |payload| {
                if (try validation.validationReportForStaleInteractionOrigin(self, intent, payload)) |report| {
                    return .{ .validation_report = report };
                }
                // Positions are document coordinates: they need a current document origin.
                if (validation.interactionHasPositions(payload)) {
                    if (try validation.validationReportForStaleBufferOrigin(self, intent)) |report| {
                        return .{ .validation_report = report };
                    }
                }
                if (try validation.validationReportForGuards(self, intent)) |report| {
                    return .{ .validation_report = report };
                }
                if (try validation.validateInteractionMutation(self, payload, self.table.graphemeCount())) |message| {
                    defer self.allocator.free(message);
                    return .{ .validation_report = try validation.validationReport(self, intent, .invalid, message, try self.allocator.alloc(types.GuardEval, 0)) };
                }
                return .{ .interaction_result = try self.applyInteractionMutation(payload) };
            },
            .composite => |payload| return self.submitComposite(intent, payload),
            .undo => {
                if (try validation.validationReportForStaleBufferOrigin(self, intent)) |report| {
                    return .{ .validation_report = report };
                }
                if (try validation.validationReportForGuards(self, intent)) |report| {
                    return .{ .validation_report = report };
                }
                if (self.undo_stack.items.len == 0) {
                    return .{ .validation_report = try validation.validationReport(self, intent, .invalid, "nothing to undo", try self.allocator.alloc(types.GuardEval, 0)) };
                }

                // Popping keeps the capacity that restoring the entry on failure needs.
                var original = self.undo_stack.pop().?;
                errdefer self.undo_stack.appendAssumeCapacity(original);
                var providers: ProviderSet = .empty;
                defer providers.deinit(self.allocator);
                const event = try self.applyOpsCommitted(
                    original.inverse_ops,
                    intent.source,
                    intent.cause,
                    &self.redo_stack,
                    original.deletion_metas,
                    &providers,
                );
                original.deinit(self.allocator);
                self.notifyViewProviders(&event, &providers);
                return .{ .edit_event = event };
            },
            .redo => {
                if (try validation.validationReportForStaleBufferOrigin(self, intent)) |report| {
                    return .{ .validation_report = report };
                }
                if (try validation.validationReportForGuards(self, intent)) |report| {
                    return .{ .validation_report = report };
                }
                if (self.redo_stack.items.len == 0) {
                    return .{ .validation_report = try validation.validationReport(self, intent, .invalid, "nothing to redo", try self.allocator.alloc(types.GuardEval, 0)) };
                }

                // Popping keeps the capacity that restoring the entry on failure needs.
                var original = self.redo_stack.pop().?;
                errdefer self.redo_stack.appendAssumeCapacity(original);
                var providers: ProviderSet = .empty;
                defer providers.deinit(self.allocator);
                const event = try self.applyOpsCommitted(
                    original.inverse_ops,
                    intent.source,
                    intent.cause,
                    &self.undo_stack,
                    original.deletion_metas,
                    &providers,
                );
                original.deinit(self.allocator);
                self.notifyViewProviders(&event, &providers);
                return .{ .edit_event = event };
            },
        }
    }

    fn submitComposite(
        self: *BufferEngine,
        intent: types.Intent,
        payload: types.Composite,
    ) !types.SubmitResult {
        if (try validation.validationReportForStaleBufferOrigin(self, intent)) |report| {
            return .{ .validation_report = report };
        }
        if (try validation.validationReportForGuards(self, intent)) |report| {
            return .{ .validation_report = report };
        }

        const flat_parts = try validation.flattenCompositeParts(self.allocator, payload.parts);
        defer self.allocator.free(flat_parts);
        var parts: CompositeParts = .{};
        defer parts.deinit(self.allocator);
        if (try self.collectCompositeParts(intent, flat_parts, &parts)) |rejection| return rejection;
        const buffer_ops = parts.buffer_ops.items;

        // Buffer operations are applied provisionally: interaction positions address the
        // text they produce, whose grapheme count cannot be predicted from requested text.
        var pending: ?PendingMutation = null;
        errdefer if (pending) |*applied| self.rollbackPending(applied);
        const edit_anchors: ?[]EditAnchors = if (parts.has_edit_refs)
            try self.allocator.alloc(EditAnchors, buffer_ops.len)
        else
            null;
        defer if (edit_anchors) |slice| self.allocator.free(slice);
        if (buffer_ops.len > 0) {
            pending = switch (try self.applyOpsPending(buffer_ops, edit_anchors)) {
                .applied => |applied| applied,
                .rejected => |message| return self.invalidReport(intent, message),
            };
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const prepared = try self.prepareCompositeInteractions(
            arena.allocator(),
            parts.interactions.items,
            edit_anchors,
        );
        const resolved = switch (prepared) {
            .resolved => |resolved| resolved,
            .rejected => |message| {
                if (pending) |*applied| self.rollbackPending(applied);
                pending = null;
                return self.invalidReport(intent, message);
            },
        };

        // Applying the interactions must not fail after the commit: reserve their anchors.
        try self.anchors_map.ensureUnusedCapacity(self.allocator, markCount(resolved));
        var providers: ProviderSet = .empty;
        defer providers.deinit(self.allocator);
        var event: ?types.EditEvent = null;
        if (pending) |applied| {
            var owned = applied;
            pending = null;
            event = try self.finishCommit(
                &owned,
                buffer_ops,
                intent.source,
                intent.cause,
                &self.undo_stack,
                &providers,
            );
            self.discardRedo();
        }

        var interaction_result: ?types.InteractionResult = null;
        for (resolved) |interaction| {
            interaction_result = try self.applyInteractionMutation(interaction);
        }

        if (event) |*edit_event| {
            // The composite is complete: providers see the edit and the interaction together.
            self.notifyViewProviders(edit_event, &providers);
            return .{ .edit_event = edit_event.* };
        }
        return .{ .interaction_result = interaction_result.? };
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
                        return try self.invalidMessage(intent, "apply requires at least one operation");
                    }
                    try parts.buffer_ops.appendSlice(self.allocator, buffer.ops);
                },
                .interaction_mutation => |interaction| {
                    seen_interaction = true;
                    if (try validation.validationReportForStaleInteractionOrigin(self, intent, interaction)) |report| {
                        return .{ .validation_report = report };
                    }
                    try parts.interactions.append(self.allocator, interaction);
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
            return try self.invalidMessage(intent, "composite intent requires at least one payload");
        }
        for (parts.interactions.items) |interaction| {
            if (!validation.interactionHasEditRefs(interaction)) continue;
            parts.has_edit_refs = true;
            if (editRefOutOfRange(interaction, parts.buffer_ops.items.len)) |op| {
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

    /// Resolves edit references to positions, drops their result anchors and validates
    /// every interaction against the text the buffer operations produced. The resolved
    /// payloads live in arena; a rejection message is owned by the caller.
    fn prepareCompositeInteractions(
        self: *BufferEngine,
        arena: std.mem.Allocator,
        interactions: []const types.InteractionMutation,
        edit_anchors: ?[]const EditAnchors,
    ) !union(enum) { resolved: []const types.InteractionMutation, rejected: []u8 } {
        const resolved = try arena.dupe(types.InteractionMutation, interactions);
        if (edit_anchors) |by_op| {
            const unresolved = self.resolveEditRefs(arena, resolved, by_op);
            for (by_op) |edit| {
                try self.dropAnchor(edit.start);
                try self.dropAnchor(edit.end);
            }
            if (try unresolved) |op| {
                return .{
                    .rejected = try std.fmt.allocPrint(
                        self.allocator,
                        "edit reference to buffer operation {d} was deleted by a later operation",
                        .{op},
                    ),
                };
            }
        }
        for (resolved) |interaction| {
            const length = self.table.graphemeCount();
            if (try validation.validateInteractionMutation(self, interaction, length)) |message| {
                return .{ .rejected = message };
            }
        }
        return .{ .resolved = resolved };
    }

    fn editRefOutOfRange(payload: types.InteractionMutation, op_count: usize) ?u32 {
        for (payload.ops) |op| switch (op) {
            .place_cursor => |place| {
                const targets = [_]?types.InteractionTarget{ place.at, place.mark };
                for (targets) |maybe_target| {
                    const target = maybe_target orelse continue;
                    if (target == .edit and target.edit.op >= op_count) return target.edit.op;
                }
            },
            else => {},
        };
        return null;
    }

    /// Replaces edit references with the current positions of their result anchors.
    /// Returns the referenced operation whose Weak start anchor died, if any.
    fn resolveEditRefs(
        self: *const BufferEngine,
        arena: std.mem.Allocator,
        payloads: []types.InteractionMutation,
        by_op: []const EditAnchors,
    ) !?u32 {
        for (payloads) |*payload| {
            if (!validation.interactionHasEditRefs(payload.*)) continue;
            const ops = try arena.dupe(types.InteractionOp, payload.ops);
            for (ops) |*op| switch (op.*) {
                .place_cursor => |*place| {
                    place.at = (try self.resolveTarget(place.at, by_op)) orelse return place.at.edit.op;
                    if (place.mark) |mark| {
                        place.mark = (try self.resolveTarget(mark, by_op)) orelse return mark.edit.op;
                    }
                },
                else => {},
            };
            payload.ops = ops;
        }
        return null;
    }

    fn resolveTarget(
        self: *const BufferEngine,
        target: types.InteractionTarget,
        by_op: []const EditAnchors,
    ) !?types.InteractionTarget {
        const ref = switch (target) {
            .position => return target,
            .edit => |ref| ref,
        };
        const edit = by_op[ref.op];
        const info = try self.queryAnchor(if (ref.edge == .start) edit.start else edit.end);
        return .{ .position = info.position orelse return null };
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
            .validation_report = try validation.validationReport(
                self,
                intent,
                .invalid,
                message,
                try self.allocator.alloc(types.GuardEval, 0),
            ),
        };
    }

    /// A new edit makes the redo branch unreachable (SPEC §2.5.6).
    fn discardRedo(self: *BufferEngine) void {
        for (self.redo_stack.items) |*entry| entry.deinit(self.allocator);
        self.redo_stack.clearRetainingCapacity();
    }

    /// Upper bound on the mark anchors that applying these interactions creates.
    fn markCount(interactions: []const types.InteractionMutation) u32 {
        var count: u32 = 0;
        for (interactions) |interaction| for (interaction.ops) |op| switch (op) {
            .move_cursor_anchor => {},
            .set_cursor_selection => |selection| count += @intFromBool(
                selection.mark_position != null,
            ),
            .place_cursor => |place| count += @intFromBool(place.mark != null),
        };
        return count;
    }

    fn validateLiveAnchor(self: *const BufferEngine, anchor_id: anchors.AnchorId) !void {
        if (self.anchors_map.get(anchor_id.value)) |anchor| {
            if (anchor.status == .dead) return error.KeyError;
        } else {
            return error.KeyError;
        }
    }

    pub fn createAnchor(
        self: *BufferEngine,
        position: u32,
        stickiness: anchors.AnchorStickiness,
    ) !anchors.AnchorId {
        if (position > self.table.graphemeCount()) return error.OutOfRange;
        const id = anchors.AnchorId{ .value = self.next_anchor_id };
        self.next_anchor_id += 1;
        try self.anchors_map.put(self.allocator, id.value, .{
            .id = id,
            .position = position,
            .stickiness = stickiness,
            .status = .live,
        });
        return id;
    }

    pub fn dropAnchor(self: *BufferEngine, anchor_id: anchors.AnchorId) !void {
        if (!self.anchors_map.remove(anchor_id.value)) {
            return error.KeyError;
        }
    }

    /// Moves an existing anchor directly. This low-level operation does not validate
    /// bounds or increment session interaction revisions; use guarded intents for coherence.
    pub fn moveAnchor(self: *BufferEngine, anchor_id: anchors.AnchorId, position: u32) !void {
        if (self.anchors_map.getPtr(anchor_id.value)) |anchor| {
            anchor.position = position;
        } else {
            return error.KeyError;
        }
    }

    pub fn queryAnchor(self: *const BufferEngine, anchor_id: anchors.AnchorId) !queries.AnchorInfo {
        if (self.anchors_map.get(anchor_id.value)) |anchor| {
            return .{
                .id = anchor.id,
                .position = if (anchor.status == .live) anchor.position else null,
                .stickiness = anchor.stickiness,
                .status = anchor.status,
            };
        }
        return error.KeyError;
    }

    pub fn createSession(self: *BufferEngine, cursor_anchors: []const anchors.AnchorId) !u32 {
        if (cursor_anchors.len == 0) return error.InvalidArgument;

        const session_id = self.next_session_id;
        self.next_session_id += 1;

        var session = Session{ .id = session_id };
        errdefer session.deinit(self.allocator);

        for (cursor_anchors) |anchor_id| {
            try self.validateLiveAnchor(anchor_id);
            try session.interaction.cursors.append(self.allocator, .{ .anchor = anchor_id });
        }

        try self.sessions.put(self.allocator, session_id, session);
        return session_id;
    }

    pub fn interactionRevision(self: *const BufferEngine, session_id: u32) !u32 {
        if (self.sessions.get(session_id)) |sess| {
            return sess.interaction.revision;
        }
        return error.KeyError;
    }

    pub fn sessionCursors(
        self: *BufferEngine,
        allocator: std.mem.Allocator,
        session_id: u32,
    ) ![]anchors.AnchorId {
        if (self.sessions.get(session_id)) |sess| {
            var cursors = try std.ArrayList(anchors.AnchorId).initCapacity(allocator, sess.interaction.cursors.items.len);
            for (sess.interaction.cursors.items) |cursor| {
                cursors.appendAssumeCapacity(cursor.anchor);
            }
            return cursors.toOwnedSlice(allocator);
        }
        return error.KeyError;
    }

    fn interactionCursorForAnchor(
        self: *BufferEngine,
        session_id: u32,
        cursor_anchor: anchors.AnchorId,
    ) !*InteractionCursor {
        if (self.sessions.getPtr(session_id)) |sess| {
            for (sess.interaction.cursors.items) |*cursor| {
                if (cursor.anchor.value == cursor_anchor.value) return cursor;
            }
        }
        return error.KeyError;
    }

    pub fn querySessionMark(
        self: *BufferEngine,
        session_id: u32,
        cursor_anchor: anchors.AnchorId,
    ) !?anchors.AnchorId {
        const cursor = try self.interactionCursorForAnchor(session_id, cursor_anchor);
        return cursor.mark;
    }

    pub fn addSessionCursor(
        self: *BufferEngine,
        session_id: u32,
        cursor_anchor: anchors.AnchorId,
    ) !void {
        const sess = self.sessions.getPtr(session_id) orelse return error.KeyError;
        try self.validateLiveAnchor(cursor_anchor);
        for (sess.interaction.cursors.items) |cursor| {
            if (cursor.anchor.value == cursor_anchor.value) return error.InvalidArgument;
        }
        try sess.interaction.cursors.append(self.allocator, .{ .anchor = cursor_anchor });
        sess.interaction.revision += 1;
    }

    pub fn dropSessionCursor(
        self: *BufferEngine,
        session_id: u32,
        cursor_anchor: anchors.AnchorId,
        drop_anchor: bool,
    ) !void {
        const sess = self.sessions.getPtr(session_id) orelse return error.KeyError;
        var found_idx: ?usize = null;
        for (sess.interaction.cursors.items, 0..) |cursor, i| {
            if (cursor.anchor.value == cursor_anchor.value) {
                found_idx = i;
                if (cursor.mark) |mark| {
                    try self.dropAnchor(mark);
                }
                break;
            }
        }
        if (found_idx) |idx| {
            _ = sess.interaction.cursors.orderedRemove(idx);
            sess.interaction.revision += 1;
            if (drop_anchor) {
                try self.dropAnchor(cursor_anchor);
            }
        } else {
            return error.KeyError;
        }
    }

    pub fn dropSession(
        self: *BufferEngine,
        session_id: u32,
        cursor_anchor: anchors.AnchorId,
    ) !void {
        try self.dropSessionCursor(session_id, cursor_anchor, true);
        const session = self.sessions.getPtr(session_id) orelse return error.KeyError;
        if (session.interaction.cursors.items.len != 0) return error.InvalidArgument;
        session.deinit(self.allocator);
        _ = self.sessions.remove(session_id);
    }

    pub fn setSessionMarkPosition(
        self: *BufferEngine,
        session_id: u32,
        cursor_anchor: anchors.AnchorId,
        mark_position: ?u32,
    ) !void {
        const sess = self.sessions.getPtr(session_id) orelse return error.KeyError;
        const cursor = try self.interactionCursorForAnchor(session_id, cursor_anchor);
        const old_mark = cursor.mark;

        if (mark_position) |pos| {
            if (pos > self.table.graphemeCount()) return error.OutOfRange;
            const new_mark = try self.createAnchor(pos, .weak);
            cursor.mark = new_mark;
            if (old_mark) |mark| try self.dropAnchor(mark);
        } else {
            if (old_mark) |mark| try self.dropAnchor(mark);
            cursor.mark = null;
        }
        sess.interaction.revision += 1;
    }

    pub fn setSessionMarkAnchor(
        self: *BufferEngine,
        session_id: u32,
        cursor_anchor: anchors.AnchorId,
        mark_anchor: ?anchors.AnchorId,
    ) !void {
        const sess = self.sessions.getPtr(session_id) orelse return error.KeyError;
        const cursor = try self.interactionCursorForAnchor(session_id, cursor_anchor);
        const old_mark = cursor.mark;

        if (old_mark != null and mark_anchor != null and old_mark.?.value == mark_anchor.?.value) {
            return;
        }

        if (mark_anchor) |ma| {
            if (ma.value == cursor_anchor.value) return error.InvalidArgument;
            try self.validateLiveAnchor(ma);
        }

        cursor.mark = mark_anchor;
        if (old_mark) |mark| try self.dropAnchor(mark);
        sess.interaction.revision += 1;
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
    fn projectToBoundary(bounds: []const u32, offset: u32, stickiness: anchors.AnchorStickiness) u32 {
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

            try dead_anchors.append(self.allocator, .{
                .anchor = anchor.id,
                .offset = anchor.position - region_start,
                .stickiness = anchor.stickiness,
            });
        }

        if (dead_anchors.items.len == 0) return null;

        const target_anchor = try self.createAnchor(region_start, .weak);
        errdefer self.dropAnchor(target_anchor) catch {};

        const inverse_text = try self.allocator.dupe(u8, restoredText(inverse_op));
        errdefer self.allocator.free(inverse_text);

        return .{
            .target_anchor = target_anchor,
            .inverse_text = inverse_text,
            .dead_anchors = try dead_anchors.toOwnedSlice(self.allocator),
        };
    }

    fn resurrectDeletionMetas(
        self: *BufferEngine,
        deletion_metas: []const types.DeletionMeta,
    ) !void {
        if (deletion_metas.len == 0) return;

        for (deletion_metas) |meta| {
            const target_anchor = self.anchors_map.get(meta.target_anchor.value) orelse return error.KeyError;
            if (target_anchor.status == .dead) return error.KeyError;
            const target_position = target_anchor.position;

            for (meta.dead_anchors) |record| {
                const anchor = self.anchors_map.getPtr(record.anchor.value) orelse return error.KeyError;
                anchor.position = target_position + record.offset;
                anchor.stickiness = record.stickiness;
                anchor.status = .live;
            }

            try self.dropAnchor(meta.target_anchor);
        }
    }

    /// Applies operations directly, without origin or guard validation, and records undo.
    /// A rejected operation rolls back the whole payload and returns error.InvalidArgument.
    pub fn applyOps(
        self: *BufferEngine,
        ops: []const types.BufferOp,
        source: []const u8,
        cause: []const u8,
    ) !void {
        if (self.notifying) return error.ReentrantMutation;
        var providers: ProviderSet = .empty;
        defer providers.deinit(self.allocator);
        var event = try self.applyOpsCommitted(ops, source, cause, &self.undo_stack, &.{}, &providers);
        defer event.deinit(self.allocator);
        self.discardRedo();
        self.notifyViewProviders(&event, &providers);
    }

    fn editClass(ops: []const types.BufferOp) []const u8 {
        if (ops.len == 0) return "mixed";
        const tag = std.meta.activeTag(ops[0]);
        for (ops[1..]) |op| {
            if (std.meta.activeTag(op) != tag) return "mixed";
        }
        return switch (tag) {
            .insert => "insert",
            .delete => "delete",
            .replace => "replace",
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
    fn applyOpsPending(
        self: *BufferEngine,
        ops: []const types.BufferOp,
        edits: ?[]EditAnchors,
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
        try pending.affected_ranges.ensureUnusedCapacity(self.allocator, 1);

        const edit = requestedEdit(op);
        const splice = try self.table.planReplace(edit.start, edit.end, edit.text);
        const inverse = self.inverseForSplice(
            splice,
            try self.table.getTextRange(splice.start, splice.old_end),
        );
        var inverse_owned = true;
        defer if (inverse_owned) freeOpText(self.allocator, inverse);

        // The hidden target anchor joins the anchor map; the snapshot removes it on rollback.
        if (try self.captureDeletionMeta(edit.start, edit.end, splice.start, inverse)) |meta| {
            errdefer {
                var owned = meta;
                owned.deinit(self.allocator);
            }
            try pending.deletion_metas.append(self.allocator, meta);
        }

        try self.table.applySplice(splice, edit.text);
        pending.inverse_ops.appendAssumeCapacity(inverse);
        inverse_owned = false;
        pending.affected_ranges.appendAssumeCapacity(
            .{ .start = splice.start, .end = splice.new_end },
        );
        try self.rebaseAnchorsForSplice(splice, edit.text, restoredText(inverse));
        if (edit_anchors) |result| {
            // Created after this operation's own rebasing, so only later operations move them.
            const edges = try self.insertedEdges(splice, edit.text, restoredText(inverse));
            result.* = .{
                .start = try self.createAnchor(edges.start, .weak),
                .end = try self.createAnchor(edges.end, .sticky),
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

    /// Commits applied operations as one revision and notifies view providers.
    /// On allocation failure before the revision advances, the mutation is rolled back.
    fn commitPending(
        self: *BufferEngine,
        pending: *PendingMutation,
        ops: []const types.BufferOp,
        source: []const u8,
        cause: []const u8,
    ) !MutationCommit {
        errdefer self.rollbackPending(pending);
        const owned_source = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(owned_source);
        const owned_cause = try self.allocator.dupe(u8, cause);
        errdefer self.allocator.free(owned_cause);
        const forward_revs = try self.allocator.alloc(u32, 1);
        errdefer self.allocator.free(forward_revs);
        const affected_ranges = try pending.affected_ranges.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(affected_ranges);
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
        pending.anchors_before.deinit(self.allocator);
        pending.* = undefined;

        // Publication: nothing below allocates or fails.
        self.table.commit();
        const old_revision = self.revision;
        self.revision += 1;
        forward_revs[0] = self.revision;
        return .{
            .event = .{
                .old_revision = old_revision,
                .new_revision = self.revision,
                .affected_ranges = affected_ranges,
                .edit_class = editClass(ops),
                .source = owned_source,
                .cause = owned_cause,
            },
            .undo_entry = .{
                .forward_revs = forward_revs,
                .inverse_ops = inverse_ops,
                .deletion_metas = deletion_metas,
            },
        };
    }

    /// Applies and commits operations that are expected to be valid (direct application,
    /// undo and redo). A rejection rolls back and returns error.InvalidArgument.
    fn applyOpsCommitted(
        self: *BufferEngine,
        ops: []const types.BufferOp,
        source: []const u8,
        cause: []const u8,
        history: *std.ArrayListUnmanaged(types.UndoEntry),
        resurrect: []const types.DeletionMeta,
        providers: *ProviderSet,
    ) !types.EditEvent {
        var pending = switch (try self.applyOpsPending(ops, null)) {
            .applied => |applied| applied,
            .rejected => |message| {
                defer self.allocator.free(message);
                log.debug("rejected direct mutation: {s}", .{message});
                return error.InvalidArgument;
            },
        };
        // Resurrection only changes anchors, which rollback restores, so it belongs
        // before publication: if it fails, the undo or redo has no effect.
        self.resurrectDeletionMetas(resurrect) catch |err| {
            self.rollbackPending(&pending);
            return err;
        };
        return self.finishCommit(&pending, ops, source, cause, history, providers);
    }

    /// Commits applied operations as one revision and records the undo entry on
    /// `history`. Everything that can fail is reserved first, including `providers` for
    /// the caller's notification, so an error rolls the mutation back and nothing after
    /// the commit can fail. The caller notifies providers once the submission is complete.
    fn finishCommit(
        self: *BufferEngine,
        pending: *PendingMutation,
        ops: []const types.BufferOp,
        source: []const u8,
        cause: []const u8,
        history: *std.ArrayListUnmanaged(types.UndoEntry),
        providers: *ProviderSet,
    ) !types.EditEvent {
        self.reserveCommit(history, providers) catch |err| {
            self.rollbackPending(pending);
            return err;
        };
        const commit = try self.commitPending(pending, ops, source, cause);
        history.appendAssumeCapacity(commit.undo_entry);
        return commit.event;
    }

    fn reserveCommit(
        self: *BufferEngine,
        history: *std.ArrayListUnmanaged(types.UndoEntry),
        seen: *ProviderSet,
    ) !void {
        try history.ensureUnusedCapacity(self.allocator, 1);
        try seen.ensureTotalCapacity(self.allocator, @intCast(self.view_providers.count()));
    }

    pub fn applyMutation(
        self: *BufferEngine,
        mutation: types.BufferMutation,
        source: []const u8,
        cause: []const u8,
    ) !void {
        try self.applyOps(mutation.ops, source, cause);
    }

    pub fn undo(self: *BufferEngine, source: []const u8, cause: []const u8) !types.EditEvent {
        var result = try self.submit(.{
            .payload = .{ .undo = .{} },
            .source = source,
            .cause = cause,
        });
        return self.requireEditEvent(&result);
    }

    pub fn redo(self: *BufferEngine, source: []const u8, cause: []const u8) !types.EditEvent {
        var result = try self.submit(.{
            .payload = .{ .redo = .{} },
            .source = source,
            .cause = cause,
        });
        return self.requireEditEvent(&result);
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

    pub fn apply(
        self: *BufferEngine,
        ops: []const types.BufferOp,
        source: []const u8,
        cause: []const u8,
    ) !types.EditEvent {
        var result = try self.submit(.{
            .payload = .{ .buffer_mutation = .{ .ops = ops } },
            .source = source,
            .cause = cause,
        });
        return self.requireEditEvent(&result);
    }

    fn requireEditEvent(self: *BufferEngine, result: *types.SubmitResult) !types.EditEvent {
        return switch (result.*) {
            .edit_event => |event| event,
            .interaction_result => error.InvalidArgument,
            .validation_report => |*report| blk: {
                defer report.deinit(self.allocator);
                break :blk error.InvalidArgument;
            },
        };
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

        var lines = try std.ArrayList(queries.LineInfo).initCapacity(self.allocator, end_line - start_line);
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
            const end_with_newline = line_end + if (line + 1 < line_count) @as(u32, 1) else @as(u32, 0);

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
        var rows = try std.ArrayList(queries.RegionLineInfo).initCapacity(self.allocator, end_line - start_line);
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

        const provider = self.view_providers.get("tokens") orelse return try self.allocator.alloc(views.TokenSpan, 0);
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

        const provider = self.view_providers.get("diagnostics") orelse return try self.allocator.alloc(views.Diagnostic, 0);
        var state = provider.stateFor("diagnostics", self.revision);
        if (state.kind == .stale) state = provider.refresh(@ptrCast(@constCast(self)));
        if (state.kind != .available and state.kind != .partial) return try self.allocator.alloc(views.Diagnostic, 0);
        return try provider.diagnosticList(self.allocator, @ptrCast(@constCast(self)), start, end, self.revision);
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

        const provider = self.view_providers.get("semantic_tokens") orelse return try self.allocator.alloc(views.SemanticToken, 0);
        var state = provider.stateFor("semantic_tokens", self.revision);
        if (state.kind == .stale) state = provider.refresh(@ptrCast(@constCast(self)));
        if (state.kind != .available and state.kind != .partial) return try self.allocator.alloc(views.SemanticToken, 0);
        return try provider.semanticTokens(self.allocator, @ptrCast(@constCast(self)), start, end, self.revision);
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

        for ([_][]const u8{ "tokens", "syntax", "diagnostics", "semantic_tokens", "type_info", "hover", "symbols" }) |view| {
            if (self.hasViewProvider(view)) {
                self.capability_supported_views_storage[len] = view;
                len += 1;
            }
        }
        if (self.hasViewProvider("symbols")) {
            capabilities.symbol_capabilities = self.view_providers.get("symbols").?.symbolCapabilities();
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

        fn put(self: *@This(), engine: *BufferEngine, view: []const u8, provider: views.ViewProvider) !void {
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
