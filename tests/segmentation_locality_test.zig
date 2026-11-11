//! Locality assumptions behind realized splices, checked against the Unicode
//! conformance data for the version zg implements, plus long contextual sequences.
const std = @import("std");
const litura = @import("litura");
const BufferEngine = litura.BufferEngine;
const BufferOp = litura.types.BufferOp;
const segmentation = litura.segmentation;
const allocator = std.testing.allocator;
/// `zig build test` samples the conformance cases; `zig build conformance` checks all.
const conformance_stride = @import("test_options").conformance_stride;

const conformance = @embedFile("grapheme_break_test");

/// One GraphemeBreakTest.txt line: UTF-8 text, code point offsets and expected boundaries.
const Case = struct {
    text: std.ArrayListUnmanaged(u8) = .empty,
    code_points: std.ArrayListUnmanaged(usize) = .empty,
    boundaries: std.ArrayListUnmanaged(usize) = .empty,

    fn deinit(self: *Case) void {
        self.text.deinit(allocator);
        self.code_points.deinit(allocator);
        self.boundaries.deinit(allocator);
    }

    fn parse(line: []const u8) !?Case {
        const content = line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len];
        const data = std.mem.trim(u8, content, " \t\r");
        if (data.len == 0) return null;
        var case: Case = .{};
        errdefer case.deinit();
        var tokens = std.mem.tokenizeAny(u8, data, " \t");
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "÷")) {
                try case.boundaries.append(allocator, case.text.items.len);
            } else if (!std.mem.eql(u8, token, "×")) {
                var buf: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(try std.fmt.parseInt(u21, token, 16), &buf);
                try case.code_points.append(allocator, case.text.items.len);
                try case.text.appendSlice(allocator, buf[0..len]);
            }
        }
        try case.code_points.append(allocator, case.text.items.len);
        return case;
    }

    fn isBoundary(self: *const Case, offset: usize) bool {
        return std.mem.indexOfScalar(usize, self.boundaries.items, offset) != null;
    }

    /// Index of the greatest boundary <= offset (weak) or least boundary >= offset (sticky).
    fn project(self: *const Case, offset: usize, sticky: bool) u32 {
        var index: usize = 0;
        while (index < self.boundaries.items.len and self.boundaries.items[index] < offset) index += 1;
        if (self.boundaries.items[index] == offset or sticky) return @intCast(index);
        return @intCast(index - 1);
    }
};

fn boundariesOf(text: []const u8) !std.ArrayListUnmanaged(usize) {
    var bounds: std.ArrayListUnmanaged(usize) = .empty;
    errdefer bounds.deinit(allocator);
    try bounds.append(allocator, 0);
    var iter = segmentation.graphemeIterator(text);
    var offset: usize = 0;
    while (iter.next()) |cluster| {
        offset += cluster.len;
        try bounds.append(allocator, offset);
    }
    return bounds;
}

fn expectEngineClusters(engine: *BufferEngine, text: []const u8, bounds: []const usize) !void {
    const actual = try engine.getText();
    defer allocator.free(actual);
    try std.testing.expectEqualSlices(u8, text, actual);
    try std.testing.expectEqual(@as(u32, @intCast(bounds.len - 1)), engine.graphemeCount());
    var cursor = try engine.graphemeCursor(0);
    for (bounds[0 .. bounds.len - 1], bounds[1..]) |start, end| {
        try std.testing.expectEqualSlices(u8, text[start..end], try cursor.current());
        _ = cursor.advance();
    }
    try std.testing.expect(!cursor.valid);
}

fn submit(engine: *BufferEngine, op: BufferOp) !void {
    var result = try engine.submit(.{
        .origin = engine.revision,
        .payload = .{ .buffer_mutation = .{ .ops = &.{op} } },
    });
    defer result.deinit(allocator);
    try std.testing.expect(result == .edit_event);
}

