//! Selection identity and ownership under SetSelections, registers, session lifecycle,
//! and the owned results every transition produces (SPEC §1.4, §2.6, §4.3, §7).
const std = @import("std");
const litura = @import("litura");
const BufferEngine = litura.BufferEngine;
const types = litura.types;
const events = litura.events;
const AnchorId = litura.anchors.AnchorId;
const allocator = std.testing.allocator;
const State = @import("engine_state.zig").State;
const support = @import("support.zig");
const id = support.id;
const position = support.position;

/// Submits one interaction mutation at head. The caller owns the result.
fn interact(
    engine: *BufferEngine,
    session: u32,
    ops: []const types.InteractionOp,
) !types.SubmitResult {
    return engine.submit(.{
        .id = id,
        .origin = engine.revision,
        .payload = .{ .interaction_mutation = .{
            .session_id = session,
            .origin = try engine.interactionRevision(session),
            .ops = ops,
        } },
    });
}

fn setSelections(
    engine: *BufferEngine,
    session: u32,
    specs: []const types.SelectionSpec,
) !types.SubmitResult {
    return interact(engine, session, &.{.{ .set_selections = .{ .selections = specs } }});
}

fn expectDisposed(engine: *BufferEngine, anchor: AnchorId) !void {
    try std.testing.expectEqual(
        litura.anchors.HandleStatus.disposed,
        (try engine.queryAnchor(anchor)).status,
    );
}

fn stickiness(engine: *BufferEngine, anchor: AnchorId) !litura.anchors.AnchorStickiness {
    return (try engine.queryAnchor(anchor)).stickiness.?;
}

/// Creates a session from `specs` and returns its identifier and selections, owned.
fn createSession(
    engine: *BufferEngine,
    specs: []const types.SelectionSpec,
) !struct { u32, []events.SelectionValue } {
    var block = try engine.createSession(
        .{ .id = id, .origin = engine.revision, .selections = specs },
    );
    defer block.deinit(allocator);
    const created = block.lifecycle.change.session_created;
    return .{ created.session, try allocator.dupe(events.SelectionValue, created.selections) };
}

test "targets in one SetSelections are resolved against the same state" {
    var engine = try BufferEngine.initFromText(allocator, "0123456789", null);
    defer engine.deinit();
    const sid, const created = try createSession(&engine, &.{
        .{ .start = .{ .new = .{ .position = 3 } } },
        .{ .start = .{ .new = .{ .position = 9 } } },
    });
    defer allocator.free(created);
    const a = created[0].start.anchor;
    const b = created[1].start.anchor;

    var swapped = try setSelections(&engine, sid, &.{
        .{ .start = .{ .move = .{ .anchor = a, .to = .{ .anchor = b } } } },
        .{ .start = .{ .move = .{ .anchor = b, .to = .{ .anchor = a } } } },
    });
    try support.expectCommitted(&engine, &swapped);
    try std.testing.expectEqual(@as(?u32, 9), try position(&engine, a));
    try std.testing.expectEqual(@as(?u32, 3), try position(&engine, b));
}

test "an endpoint the replacement omits can still be sampled, and is released afterwards" {
    var engine = try BufferEngine.initFromText(allocator, "abcdef", null);
    defer engine.deinit();
    const sid, const cursor = try support.caret(&engine, 4);

    var result = try setSelections(
        &engine,
        sid,
        &.{.{ .start = .{ .new = .{ .anchor = cursor } } }},
    );
    defer result.deinit(allocator);
    const values = result.committed.transition.interactions[0].selections.?.new;
    try std.testing.expectEqual(@as(?u32, 4), values[0].start.position);
    try std.testing.expect(values[0].start.anchor.value != cursor.value);
    try expectDisposed(&engine, cursor);
}

