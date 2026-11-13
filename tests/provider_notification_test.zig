//! View providers receive each complete block, borrowed, after its transition is
//! published; they cannot change engine state from that notification; and the shipped
//! providers handle it without allocating.
const std = @import("std");
const litura = @import("litura");
const BufferEngine = litura.BufferEngine;
const types = litura.types;
const events = litura.events;
const StaticTokenProvider = litura.views.StaticTokenProvider;
const allocator = std.testing.allocator;
const support = @import("support.zig");
const id = support.id;

/// A static token provider that also records what its notification observes.
const Observer = struct {
    static: StaticTokenProvider = .{ .spans = &.{} },
    vtable: litura.views.ViewProvider.VTable = undefined,
    cursor: litura.anchors.AnchorId = undefined,
    session: u32 = 0,
    attempt_reentry: bool = false,
    seen_position: ?u32 = null,
    seen_interaction_revision: ?u32 = null,
    seen_sequences: [4]u64 = undefined,
    seen_count: usize = 0,
    seen_complete_block: bool = false,
    submit_error: ?anyerror = null,

    /// Registers in place: the engine keeps pointers to `static` and `vtable`.
    fn register(self: *Observer, engine: *BufferEngine) !void {
        self.vtable = self.static.provider().vtable.*;
        self.vtable.onBufferEventFn = onBufferEvent;
        try engine.registerViewProvider(.{ .ptr = &self.static, .vtable = &self.vtable });
    }

    fn onBufferEvent(ptr: *anyopaque, engine_ptr: *anyopaque, block_ptr: *anyopaque) void {
        const static: *StaticTokenProvider = @ptrCast(@alignCast(ptr));
        const self: *Observer = @fieldParentPtr("static", static);
        const engine: *BufferEngine = @ptrCast(@alignCast(engine_ptr));
        const block: *const events.Block = @ptrCast(@alignCast(block_ptr));
        if (self.seen_count < self.seen_sequences.len) {
            self.seen_sequences[self.seen_count] = block.sequence();
        }
        self.seen_count += 1;
        if (block.* == .transition) {
            const transition = block.transition;
            self.seen_complete_block = transition.edit != null and transition.interactions.len == 1;
        }
        self.seen_position = (engine.queryAnchor(self.cursor) catch return).position;
        self.seen_interaction_revision = engine.interactionRevision(self.session) catch return;
        if (!self.attempt_reentry) return;
        // Once only: without the guard, a nested edit would notify this provider again.
        self.attempt_reentry = false;
        const op = [_]types.BufferOp{.{ .insert = .{ .pos = 0, .text = "!" } }};
        if (engine.submit(
            .{
                .id = id,
                .origin = engine.revision,
                .payload = .{ .buffer_mutation = .{ .ops = &op } },
            },
        )) |result| {
            var owned = result;
            owned.deinit(engine.allocator);
        } else |err| self.submit_error = err;
    }
};

test "providers receive the complete block after a composite's interaction part is applied" {
    var engine = try BufferEngine.initFromText(allocator, "ab", null);
    defer engine.deinit();
    var observer: Observer = .{};
    observer.session, observer.cursor = try support.caret(&engine, 0);
    try observer.register(&engine);

    // Passive rebasing would carry the sticky cursor to 2; only the interaction part
    // places it at the start of the insertion.
    const insert = [_]types.BufferOp{.{ .insert = .{ .pos = 0, .text = "xy" } }};
    const place = [_]types.InteractionOp{.{ .set_selections = .{ .selections = &.{
        support.placeSpec(observer.cursor, .{ .edit = .{ .op = 0, .edge = .start } }, null),
    } } }};
    var result = try engine.submit(.{
        .id = id,
        .origin = engine.revision,
        .payload = .{ .composite = .{ .parts = &.{
            .{ .buffer_mutation = .{ .ops = &insert } },
            .{
                .interaction_mutation = .{
                    .session_id = observer.session,
                    .origin = 0,
                    .ops = &place,
                },
            },
        } } },
    });
    try support.expectCommitted(&engine, &result);
    try std.testing.expectEqual(@as(?u32, 0), observer.seen_position);
    try std.testing.expectEqual(@as(?u32, 1), observer.seen_interaction_revision);
    try std.testing.expect(observer.seen_complete_block);
}

