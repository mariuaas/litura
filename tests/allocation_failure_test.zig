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
const support = @import("support.zig");
const id = support.id;
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
        self.session, self.cursor = try support.caret(&self.engine, 0);
    }

    fn deinit(self: *Fixture) void {
        self.engine.deinit();
        self.* = undefined;
    }

    fn apply(self: *Fixture, op: types.BufferOp) !void {
        try support.edit(&self.engine, &.{op});
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
            try std.testing.expect(owned == .rejected);
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
            const place = [_]types.InteractionOp{.{ .set_selections = .{ .selections = &.{
                support.placeSpec(
                    fixture.cursor,
                    .{ .edit = .{ .op = 0 } },
                    .{ .edit = .{ .op = 2, .edge = .start } },
                ),
            } } }};
            return fixture.engine.submit(.{
                .id = id,
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
    }.act, .committed);
}

fn joiningDeletion(fixture: *Fixture) anyerror!void {
    _ = try fixture.engine.createAnchor(2, .weak);
    try fixture.apply(.{ .delete = .{ .start = 1, .end = 4 } });
}

fn submitUndo(fixture: *Fixture) anyerror!types.SubmitResult {
    return fixture.engine.submit(
        .{ .id = id, .origin = fixture.engine.revision, .payload = .{ .undo = .{} } },
    );
}

test "exhaustion during undo that resurrects an anchor leaves no effect" {
    try sweep("e\nX\n\u{0301}", joiningDeletion, submitUndo, .committed);
}

test "exhaustion during undo of nested deletions in one entry leaves no effect" {
    // The second deletion kills the first's undo target, so replay must resurrect it
    // between the two inverse operations.
    try sweep("abcdefgh", struct {
        fn setup(fixture: *Fixture) anyerror!void {
            _ = try fixture.engine.createAnchor(5, .weak);
            _ = try fixture.engine.createAnchor(7, .weak);
            var result = try fixture.engine.submit(
                .{
                    .id = id,
                    .origin = fixture.engine.revision,
                    .payload = .{ .buffer_mutation = .{ .ops = &.{
                        .{ .delete = .{ .start = 4, .end = 6 } },
                        .{ .delete = .{ .start = 2, .end = 6 } },
                    } } },
                },
            );
            defer result.deinit(fixture.engine.allocator);
            try std.testing.expect(result == .committed);
        }
    }.setup, submitUndo, .committed);
}

/// Places the fixture's cursor with a mark, replacing the mark it already has.
fn placeWithMark(fixture: *Fixture) anyerror!types.SubmitResult {
    return fixture.engine.submit(.{
        .id = id,
        .origin = fixture.engine.revision,
        .payload = .{ .interaction_mutation = .{
            .session_id = fixture.session,
            .origin = try fixture.engine.interactionRevision(fixture.session),
            .ops = &.{
                .{ .set_selections = .{ .selections = &.{
                    support.placeSpec(fixture.cursor, .{ .position = 3 }, .{ .position = 1 }),
                } } },
                .{ .write_register = .{ .key = "mode", .value = .{ .string = "visual" } } },
            },
        } },
    });
}

test "exhaustion during an interaction-only mutation leaves no effect" {
    try sweep("abcdef", struct {
        fn setup(fixture: *Fixture) anyerror!void {
            var result = try placeWithMark(fixture);
            result.deinit(fixture.engine.allocator);
        }
    }.setup, placeWithMark, .committed);
}

test "exhaustion while constructing an engine leaks nothing" {
    var fail_after: usize = 0;
    while (true) : (fail_after += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_after });
        var engine = BufferEngine.initFromText(
            failing.allocator(),
            base_text,
            "doc.txt",
        ) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        engine.deinit();
        if (!failing.has_induced_failure) return;
    }
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
            return fixture.engine.submit(
                .{ .id = id, .origin = fixture.engine.revision, .payload = .{ .redo = .{} } },
            );
        }
    }.act, .committed);
}

test "exhaustion during an unaligned splice leaves no effect" {
    try sweep("cafe", noSetup, struct {
        fn act(fixture: *Fixture) anyerror!types.SubmitResult {
            const op = [_]types.BufferOp{.{ .insert = .{ .pos = 4, .text = "\u{0301}" } }};
            return fixture.engine.submit(
                .{
                    .id = id,
                    .origin = fixture.engine.revision,
                    .payload = .{ .buffer_mutation = .{ .ops = &op } },
                },
            );
        }
    }.act, .committed);
}

test "exhaustion during a multi-chunk paste that splits nodes leaves no effect" {
    try sweep(base_text, fragment, struct {
        fn act(fixture: *Fixture) anyerror!types.SubmitResult {
            const paste = "0123456789" ** 120;
            const mid = fixture.engine.graphemeCount() / 2;
            const op = [_]types.BufferOp{.{ .insert = .{ .pos = mid, .text = paste } }};
            return fixture.engine.submit(
                .{
                    .id = id,
                    .origin = fixture.engine.revision,
                    .payload = .{ .buffer_mutation = .{ .ops = &op } },
                },
            );
        }
    }.act, .committed);
}

test "exhaustion during a deletion across many leaves leaves no effect" {
    try sweep(base_text, fragment, struct {
        fn act(fixture: *Fixture) anyerror!types.SubmitResult {
            const count = fixture.engine.graphemeCount();
            const op = [_]types.BufferOp{.{ .delete = .{ .start = 10, .end = count - 10 } }};
            return fixture.engine.submit(
                .{
                    .id = id,
                    .origin = fixture.engine.revision,
                    .payload = .{ .buffer_mutation = .{ .ops = &op } },
                },
            );
        }
    }.act, .committed);
}