test "keeping an untouched selection preserves its dead mark for undo while another moves" {
    var engine = try BufferEngine.initFromText(allocator, "abcdefghij", null);
    defer engine.deinit();
    const sid, const created = try createSession(&engine, &.{
        .{ .start = .{ .new = .{ .position = 2 } }, .end = .{ .new = .{ .position = 6 } } },
        .{ .start = .{ .new = .{ .position = 8 } } },
    });
    defer allocator.free(created);
    const mark = created[0].start.anchor;
    const point = created[0].end.anchor;
    const caret = created[1].start.anchor;

    // Another client deletes around the mark.
    try support.edit(&engine, &.{.{ .delete = .{ .start = 1, .end = 4 } }});
    try std.testing.expectEqual(@as(?u32, null), try position(&engine, mark));

    var moved = try setSelections(&engine, sid, &.{
        .{ .start = .{ .keep = mark }, .end = .{ .keep = point } },
        .{ .start = .{ .move = .{ .anchor = caret, .to = .{ .position = 0 } } } },
    });
    defer moved.deinit(allocator);
    const change = moved.committed.transition.interactions[0].selections.?;
    try std.testing.expectEqual(@as(?u32, null), change.new[0].start.position);
    try std.testing.expectEqual(mark, change.new[0].start.anchor);
    try std.testing.expectEqual(caret, change.new[1].start.anchor);

    try support.undo(&engine);
    try std.testing.expectEqual(@as(?u32, 2), try position(&engine, mark));
    try std.testing.expectEqual(@as(?u32, 6), try position(&engine, point));
    try std.testing.expectEqual(@as(?u32, 0), try position(&engine, caret));
}

test "an endpoint created and released within one composite is never issued" {
    var engine = try BufferEngine.initFromText(allocator, "abcdef", null);
    defer engine.deinit();
    const sid, const cursor = try support.caret(&engine, 1);
    const boundary = engine.next_public_anchor_id;
    const origin = try engine.interactionRevision(sid);

    // The second part cannot keep the first part's new endpoint: no client could name it.
    var result = try engine.submit(.{
        .id = id,
        .origin = engine.revision,
        .payload = .{ .composite = .{ .parts = &.{
            .{ .buffer_mutation = .{ .ops = &.{.{ .insert = .{ .pos = 0, .text = "x" } }} } },
            .{ .interaction_mutation = .{ .session_id = sid, .origin = origin, .ops = &.{
                .{ .set_selections = .{ .selections = &.{
                    .{ .start = .{ .keep = cursor } },
                    .{ .start = .{ .new = .{ .position = 3 } } },
                } } },
            } } },
            .{ .interaction_mutation = .{ .session_id = sid, .origin = origin, .ops = &.{
                .{ .set_selections = .{ .selections = &.{.{ .start = .{ .keep = cursor } }} } },
            } } },
        } } },
    });
    defer result.deinit(allocator);

    // One net event for the session: the provisional endpoint never existed publicly.
    const interactions = result.committed.transition.interactions;
    try std.testing.expectEqual(@as(usize, 1), interactions.len);
    try std.testing.expectEqual(@as(?events.SelectionChange, null), interactions[0].selections);
    try std.testing.expectEqual(@as(u32, 0), interactions[0].old_revision);
    try std.testing.expectEqual(@as(u32, 2), interactions[0].new_revision);
    try std.testing.expectEqual(boundary, engine.next_public_anchor_id);
    try std.testing.expectError(error.KeyError, engine.queryAnchor(.{ .value = boundary }));
}

