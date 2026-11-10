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

    const PreparedOp = struct {
        op: types.BufferOp,
        inserted_graphemes: u32,
    };

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
            }
        }

        session.interaction.revision += 1;
        return .{
            .session_id = payload.session_id,
            .old_revision = old_revision,
            .new_revision = session.interaction.revision,
        };
    }

    fn notifyViewProviders(self: *BufferEngine, event: *const types.EditEvent) !void {
        var seen = std.AutoHashMap(usize, void).init(self.allocator);
        defer seen.deinit();
        try seen.ensureTotalCapacity(self.view_providers.count());

        var iter = self.view_providers.valueIterator();
        while (iter.next()) |provider| {
            const identity = @intFromPtr(provider.ptr);
            if (seen.contains(identity)) continue;
            try seen.put(identity, {});
            provider.onBufferEvent(@ptrCast(self), @ptrCast(@constCast(event)));
        }
    }

    /// Validates origins and guards, then applies the intent synchronously.
    /// Rejections are owning validation reports. Allocation errors can leave partial
    /// progress; this differs from the draft atomicity contract (docs/known-issues.md).
    pub fn submit(self: *BufferEngine, intent: types.Intent) !types.SubmitResult {
        switch (intent.payload) {
            .buffer_mutation => |payload| {
                if (try validation.validationReportForStaleBufferOrigin(self, intent)) |report| {
                    return .{ .validation_report = report };
                }
                if (try validation.validationReportForGuards(self, intent)) |report| {
                    return .{ .validation_report = report };
                }
                if (try validation.validateBufferOpsAgainstLength(self, payload.ops, self.table.graphemeCount())) |message| {
                    defer self.allocator.free(message);
                    return .{ .validation_report = try validation.validationReport(self, intent, .invalid, message, try self.allocator.alloc(types.GuardEval, 0)) };
                }
                var commit = try self.applyOpsInternal(payload.ops, intent.source, intent.cause);
                errdefer commit.deinit(self.allocator);
                try self.undo_stack.append(self.allocator, commit.undo_entry);
                for (self.redo_stack.items) |*entry| entry.deinit(self.allocator);
                self.redo_stack.clearRetainingCapacity();
                return .{ .edit_event = commit.event };
            },
            .interaction_mutation => |payload| {
                if (try validation.validationReportForStaleInteractionOrigin(self, intent, payload)) |report| {
                    return .{ .validation_report = report };
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

                var original = self.undo_stack.pop().?;
                errdefer self.undo_stack.append(self.allocator, original) catch {};
                var commit = try self.applyOpsInternal(original.inverse_ops, intent.source, intent.cause);
                errdefer commit.deinit(self.allocator);
                try self.resurrectDeletionMetas(original.deletion_metas);
                try self.redo_stack.append(self.allocator, commit.undo_entry);
                original.deinit(self.allocator);
                return .{ .edit_event = commit.event };
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

                var original = self.redo_stack.pop().?;
                errdefer self.redo_stack.append(self.allocator, original) catch {};
                var commit = try self.applyOpsInternal(original.inverse_ops, intent.source, intent.cause);
                errdefer commit.deinit(self.allocator);
                try self.resurrectDeletionMetas(original.deletion_metas);
                try self.undo_stack.append(self.allocator, commit.undo_entry);
                original.deinit(self.allocator);
                return .{ .edit_event = commit.event };
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
        if (flat_parts.len == 0) {
            return .{ .validation_report = try validation.validationReport(self, intent, .invalid, "composite intent requires at least one payload", try self.allocator.alloc(types.GuardEval, 0)) };
        }

        var combined_ops = std.ArrayListUnmanaged(types.BufferOp).empty;
        defer combined_ops.deinit(self.allocator);
        var interaction_payloads = std.ArrayListUnmanaged(types.InteractionMutation).empty;
        defer interaction_payloads.deinit(self.allocator);
        var working_length = self.table.graphemeCount();
        var seen_interaction = false;

        for (flat_parts) |part| {
            switch (part) {
                .buffer_mutation => |buffer| {
                    if (seen_interaction) {
                        return .{ .validation_report = try validation.validationReport(self, intent, .invalid, "buffer mutations must precede interaction mutations in a composite", try self.allocator.alloc(types.GuardEval, 0)) };
                    }
                    if (try validation.validateBufferOpsIntoLength(self, buffer.ops, &working_length)) |message| {
                        defer self.allocator.free(message);
                        return .{ .validation_report = try validation.validationReport(self, intent, .invalid, message, try self.allocator.alloc(types.GuardEval, 0)) };
                    }
                    try combined_ops.appendSlice(self.allocator, buffer.ops);
                },
                .interaction_mutation => |interaction| {
                    seen_interaction = true;
                    if (try validation.validationReportForStaleInteractionOrigin(self, intent, interaction)) |report| {
                        return .{ .validation_report = report };
                    }
                    if (try validation.validateInteractionMutation(self, interaction, working_length)) |message| {
                        defer self.allocator.free(message);
                        return .{ .validation_report = try validation.validationReport(self, intent, .invalid, message, try self.allocator.alloc(types.GuardEval, 0)) };
                    }
                    try interaction_payloads.append(self.allocator, interaction);
                },
                else => {
                    return .{ .validation_report = try validation.validationReport(self, intent, .invalid, "composite only supports buffer and interaction mutations", try self.allocator.alloc(types.GuardEval, 0)) };
                },
            }
        }

        if (combined_ops.items.len == 0 and interaction_payloads.items.len == 0) {
            return .{ .validation_report = try validation.validationReport(self, intent, .invalid, "composite intent requires at least one payload", try self.allocator.alloc(types.GuardEval, 0)) };
        }

        var event: ?types.EditEvent = null;
        if (combined_ops.items.len > 0) {
            var commit = try self.applyOpsInternal(combined_ops.items, intent.source, intent.cause);
            errdefer commit.deinit(self.allocator);
            try self.undo_stack.append(self.allocator, commit.undo_entry);
            for (self.redo_stack.items) |*entry| entry.deinit(self.allocator);
            self.redo_stack.clearRetainingCapacity();
            event = commit.event;
        }

        var interaction_result: ?types.InteractionResult = null;
        for (interaction_payloads.items) |interaction| {
            interaction_result = try self.applyInteractionMutation(interaction);
        }

        if (event) |edit_event| return .{ .edit_event = edit_event };
        return .{ .interaction_result = interaction_result.? };
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

    fn inverseForOp(self: *const BufferEngine, prepared: PreparedOp) !types.BufferOp {
        switch (prepared.op) {
            .insert => |ins| return .{ .delete = .{ .start = ins.pos, .end = ins.pos + prepared.inserted_graphemes } },
            .delete => |del| return .{ .insert = .{ .pos = del.start, .text = try self.table.getTextRange(del.start, del.end) } },
            .replace => |rep| return .{ .replace = .{
                .start = rep.start,
                .end = rep.start + prepared.inserted_graphemes,
                .text = try self.table.getTextRange(rep.start, rep.end),
            } },
        }
    }

    fn rebaseAnchorsForInsert(self: *BufferEngine, pos: u32, length: u32) !void {
        if (length == 0) return;
        var iter = self.anchors_map.valueIterator();
        var bumped_sessions = std.AutoHashMap(u32, void).init(self.allocator);
        defer bumped_sessions.deinit();
        try bumped_sessions.ensureTotalCapacity(self.sessions.count());

        while (iter.next()) |anchor| {
            if (anchor.status == .dead) continue;

            var moved = false;
            if (anchor.position > pos) {
                anchor.position += length;
                moved = true;
            } else if (anchor.position == pos and anchor.stickiness == .sticky) {
                anchor.position += length;
                moved = true;
            }

            if (moved) {
                // Check which sessions this anchor belongs to and bump revision
                var sess_iter = self.sessions.valueIterator();
                while (sess_iter.next()) |sess| {
                    if (bumped_sessions.contains(sess.id)) continue;
                    var belongs = false;
                    for (sess.interaction.cursors.items) |cursor| {
                        if (cursor.anchor.value == anchor.id.value or
                            (cursor.mark != null and cursor.mark.?.value == anchor.id.value))
                        {
                            belongs = true;
                            break;
                        }
                    }
                    if (belongs) {
                        sess.interaction.revision += 1;
                        bumped_sessions.putAssumeCapacity(sess.id, {});
                    }
                }
            }
        }
    }

    fn rebaseAnchorsForDelete(self: *BufferEngine, start: u32, end: u32) !void {
        if (start == end) return;
        const length = end - start;
        var iter = self.anchors_map.valueIterator();
        var bumped_sessions = std.AutoHashMap(u32, void).init(self.allocator);
        defer bumped_sessions.deinit();
        try bumped_sessions.ensureTotalCapacity(self.sessions.count());

        while (iter.next()) |anchor| {
            if (anchor.status == .dead) continue;
            if (anchor.position <= start) continue;

            var moved = false;
            if (anchor.position < end) {
                if (anchor.stickiness == .sticky) {
                    anchor.position = start;
                    moved = true;
                } else {
                    anchor.status = .dead;
                    moved = true;
                }
            } else if (anchor.position == end) {
                anchor.position = start;
                moved = true;
            } else {
                anchor.position -= length;
                moved = true;
            }

            if (moved) {
                var sess_iter = self.sessions.valueIterator();
                while (sess_iter.next()) |sess| {
                    if (bumped_sessions.contains(sess.id)) continue;
                    var belongs = false;
                    for (sess.interaction.cursors.items) |cursor| {
                        if (cursor.anchor.value == anchor.id.value or
                            (cursor.mark != null and cursor.mark.?.value == anchor.id.value))
                        {
                            belongs = true;
                            break;
                        }
                    }
                    if (belongs) {
                        sess.interaction.revision += 1;
                        bumped_sessions.putAssumeCapacity(sess.id, {});
                    }
                }
            }
        }
    }

    fn bumpSessionsForAnchorId(self: *BufferEngine, anchor_id: anchors.AnchorId, bumped_sessions: *std.AutoHashMap(u32, void)) !void {
        var sess_iter = self.sessions.valueIterator();
        while (sess_iter.next()) |sess| {
            if (bumped_sessions.contains(sess.id)) continue;
            var belongs = false;
            for (sess.interaction.cursors.items) |cursor| {
                if (cursor.anchor.value == anchor_id.value or
                    (cursor.mark != null and cursor.mark.?.value == anchor_id.value))
                {
                    belongs = true;
                    break;
                }
            }
            if (belongs) {
                sess.interaction.revision += 1;
                bumped_sessions.putAssumeCapacity(sess.id, {});
            }
        }
    }

    fn deletedTextForInverseOp(inverse_op: types.BufferOp) []const u8 {
        return switch (inverse_op) {
            .insert => |ins| ins.text,
            .replace => |rep| rep.text,
            else => unreachable,
        };
    }

    fn captureDeletionMeta(
        self: *BufferEngine,
        start: u32,
        end: u32,
        inverse_op: types.BufferOp,
    ) !?types.DeletionMeta {
        if (start == end) return null;

        var dead_anchors = std.ArrayListUnmanaged(types.DeadAnchorRecord).empty;
        errdefer {
            if (dead_anchors.items.len > 0) self.allocator.free(dead_anchors.items);
            dead_anchors = .empty;
        }

        var iter = self.anchors_map.valueIterator();
        while (iter.next()) |anchor| {
            if (anchor.status == .dead) continue;
            if (anchor.position <= start or anchor.position >= end) continue;
            if (anchor.stickiness != .weak) continue;

            try dead_anchors.append(self.allocator, .{
                .anchor = anchor.id,
                .offset = anchor.position - start,
                .stickiness = anchor.stickiness,
            });
        }

        if (dead_anchors.items.len == 0) return null;

        const target_anchor = try self.createAnchor(start, .weak);
        errdefer self.dropAnchor(target_anchor) catch {};

        const inverse_text = try self.allocator.dupe(u8, deletedTextForInverseOp(inverse_op));
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

        var bumped_sessions = std.AutoHashMap(u32, void).init(self.allocator);
        defer bumped_sessions.deinit();
        try bumped_sessions.ensureTotalCapacity(self.sessions.count());

        for (deletion_metas) |meta| {
            const target_anchor = self.anchors_map.get(meta.target_anchor.value) orelse return error.KeyError;
            if (target_anchor.status == .dead) return error.KeyError;
            const target_position = target_anchor.position;

            for (meta.dead_anchors) |record| {
                const anchor = self.anchors_map.getPtr(record.anchor.value) orelse return error.KeyError;
                anchor.position = target_position + record.offset;
                anchor.stickiness = record.stickiness;
                anchor.status = .live;
                try self.bumpSessionsForAnchorId(record.anchor, &bumped_sessions);
            }

            try self.dropAnchor(meta.target_anchor);
        }
    }

    fn applyOne(self: *BufferEngine, prepared: PreparedOp) !void {
        switch (prepared.op) {
            .insert => |ins| {
                try self.table.insert(ins.pos, ins.text);
            },
            .delete => |del| {
                try self.table.delete(del.start, del.end);
            },
            .replace => |rep| {
                try self.table.delete(rep.start, rep.end);
                try self.table.insert(rep.start, rep.text);
            },
        }
    }

    pub fn applyOps(
        self: *BufferEngine,
        ops: []const types.BufferOp,
        source: []const u8,
        cause: []const u8,
    ) !void {
        var commit = try self.applyOpsInternal(ops, source, cause);
        defer commit.event.deinit(self.allocator);
        try self.undo_stack.append(self.allocator, commit.undo_entry);
        for (self.redo_stack.items) |*entry| entry.deinit(self.allocator);
        self.redo_stack.clearRetainingCapacity();
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

    fn applyOpsInternal(
        self: *BufferEngine,
        ops: []const types.BufferOp,
        source: []const u8,
        cause: []const u8,
    ) !MutationCommit {
        if (ops.len == 0) return error.InvalidArgument;

        var prepared_ops = try std.ArrayListUnmanaged(PreparedOp).initCapacity(self.allocator, ops.len);
        defer prepared_ops.deinit(self.allocator);

        var inverse_ops = try std.ArrayListUnmanaged(types.BufferOp).initCapacity(self.allocator, ops.len);
        errdefer {
            for (inverse_ops.items) |inv| {
                switch (inv) {
                    .insert => |ins| self.allocator.free(ins.text),
                    .replace => |rep| self.allocator.free(rep.text),
                    else => {},
                }
            }
            inverse_ops.deinit(self.allocator);
        }

        var affected_ranges = try std.ArrayListUnmanaged(types.Range).initCapacity(self.allocator, ops.len);
        defer affected_ranges.deinit(self.allocator);

        var deletion_metas = std.ArrayListUnmanaged(types.DeletionMeta).empty;
        errdefer {
            for (deletion_metas.items) |*meta| meta.deinit(self.allocator);
            if (deletion_metas.items.len > 0) self.allocator.free(deletion_metas.items);
            deletion_metas = .empty;
        }

        for (ops) |op| {
            var inserted: u32 = 0;
            switch (op) {
                .insert => |ins| inserted = self.countGraphemes(ins.text),
                .replace => |rep| inserted = self.countGraphemes(rep.text),
                else => {},
            }
            const prep = PreparedOp{ .op = op, .inserted_graphemes = inserted };
            prepared_ops.appendAssumeCapacity(prep);

            const inv = try self.inverseForOp(prep);
            inverse_ops.appendAssumeCapacity(inv);

            switch (prep.op) {
                .delete => |del| {
                    if (try self.captureDeletionMeta(del.start, del.end, inv)) |meta| {
                        errdefer {
                            var owned = meta;
                            owned.deinit(self.allocator);
                        }
                        try deletion_metas.append(self.allocator, meta);
                    }
                },
                .replace => |rep| {
                    if (try self.captureDeletionMeta(rep.start, rep.end, inv)) |meta| {
                        errdefer {
                            var owned = meta;
                            owned.deinit(self.allocator);
                        }
                        try deletion_metas.append(self.allocator, meta);
                    }
                },
                else => {},
            }

            try self.applyOne(prep);

            switch (prep.op) {
                .insert => |ins| {
                    try self.rebaseAnchorsForInsert(ins.pos, prep.inserted_graphemes);
                    affected_ranges.appendAssumeCapacity(.{ .start = ins.pos, .end = ins.pos + prep.inserted_graphemes });
                },
                .delete => |del| {
                    try self.rebaseAnchorsForDelete(del.start, del.end);
                    affected_ranges.appendAssumeCapacity(.{ .start = del.start, .end = del.start });
                },
                .replace => |rep| {
                    try self.rebaseAnchorsForDelete(rep.start, rep.end);
                    try self.rebaseAnchorsForInsert(rep.start, prep.inserted_graphemes);
                    affected_ranges.appendAssumeCapacity(.{ .start = rep.start, .end = rep.start + prep.inserted_graphemes });
                },
            }
        }

        const old_revision = self.revision;
        self.revision += 1;

        const event = types.EditEvent{
            .old_revision = old_revision,
            .new_revision = self.revision,
            .affected_ranges = try affected_ranges.toOwnedSlice(self.allocator),
            .edit_class = editClass(ops),
            .source = try self.allocator.dupe(u8, source),
            .cause = try self.allocator.dupe(u8, cause),
        };

        const owned_inverse_ops = blk: {
            const owned = try inverse_ops.toOwnedSlice(self.allocator);
            std.mem.reverse(types.BufferOp, owned);
            break :blk owned;
        };
        inverse_ops = std.ArrayListUnmanaged(types.BufferOp).empty;

        var forward_revs = try self.allocator.alloc(u32, 1);
        errdefer self.allocator.free(forward_revs);
        forward_revs[0] = self.revision;

        try self.notifyViewProviders(&event);

        return .{
            .event = event,
            .undo_entry = .{
                .forward_revs = forward_revs,
                .inverse_ops = owned_inverse_ops,
                .deletion_metas = if (deletion_metas.items.len > 0)
                    try deletion_metas.toOwnedSlice(self.allocator)
                else
                    &.{},
            },
        };
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
