//! SPEC 1.3: logical grapheme coordinates must be independent of edit/piece boundaries.
const std = @import("std");
const litura = @import("litura");
const BufferEngine = litura.BufferEngine;
const allocator = std.testing.allocator;
const decomposed = "e\u{0301}";

fn insert(engine: *BufferEngine, position: u32, text: []const u8) !void {
    var result = try engine.submit(.{
        .origin = engine.revision,
        .payload = .{ .buffer_mutation = .{ .ops = &.{.{ .insert = .{
            .pos = position,
            .text = text,
        } }} } },
        .source = "test",
        .cause = "separate-code-point-input",
    });
    defer result.deinit(allocator);
    try std.testing.expect(result == .edit_event);
}

fn expectText(engine: *BufferEngine, expected: []const u8) !void {
    const text = try engine.getText();
    defer allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

test "separate base and combining insertions form one logical grapheme" {
    var engine = try BufferEngine.init(allocator);
    defer engine.deinit();
    try insert(&engine, 0, "e");
    try insert(&engine, 1, "\u{0301}");
    try expectText(&engine, decomposed);
    try std.testing.expectEqual(@as(u32, 2), engine.revision);
    try std.testing.expectEqual(@as(u32, 1), engine.graphemeCount());
    const cluster = try engine.getTextRange(0, 1);
    defer allocator.free(cluster);
    try std.testing.expectEqualStrings(decomposed, cluster);
    var cursor = try engine.graphemeCursor(0);
    try std.testing.expectEqualStrings(decomposed, try cursor.current());
    try std.testing.expect(!cursor.advance());
    try std.testing.expectEqual(@as(u32, 1), cursor.position);
}

test "sticky session cursor remains at the end of a combined grapheme" {
    var engine = try BufferEngine.init(allocator);
    defer engine.deinit();
    const cursor = try engine.createAnchor(0, .sticky);
    const session = try engine.createSession(&.{cursor});
    try insert(&engine, 0, "e");
    try std.testing.expectEqual(@as(?u32, 1), (try engine.queryAnchor(cursor)).position);
    const interaction_revision = try engine.interactionRevision(session);
    try insert(&engine, 1, "\u{0301}");
    try std.testing.expectEqual(@as(?u32, 1), (try engine.queryAnchor(cursor)).position);
    try std.testing.expect((try engine.queryAnchor(cursor)).position.? <= engine.graphemeCount());
    // Text changed, but the logical cursor and selection did not move.
    try std.testing.expectEqual(interaction_revision, try engine.interactionRevision(session));
}

test "one grapheme deletion removes separately inserted base and accent and undo restores both" {
    var engine = try BufferEngine.init(allocator);
    defer engine.deinit();
    const cursor = try engine.createAnchor(0, .sticky);
    _ = try engine.createSession(&.{cursor});
    try insert(&engine, 0, "e");
    try insert(&engine, 1, "\u{0301}");
    var deletion = try engine.submit(.{
        .origin = engine.revision,
        .payload = .{ .buffer_mutation = .{ .ops = &.{.{ .delete = .{
            .start = 0,
            .end = 1,
        } }} } },
    });
    defer deletion.deinit(allocator);
    try std.testing.expect(deletion == .edit_event);
    try expectText(&engine, "");
    try std.testing.expectEqual(@as(u32, 0), engine.graphemeCount());
    try std.testing.expectEqual(@as(?u32, 0), (try engine.queryAnchor(cursor)).position);
    var undo = try engine.submit(.{ .payload = .{ .undo = .{} }, .origin = engine.revision });
    defer undo.deinit(allocator);
    try std.testing.expect(undo == .edit_event);
    try expectText(&engine, decomposed);
    try std.testing.expectEqual(@as(u32, 1), engine.graphemeCount());
    try std.testing.expectEqual(@as(?u32, 1), (try engine.queryAnchor(cursor)).position);
}

test "undo accent insertion restores base and redo restores one grapheme" {
    var engine = try BufferEngine.init(allocator);
    defer engine.deinit();
    const cursor = try engine.createAnchor(0, .sticky);
    try insert(&engine, 0, "e");
    try insert(&engine, 1, "\u{0301}");
    var undo = try engine.submit(.{ .payload = .{ .undo = .{} }, .origin = engine.revision });
    defer undo.deinit(allocator);
    try std.testing.expect(undo == .edit_event);
    try expectText(&engine, "e");
    try std.testing.expectEqual(@as(?u32, 1), (try engine.queryAnchor(cursor)).position);
    var redo = try engine.submit(.{ .payload = .{ .redo = .{} }, .origin = engine.revision });
    defer redo.deinit(allocator);
    try std.testing.expect(redo == .edit_event);
    try expectText(&engine, decomposed);
    try std.testing.expectEqual(@as(u32, 4), engine.revision);
    try std.testing.expectEqual(@as(u32, 1), engine.graphemeCount());
    try std.testing.expectEqual(@as(?u32, 1), (try engine.queryAnchor(cursor)).position);
}

test "precomposed and single-submission decomposed text each form one grapheme" {
    for ([_][]const u8{ "\u{00e9}", decomposed }) |text| {
        var engine = try BufferEngine.init(allocator);
        defer engine.deinit();
        try insert(&engine, 0, text);
        try std.testing.expectEqual(@as(u32, 1), engine.graphemeCount());
        try expectText(&engine, text);
    }
}

test "piece table segmentation is independent of insertion boundaries" {
    var table = try litura.piece_table.PieceTable.init(allocator);
    defer table.deinit();
    try table.insert(0, "e");
    try table.insert(1, "\u{0301}");
    try std.testing.expectEqual(@as(u32, 1), table.graphemeCount());
    try std.testing.expectEqualStrings(decomposed, try table.graphemeAt(0));
}

test "deleting a separator resegments the newly adjacent text" {
    var table = try litura.piece_table.PieceTable.init(allocator);
    defer table.deinit();
    try table.initFromText("e\n\u{0301}");
    try std.testing.expectEqual(@as(u32, 3), table.graphemeCount());
    try table.delete(1, 2);
    const text = try table.getText();
    defer allocator.free(text);
    try std.testing.expectEqualStrings(decomposed, text);
    try std.testing.expectEqual(@as(u32, 1), table.graphemeCount());
}

fn submitOps(engine: *BufferEngine, ops: []const litura.types.BufferOp) !void {
    var result = try engine.submit(.{
        .origin = engine.revision,
        .payload = .{ .buffer_mutation = .{ .ops = ops } },
    });
    defer result.deinit(allocator);
    try std.testing.expect(result == .edit_event);
}

fn submitHistory(engine: *BufferEngine, comptime kind: enum { undo, redo }) !void {
    var result = try engine.submit(.{
        .origin = engine.revision,
        .payload = if (kind == .undo) .{ .undo = .{} } else .{ .redo = .{} },
    });
    defer result.deinit(allocator);
    try std.testing.expect(result == .edit_event);
}

/// Oracle: the engine's clusters must equal whole-text segmentation of its current text.
fn expectSegmentationMatchesWholeText(engine: *BufferEngine) !void {
    const text = try engine.getText();
    defer allocator.free(text);
    var expected = litura.segmentation.graphemeIterator(text);
    var count: u32 = 0;
    var cursor = try engine.graphemeCursor(0);
    while (expected.next()) |cluster| : (count += 1) {
        try std.testing.expect(cursor.valid);
        try std.testing.expectEqual(count, cursor.position);
        try std.testing.expectEqualStrings(cluster, try cursor.current());
        const range = try engine.getTextRange(count, count + 1);
        defer allocator.free(range);
        try std.testing.expectEqualStrings(cluster, range);
        _ = cursor.advance();
    }
    try std.testing.expect(!cursor.valid);
    try std.testing.expectEqual(count, engine.graphemeCount());
}

test "incremental segmentation matches whole-text segmentation and undo restores every revision" {
    const fragments = [_][]const u8{
        "e",         "\u{0301}",  "a",         "\r",       "\n",
        "\u{1F1F3}", "\u{1F1F4}", "\u{1F1F8}", "\u{200D}", "\u{1F468}",
        "\u{1F469}", "\u{1F3FD}", "\u{FE0F}",  "\u{0915}", "\u{094D}",
        "\u{0937}",  "\u{1100}",  "\u{1161}",  "\u{11A8}", " ",
    };
    var prng = std.Random.DefaultPrng.init(0x11ce_5eed);
    const random = prng.random();

    for (0..4) |_| {
        var engine = try BufferEngine.init(allocator);
        defer engine.deinit();
        var history: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (history.items) |text| allocator.free(text);
            history.deinit(allocator);
        }
        try history.append(allocator, try engine.getText());

        for (0..60) |_| {
            var insertion: [12]u8 = undefined;
            var insertion_len: usize = 0;
            for (0..random.intRangeAtMost(usize, 1, 3)) |_| {
                const fragment = fragments[random.uintLessThan(usize, fragments.len)];
                @memcpy(insertion[insertion_len..][0..fragment.len], fragment);
                insertion_len += fragment.len;
            }
            const count = engine.graphemeCount();
            const start = random.uintAtMost(u32, count);
            const end = @min(count, start + random.uintAtMost(u32, 2));
            const text = insertion[0..insertion_len];
            const op: litura.types.BufferOp = switch (random.uintLessThan(u8, 4)) {
                0, 1 => .{ .insert = .{ .pos = start, .text = text } },
                2 => .{ .delete = .{ .start = start, .end = end } },
                else => .{ .replace = .{ .start = start, .end = end, .text = text } },
            };
            try submitOps(&engine, &.{op});
            try expectSegmentationMatchesWholeText(&engine);
            try history.append(allocator, try engine.getText());
        }

        var index = history.items.len - 1;
        while (index > 0) : (index -= 1) {
            try submitHistory(&engine, .undo);
            try expectText(&engine, history.items[index - 1]);
            try expectSegmentationMatchesWholeText(&engine);
        }
        for (history.items[1..]) |text| {
            try submitHistory(&engine, .redo);
            try expectText(&engine, text);
            try expectSegmentationMatchesWholeText(&engine);
        }
    }
}