test "an endpoint published by one transition and released by a later one is issued, then disposed" {
    var engine = try BufferEngine.initFromText(allocator, "abcdef", null);
    defer engine.deinit();
    const sid, const cursor = try support.caret(&engine, 1);

    var created = try setSelections(&engine, sid, &.{
        .{ .start = .{ .keep = cursor } },
        .{ .start = .{ .new = .{ .position = 3 } } },
    });
    defer created.deinit(allocator);
    const endpoint = created.committed.transition.interactions[0].selections.?.new[1].start.anchor;
    try std.testing.expectEqual(
        litura.anchors.HandleStatus.live,
        (try engine.queryAnchor(endpoint)).status,
    );

    var released = try setSelections(&engine, sid, &.{.{ .start = .{ .keep = cursor } }});
    defer released.deinit(allocator);
    const old = released.committed.transition.interactions[0].selections.?.old;
    try std.testing.expectEqual(endpoint, old[1].start.anchor);
    try expectDisposed(&engine, endpoint);
}

test "a transition reports one net event per session it changed, in order of first change" {
    var engine = try BufferEngine.initFromText(allocator, "abcdef", null);
    defer engine.deinit();
    const a, const a_cursor = try support.caret(&engine, 1);
    const b, const b_cursor = try support.caret(&engine, 2);

    var result = try engine.submit(.{
        .id = id,
        .origin = engine.revision,
        .payload = .{ .composite = .{ .parts = &.{
            .{ .interaction_mutation = .{ .session_id = b, .origin = 0, .ops = &.{
                .{ .write_register = .{ .key = "k", .value = .{ .int = 1 } } },
            } } },
            .{ .interaction_mutation = .{ .session_id = a, .origin = 0, .ops = &.{
                .{
                    .set_selections = .{
                        .selections = &.{support.placeSpec(a_cursor, .{ .position = 4 }, null)},
                    },
                },
            } } },
            .{ .interaction_mutation = .{ .session_id = b, .origin = 0, .ops = &.{
                .{ .write_register = .{ .key = "k", .value = .{ .int = 2 } } },
                .{
                    .set_selections = .{
                        .selections = &.{support.placeSpec(b_cursor, .{ .position = 5 }, null)},
                    },
                },
            } } },
        } } },
    });
    defer result.deinit(allocator);
    const interactions = result.committed.transition.interactions;
    try std.testing.expectEqual(@as(usize, 2), interactions.len);
    try std.testing.expectEqual(b, interactions[0].session);
    try std.testing.expectEqual(@as(u32, 0), interactions[0].old_revision);
    try std.testing.expectEqual(@as(u32, 2), interactions[0].new_revision);
    try std.testing.expectEqual(
        @as(?events.InteractionValue, null),
        interactions[0].registers[0].old,
    );
    try std.testing.expectEqual(@as(i64, 2), interactions[0].registers[0].new.?.int);
    try std.testing.expectEqual(@as(?u32, 5), interactions[0].selections.?.new[0].start.position);
    try std.testing.expectEqual(a, interactions[1].session);
    try std.testing.expectEqual(@as(u32, 1), interactions[1].new_revision);
    try std.testing.expectEqual(@as(u32, 2), try engine.interactionRevision(b));
}

test "a composite rejected after preparing new endpoints issues nothing and changes nothing" {
    var engine = try BufferEngine.initFromText(allocator, "abcdef", null);
    defer engine.deinit();
    var provider = litura.views.StaticTokenProvider{ .spans = &.{} };
    try engine.registerViewProvider(provider.provider());
    const sid, const cursor = try support.caret(&engine, 1);
    try support.edit(&engine, &.{.{ .insert = .{ .pos = 0, .text = "!" } }});
    try support.undo(&engine);
    provider.stale = false;
    var before = try State.capture(allocator, &engine, &provider);
    defer before.deinit();

    var result = try engine.submit(.{
        .id = id,
        .origin = engine.revision,
        .payload = .{ .composite = .{ .parts = &.{
            .{ .buffer_mutation = .{ .ops = &.{.{ .insert = .{ .pos = 0, .text = "xy" } }} } },
            .{
                .interaction_mutation = .{
                    .session_id = sid,
                    .origin = try engine.interactionRevision(sid),
                    .ops = &.{
                        .{ .set_selections = .{ .selections = &.{
                            .{ .start = .{ .keep = cursor } },
                            .{ .start = .{ .new = .{ .edit = .{ .op = 0 } } } },
                            .{
                                .start = .{ .new = .{ .position = 4 } },
                                .end = .{ .new = .{ .position = 6 } },
                            },
                        } } },
                        .{ .write_register = .{ .key = "k", .value = .{ .int = 1 } } },
                    },
                },
            },
            .{
                .interaction_mutation = .{
                    .session_id = sid,
                    .origin = try engine.interactionRevision(sid),
                    .ops = &.{.{ .set_selections = .{ .selections = &.{
                        .{ .start = .{ .new = .{ .position = 99 } } },
                    } } }},
                },
            },
        } } },
    });
    try support.expectRejected(&engine, &result, .invalid, "position 99 out of range");
    var after = try State.capture(allocator, &engine, &provider);
    defer after.deinit();
    try State.expectEqual(&before, &after);
    try std.testing.expect(engine.canRedo());
}