fn submitUndo(engine: *BufferEngine) !void {
    var result = try engine.submit(.{ .origin = engine.revision, .payload = .{ .undo = .{} } });
    defer result.deinit(allocator);
    try std.testing.expect(result == .edit_event);
}

fn position(engine: *BufferEngine, anchor: litura.anchors.AnchorId) !?u32 {
    return (try engine.queryAnchor(anchor)).position;
}

fn forEachCase(comptime check: fn (*const Case) anyerror!void) !void {
    var lines = std.mem.splitScalar(u8, conformance, '\n');
    var cases: usize = 0;
    while (lines.next()) |line| {
        var case = (try Case.parse(line)) orelse continue;
        defer case.deinit();
        if (cases % conformance_stride == 0) try check(&case);
        cases += 1;
    }
    try std.testing.expect(cases > 500);
}

test "zg agrees with the Unicode grapheme break conformance data" {
    try forEachCase(struct {
        fn check(case: *const Case) !void {
            var bounds = try boundariesOf(case.text.items);
            defer bounds.deinit(allocator);
            try std.testing.expectEqualSlices(usize, case.boundaries.items, bounds.items);
        }
    }.check);
}

test "locality: edits cannot move earlier boundaries and segmentation restarts exactly at a boundary" {
    try forEachCase(struct {
        fn check(case: *const Case) !void {
            const text = case.text.items;
            // Left: boundaries before a split depend only on the text before it and the
            // code point at it.
            for (case.code_points.items[1..]) |split| {
                var prefix = try boundariesOf(text[0..split]);
                defer prefix.deinit(allocator);
                for (prefix.items[0 .. prefix.items.len - 1]) |boundary| {
                    try std.testing.expect(case.isBoundary(boundary));
                }
                for (case.boundaries.items) |boundary| {
                    if (boundary >= split) continue;
                    try std.testing.expect(
                        std.mem.indexOfScalar(usize, prefix.items, boundary) != null,
                    );
                }
            }
            // Right: resegmenting from any boundary reproduces every later boundary.
            for (case.boundaries.items) |start| {
                var suffix = try boundariesOf(text[start..]);
                defer suffix.deinit(allocator);
                var expected: usize = 0;
                for (case.boundaries.items) |whole| {
                    if (whole < start) continue;
                    try std.testing.expectEqual(whole, start + suffix.items[expected]);
                    expected += 1;
                }
                try std.testing.expectEqual(expected, suffix.items.len);
            }
        }
    }.check);
}

test "conformance strings built one code point at a time segment like whole text" {
    try forEachCase(struct {
        fn check(case: *const Case) !void {
            const text = case.text.items;
            const cps = case.code_points.items;
            for ([_]bool{ false, true }) |prepend| {
                var engine = try BufferEngine.init(allocator);
                defer engine.deinit();
                for (0..cps.len - 1) |step| {
                    const index = if (prepend) cps.len - 2 - step else step;
                    const at = if (prepend) 0 else engine.graphemeCount();
                    const code_point = text[cps[index]..cps[index + 1]];
                    try submit(&engine, .{ .insert = .{ .pos = at, .text = code_point } });
                }
                try expectEngineClusters(&engine, text, case.boundaries.items);
                for (0..cps.len - 1) |_| try submitUndo(&engine);
                try std.testing.expectEqual(@as(u32, 0), engine.graphemeCount());
            }
        }
    }.check);
}