test "separately inserted CR and LF form one grapheme" {
    var engine = try BufferEngine.init(allocator);
    defer engine.deinit();
    try insert(&engine, 0, "a\r");
    try insert(&engine, 2, "\nb");
    try std.testing.expectEqual(@as(u32, 3), engine.graphemeCount());
    try expectSegmentationMatchesWholeText(&engine);
}

test "disappearing boundary projects weak anchors back and sticky anchors forward" {
    var engine = try BufferEngine.init(allocator);
    defer engine.deinit();
    try insert(&engine, 0, "e");
    const weak = try engine.createAnchor(1, .weak);
    const sticky = try engine.createAnchor(1, .sticky);
    try insert(&engine, 1, "\u{0301}");
    // The inserted accent stays after the weak anchor and before the sticky one.
    // Resegmentation is not deletion: neither anchor dies.
    try std.testing.expectEqual(@as(?u32, 0), (try engine.queryAnchor(weak)).position);
    try std.testing.expectEqual(@as(?u32, 1), (try engine.queryAnchor(sticky)).position);
}

test "regional indicator parity change rebases anchors to the right of the edit" {
    var engine = try BufferEngine.init(allocator);
    defer engine.deinit();
    // Inserted one code point at a time: NO SE flags.
    for ([_][]const u8{ "\u{1F1F3}", "\u{1F1F4}", "\u{1F1F8}", "\u{1F1EA}" }) |ri| {
        try insert(&engine, engine.graphemeCount(), ri);
    }
    try std.testing.expectEqual(@as(u32, 2), engine.graphemeCount());
    const weak = try engine.createAnchor(1, .weak);
    const sticky = try engine.createAnchor(1, .sticky);

    try insert(&engine, 0, "\u{1F1E6}");
    // Five indicators pair from the left: (A N)(O S)(E). The old N|O boundary byte
    // now lies inside (O S): weak rounds down, sticky rounds up.
    try std.testing.expectEqual(@as(u32, 3), engine.graphemeCount());
    try expectSegmentationMatchesWholeText(&engine);
    try std.testing.expectEqual(@as(?u32, 1), (try engine.queryAnchor(weak)).position);
    try std.testing.expectEqual(@as(?u32, 2), (try engine.queryAnchor(sticky)).position);

    try submitHistory(&engine, .undo);
    try expectText(&engine, "\u{1F1F3}\u{1F1F4}\u{1F1F8}\u{1F1EA}");
    try std.testing.expectEqual(@as(u32, 2), engine.graphemeCount());
}