test "selection stickiness follows the endpoint's role" {
    var engine = try BufferEngine.initFromText(allocator, "abcdef", null);
    defer engine.deinit();
    const sid, const cursor = try support.caret(&engine, 4);
    try std.testing.expectEqual(.sticky, try stickiness(&engine, cursor));

    var extended = try setSelections(&engine, sid, &.{
        .{ .start = .{ .new = .{ .position = 1 } }, .end = .{ .keep = cursor }, .active = .end },
    });
    try support.expectCommitted(&engine, &extended);
    const mark = (try support.mark(&engine, sid)).?;
    try std.testing.expectEqual(.weak, try stickiness(&engine, mark));
    try std.testing.expectEqual(.sticky, try stickiness(&engine, cursor));

    // Exchanging point and mark exchanges their stickiness, not their identities.
    var exchanged = try setSelections(&engine, sid, &.{
        .{ .start = .{ .keep = mark }, .end = .{ .keep = cursor }, .active = .start },
    });
    try support.expectCommitted(&engine, &exchanged);
    try std.testing.expectEqual(.sticky, try stickiness(&engine, mark));
    try std.testing.expectEqual(.weak, try stickiness(&engine, cursor));
    try std.testing.expectEqual(@as(?u32, 4), try position(&engine, cursor));

    // A dead fixed endpoint cannot become the active one or a caret.
    var back = try setSelections(&engine, sid, &.{
        .{ .start = .{ .keep = mark }, .end = .{ .keep = cursor }, .active = .end },
    });
    try support.expectCommitted(&engine, &back);
    try support.edit(&engine, &.{.{ .delete = .{ .start = 0, .end = 2 } }});
    var promoted = try setSelections(&engine, sid, &.{
        .{ .start = .{ .keep = mark }, .end = .{ .keep = cursor }, .active = .start },
    });
    var expected: [80]u8 = undefined;
    const message = try std.fmt.bufPrint(
        &expected,
        "dead endpoint {d} can only be kept as a fixed endpoint",
        .{mark.value},
    );
    try support.expectRejected(&engine, &promoted, .invalid, message);
    var caret = try setSelections(&engine, sid, &.{.{ .start = .{ .keep = mark } }});
    try support.expectRejected(&engine, &caret, .invalid, message);
    var moved = try setSelections(&engine, sid, &.{
        .{
            .start = .{ .move = .{ .anchor = mark, .to = .{ .position = 0 } } },
            .end = .{ .keep = cursor },
        },
    });
    const dead = try std.fmt.bufPrint(
        &expected,
        "endpoint {d} is dead and cannot move",
        .{mark.value},
    );
    try support.expectRejected(&engine, &moved, .invalid, dead);
}

