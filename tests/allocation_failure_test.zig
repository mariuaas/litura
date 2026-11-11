//! Persistent allocator exhaustion during a submission must leave every observable part
//! of the engine unchanged (SPEC §4.1, §11 item 12), and the engine must stay usable.
//!
//! Method: for each scenario and every n, build a fresh fixture, snapshot it, make every
//! allocation from the nth onward fail, and submit. Unlike a transient failure, the
//! rollback itself runs while the allocator is exhausted. A failed submission must match
//! the snapshot exactly and leave a structurally valid tree; the same submission must
//! then succeed once allocation recovers. The sweep ends at the first n with no failure.
const std = @import("std");
const litura = @import("litura");
const BufferEngine = litura.BufferEngine;
const types = litura.types;
const State = @import("engine_state.zig").State;
const tree_check = @import("tree_check.zig");
const allocator = std.testing.allocator;

const Fixture = struct {
    failing: std.testing.FailingAllocator,
    engine: BufferEngine,
    provider: litura.views.StaticTokenProvider = .{ .spans = &.{} },
    cursor: litura.anchors.AnchorId,
    session: u32,

    /// Initializes in place: the engine keeps a pointer to `failing`.
    fn init(self: *Fixture, text: []const u8) !void {
        self.* = .{
            .failing = std.testing.FailingAllocator.init(allocator, .{}),
            .engine = undefined,
            .cursor = undefined,
            .session = undefined,
        };
        self.engine = try BufferEngine.initFromText(self.failing.allocator(), text, null);
        errdefer self.engine.deinit();
        try self.engine.registerViewProvider(self.provider.provider());
        self.cursor = try self.engine.createAnchor(0, .sticky);
        self.session = try self.engine.createSession(&.{self.cursor});
    }

    fn deinit(self: *Fixture) void {
        self.engine.deinit();
        self.* = undefined;
    }

    fn apply(self: *Fixture, op: types.BufferOp) !void {
        var result = try self.engine.submit(.{ .payload = .{ .buffer_mutation = .{ .ops = &.{op} } } });
        defer result.deinit(self.engine.allocator);
        try std.testing.expect(result == .edit_event);
    }
};

const Expected = std.meta.Tag(types.SubmitResult);

fn sweep(
    text: []const u8,
    comptime setup: fn (*Fixture) anyerror!void,
    comptime act: fn (*Fixture) anyerror!types.SubmitResult,
    expected: Expected,
) !void {
    var fail_after: usize = 0;
    while (true) : (fail_after += 1) {
        var fixture: Fixture = undefined;
        try fixture.init(text);
        defer fixture.deinit();
        try setup(&fixture);
        fixture.provider.stale = false;
        var before = try State.capture(allocator, &fixture.engine, &fixture.provider);
        defer before.deinit();

        fixture.failing.fail_index = fixture.failing.alloc_index + fail_after;
        const outcome = act(&fixture);
        const failed = fixture.failing.has_induced_failure;
        fixture.failing.fail_index = std.math.maxInt(usize);

        if (outcome) |result| {
            var owned = result;
            defer owned.deinit(fixture.engine.allocator);
            if (!failed) {
                try std.testing.expectEqual(expected, std.meta.activeTag(owned));
                try tree_check.expectValidTree(allocator, &fixture.engine.table);
                return;
            }
            // A failure was absorbed internally: only a rejection may result.
            try std.testing.expect(owned == .validation_report);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }

        var after = try State.capture(allocator, &fixture.engine, &fixture.provider);
        defer after.deinit();
        State.expectEqual(&before, &after) catch |mismatch| {
            std.debug.print("allocation {d} failed and changed observable state\n", .{fail_after});
            return mismatch;
        };
        try tree_check.expectValidTree(allocator, &fixture.engine.table);

        var again = try act(&fixture);
        defer again.deinit(fixture.engine.allocator);
        try std.testing.expectEqual(expected, std.meta.activeTag(again));
        try tree_check.expectValidTree(allocator, &fixture.engine.table);
    }
}

fn noSetup(_: *Fixture) anyerror!void {}

/// Fragments the document so that edits cross many leaves and internal nodes.
fn fragment(fixture: *Fixture) anyerror!void {
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    for (0..120) |_| {
        const pos = random.uintAtMost(u32, fixture.engine.graphemeCount());
        try fixture.apply(.{ .insert = .{ .pos = pos, .text = "x" } });
    }
}

const base_text = "The quick brown fox jumps over the lazy dog.\n" ** 24;

test "exhaustion during a composite with edit references leaves no effect" {
    try sweep("e\nabcd", struct {
        fn setup(fixture: *Fixture) anyerror!void {
            _ = try fixture.engine.createAnchor(4, .weak);
            _ = try fixture.engine.createAnchor(6, .sticky);
        }
    }.setup, struct {
        fn act(fixture: *Fixture) anyerror!types.SubmitResult {
            const edits = [_]types.BufferOp{
                .{ .insert = .{ .pos = 1, .text = "\u{0301}" } },
                .{ .delete = .{ .start = 3, .end = 5 } },
                .{ .replace = .{ .start = 1, .end = 2, .text = "XY" } },
            };
            const place = [_]types.InteractionOp{.{ .place_cursor = .{
                .cursor = fixture.cursor,
                .at = .{ .edit = .{ .op = 0 } },
                .mark = .{ .edit = .{ .op = 2, .edge = .start } },
            } }};
            return fixture.engine.submit(.{
                .origin = fixture.engine.revision,
                .payload = .{ .composite = .{ .parts = &.{
                    .{ .buffer_mutation = .{ .ops = &edits } },
                    .{ .interaction_mutation = .{
                        .session_id = fixture.session,
                        .origin = try fixture.engine.interactionRevision(fixture.session),
                        .ops = &place,
                    } },
                } } },
            });
        }
    }.act, .edit_event);
}