test "undo of a joining deletion restores text and resurrects interior weak anchors" {
    var engine = try BufferEngine.initFromText(allocator, "e\nX\n\u{0301}", null);
    defer engine.deinit();
    const interior = try engine.createAnchor(2, .weak);
    try submitOps(&engine, &.{.{ .delete = .{ .start = 1, .end = 4 } }});
    try expectText(&engine, decomposed);
    try std.testing.expectEqual(@as(u32, 1), engine.graphemeCount());
    try std.testing.expectEqual(litura.anchors.AnchorStatus.dead, (try engine.queryAnchor(interior)).status);

    try submitHistory(&engine, .undo);
    try expectText(&engine, "e\nX\n\u{0301}");
    try std.testing.expectEqual(@as(?u32, 2), (try engine.queryAnchor(interior)).position);
}

test "SPEC 1.4: deleting a separator realizes a splice wider than the request" {
    var table = try litura.piece_table.PieceTable.init(allocator);
    defer table.deinit();
    try table.initFromText("e\n\u{0301}");
    const splice = try table.planReplace(1, 2, "");
    try std.testing.expectEqual(@as(u32, 0), splice.start);
    try std.testing.expectEqual(@as(u32, 3), splice.old_end);
    try std.testing.expectEqual(@as(u32, 1), splice.new_end);
}