test "SetSelections can only keep or move the session's own endpoints, once each" {
    var engine = try BufferEngine.initFromText(allocator, "abcdef", null);
    defer engine.deinit();
    const sid, const cursor = try support.caret(&engine, 2);
    _, const other = try support.caret(&engine, 3);
    const client = try engine.createAnchor(1, .weak);
    var expected: [80]u8 = undefined;

    var foreign = try setSelections(&engine, sid, &.{.{ .start = .{ .keep = other } }});
    try support.expectRejected(&engine, &foreign, .invalid, try std.fmt.bufPrint(
        &expected,
        "anchor {d} is not an endpoint of session {d}",
        .{ other.value, sid },
    ));
    var adopted = try setSelections(&engine, sid, &.{.{ .start = .{ .keep = client } }});
    try support.expectRejected(&engine, &adopted, .invalid, try std.fmt.bufPrint(
        &expected,
        "anchor {d} is not an endpoint of session {d}",
        .{ client.value, sid },
    ));
    var twice = try setSelections(&engine, sid, &.{
        .{ .start = .{ .keep = cursor } },
        .{ .start = .{ .move = .{ .anchor = cursor, .to = .{ .position = 0 } } } },
    });
    try support.expectRejected(&engine, &twice, .invalid, try std.fmt.bufPrint(
        &expected,
        "endpoint {d} appears more than once",
        .{cursor.value},
    ));
    var empty = try setSelections(&engine, sid, &.{});
    try support.expectRejected(&engine, &empty, .invalid, "a session needs at least one selection");

    // Sampling another session's endpoint or a client anchor creates no relationship.
    var sampled = try setSelections(&engine, sid, &.{
        .{
            .start = .{ .new = .{ .anchor = client } },
            .end = .{ .move = .{ .anchor = cursor, .to = .{ .anchor = other } } },
        },
    });
    try support.expectCommitted(&engine, &sampled);
    try engine.dropAnchor(client);
    try std.testing.expectEqual(@as(?u32, 3), try position(&engine, cursor));
    try std.testing.expectEqual(
        @as(?u32, 1),
        try position(&engine, (try support.mark(&engine, sid)).?),
    );
}

test "registers are written and cleared as interaction state with explicit deltas" {
    var engine = try BufferEngine.initFromText(allocator, "abc", null);
    defer engine.deinit();
    const sid, _ = try support.caret(&engine, 0);

    // The request's strings are released before the result is inspected.
    const key = try allocator.dupe(u8, "mode");
    const value = try allocator.dupe(u8, "visual");
    var written = try interact(&engine, sid, &.{
        .{ .write_register = .{ .key = key, .value = .{ .string = value } } },
        .{ .write_register = .{ .key = "count", .value = .{ .int = 3 } } },
        .{ .write_register = .{ .key = "temporary", .value = .{ .boolean = true } } },
        .{ .clear_register = .{ .key = "temporary" } },
    });
    allocator.free(key);
    allocator.free(value);
    defer written.deinit(allocator);
    const event = written.committed.transition.interactions[0];
    try std.testing.expectEqual(@as(?events.SelectionChange, null), event.selections);
    try std.testing.expectEqual(@as(usize, 2), event.registers.len);
    try std.testing.expectEqualStrings("mode", event.registers[0].key);
    try std.testing.expectEqual(@as(?events.InteractionValue, null), event.registers[0].old);
    try std.testing.expectEqualStrings("visual", event.registers[0].new.?.string);
    try std.testing.expectEqualStrings("visual", (try engine.queryRegister(sid, "mode")).?.string);
    try std.testing.expectEqual(@as(i64, 3), (try engine.queryRegister(sid, "count")).?.int);
    try std.testing.expectEqual(
        @as(?events.InteractionValue, null),
        try engine.queryRegister(sid, "temporary"),
    );

    var cleared = try interact(&engine, sid, &.{.{ .clear_register = .{ .key = "mode" } }});
    defer cleared.deinit(allocator);
    const change = cleared.committed.transition.interactions[0].registers[0];
    try std.testing.expectEqualStrings("visual", change.old.?.string);
    try std.testing.expectEqual(@as(?events.InteractionValue, null), change.new);
    try std.testing.expectEqual(@as(u32, 2), try engine.interactionRevision(sid));
}