test "providers receive lifecycle blocks in sequence with transitions" {
    var engine = try BufferEngine.initFromText(allocator, "ab", null);
    defer engine.deinit();
    var observer: Observer = .{};
    try observer.register(&engine);
    observer.session, observer.cursor = try support.caret(&engine, 0);
    try support.edit(&engine, &.{.{ .insert = .{ .pos = 0, .text = "x" } }});
    try support.dropSession(&engine, observer.session);
    try std.testing.expectEqual(@as(usize, 3), observer.seen_count);
    try std.testing.expectEqualSlices(u64, &.{ 0, 1, 2 }, observer.seen_sequences[0..3]);
}

test "a provider cannot mutate the engine from its notification" {
    var engine = try BufferEngine.initFromText(allocator, "ab", null);
    defer engine.deinit();
    var observer: Observer = .{ .attempt_reentry = true };
    observer.session, observer.cursor = try support.caret(&engine, 0);
    try observer.register(&engine);

    try support.edit(&engine, &.{.{ .insert = .{ .pos = 2, .text = "c" } }});
    try std.testing.expectEqual(@as(?anyerror, error.ReentrantMutation), observer.submit_error);

    // Only the outer edit committed, and the engine accepts edits again afterwards.
    try support.expectText(&engine, "abc");
    try std.testing.expectEqual(@as(u32, 1), engine.revision);
    try support.edit(&engine, &.{.{ .insert = .{ .pos = 0, .text = "!" } }});
    try std.testing.expectEqual(@as(u32, 2), engine.revision);
}