test "SPEC 1.4: Replace is not Delete followed by Insert" {
    var replaced = try BufferEngine.initFromText(allocator, "e\n\u{0301}", null);
    defer replaced.deinit();
    try submitOps(&replaced, &.{.{ .replace = .{ .start = 1, .end = 2, .text = "a" } }});
    try expectText(&replaced, "ea\u{0301}");
    try std.testing.expectEqual(@as(u32, 2), replaced.graphemeCount());

    // Separate intents and one sequential payload agree: each operation is
    // resegmented before the next resolves its coordinates.
    var split = try BufferEngine.initFromText(allocator, "e\n\u{0301}", null);
    defer split.deinit();
    try submitOps(&split, &.{.{ .delete = .{ .start = 1, .end = 2 } }});
    try submitOps(&split, &.{.{ .insert = .{ .pos = 1, .text = "a" } }});
    try expectText(&split, "e\u{0301}a");

    var payload = try BufferEngine.initFromText(allocator, "e\n\u{0301}", null);
    defer payload.deinit();
    try submitOps(&payload, &.{
        .{ .delete = .{ .start = 1, .end = 2 } },
        .{ .insert = .{ .pos = 1, .text = "a" } },
    });
    try expectText(&payload, "e\u{0301}a");
    try std.testing.expectEqual(@as(u32, 1), payload.revision);
}

test "SPEC 2.5.1 and 7: inverse and affected range come from the realized splice" {
    var engine = try BufferEngine.initFromText(allocator, "e", null);
    defer engine.deinit();
    var result = try engine.submit(.{
        .origin = engine.revision,
        .payload = .{ .buffer_mutation = .{ .ops = &.{.{ .insert = .{ .pos = 1, .text = "\u{0301}" } }} } },
    });
    defer result.deinit(allocator);
    // Non-empty affected range with an unchanged grapheme count.
    try std.testing.expectEqualSlices(litura.types.Range, &.{.{ .start = 0, .end = 1 }}, result.edit_event.affected_ranges);
    const inverse = engine.undo_stack.items[0].inverse_ops[0].replace;
    try std.testing.expectEqual(@as(u32, 0), inverse.start);
    try std.testing.expectEqual(@as(u32, 1), inverse.end);
    try std.testing.expectEqualStrings("e", inverse.text);
}