test "exhaustion during a deletion that empties the document leaves no effect" {
    try sweep(base_text, fragment, struct {
        fn act(fixture: *Fixture) anyerror!types.SubmitResult {
            const count = fixture.engine.graphemeCount();
            const op = [_]types.BufferOp{.{ .delete = .{ .start = 0, .end = count } }};
            return fixture.engine.submit(
                .{
                    .id = id,
                    .origin = fixture.engine.revision,
                    .payload = .{ .buffer_mutation = .{ .ops = &op } },
                },
            );
        }
    }.act, .committed);
}

test "exhaustion while rejecting a composite after its buffer operations leaves no effect" {
    try sweep("abcd", noSetup, struct {
        fn act(fixture: *Fixture) anyerror!types.SubmitResult {
            // Operation 1 deletes the start of operation 0's insertion: the reference dies.
            const edits = [_]types.BufferOp{
                .{ .insert = .{ .pos = 2, .text = "x" } },
                .{ .delete = .{ .start = 1, .end = 4 } },
            };
            const place = [_]types.InteractionOp{.{ .set_selections = .{ .selections = &.{
                .{ .start = .{ .new = .{ .position = 0 } } },
                support.placeSpec(fixture.cursor, .{ .edit = .{ .op = 0, .edge = .start } }, null),
            } } }};
            return fixture.engine.submit(.{
                .id = id,
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
    }.act, .rejected);
}

test "exhaustion while rejecting a payload with an invalid later operation leaves no effect" {
    try sweep(base_text, fragment, struct {
        fn act(fixture: *Fixture) anyerror!types.SubmitResult {
            const count = fixture.engine.graphemeCount();
            const ops = [_]types.BufferOp{
                .{ .replace = .{ .start = 5, .end = 40, .text = "replacement" } },
                .{ .delete = .{ .start = count, .end = count + 5 } },
            };
            return fixture.engine.submit(
                .{
                    .id = id,
                    .origin = fixture.engine.revision,
                    .payload = .{ .buffer_mutation = .{ .ops = &ops } },
                },
            );
        }
    }.act, .rejected);
}

test "exhaustion while creating a session leaves no effect and issues no identity" {
    try sweep("abcdef", noSetup, struct {
        fn act(fixture: *Fixture) anyerror!types.SubmitResult {
            const block = try fixture.engine.createSession(
                .{ .id = id, .origin = fixture.engine.revision, .selections = &.{
                    .{
                        .start = .{ .new = .{ .position = 1 } },
                        .end = .{ .new = .{ .position = 4 } },
                    },
                    .{ .start = .{ .new = .{ .anchor = fixture.cursor } } },
                } },
            );
            return .{ .committed = block };
        }
    }.act, .committed);
}

test "exhaustion during a composite that prepares new endpoints leaves no effect" {
    try sweep("abcdef", noSetup, struct {
        fn act(fixture: *Fixture) anyerror!types.SubmitResult {
            const session = fixture.session;
            return fixture.engine.submit(.{
                .id = id,
                .origin = fixture.engine.revision,
                .label = "multi-cursor paste",
                .source = .{ .extension = "paste" },
                .payload = .{ .composite = .{ .parts = &.{
                    .{ .buffer_mutation = .{ .ops = &.{
                        .{ .insert = .{ .pos = 0, .text = "xy" } },
                        .{ .insert = .{ .pos = 5, .text = "z" } },
                    } } },
                    .{
                        .interaction_mutation = .{
                            .session_id = session,
                            .origin = try fixture.engine.interactionRevision(session),
                            .ops = &.{
                                .{ .set_selections = .{ .selections = &.{
                                    .{ .start = .{ .new = .{ .edit = .{ .op = 0 } } } },
                                    .{ .start = .{
                                        .new = .{ .edit = .{ .op = 1, .edge = .start } },
                                    }, .end = .{
                                        .new = .{ .edit = .{ .op = 1 } },
                                    } },
                                    .{ .start = .{ .keep = fixture.cursor } },
                                } } },
                                .{ .write_register = .{ .key = "pasted", .value = .{ .int = 2 } } },
                            },
                        },
                    },
                } } },
            });
        }
    }.act, .committed);
}

test "exhaustion while dropping a session is impossible: teardown does not allocate" {
    var fixture: Fixture = undefined;
    try fixture.init("abc");
    defer fixture.deinit();
    fixture.failing.fail_index = fixture.failing.alloc_index;
    var block = try fixture.engine.dropSession(.{ .id = id, .session = fixture.session });
    block.deinit(fixture.engine.allocator);
    try std.testing.expect(!fixture.failing.has_induced_failure);
}

test "exhaustion while taking a snapshot of several sessions leaks and double-frees nothing" {
    var fixture: Fixture = undefined;
    try fixture.init("abcdef");
    defer fixture.deinit();
    for (0..3) |index| {
        const session, _ = try support.caret(&fixture.engine, @intCast(index));
        var written = try fixture.engine.submit(
            .{ .id = id, .origin = fixture.engine.revision, .payload = .{ .interaction_mutation = .{
                .session_id = session,
                .origin = 0,
                .ops = &.{
                    .{ .write_register = .{ .key = "mode", .value = .{ .string = "insert" } } },
                    .{ .write_register = .{ .key = "count", .value = .{ .int = 2 } } },
                },
            } } },
        );
        written.deinit(fixture.engine.allocator);
    }
    var fail_after: usize = 0;
    while (true) : (fail_after += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_after });
        var snapshot = fixture.engine.snapshot(failing.allocator()) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        snapshot.deinit(failing.allocator());
        if (!failing.has_induced_failure) break;
    }
}