test "shipped providers handle edit notifications without allocating" {
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var engine = try BufferEngine.initFromText(failing.allocator(), "local x = 1\n", null);
    defer engine.deinit();
    var static: StaticTokenProvider = .{ .spans = &.{} };
    if (litura.tree_sitter_enabled) {
        const TreeSitter = litura.tree_sitter.TreeSitterTokenProvider;
        try std.testing.expect(try TreeSitter.attachTokensBuiltin(&engine, "lua"));
    } else {
        try engine.registerViewProvider(static.provider());
    }
    var block = try support.editBlock(&engine, &.{.{ .insert = .{ .pos = 0, .text = "-- " } }});
    defer block.deinit(engine.allocator);

    // Deliver the same block again with every allocation failing.
    failing.fail_index = failing.alloc_index;
    const allocations = failing.allocations;
    var iter = engine.view_providers.valueIterator();
    while (iter.next()) |provider| {
        provider.onBufferEvent(@ptrCast(&engine), @ptrCast(&block));
    }
    try std.testing.expectEqual(allocations, failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
    failing.fail_index = std.math.maxInt(usize);
}

/// Tries every state-changing entry point from inside a notification, and a few reads.
const Prober = struct {
    static: StaticTokenProvider = .{ .spans = &.{} },
    vtable: litura.views.ViewProvider.VTable = undefined,
    client_anchor: litura.anchors.AnchorId = undefined,
    session: u32 = 0,
    refused: usize = 0,
    accepted: usize = 0,
    reads_ok: bool = false,
    probed: bool = false,

    fn register(self: *Prober, engine: *BufferEngine) !void {
        self.vtable = self.static.provider().vtable.*;
        self.vtable.onBufferEventFn = onBufferEvent;
        try engine.registerViewProvider(.{ .ptr = &self.static, .vtable = &self.vtable });
    }

    fn count(self: *Prober, outcome: anyerror!void) void {
        if (outcome) |_| {
            self.accepted += 1;
        } else |err| {
            if (err == error.ReentrantMutation) self.refused += 1 else self.accepted += 1;
        }
    }

    fn discard(engine: *BufferEngine, outcome: anyerror!events.Block) anyerror!void {
        var block = try outcome;
        block.deinit(engine.allocator);
    }

    fn onBufferEvent(ptr: *anyopaque, engine_ptr: *anyopaque, _: *anyopaque) void {
        const static: *StaticTokenProvider = @ptrCast(@alignCast(ptr));
        const self: *Prober = @fieldParentPtr("static", static);
        if (self.probed) return;
        self.probed = true;
        const engine: *BufferEngine = @ptrCast(@alignCast(engine_ptr));
        self.count(
            if (engine.submit(
                .{ .id = id, .origin = engine.revision, .payload = .{ .undo = .{} } },
            )) |result| blk: {
                var owned = result;
                owned.deinit(engine.allocator);
                break :blk {};
            } else |err| err,
        );
        self.count(if (engine.createAnchor(0, .weak)) |_| {} else |err| err);
        self.count(engine.dropAnchor(self.client_anchor));
        self.count(discard(engine, engine.createSession(.{
            .id = id,
            .origin = engine.revision,
            .selections = &.{.{ .start = .{ .new = .{ .position = 0 } } }},
        })));
        self.count(discard(engine, engine.dropSession(.{ .id = id, .session = self.session })));
        self.count(engine.save("never-written.txt"));
        self.count(engine.registerViewProvider(self.static.provider()));

        // Reads, including a lazy provider refresh and a snapshot, remain available.
        const text = engine.getText() catch return;
        defer engine.allocator.free(text);
        const spans = engine.queryTokenSpans(0, engine.graphemeCount(), null) catch return;
        defer engine.allocator.free(spans);
        var snapshot = engine.snapshot(engine.allocator) catch return;
        defer snapshot.deinit(engine.allocator);
        const stale = engine.queryViewState("tokens").kind != .available;
        self.reads_ok = std.mem.eql(u8, text, "abc") and stale and snapshot.next_sequence == 2;
    }
};

test "every state-changing entry point is refused during notification" {
    var engine = try BufferEngine.initFromText(allocator, "ab", null);
    defer engine.deinit();
    var prober: Prober = .{};
    prober.client_anchor = try engine.createAnchor(0, .sticky);
    prober.session, _ = try support.caret(&engine, 0);
    try prober.register(&engine);

    try support.edit(&engine, &.{.{ .insert = .{ .pos = 2, .text = "c" } }});
    try std.testing.expectEqual(@as(usize, 7), prober.refused);
    try std.testing.expectEqual(@as(usize, 0), prober.accepted);
    try std.testing.expect(prober.reads_ok);
    try std.testing.expectEqual(@as(u32, 1), engine.revision);
    try std.testing.expectEqual(@as(u64, 2), engine.next_sequence);
    try std.testing.expectEqual(@as(u32, 0), try engine.interactionRevision(prober.session));
}

/// One implementation registered for two views, counting its destruction.
const TwoViews = struct {
    static: StaticTokenProvider = .{ .spans = &.{} },
    vtable: litura.views.ViewProvider.VTable = undefined,
    deinits: usize = 0,

    fn register(self: *TwoViews, engine: *BufferEngine) !void {
        self.vtable = self.static.provider().vtable.*;
        self.vtable.views = &.{ "tokens", "diagnostics" };
        self.vtable.deinitFn = deinit;
        try engine.registerViewProvider(.{ .ptr = &self.static, .vtable = &self.vtable });
    }

    fn deinit(ptr: *anyopaque, _: std.mem.Allocator) void {
        const static: *StaticTokenProvider = @ptrCast(@alignCast(ptr));
        const self: *TwoViews = @fieldParentPtr("static", static);
        self.deinits += 1;
    }
};

test "a provider serving several views is destroyed once, even without memory" {
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var engine = try BufferEngine.initFromText(failing.allocator(), "ab", null);
    var provider: TwoViews = .{};
    try provider.register(&engine);
    failing.fail_index = failing.alloc_index;
    engine.deinit();
    try std.testing.expectEqual(@as(usize, 1), provider.deinits);
}

test "blocks that leave the text unchanged do not make text views stale" {
    var engine = try BufferEngine.initFromText(allocator, "abc", null);
    defer engine.deinit();
    var provider: StaticTokenProvider = .{ .spans = &.{} };
    try engine.registerViewProvider(provider.provider());
    const session, const cursor = try support.caret(&engine, 0);
    try support.place(&engine, session, cursor, 2, 1);
    try support.dropSession(&engine, session);
    try std.testing.expect(!provider.stale);
    try support.edit(&engine, &.{.{ .insert = .{ .pos = 0, .text = "x" } }});
    try std.testing.expect(provider.stale);
}