test "an accepted no-op still commits: revisions, history and blocks follow" {
    var engine = try BufferEngine.initFromText(allocator, "abc", null);
    defer engine.deinit();
    const sid, const cursor = try support.caret(&engine, 1);
    const weak = try engine.createAnchor(2, .weak);

    // An identical selection list: the interaction revision advances, the delta is empty.
    var same = try setSelections(&engine, sid, &.{.{ .start = .{ .keep = cursor } }});
    defer same.deinit(allocator);
    const event = same.committed.transition.interactions[0];
    try std.testing.expectEqual(@as(?events.SelectionChange, null), event.selections);
    try std.testing.expectEqual(@as(usize, 0), event.registers.len);
    try std.testing.expectEqual(@as(u32, 1), event.new_revision);

    // Text that ends up identical is still an edit: it records undo and discards redo,
    // and a replacement can kill anchors even though the bytes are unchanged.
    try support.edit(&engine, &.{.{ .insert = .{ .pos = 0, .text = "x" } }});
    try support.undo(&engine);
    try engine.save("interaction-test-no-op.txt");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, "interaction-test-no-op.txt") catch {};
    const revision = engine.revision;
    const sequence = engine.next_sequence;
    try support.edit(&engine, &.{.{ .replace = .{ .start = 1, .end = 3, .text = "bc" } }});
    try support.expectText(&engine, "abc");
    try std.testing.expectEqual(revision + 1, engine.revision);
    try std.testing.expectEqual(sequence + 1, engine.next_sequence);
    try std.testing.expect(engine.dirty());
    try std.testing.expect(engine.canUndo());
    try std.testing.expect(!engine.canRedo());
    try std.testing.expectEqual(
        litura.anchors.HandleStatus.dead,
        (try engine.queryAnchor(weak)).status,
    );
}

test "session creation rejects anything but new endpoints, and issues nothing on failure" {
    var engine = try BufferEngine.initFromText(allocator, "abc", null);
    defer engine.deinit();
    _, const cursor = try support.caret(&engine, 0);
    const boundary = engine.next_public_anchor_id;
    const sequence = engine.next_sequence;
    const next_session = engine.next_session_id;

    const invalid = [_][]const types.SelectionSpec{
        &.{},
        &.{.{ .start = .{ .keep = cursor } }},
        &.{.{ .start = .{ .new = .{ .edit = .{ .op = 0 } } } }},
        &.{
            .{ .start = .{ .new = .{ .position = 1 } } },
            .{ .start = .{ .new = .{ .position = 4 } } },
        },
    };
    for (invalid) |specs| {
        try std.testing.expectError(
            error.InvalidArgument,
            engine.createSession(.{ .id = id, .origin = engine.revision, .selections = specs }),
        );
    }
    try std.testing.expectError(error.StaleOrigin, engine.createSession(.{
        .id = id,
        .origin = 5,
        .selections = &.{.{ .start = .{ .new = .{ .position = 0 } } }},
    }));
    try std.testing.expectEqual(boundary, engine.next_public_anchor_id);
    try std.testing.expectEqual(sequence, engine.next_sequence);
    try std.testing.expectEqual(next_session, engine.next_session_id);
}