test "joining at every code point offset: anchors project weak down and sticky up and never die" {
    try forEachCase(struct {
        fn check(case: *const Case) !void {
            const text = case.text.items;
            const cps = case.code_points.items;
            for (cps[1 .. cps.len - 1]) |split| {
                var left = try boundariesOf(text[0..split]);
                defer left.deinit(allocator);
                const join: u32 = @intCast(left.items.len - 1);

                // Insert the suffix after the prefix; anchors sit at the join.
                {
                    var engine = try BufferEngine.initFromText(allocator, text[0..split], null);
                    defer engine.deinit();
                    const weak = try engine.createAnchor(join, .weak);
                    const sticky = try engine.createAnchor(join, .sticky);
                    try submit(&engine, .{ .insert = .{ .pos = join, .text = text[split..] } });
                    try expectEngineClusters(&engine, text, case.boundaries.items);
                    try std.testing.expectEqual(
                        @as(?u32, case.project(split, false)),
                        try position(&engine, weak),
                    );
                    try std.testing.expectEqual(
                        @as(?u32, case.project(text.len, true)),
                        try position(&engine, sticky),
                    );
                    try submitUndo(&engine);
                    try expectEngineClusters(&engine, text[0..split], left.items);
                }

                // Delete a control separator; anchors at both deletion endpoints survive.
                {
                    const separated = try std.mem.concat(
                        allocator,
                        u8,
                        &.{ text[0..split], "\x07", text[split..] },
                    );
                    defer allocator.free(separated);
                    var engine = try BufferEngine.initFromText(allocator, separated, null);
                    defer engine.deinit();
                    const anchors = [_]litura.anchors.AnchorId{
                        try engine.createAnchor(join, .weak),
                        try engine.createAnchor(join + 1, .weak),
                        try engine.createAnchor(join, .sticky),
                        try engine.createAnchor(join + 1, .sticky),
                    };
                    try submit(&engine, .{ .delete = .{ .start = join, .end = join + 1 } });
                    try expectEngineClusters(&engine, text, case.boundaries.items);
                    for (anchors, [_]bool{ false, false, true, true }) |anchor, sticky| {
                        try std.testing.expectEqual(
                            @as(?u32, case.project(split, sticky)),
                            try position(&engine, anchor),
                        );
                    }
                    try submitUndo(&engine);
                    const restored = try engine.getText();
                    defer allocator.free(restored);
                    try std.testing.expectEqualSlices(u8, separated, restored);
                }
            }
        }
    }.check);
}

/// Builds text one code point at a time, at the end or the front, and checks the oracle.
fn buildByCodePoint(engine: *BufferEngine, text: []const u8, prepend: bool) !void {
    var offsets: std.ArrayListUnmanaged(usize) = .empty;
    defer offsets.deinit(allocator);
    var view = try std.unicode.Utf8View.init(text);
    var iter = view.iterator();
    while (iter.i < text.len) {
        try offsets.append(allocator, iter.i);
        _ = iter.nextCodepointSlice();
    }
    try offsets.append(allocator, text.len);
    const n = offsets.items.len - 1;
    for (0..n) |step| {
        const index = if (prepend) n - 1 - step else step;
        const pos = if (prepend) 0 else engine.graphemeCount();
        try engine.table.insert(pos, text[offsets.items[index]..offsets.items[index + 1]]);
    }
    var bounds = try boundariesOf(text);
    defer bounds.deinit(allocator);
    try expectEngineClusters(engine, text, bounds.items);
}

fn repeat(parts: []const []const u8, times: usize, tail: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (0..times) |_| for (parts) |part| try out.appendSlice(allocator, part);
    try out.appendSlice(allocator, tail);
    return out.toOwnedSlice(allocator);
}

