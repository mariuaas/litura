//! The stream explains session state (SPEC §7): an observer that starts from a snapshot
//! and consumes only published blocks, without querying the engine, reading its anchors
//! or segmenting text, reconstructs every session exactly.
//!
//! Method: a seeded random workload of edits (including combining marks and newlines
//! that resegment), composites with edit references, selection changes, undo and redo,
//! registers and session lifecycle. After every block the observer's state is compared
//! with an authoritative snapshot. Sparse endpoint effects are checked against the
//! exhaustive reference: every endpoint the edit changed must be either listed or
//! explained by the splices' shift rule.
const std = @import("std");
const litura = @import("litura");
const BufferEngine = litura.BufferEngine;
const types = litura.types;
const events = litura.events;
const AnchorId = litura.anchors.AnchorId;
const allocator = std.testing.allocator;
const support = @import("support.zig");
const id = support.id;

const SessionModel = struct {
    revision: u32,
    selections: []events.SelectionValue,
    registers: std.StringArrayHashMapUnmanaged(events.InteractionValue) = .empty,

    fn deinit(self: *SessionModel) void {
        allocator.free(self.selections);
        var iter = self.registers.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.free(allocator);
        }
        self.registers.deinit(allocator);
    }
};

const Stats = struct {
    blocks: usize = 0,
    edits: usize = 0,
    listed: usize = 0,
    shifted: usize = 0,
    deaths: usize = 0,
    revivals: usize = 0,
    lifecycle: usize = 0,
};

/// Knows only what snapshots and blocks tell it.
const Observer = struct {
    next_sequence: u64,
    sessions: std.AutoArrayHashMapUnmanaged(u32, SessionModel) = .empty,
    stats: Stats = .{},

    fn init(snapshot: events.Snapshot) !Observer {
        var observer = Observer{ .next_sequence = snapshot.next_sequence };
        errdefer observer.deinit();
        for (snapshot.sessions) |session| {
            var model = SessionModel{
                .revision = session.interaction_revision,
                .selections = try allocator.dupe(events.SelectionValue, session.selections),
            };
            errdefer model.deinit();
            for (session.registers) |entry| try putRegister(&model, entry.key, entry.value);
            try observer.sessions.put(allocator, session.id, model);
        }
        return observer;
    }

    fn deinit(self: *Observer) void {
        for (self.sessions.values()) |*model| model.deinit();
        self.sessions.deinit(allocator);
    }

    fn apply(self: *Observer, block: events.Block) !void {
        try std.testing.expectEqual(self.next_sequence, block.sequence());
        self.next_sequence += 1;
        self.stats.blocks += 1;
        switch (block) {
            .lifecycle => |lifecycle| {
                self.stats.lifecycle += 1;
                switch (lifecycle.change) {
                    .session_created => |created| try self.sessions.put(
                        allocator,
                        created.session,
                        .{
                            .revision = 0,
                            .selections = try allocator.dupe(
                                events.SelectionValue,
                                created.selections,
                            ),
                        },
                    ),
                    .session_dropped => |dropped| {
                        var removed = self.sessions.fetchSwapRemove(dropped.session).?;
                        try std.testing.expectEqual(
                            removed.value.revision,
                            dropped.interaction_revision,
                        );
                        removed.value.deinit();
                    },
                }
            },
            .transition => |transition| {
                if (transition.edit) |edit| try self.applyEdit(edit);
                for (transition.interactions) |event| try self.applyInteraction(event);
            },
        }
    }

    fn applyEdit(self: *Observer, edit: events.EditEvent) !void {
        self.stats.edits += 1;
        for (self.sessions.keys(), self.sessions.values()) |session, *model| {
            for (model.selections) |*selection| {
                try self.applyEffect(edit, session, &selection.start);
                try self.applyEffect(edit, session, &selection.end);
            }
        }
    }

    /// Takes the endpoint's listed value, or carries it through the splices' shift rule.
    fn applyEffect(
        self: *Observer,
        edit: events.EditEvent,
        session: u32,
        endpoint: *events.EndpointValue,
    ) !void {
        for (edit.endpoint_effects) |effect| {
            if (effect.session != session or effect.anchor.value != endpoint.anchor.value) continue;
            try std.testing.expectEqual(endpoint.position, effect.old);
            if (effect.old != null and effect.new == null) self.stats.deaths += 1;
            if (effect.old == null and effect.new != null) self.stats.revivals += 1;
            self.stats.listed += 1;
            endpoint.position = effect.new;
            return;
        }
        var position = endpoint.position orelse return; // dead and unlisted: unchanged
        const before = position;
        for (edit.splices) |splice| {
            if (position < splice.start) continue;
            // An unlisted endpoint inside a splice region would make the stream incomplete.
            try std.testing.expect(position > splice.old_end);
            position = position - splice.old_end + splice.new_end;
        }
        if (position != before) self.stats.shifted += 1;
        endpoint.position = position;
    }

    fn applyInteraction(self: *Observer, event: events.InteractionEvent) !void {
        const model = self.sessions.getPtr(event.session).?;
        try std.testing.expectEqual(model.revision, event.old_revision);
        model.revision = event.new_revision;
        if (event.selections) |change| {
            try std.testing.expectEqualSlices(events.SelectionValue, model.selections, change.old);
            allocator.free(model.selections);
            model.selections = try allocator.dupe(events.SelectionValue, change.new);
        }
        for (event.registers) |change| {
            const current = model.registers.get(change.key);
            try std.testing.expect(optionalValuesEqual(current, change.old));
            if (change.new) |value| {
                try putRegister(model, change.key, value);
            } else if (model.registers.fetchOrderedRemove(change.key)) |removed| {
                allocator.free(removed.key);
                removed.value.free(allocator);
            }
        }
    }

    fn expectMatches(self: *const Observer, snapshot: events.Snapshot) !void {
        try std.testing.expectEqual(snapshot.next_sequence, self.next_sequence);
        try std.testing.expectEqual(snapshot.sessions.len, self.sessions.count());
        for (snapshot.sessions) |session| {
            const model = self.sessions.get(session.id).?;
            try std.testing.expectEqual(session.interaction_revision, model.revision);
            try std.testing.expectEqualSlices(
                events.SelectionValue,
                session.selections,
                model.selections,
            );
            try std.testing.expectEqual(session.registers.len, model.registers.count());
            for (session.registers) |entry| {
                try std.testing.expect(
                    optionalValuesEqual(model.registers.get(entry.key), entry.value),
                );
            }
        }
    }
};