test "reports and blocks own their contents after the request's memory is freed" {
    var engine = try BufferEngine.initFromText(allocator, "hello", null);
    defer engine.deinit();

    const expected_text = try allocator.dupe(u8, "jello");
    const extension = try allocator.dupe(u8, "spell-check");
    const label = try allocator.dupe(u8, "fix typo");
    const guards = try allocator.dupe(types.Guard, &.{.{ .slice_equality = .{
        .start = .{ .position = 0 },
        .end = .{ .position = 5 },
        .expected = expected_text,
        .max_extent = 16,
    } }});
    const ops = try allocator.dupe(
        types.BufferOp,
        &.{.{ .replace = .{ .start = 0, .end = 1, .text = "j" } }},
    );
    const intent = types.Intent{
        .origin = engine.revision,
        .id = .{ .value = 0xfeed },
        .payload = .{ .buffer_mutation = .{ .ops = ops } },
        .source = .{ .extension = extension },
        .label = label,
        .guards = guards,
    };
    var rejected = try engine.submit(intent);
    defer rejected.deinit(allocator);
    var committed = try engine.submit(.{
        .id = .{ .value = 0xbeef },
        .origin = engine.revision,
        .payload = intent.payload,
        .source = intent.source,
        .label = intent.label,
    });
    defer committed.deinit(allocator);
    @memset(expected_text, '#');
    @memset(extension, '#');
    @memset(label, '#');
    allocator.free(expected_text);
    allocator.free(extension);
    allocator.free(label);
    allocator.free(guards);
    allocator.free(ops);

    const report = rejected.rejected;
    try std.testing.expectEqual(@as(u128, 0xfeed), report.intent.value);
    try std.testing.expectEqualStrings("jello", report.per_guard[0].guard.slice_equality.expected);
    const transition = committed.committed.transition;
    try std.testing.expectEqual(@as(u128, 0xbeef), transition.intent.value);
    try std.testing.expectEqualStrings("spell-check", transition.source.extension);
    try std.testing.expectEqualStrings("fix typo", transition.label.?);
}

test "sequence numbers are gapless, skip rejections, and resume from a snapshot" {
    var engine = try BufferEngine.initFromText(allocator, "abc", null);
    defer engine.deinit();
    var initial = try engine.snapshot(allocator);
    defer initial.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 0), initial.next_sequence);

    var created = try engine.createSession(
        .{
            .id = id,
            .origin = engine.revision,
            .selections = &.{.{ .start = .{ .new = .{ .position = 0 } } }},
        },
    );
    defer created.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 0), created.sequence());
    var rejected = try engine.submit(.{ .id = id, .origin = 7, .payload = .{ .undo = .{} } });
    rejected.deinit(allocator);
    var edited = try support.editBlock(&engine, &.{.{ .insert = .{ .pos = 0, .text = "x" } }});
    defer edited.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 1), edited.sequence());

    var later = try engine.snapshot(allocator);
    defer later.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), later.next_sequence);
    try std.testing.expectEqual(@as(usize, 1), later.sessions.len);
    try std.testing.expectEqual(@as(?u32, 1), later.sessions[0].selections[0].start.position);
}

test "an endpoint created and released within one mutation is never issued" {
    var engine = try BufferEngine.initFromText(allocator, "abcdef", null);
    defer engine.deinit();
    const sid, const cursor = try support.caret(&engine, 1);
    const boundary = engine.next_public_anchor_id;

    // The second replacement cannot keep the first one's new endpoint: no client could
    // name it. It is released before the mutation's event is built.
    var result = try interact(&engine, sid, &.{
        .{ .set_selections = .{ .selections = &.{
            .{ .start = .{ .keep = cursor } },
            .{ .start = .{ .new = .{ .position = 3 } } },
        } } },
        .{ .set_selections = .{ .selections = &.{
            .{ .start = .{ .keep = cursor } },
            .{ .start = .{ .new = .{ .position = 5 } } },
        } } },
    });
    defer result.deinit(allocator);
    const change = result.committed.transition.interactions[0].selections.?;
    const kept = change.new[1].start.anchor;
    try std.testing.expectEqual(boundary, kept.value);
    try std.testing.expectEqual(@as(?u32, 5), change.new[1].start.position);
    try std.testing.expectEqual(boundary + 1, engine.next_public_anchor_id);
    try std.testing.expectEqual(
        litura.anchors.HandleStatus.live,
        (try engine.queryAnchor(kept)).status,
    );
}