fn joiningDeletion(fixture: *Fixture) anyerror!void {
    _ = try fixture.engine.createAnchor(2, .weak);
    try fixture.apply(.{ .delete = .{ .start = 1, .end = 4 } });
}

fn submitUndo(fixture: *Fixture) anyerror!types.SubmitResult {
    return fixture.engine.submit(.{ .payload = .{ .undo = .{} } });
}

test "exhaustion during undo that resurrects an anchor leaves no effect" {
    try sweep("e\nX\n\u{0301}", joiningDeletion, submitUndo, .edit_event);
}

test "exhaustion during redo leaves no effect" {
    try sweep("e\nX\n\u{0301}", struct {
        fn setup(fixture: *Fixture) anyerror!void {
            try joiningDeletion(fixture);
            var undo = try submitUndo(fixture);
            undo.deinit(fixture.engine.allocator);
        }
    }.setup, struct {
        fn act(fixture: *Fixture) anyerror!types.SubmitResult {
            return fixture.engine.submit(.{ .payload = .{ .redo = .{} } });
        }
    }.act, .edit_event);
}

test "exhaustion during an unaligned splice leaves no effect" {
    try sweep("cafe", noSetup, struct {
        fn act(fixture: *Fixture) anyerror!types.SubmitResult {
            const op = [_]types.BufferOp{.{ .insert = .{ .pos = 4, .text = "\u{0301}" } }};
            return fixture.engine.submit(.{ .payload = .{ .buffer_mutation = .{ .ops = &op } } });
        }
    }.act, .edit_event);
}

test "exhaustion during a multi-chunk paste that splits nodes leaves no effect" {
    try sweep(base_text, fragment, struct {
        fn act(fixture: *Fixture) anyerror!types.SubmitResult {
            const paste = "0123456789" ** 120;
            const mid = fixture.engine.graphemeCount() / 2;
            const op = [_]types.BufferOp{.{ .insert = .{ .pos = mid, .text = paste } }};
            return fixture.engine.submit(.{ .payload = .{ .buffer_mutation = .{ .ops = &op } } });
        }
    }.act, .edit_event);
}

test "exhaustion during a deletion across many leaves leaves no effect" {
    try sweep(base_text, fragment, struct {
        fn act(fixture: *Fixture) anyerror!types.SubmitResult {
            const count = fixture.engine.graphemeCount();
            const op = [_]types.BufferOp{.{ .delete = .{ .start = 10, .end = count - 10 } }};
            return fixture.engine.submit(.{ .payload = .{ .buffer_mutation = .{ .ops = &op } } });
        }
    }.act, .edit_event);
}

test "exhaustion during a deletion that empties the document leaves no effect" {
    try sweep(base_text, fragment, struct {
        fn act(fixture: *Fixture) anyerror!types.SubmitResult {
            const count = fixture.engine.graphemeCount();
            const op = [_]types.BufferOp{.{ .delete = .{ .start = 0, .end = count } }};
            return fixture.engine.submit(.{ .payload = .{ .buffer_mutation = .{ .ops = &op } } });
        }
    }.act, .edit_event);
}

test "exhaustion while rejecting a composite after its buffer operations leaves no effect" {
    try sweep("abcd", noSetup, struct {
        fn act(fixture: *Fixture) anyerror!types.SubmitResult {
            // Operation 1 deletes the start of operation 0's insertion: the reference dies.
            const edits = [_]types.BufferOp{
                .{ .insert = .{ .pos = 2, .text = "x" } },
                .{ .delete = .{ .start = 1, .end = 4 } },
            };
            const place = [_]types.InteractionOp{.{ .place_cursor = .{
                .cursor = fixture.cursor,
                .at = .{ .edit = .{ .op = 0, .edge = .start } },
            } }};
            return fixture.engine.submit(.{
                .origin = fixture.engine.revision,
                .payload = .{ .composite = .{ .parts = &.{
                    .{ .buffer_mutation = .{ .ops = &edits } },
                    .{ .interaction_mutation = .{
                        .session_id = fixture.session,
                        .origin = try fixture.engine.interactionRevision(fixture.session),
                        .ops = &place,
                    } },
                } } },
            });
        }
    }.act, .validation_report);
}

test "exhaustion while rejecting a payload with an invalid later operation leaves no effect" {
    try sweep(base_text, fragment, struct {
        fn act(fixture: *Fixture) anyerror!types.SubmitResult {
            const count = fixture.engine.graphemeCount();
            const ops = [_]types.BufferOp{
                .{ .replace = .{ .start = 5, .end = 40, .text = "replacement" } },
                .{ .delete = .{ .start = count, .end = count + 5 } },
            };
            return fixture.engine.submit(.{ .payload = .{ .buffer_mutation = .{ .ops = &ops } } });
        }
    }.act, .validation_report);
}
