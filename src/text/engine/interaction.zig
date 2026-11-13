//! Prepared interaction transitions (SPEC §2.6). Interaction mutations and session
//! creation are resolved and validated against an overlay over the engine's anchors
//! and sessions, which the engine publishes without allocating, or discards.

const std = @import("std");
const anchors = @import("anchors.zig");
const events = @import("events.zig");
const types = @import("buffer_types.zig");
const session_state = @import("session.zig");
const BufferEngine = @import("buffer_engine.zig").BufferEngine;

const Selection = session_state.Selection;
const Registers = session_state.Registers;
const AnchorId = anchors.AnchorId;
const Anchor = anchors.Anchor;

/// The transient anchors carrying one buffer operation's result through later
/// operations of a composite.
pub const EditAnchors = struct {
    start: AnchorId,
    end: AnchorId,
};

/// What interaction targets resolve against.
pub const Context = struct {
    /// Grapheme count of the text that positions address: the text after the
    /// transition's buffer operations.
    length: u32,
    /// The composite's edit result anchors, by buffer operation; null outside composites.
    edits: ?[]const EditAnchors = null,
    /// The revision positions in the resulting events are expressed at.
    document_revision: u32,
};

const Error = std.mem.Allocator.Error || error{Rejected};

/// One endpoint of a selection spec, resolved against the state before the operation.
const Resolved = union(enum) {
    keep: AnchorId,
    move: struct { anchor: AnchorId, position: u32 },
    new: u32,
};

const ResolvedSpec = struct {
    start: Resolved,
    end: ?Resolved,
    active: events.Edge,
};

/// A session's state when the transition first changed it, from which `finish` builds
/// the session's one interaction event.
const Touched = struct {
    session: u32,
    old_revision: u32,
    /// Selection values after the edit's passive effects, before any explicit change.
    /// They name only published identities.
    old_values: []events.SelectionValue,
    /// Each register the transition touched, with its value before the first touch.
    registers: std.ArrayListUnmanaged(events.RegisterChange) = .empty,

    fn deinit(self: *Touched, allocator: std.mem.Allocator) void {
        allocator.free(self.old_values);
        freeChanges(allocator, &self.registers);
        self.* = undefined;
    }
};

/// An endpoint created during preparation, under a placeholder identity.
const Created = struct {
    placeholder: u32,
    session: u32,
};

const SessionChange = struct {
    selections: ?[]Selection = null,
    registers: ?Registers = null,
    revision: u32,
    created: bool = false,
};