fn putRegister(model: *SessionModel, key: []const u8, value: events.InteractionValue) !void {
    const copy = try value.dupe(allocator);
    errdefer copy.free(allocator);
    if (model.registers.getPtr(key)) |existing| {
        existing.free(allocator);
        existing.* = copy;
        return;
    }
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try model.registers.put(allocator, owned_key, copy);
}

fn optionalValuesEqual(a: ?events.InteractionValue, b: ?events.InteractionValue) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    return left.eql(right);
}

/// Drives the engine at random. It may query the engine to build valid requests; the
/// observer never does.
const Workload = struct {
    engine: *BufferEngine,
    random: std.Random,
    observer: *Observer,
    client_anchors: std.ArrayListUnmanaged(AnchorId) = .empty,

    const texts = [_][]const u8{ "x", "ab", "\u{0301}", "\n", "e\u{0301}", "  ", "\u{200d}", "ä" };

    fn deliver(self: *Workload, block: *events.Block) !void {
        defer block.deinit(allocator);
        try self.observer.apply(block.*);
        var snapshot = try self.engine.snapshot(allocator);
        defer snapshot.deinit(allocator);
        try self.observer.expectMatches(snapshot);
    }

    fn submit(self: *Workload, intent: types.Intent) !void {
        var result = try self.engine.submit(intent);
        switch (result) {
            .committed => |*block| try self.deliver(block),
            .rejected => result.deinit(allocator),
        }
    }

    fn position(self: *Workload) u32 {
        return self.random.uintAtMost(u32, self.engine.graphemeCount());
    }

    fn bufferOps(self: *Workload, storage: []types.BufferOp) []types.BufferOp {
        const count = 1 + self.random.uintLessThan(usize, storage.len);
        for (storage[0..count]) |*op| {
            const length = self.engine.graphemeCount();
            const start = self.random.uintAtMost(u32, length);
            const end = start + self.random.uintAtMost(u32, @min(4, length - start));
            const text = texts[self.random.uintLessThan(usize, texts.len)];
            op.* = switch (self.random.uintLessThan(u8, 3)) {
                0 => .{ .insert = .{ .pos = start, .text = text } },
                1 => .{ .delete = .{ .start = start, .end = end } },
                else => .{ .replace = .{ .start = start, .end = end, .text = text } },
            };
        }
        return storage[0..count];
    }

    fn randomSession(self: *Workload) u32 {
        const keys = self.observer.sessions.keys();
        return keys[self.random.uintLessThan(usize, keys.len)];
    }

    /// A random target that names a live public anchor or a position.
    fn target(self: *Workload, sid: u32) !types.Target {
        if (self.random.boolean()) return .{ .position = self.position() };
        const values = try self.engine.querySelections(allocator, sid);
        defer allocator.free(values);
        const choice = values[self.random.uintLessThan(usize, values.len)];
        if (choice.end.position != null) return .{ .anchor = choice.end.anchor };
        return .{ .position = self.position() };
    }

    /// Builds a random replacement from the session's current selections.
    fn selectionSpecs(
        self: *Workload,
        sid: u32,
        specs: *std.ArrayListUnmanaged(types.SelectionSpec),
    ) !void {
        const values = try self.engine.querySelections(allocator, sid);
        defer allocator.free(values);
        for (values) |value| {
            const active = if (value.active == .end) value.end else value.start;
            const fixed = if (value.active == .end) value.start else value.end;
            const caret = value.isCaret();
            switch (self.random.uintLessThan(u8, 5)) {
                0 => {}, // omitted: released
                1 => try specs.append(allocator, if (caret)
                    .{ .start = .{ .keep = active.anchor } }
                else
                    .{
                        .start = .{ .keep = value.start.anchor },
                        .end = .{ .keep = value.end.anchor },
                        .active = value.active,
                    }),
                2 => {
                    const moved: types.Endpoint = .{
                        .move = .{ .anchor = active.anchor, .to = try self.target(sid) },
                    };
                    try specs.append(allocator, if (caret)
                        .{ .start = moved }
                    else
                        .{ .start = .{ .keep = fixed.anchor }, .end = moved, .active = .end });
                },
                3 => try specs.append(allocator, .{ .start = .{ .keep = active.anchor } }),
                else => try specs.append(allocator, .{
                    .start = .{ .new = .{ .position = self.position() } },
                    .end = .{ .keep = active.anchor },
                    .active = .end,
                }),
            }
        }
        if (specs.items.len == 0 or self.random.uintLessThan(u8, 4) == 0) {
            try specs.append(allocator, .{ .start = .{ .new = .{ .position = self.position() } } });
        }
    }

    fn step(self: *Workload) !void {
        var ops_storage: [3]types.BufferOp = undefined;
        var specs: std.ArrayListUnmanaged(types.SelectionSpec) = .empty;
        defer specs.deinit(allocator);
        const roll = self.random.uintLessThan(u8, 100);
        if (roll < 30) {
            try self.submit(
                .{
                    .id = id,
                    .origin = self.engine.revision,
                    .payload = .{ .buffer_mutation = .{ .ops = self.bufferOps(&ops_storage) } },
                },
            );
        } else if (roll < 45) {
            const sid = self.randomSession();
            const ops = self.bufferOps(&ops_storage);
            const values = try self.engine.querySelections(allocator, sid);
            defer allocator.free(values);
            for (values) |value| {
                if (self.random.boolean()) try specs.append(allocator, if (value.isCaret())
                    .{ .start = .{ .keep = value.start.anchor } }
                else
                    .{
                        .start = .{ .keep = value.start.anchor },
                        .end = .{ .keep = value.end.anchor },
                        .active = value.active,
                    });
            }
            const op: u32 = @intCast(self.random.uintLessThan(usize, ops.len));
            try specs.append(allocator, .{
                .start = .{ .new = .{ .edit = .{ .op = op, .edge = .start } } },
                .end = .{ .new = .{ .edit = .{ .op = op } } },
            });
            // Half the time a second part changes the same session again: the block then
            // reports one net event spanning both revisions.
            const origin = try self.engine.interactionRevision(sid);
            const parts = [_]types.IntentPayload{
                .{ .buffer_mutation = .{ .ops = ops } },
                .{ .interaction_mutation = .{
                    .session_id = sid,
                    .origin = origin,
                    .ops = &.{.{ .set_selections = .{ .selections = specs.items } }},
                } },
                .{ .interaction_mutation = .{
                    .session_id = sid,
                    .origin = origin,
                    .ops = &.{.{ .write_register = .{ .key = "mode", .value = .{ .int = 9 } } }},
                } },
            };
            const count: usize = if (self.random.boolean()) 3 else 2;
            try self.submit(.{
                .id = id,
                .origin = self.engine.revision,
                .payload = .{ .composite = .{ .parts = parts[0..count] } },
            });
        } else if (roll < 65) {
            const sid = self.randomSession();
            try self.selectionSpecs(sid, &specs);
            try self.submit(
                .{
                    .id = id,
                    .origin = self.engine.revision,
                    .payload = .{
                        .interaction_mutation = .{
                            .session_id = sid,
                            .origin = try self.engine.interactionRevision(sid),
                            .ops = &.{
                                .{ .set_selections = .{ .selections = specs.items } },
                            },
                        },
                    },
                },
            );
        } else if (roll < 77) {
            try self.submit(
                .{ .id = id, .origin = self.engine.revision, .payload = .{ .undo = .{} } },
            );
        } else if (roll < 83) {
            try self.submit(
                .{ .id = id, .origin = self.engine.revision, .payload = .{ .redo = .{} } },
            );
        } else if (roll < 88) {
            var block = try self.engine.createSession(
                .{ .id = id, .origin = self.engine.revision, .selections = &.{
                    .{
                        .start = .{ .new = .{ .position = self.position() } },
                        .end = .{ .new = .{ .position = self.position() } },
                    },
                } },
            );
            try self.deliver(&block);
        } else if (roll < 91) {
            if (self.observer.sessions.count() > 1) {
                var block = try self.engine.dropSession(
                    .{ .id = id, .session = self.randomSession() },
                );
                try self.deliver(&block);
            }
        } else if (roll < 97) {
            const keys = [_][]const u8{ "mode", "count", "flag" };
            const key = keys[self.random.uintLessThan(usize, keys.len)];
            const op: types.InteractionOp = if (self.random.boolean())
                .{ .write_register = .{ .key = key, .value = .{ .int = self.random.int(i8) } } }
            else
                .{ .clear_register = .{ .key = key } };
            try self.submit(
                .{
                    .id = id,
                    .origin = self.engine.revision,
                    .payload = .{ .interaction_mutation = .{
                        .session_id = self.randomSession(),
                        .origin = try self.engine.interactionRevision(self.randomSession()),
                        .ops = &.{op},
                    } },
                },
            );
        } else {
            // Client anchors are outside the stream: no block is produced.
            const before = self.engine.next_sequence;
            if (self.client_anchors.items.len > 0 and self.random.boolean()) {
                try self.engine.dropAnchor(self.client_anchors.pop().?);
            } else {
                try self.client_anchors.append(
                    allocator,
                    try self.engine.createAnchor(self.position(), .weak),
                );
            }
            try std.testing.expectEqual(before, self.engine.next_sequence);
        }
    }
};

test "an observer reconstructs every session from a snapshot and the blocks alone" {
    var engine = try BufferEngine.initFromText(allocator, "e\nX\n\u{0301} abc\ndef ghi", null);
    defer engine.deinit();
    // Blocks before the snapshot are never delivered: the observer starts mid-stream.
    _ = try support.caret(&engine, 2);
    _ = try support.caret(&engine, 6);
    try support.edit(&engine, &.{.{ .insert = .{ .pos = 0, .text = "start " } }});
    var snapshot = try engine.snapshot(allocator);
    var observer = try Observer.init(snapshot);
    defer observer.deinit();
    snapshot.deinit(allocator);

    var prng = std.Random.DefaultPrng.init(0x5eed);
    var workload = Workload{ .engine = &engine, .random = prng.random(), .observer = &observer };
    defer workload.client_anchors.deinit(allocator);
    for (0..1500) |_| try workload.step();

    const stats = observer.stats;
    std.log.debug("observer: {any}", .{stats});
    try std.testing.expect(stats.blocks > 1000);
    try std.testing.expect(stats.deaths > 0);
    try std.testing.expect(stats.revivals > 0);
    try std.testing.expect(stats.shifted > 0);
    try std.testing.expect(stats.lifecycle > 0);
}