test "long contextual sequences built one code point at a time" {
    const sequences = [_]struct {
        parts: []const []const u8,
        times: usize,
        tail: []const u8,
        clusters: u32,
    }{
        // GB12/13: regional indicator parity across a 401-indicator run.
        .{ .parts = &.{"\u{1F1E6}"}, .times = 401, .tail = "", .clusters = 201 },
        // GB11: one emoji ZWJ sequence of 301 pictographs.
        .{ .parts = &.{ "\u{1F468}", "\u{200D}" }, .times = 60, .tail = "\u{1F469}", .clusters = 1 },
        // GB9c: one Devanagari conjunct of 61 consonants.
        .{ .parts = &.{ "\u{0915}", "\u{094D}" }, .times = 60, .tail = "\u{0937}", .clusters = 1 },
        // GB6-8: one Hangul syllable with long jamo runs.
        .{ .parts = &.{"\u{1100}"}, .times = 120, .tail = "\u{1161}\u{11A8}", .clusters = 1 },
        // GB9: a base followed by 200 combining marks.
        .{ .parts = &.{"\u{0301}"}, .times = 200, .tail = "", .clusters = 1 },
    };
    for (sequences) |sequence| {
        const text = try repeat(sequence.parts, sequence.times, sequence.tail);
        defer allocator.free(text);
        const based = if (sequence.parts[0][0] == 0xCC) try std.mem.concat(
            allocator,
            u8,
            &.{ "e", text },
        ) else try allocator.dupe(u8, text);
        defer allocator.free(based);
        for ([_]bool{ false, true }) |prepend| {
            var engine = try BufferEngine.init(allocator);
            defer engine.deinit();
            try buildByCodePoint(&engine, based, prepend);
            try std.testing.expectEqual(sequence.clusters, engine.graphemeCount());
        }
    }
}

test "worst case: one indicator flips pairing across a long run, and undo restores it" {
    const flags = try repeat(&.{"\u{1F1E6}"}, 400, "");
    defer allocator.free(flags);
    var engine = try BufferEngine.init(allocator);
    defer engine.deinit();
    try buildByCodePoint(&engine, flags, false);
    try std.testing.expectEqual(@as(u32, 200), engine.graphemeCount());

    const splice = try engine.table.planReplace(0, 0, "\u{1F1E6}");
    try std.testing.expectEqual(@as(u32, 200), splice.right_context);
    try std.testing.expectEqual(@as(u32, 201), splice.new_end);

    const weak = try engine.createAnchor(100, .weak);
    const sticky = try engine.createAnchor(100, .sticky);
    const after = try engine.createAnchor(200, .weak);
    try submit(&engine, .{ .insert = .{ .pos = 0, .text = "\u{1F1E6}" } });
    try std.testing.expectEqual(@as(u32, 201), engine.graphemeCount());
    // Old boundary at indicator 200 is now indicator 201, inside pair 100.
    try std.testing.expectEqual(@as(?u32, 100), try position(&engine, weak));
    try std.testing.expectEqual(@as(?u32, 101), try position(&engine, sticky));
    try std.testing.expectEqual(@as(?u32, 201), try position(&engine, after));

    try submitUndo(&engine);
    var bounds = try boundariesOf(flags);
    defer bounds.deinit(allocator);
    try expectEngineClusters(&engine, flags, bounds.items);
}

test "descending payloads are sequential: an earlier insertion can merge into the next target" {
    var engine = try BufferEngine.initFromText(allocator, "ae", null);
    defer engine.deinit();
    // Positions are unchanged by the first operation, but grapheme 1 is now "é".
    const ops = [_]BufferOp{
        .{ .insert = .{ .pos = 2, .text = "\u{0301}" } },
        .{ .delete = .{ .start = 1, .end = 2 } },
    };
    var result = try engine.submit(.{
        .origin = engine.revision,
        .payload = .{ .buffer_mutation = .{ .ops = &ops } },
    });
    defer result.deinit(allocator);
    const text = try engine.getText();
    defer allocator.free(text);
    try std.testing.expectEqualStrings("a", text);
}

test "undo restores text but not projected anchor positions" {
    var engine = try BufferEngine.initFromText(allocator, "e", null);
    defer engine.deinit();
    const weak = try engine.createAnchor(1, .weak);
    try submit(&engine, .{ .insert = .{ .pos = 1, .text = "\u{0301}" } });
    try std.testing.expectEqual(@as(?u32, 0), try position(&engine, weak));
    try submitUndo(&engine);
    // Spatial continuity: the anchor is at the start of the restored splice.
    try std.testing.expectEqual(@as(?u32, 0), try position(&engine, weak));
}
