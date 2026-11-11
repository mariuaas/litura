//! View providers are notified after a submission is completely published, cannot
//! mutate the engine from that notification, and the shipped providers handle it
//! without allocating.
const std = @import("std");
const litura = @import("litura");
const BufferEngine = litura.BufferEngine;
const types = litura.types;
const StaticTokenProvider = litura.views.StaticTokenProvider;
const allocator = std.testing.allocator;

/// A static token provider that also records what its notification observes.
const Observer = struct {
    static: StaticTokenProvider = .{ .spans = &.{} },
    vtable: litura.views.ViewProvider.VTable = undefined,
    cursor: litura.anchors.AnchorId = undefined,
    session: u32 = 0,
    attempt_reentry: bool = false,
    seen_position: ?u32 = null,
    seen_interaction_revision: ?u32 = null,
    submit_error: ?anyerror = null,
    apply_error: ?anyerror = null,

    /// Registers in place: the engine keeps pointers to `static` and `vtable`.
    fn register(self: *Observer, engine: *BufferEngine) !void {
        self.vtable = self.static.provider().vtable.*;
        self.vtable.onBufferEventFn = onBufferEvent;
        try engine.registerViewProvider(.{ .ptr = &self.static, .vtable = &self.vtable });
    }

    fn onBufferEvent(ptr: *anyopaque, engine_ptr: *anyopaque, _: *anyopaque) void {
        const static: *StaticTokenProvider = @ptrCast(@alignCast(ptr));
        const self: *Observer = @fieldParentPtr("static", static);
        const engine: *BufferEngine = @ptrCast(@alignCast(engine_ptr));
        self.seen_position = (engine.queryAnchor(self.cursor) catch return).position;
        self.seen_interaction_revision = engine.interactionRevision(self.session) catch return;
        if (!self.attempt_reentry) return;
        // Once only: without the guard, a nested edit would notify this provider again.
        self.attempt_reentry = false;
        const op = [_]types.BufferOp{.{ .insert = .{ .pos = 0, .text = "!" } }};
        if (engine.submit(.{ .payload = .{ .buffer_mutation = .{ .ops = &op } } })) |result| {
            var owned = result;
            owned.deinit(engine.allocator);
        } else |err| self.submit_error = err;
        engine.applyOps(&op, "provider", "reentry") catch |err| {
            self.apply_error = err;
        };
    }
};

test "providers are notified after a composite's interaction part is applied" {
    var engine = try BufferEngine.initFromText(allocator, "ab", null);
    defer engine.deinit();
    var observer: Observer = .{};
    observer.cursor = try engine.createAnchor(0, .sticky);
    observer.session = try engine.createSession(&.{observer.cursor});
    try observer.register(&engine);

    // Passive rebasing would carry the sticky cursor to 2; only the interaction part
    // places it at the start of the insertion.
    const insert = [_]types.BufferOp{.{ .insert = .{ .pos = 0, .text = "xy" } }};
    const place = [_]types.InteractionOp{.{ .place_cursor = .{
        .cursor = observer.cursor,
        .at = .{ .edit = .{ .op = 0, .edge = .start } },
    } }};
    var result = try engine.submit(.{
        .origin = engine.revision,
        .payload = .{ .composite = .{ .parts = &.{
            .{ .buffer_mutation = .{ .ops = &insert } },
            .{ .interaction_mutation = .{ .session_id = observer.session, .origin = 0, .ops = &place } },
        } } },
    });
    defer result.deinit(allocator);
    try std.testing.expect(result == .edit_event);
    try std.testing.expectEqual(@as(?u32, 0), observer.seen_position);
    try std.testing.expectEqual(@as(?u32, 1), observer.seen_interaction_revision);
}

test "a provider cannot mutate the engine from its notification" {
    var engine = try BufferEngine.initFromText(allocator, "ab", null);
    defer engine.deinit();
    var observer: Observer = .{ .attempt_reentry = true };
    observer.cursor = try engine.createAnchor(0, .sticky);
    observer.session = try engine.createSession(&.{observer.cursor});
    try observer.register(&engine);

    const op = [_]types.BufferOp{.{ .insert = .{ .pos = 2, .text = "c" } }};
    var result = try engine.submit(.{ .payload = .{ .buffer_mutation = .{ .ops = &op } } });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(?anyerror, error.ReentrantMutation), observer.submit_error);
    try std.testing.expectEqual(@as(?anyerror, error.ReentrantMutation), observer.apply_error);

    // Only the outer edit committed, and the engine accepts edits again afterwards.
    const text = try engine.getText();
    defer allocator.free(text);
    try std.testing.expectEqualStrings("abc", text);
    try std.testing.expectEqual(@as(u32, 1), engine.revision);
    try engine.applyOps(&op, "test", "after");
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
    const op = [_]types.BufferOp{.{ .insert = .{ .pos = 0, .text = "-- " } }};
    var result = try engine.submit(.{ .payload = .{ .buffer_mutation = .{ .ops = &op } } });
    defer result.deinit(engine.allocator);

    // Deliver the same event again with every allocation failing.
    failing.fail_index = failing.alloc_index;
    const allocations = failing.allocations;
    var iter = engine.view_providers.valueIterator();
    while (iter.next()) |provider| {
        provider.onBufferEvent(@ptrCast(&engine), @ptrCast(&result.edit_event));
    }
    try std.testing.expectEqual(allocations, failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
    failing.fail_index = std.math.maxInt(usize);
}