/// Changes not yet visible in the engine, owned through the engine allocator. Reads go
/// through the overlay, so each operation sees the ones before it. `publish` installs
/// everything and cannot fail once the caller has reserved `newAnchorCount` anchor slots
/// (and one session slot per created session); `abort` discards everything, including
/// the provisional public identifiers it took. Either way, call `deinit` afterwards.
pub const Prepared = struct {
    /// Changed anchors by identifier: the new state, or null once released.
    anchor_changes: std.AutoArrayHashMapUnmanaged(u32, ?Anchor) = .empty,
    session_changes: std.AutoArrayHashMapUnmanaged(u32, SessionChange) = .empty,
    /// Sessions the interaction mutations changed, in order of first change.
    touched: std.ArrayListUnmanaged(Touched) = .empty,
    /// Endpoints created during preparation, in creation order. `finish` gives the ones
    /// that survive the transition public identities; the rest are never issued.
    created: std.ArrayListUnmanaged(Created) = .empty,
    /// The engine's issued-identity boundary when preparation began.
    public_boundary: u32,
    new_anchor_count: u32 = 0,
    created_session_count: u32 = 0,
    /// Set together with error.Rejected; owned.
    rejection: ?[]u8 = null,

    pub fn init(engine: *const BufferEngine) Prepared {
        return .{ .public_boundary = engine.next_public_anchor_id };
    }

    pub fn deinit(self: *Prepared, allocator: std.mem.Allocator) void {
        self.anchor_changes.deinit(allocator);
        self.created.deinit(allocator);
        for (self.session_changes.values()) |*change| {
            if (change.selections) |list| allocator.free(list);
            if (change.registers) |*registers| session_state.freeRegisters(allocator, registers);
        }
        self.session_changes.deinit(allocator);
        for (self.touched.items) |*touched| touched.deinit(allocator);
        self.touched.deinit(allocator);
        if (self.rejection) |message| allocator.free(message);
        self.* = undefined;
    }

    /// Gives back the provisional identifiers preparation took. The engine is left as it
    /// was before preparation began.
    pub fn abort(self: *Prepared, engine: *BufferEngine) void {
        engine.next_public_anchor_id = self.public_boundary;
    }

    /// Anchors the publication inserts; the caller reserves this many map slots. Known
    /// once `finish` has run.
    pub fn newAnchorCount(self: *const Prepared) u32 {
        return self.new_anchor_count;
    }

    /// Ends preparation. Endpoints that survive the transition receive public
    /// identities, in creation order; endpoints created and released within it are
    /// dropped without ever being issued (SPEC §1.4). Returns one owned interaction
    /// event per session the transition changed, in order of first change, each from
    /// the session's state before the transition's explicit changes to its final state.
    pub fn finish(
        self: *Prepared,
        engine: *BufferEngine,
        document_revision: u32,
    ) ![]events.InteractionEvent {
        try self.issueCreated(engine);
        const allocator = engine.allocator;
        const result = try allocator.alloc(events.InteractionEvent, self.touched.items.len);
        var built: usize = 0;
        errdefer {
            for (result[0..built]) |*event| event.deinit(allocator);
            allocator.free(result);
        }
        for (self.touched.items, result) |*touched, *event| {
            event.* = try self.buildEvent(engine, touched, document_revision);
            built += 1;
        }
        return result;
    }

    /// Moves a touched session's starting state into its event. On error the touched
    /// record still owns everything.
    fn buildEvent(
        self: *Prepared,
        engine: *BufferEngine,
        touched: *Touched,
        document_revision: u32,
    ) !events.InteractionEvent {
        const allocator = engine.allocator;
        const session_id = touched.session;
        const new_revision = try self.revisionOf(engine, session_id);
        const new_values = try self.selectionValues(engine, session_id);
        errdefer allocator.free(new_values);
        const register_changes = try self.finishRegisterChanges(
            engine,
            session_id,
            &touched.registers,
        );
        // Nothing below can fail.
        const unchanged = selectionsEqual(touched.old_values, new_values);
        const old_values = touched.old_values;
        touched.old_values = &.{};
        if (unchanged) {
            allocator.free(old_values);
            allocator.free(new_values);
        }
        return .{
            .session = session_id,
            .document_revision = document_revision,
            .old_revision = touched.old_revision,
            .new_revision = new_revision,
            .selections = if (unchanged) null else .{ .old = old_values, .new = new_values },
            .registers = register_changes,
        };
    }

    /// Installs every change. Does not allocate or fail, given the reservations above.
    /// The replaced selection lists and registers stay here for deinit to free.
    pub fn publish(self: *Prepared, engine: *BufferEngine) void {
        var anchor_iter = self.anchor_changes.iterator();
        while (anchor_iter.next()) |entry| {
            if (entry.value_ptr.*) |installed| {
                // Placeholders were all issued or dropped when their mutation finished.
                std.debug.assert(!installed.id.isInternal());
                engine.anchors_map.putAssumeCapacity(entry.key_ptr.*, installed);
            } else {
                _ = engine.anchors_map.remove(entry.key_ptr.*);
            }
        }
        var session_iter = self.session_changes.iterator();
        while (session_iter.next()) |entry| {
            const change = entry.value_ptr;
            if (change.created) {
                engine.sessions.putAssumeCapacityNoClobber(entry.key_ptr.*, .{
                    .id = entry.key_ptr.*,
                    .revision = change.revision,
                    .selections = change.selections.?,
                    .registers = change.registers orelse .empty,
                });
                change.selections = null;
                change.registers = null;
                continue;
            }
            const target = engine.sessions.getPtr(entry.key_ptr.*).?;
            target.revision = change.revision;
            if (change.selections) |*list| std.mem.swap([]Selection, &target.selections, list);
            if (change.registers) |*registers| std.mem.swap(
                Registers,
                &target.registers,
                registers,
            );
        }
    }

    /// Prepares a new session whose selections are given by `specs`. Returns an owned
    /// rejection message when the specs are invalid.
    pub fn createSession(
        self: *Prepared,
        engine: *BufferEngine,
        session_id: u32,
        specs: []const types.SelectionSpec,
        context: Context,
    ) !?[]u8 {
        try self.session_changes.ensureUnusedCapacity(engine.allocator, 1);
        const empty = try engine.allocator.alloc(Selection, 0);
        self.session_changes.putAssumeCapacityNoClobber(session_id, .{
            .selections = empty,
            .revision = 0,
            .created = true,
        });
        self.created_session_count += 1;
        self.setSelections(engine, session_id, .{ .selections = specs }, context) catch |err| {
            return try self.rejected(err);
        };
        return null;
    }

    /// Prepares one interaction mutation. Returns an owned rejection message when it is
    /// invalid; the whole transition is then abandoned.
    pub fn applyMutation(
        self: *Prepared,
        engine: *BufferEngine,
        payload: types.InteractionMutation,
        context: Context,
    ) !?[]u8 {
        self.applyMutationOps(engine, payload, context) catch |err| return try self.rejected(err);
        return null;
    }

    fn rejected(self: *Prepared, err: Error) ![]u8 {
        return switch (err) {
            error.Rejected => blk: {
                const message = self.rejection.?;
                self.rejection = null;
                break :blk message;
            },
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn reject(
        self: *Prepared,
        allocator: std.mem.Allocator,
        comptime format: []const u8,
        args: anytype,
    ) Error {
        std.debug.assert(self.rejection == null);
        self.rejection = std.fmt.allocPrint(allocator, format, args) catch return error.OutOfMemory;
        return error.Rejected;
    }

    fn applyMutationOps(
        self: *Prepared,
        engine: *BufferEngine,
        payload: types.InteractionMutation,
        context: Context,
    ) Error!void {
        const allocator = engine.allocator;
        const session_id = payload.session_id;
        if (self.selections(engine, session_id) == null) {
            return self.reject(allocator, "unknown session id: {d}", .{session_id});
        }
        if (payload.ops.len == 0) {
            return self.reject(
                allocator,
                "interaction mutation requires at least one operation",
                .{},
            );
        }

        const touched = try self.touch(engine, session_id);
        for (payload.ops) |op| switch (op) {
            .set_selections => |spec| try self.setSelections(engine, session_id, spec, context),
            .write_register => |write| {
                try self.trackRegister(engine, session_id, write.key, &touched.registers);
                try self.writeRegister(engine, session_id, write.key, write.value);
            },
            .clear_register => |clear| {
                try self.trackRegister(engine, session_id, clear.key, &touched.registers);
                const registers = try self.mutableRegisters(engine, session_id);
                if (registers.fetchOrderedRemove(clear.key)) |removed| {
                    allocator.free(removed.key);
                    removed.value.free(allocator);
                }
            },
        };
        // Every mutation advances the interaction revision once, even within one event.
        const change = try self.changeFor(engine, session_id);
        change.revision += 1;
    }

    /// The session's record of its state before the transition first changed it.
    /// Pointers into `touched` stay valid only until the next call.
    fn touch(self: *Prepared, engine: *BufferEngine, session_id: u32) !*Touched {
        for (self.touched.items) |*touched| {
            if (touched.session == session_id) return touched;
        }
        const allocator = engine.allocator;
        try self.touched.ensureUnusedCapacity(allocator, 1);
        const old_values = try self.selectionValues(engine, session_id);
        self.touched.appendAssumeCapacity(.{
            .session = session_id,
            .old_revision = try self.revisionOf(engine, session_id),
            .old_values = old_values,
        });
        return &self.touched.items[self.touched.items.len - 1];
    }

    /// Resolves every spec against the state before this operation, then installs the
    /// replacement list. Endpoints the list omits are released last, so they can still
    /// be sampled during resolution.
    fn setSelections(
        self: *Prepared,
        engine: *BufferEngine,
        session_id: u32,
        spec: types.SetSelections,
        context: Context,
    ) Error!void {
        const allocator = engine.allocator;
        if (spec.selections.len == 0) {
            return self.reject(allocator, "a session needs at least one selection", .{});
        }
        const current = self.selections(engine, session_id).?;

        const resolved = try allocator.alloc(ResolvedSpec, spec.selections.len);
        defer allocator.free(resolved);
        var used: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer used.deinit(allocator);
        for (spec.selections, resolved) |selection, *out| {
            const sid = session_id;
            out.* = .{
                .start = try self.resolveEndpoint(
                    engine,
                    sid,
                    current,
                    selection.start,
                    context,
                    &used,
                ),
                .end = null,
                .active = selection.active,
            };
            if (selection.end) |end| {
                out.end = try self.resolveEndpoint(engine, sid, current, end, context, &used);
            }
            try self.checkDeadEndpoints(engine, out.*);
        }

        const replacement = try allocator.alloc(Selection, resolved.len);
        var replacement_owned = true;
        defer if (replacement_owned) allocator.free(replacement);
        for (resolved, replacement) |selection, *out| {
            const caret = selection.end == null;
            const start_active = caret or selection.active == .start;
            const start = try self.materialize(engine, session_id, selection.start, start_active);
            const end = if (selection.end) |end|
                try self.materialize(engine, session_id, end, selection.active == .end)
            else
                start;
            out.* = .{
                .start = start,
                .end = end,
                .active = if (caret) .end else selection.active,
            };
        }
        for (current) |selection| {
            for ([_]AnchorId{ selection.start, selection.end }) |endpoint| {
                if (used.contains(endpoint.value)) continue;
                try self.anchor_changes.put(allocator, endpoint.value, null);
            }
        }

        const change = try self.changeFor(engine, session_id);
        if (change.selections) |previous| allocator.free(previous);
        change.selections = replacement;
        replacement_owned = false;
    }

    fn resolveEndpoint(
        self: *Prepared,
        engine: *BufferEngine,
        session_id: u32,
        current: []const Selection,
        endpoint: types.Endpoint,
        context: Context,
        used: *std.AutoHashMapUnmanaged(u32, void),
    ) Error!Resolved {
        const allocator = engine.allocator;
        const id: AnchorId, const destination: ?types.Target = switch (endpoint) {
            .new => |target| return .{ .new = try self.resolveTarget(engine, target, context) },
            .keep => |id| .{ id, null },
            .move => |move| .{ move.anchor, move.to },
        };
        if (!ownsEndpoint(current, id)) {
            return self.reject(
                allocator,
                "anchor {d} is not an endpoint of session {d}",
                .{ id.value, session_id },
            );
        }
        if ((try used.fetchPut(allocator, id.value, {})) != null) {
            return self.reject(allocator, "endpoint {d} appears more than once", .{id.value});
        }
        const target = destination orelse return .{ .keep = id };
        if (self.anchor(engine, id).?.status == .dead) {
            return self.reject(allocator, "endpoint {d} is dead and cannot move", .{id.value});
        }
        const position = try self.resolveTarget(engine, target, context);
        return .{ .move = .{ .anchor = id, .position = position } };
    }

    /// A dead endpoint has no position from which to act as a cursor, so it can only be
    /// kept as the fixed endpoint of a selection.
    fn checkDeadEndpoints(self: *Prepared, engine: *BufferEngine, spec: ResolvedSpec) Error!void {
        const fixed: ?Resolved = if (spec.end == null)
            null
        else if (spec.active == .end)
            spec.start
        else
            spec.end;
        for ([_]?Resolved{ spec.start, spec.end }) |maybe| {
            const endpoint = maybe orelse continue;
            if (endpoint != .keep) continue;
            if (self.anchor(engine, endpoint.keep).?.status == .live) continue;
            const is_fixed = if (fixed) |kept|
                kept == .keep and kept.keep.value == endpoint.keep.value
            else
                false;
            if (!is_fixed) {
                return self.reject(
                    engine.allocator,
                    "dead endpoint {d} can only be kept as a fixed endpoint",
                    .{endpoint.keep.value},
                );
            }
        }
    }

    fn resolveTarget(
        self: *Prepared,
        engine: *BufferEngine,
        target: types.Target,
        context: Context,
    ) Error!u32 {
        const allocator = engine.allocator;
        switch (target) {
            .position => |position| {
                if (position > context.length) {
                    return self.reject(allocator, "position {d} out of range", .{position});
                }
                return position;
            },
            .edit => |ref| {
                const edits = context.edits orelse {
                    return self.reject(
                        allocator,
                        "edit references require a buffer operation in the same composite",
                        .{},
                    );
                };
                // The composite checked every reference's index before applying anything.
                const edit = edits[ref.op];
                const result_id = if (ref.edge == .start) edit.start else edit.end;
                const result = engine.anchors_map.get(result_id.value).?;
                if (result.status == .dead) {
                    return self.reject(
                        allocator,
                        "edit reference to buffer operation {d} was deleted by a later operation",
                        .{ref.op},
                    );
                }
                return result.position;
            },
            .anchor => |id| {
                const sampled = self.publicAnchor(engine, id) orelse {
                    return self.reject(allocator, "unknown anchor id: {d}", .{id.value});
                };
                if (sampled.status == .dead) {
                    return self.reject(allocator, "anchor {d} is not live", .{id.value});
                }
                return sampled.position;
            },
        }
    }

    /// Installs a resolved endpoint in the overlay with the stickiness of its role:
    /// Sticky for an active endpoint or caret, Weak for a fixed one.
    fn materialize(
        self: *Prepared,
        engine: *BufferEngine,
        session_id: u32,
        endpoint: Resolved,
        active: bool,
    ) !AnchorId {
        const allocator = engine.allocator;
        const stickiness: anchors.AnchorStickiness = if (active) .sticky else .weak;
        switch (endpoint) {
            .keep => |id| {
                var kept = self.anchor(engine, id).?;
                // A dead endpoint keeps its role (checkDeadEndpoints), so it keeps its stickiness.
                if (kept.status == .live and kept.stickiness != stickiness) {
                    kept.stickiness = stickiness;
                    try self.anchor_changes.put(allocator, id.value, kept);
                }
                return id;
            },
            .move => |move| {
                var moved = self.anchor(engine, move.anchor).?;
                moved.position = move.position;
                moved.stickiness = stickiness;
                try self.anchor_changes.put(allocator, move.anchor.value, moved);
                return move.anchor;
            },
            .new => |position| {
                // A placeholder from the internal namespace: no client can name it, and it
                // becomes a public identity only if it survives the mutation.
                try self.anchor_changes.ensureUnusedCapacity(allocator, 1);
                try self.created.ensureUnusedCapacity(allocator, 1);
                const id = engine.takeAnchorId(.transient);
                const owner = session_id;
                self.anchor_changes.putAssumeCapacityNoClobber(id.value, .{
                    .id = id,
                    .position = position,
                    .stickiness = stickiness,
                    .kind = .endpoint,
                });
                self.created.appendAssumeCapacity(.{ .placeholder = id.value, .session = owner });
                return id;
            },
        }
    }

    /// Gives each endpoint the transition created and kept a public identity, in
    /// creation order. One the transition also released is dropped without ever being
    /// issued, so every issued identity appears in the published block (SPEC §1.4).
    fn issueCreated(self: *Prepared, engine: *BufferEngine) !void {
        if (self.created.items.len == 0) return;
        defer self.created.clearRetainingCapacity();
        try self.anchor_changes.ensureUnusedCapacity(engine.allocator, self.created.items.len);
        for (self.created.items) |created| {
            const removed = self.anchor_changes.fetchSwapRemove(created.placeholder).?;
            var endpoint = removed.value orelse continue;
            const id = engine.takeAnchorId(.endpoint);
            endpoint.id = id;
            self.anchor_changes.putAssumeCapacityNoClobber(id.value, endpoint);
            self.new_anchor_count += 1;
            const list = self.session_changes.getPtr(created.session).?.selections.?;
            for (list) |*selection| {
                if (selection.start.value == created.placeholder) selection.start = id;
                if (selection.end.value == created.placeholder) selection.end = id;
            }
        }
    }

    /// Records a register's value before this mutation first touches it.
    fn trackRegister(
        self: *Prepared,
        engine: *BufferEngine,
        session_id: u32,
        key: []const u8,
        tracked: *std.ArrayListUnmanaged(events.RegisterChange),
    ) !void {
        for (tracked.items) |change| if (std.mem.eql(u8, change.key, key)) return;
        const allocator = engine.allocator;
        try tracked.ensureUnusedCapacity(allocator, 1);
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        const old: ?events.InteractionValue = if (self.registersOf(
            engine,
            session_id,
        ).get(key)) |value|
            try value.dupe(allocator)
        else
            null;
        tracked.appendAssumeCapacity(.{ .key = owned_key, .old = old, .new = null });
    }

    fn writeRegister(
        self: *Prepared,
        engine: *BufferEngine,
        session_id: u32,
        key: []const u8,
        value: events.InteractionValue,
    ) !void {
        const allocator = engine.allocator;
        const registers = try self.mutableRegisters(engine, session_id);
        const owned_value = try value.dupe(allocator);
        errdefer owned_value.free(allocator);
        if (registers.getPtr(key)) |existing| {
            existing.free(allocator);
            existing.* = owned_value;
            return;
        }
        try registers.ensureUnusedCapacity(allocator, 1);
        registers.putAssumeCapacityNoClobber(try allocator.dupe(u8, key), owned_value);
    }

    /// Completes the tracked changes with their new values, keeping only real changes.
    /// Takes ownership of every tracked change.
    fn finishRegisterChanges(
        self: *Prepared,
        engine: *BufferEngine,
        session_id: u32,
        tracked: *std.ArrayListUnmanaged(events.RegisterChange),
    ) ![]events.RegisterChange {
        const allocator = engine.allocator;
        const registers = self.registersOf(engine, session_id);
        for (tracked.items) |*change| {
            if (registers.get(change.key)) |value| change.new = try value.dupe(allocator);
        }
        var kept: usize = 0;
        for (tracked.items) |*change| {
            const same = if (change.old) |old|
                (if (change.new) |new| old.eql(new) else false)
            else
                change.new == null;
            if (same) {
                freeChange(allocator, change);
                continue;
            }
            tracked.items[kept] = change.*;
            kept += 1;
        }
        tracked.shrinkRetainingCapacity(kept);
        return tracked.toOwnedSlice(allocator);
    }

    fn changeFor(self: *Prepared, engine: *BufferEngine, session_id: u32) !*SessionChange {
        const entry = try self.session_changes.getOrPut(engine.allocator, session_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .revision = engine.sessions.getPtr(session_id).?.revision };
        }
        return entry.value_ptr;
    }

    fn mutableRegisters(self: *Prepared, engine: *BufferEngine, session_id: u32) !*Registers {
        const change = try self.changeFor(engine, session_id);
        if (change.registers == null) {
            const base = if (change.created)
                Registers.empty
            else
                engine.sessions.getPtr(session_id).?.registers;
            change.registers = try session_state.cloneRegisters(engine.allocator, base);
        }
        return &change.registers.?;
    }

    fn registersOf(self: *const Prepared, engine: *const BufferEngine, session_id: u32) Registers {
        if (self.session_changes.get(session_id)) |change| {
            if (change.registers) |registers| return registers;
            if (change.created) return .empty;
        }
        return engine.sessions.getPtr(session_id).?.registers;
    }

    fn revisionOf(self: *const Prepared, engine: *const BufferEngine, session_id: u32) !u32 {
        if (self.session_changes.get(session_id)) |change| return change.revision;
        return engine.sessions.getPtr(session_id).?.revision;
    }

    /// The selection list as prepared so far, or null for an unknown session.
    pub fn selections(
        self: *const Prepared,
        engine: *const BufferEngine,
        session_id: u32,
    ) ?[]const Selection {
        if (self.session_changes.get(session_id)) |change| {
            if (change.selections) |list| return list;
        }
        const existing = engine.sessions.getPtr(session_id) orelse return null;
        return existing.selections;
    }

    /// An anchor as prepared so far; null once released.
    pub fn anchor(self: *const Prepared, engine: *const BufferEngine, id: AnchorId) ?Anchor {
        if (self.anchor_changes.get(id.value)) |change| return change;
        return engine.anchors_map.get(id.value);
    }

    fn publicAnchor(self: *const Prepared, engine: *const BufferEngine, id: AnchorId) ?Anchor {
        if (id.isInternal()) return null;
        return self.anchor(engine, id);
    }

    /// The session's selections as owned values, at the prepared state.
    pub fn selectionValues(
        self: *const Prepared,
        engine: *const BufferEngine,
        session_id: u32,
    ) ![]events.SelectionValue {
        const list = self.selections(engine, session_id).?;
        const values = try engine.allocator.alloc(events.SelectionValue, list.len);
        for (list, values) |selection, *value| {
            value.* = .{
                .start = self.endpointValue(engine, selection.start),
                .end = self.endpointValue(engine, selection.end),
                .active = selection.active,
            };
        }
        return values;
    }

    fn endpointValue(
        self: *const Prepared,
        engine: *const BufferEngine,
        id: AnchorId,
    ) events.EndpointValue {
        const endpoint = self.anchor(engine, id).?;
        return .{
            .anchor = id,
            .position = if (endpoint.status == .live) endpoint.position else null,
        };
    }
};

fn ownsEndpoint(list: []const Selection, id: AnchorId) bool {
    for (list) |selection| {
        if (selection.start.value == id.value or selection.end.value == id.value) return true;
    }
    return false;
}

fn selectionsEqual(a: []const events.SelectionValue, b: []const events.SelectionValue) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.meta.eql(left, right)) return false;
    }
    return true;
}

fn freeChange(allocator: std.mem.Allocator, change: *events.RegisterChange) void {
    allocator.free(change.key);
    if (change.old) |value| value.free(allocator);
    if (change.new) |value| value.free(allocator);
    change.* = undefined;
}

fn freeChanges(
    allocator: std.mem.Allocator,
    changes: *std.ArrayListUnmanaged(events.RegisterChange),
) void {
    for (changes.items) |*change| freeChange(allocator, change);
    changes.deinit(allocator);
}
