//! Word, line, selection and search spans over caller-supplied engine views.
//! Engine arguments satisfy engine_view.assertEngineView; results use grapheme offsets.
//! Queries may allocate via the engine and propagate its errors.

const std = @import("std");

const anchors = @import("anchors.zig");
const engine_view = @import("engine_view.zig");
const selection = @import("selection.zig");
const segmentation = @import("text_segmentation.zig");

pub const Span = struct {
    start: u32,
    end: u32,
};

pub const SpanPair = struct {
    first: Span,
    second: Span,
};

fn codePointIsWhitespace(cp: u21) bool {
    return switch (cp) {
        0x0009...0x000D,
        0x0020,
        0x0085,
        0x00A0,
        0x1680,
        0x2000...0x200A,
        0x2028,
        0x2029,
        0x202F,
        0x205F,
        0x3000,
        => true,
        else => false,
    };
}

fn clusterIsWhitespace(cluster: []const u8) bool {
    if (cluster.len == 0) return false;

    var index: usize = 0;
    while (index < cluster.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(cluster[index]) catch return false;
        if (index + seq_len > cluster.len) return false;
        const cp = std.unicode.utf8Decode(cluster[index .. index + seq_len]) catch return false;
        if (!codePointIsWhitespace(cp)) return false;
        index += seq_len;
    }

    return true;
}

fn currentIsWhitespace(cursor: anytype) bool {
    const cluster = cursor.current() catch return false;
    return clusterIsWhitespace(cluster);
}

pub fn wordLeftPosition(engine: anytype, position: u32) !u32 {
    engine_view.assertEngineView(@TypeOf(engine));

    var cursor = try engine.graphemeCursor(position);
    _ = cursor.retreat();

    while (cursor.valid and currentIsWhitespace(&cursor)) {
        _ = cursor.retreat();
    }
    while (cursor.valid and !currentIsWhitespace(&cursor)) {
        _ = cursor.retreat();
    }

    if (!cursor.valid) return 0;
    return cursor.position + 1;
}

pub fn wordRightPosition(engine: anytype, position: u32) !u32 {
    engine_view.assertEngineView(@TypeOf(engine));

    var cursor = try engine.graphemeCursor(position);

    while (cursor.valid and currentIsWhitespace(&cursor)) {
        _ = cursor.advance();
    }
    while (cursor.valid and !currentIsWhitespace(&cursor)) {
        _ = cursor.advance();
    }

    return cursor.position;
}

pub fn lineSpanAt(engine: anytype, position: u32, include_newline: bool) !Span {
    engine_view.assertEngineView(@TypeOf(engine));

    const info = try engine.queryPosition(position);
    const end = if (include_newline) info.line_end_with_newline else info.line_end;
    return .{ .start = info.line_start, .end = end };
}

pub fn lineTailSpanAt(engine: anytype, position: u32) !?Span {
    engine_view.assertEngineView(@TypeOf(engine));

    const info = try engine.queryPosition(position);
    const end = if (position == info.line_end) info.line_end_with_newline else info.line_end;
    if (end <= position) return null;
    return .{ .start = position, .end = end };
}

pub fn selectionSpanForCursor(
    allocator: std.mem.Allocator,
    engine: anytype,
    cursor_selection: ?selection.CursorSelection,
    cursor_anchor: anchors.AnchorId,
) !?Span {
    engine_view.assertEngineView(@TypeOf(engine));

    const resolved_selection = cursor_selection orelse return null;
    var info = try selection.queryCursorSelection(allocator, engine, resolved_selection, cursor_anchor);
    defer info.deinit(allocator);

    if (info.start == null or info.end == null or info.start.? == info.end.?) return null;
    return .{ .start = info.start.?, .end = info.end.? };
}

pub fn searchMatchSpanAt(engine: anytype, query: ?[]const u8, position: u32) !?Span {
    engine_view.assertEngineView(@TypeOf(engine));

    const resolved_query = query orelse return null;
    if (resolved_query.len == 0) return null;

    const start = (try engine.findNext(resolved_query, position)) orelse return null;
    return .{
        .start = start,
        .end = start + @as(u32, @intCast(segmentation.graphemeCount(resolved_query))),
    };
}

pub fn wordSpanAt(engine: anytype, position: u32) !?Span {
    engine_view.assertEngineView(@TypeOf(engine));

    const clamped_position = @min(position, engine.graphemeCount());
    if (try wordSpanContaining(engine, clamped_position)) |current| {
        return current;
    }

    if (try isWordBefore(engine, clamped_position)) {
        return try wordSpanContaining(engine, clamped_position - 1);
    }

    return try wordSpanStartingAtOrAfter(engine, clamped_position);
}

pub fn transposeWordPair(engine: anytype, position: u32) !?SpanPair {
    engine_view.assertEngineView(@TypeOf(engine));

    if (try wordSpanAt(engine, position)) |current| {
        const previous = try wordSpanEndingBefore(engine, current.start);
        const following = try wordSpanStartingAtOrAfter(engine, current.end);

        if (position == current.start) {
            if (previous) |pair_prev| return .{ .first = pair_prev, .second = current };
            if (following) |pair_following| return .{ .first = current, .second = pair_following };
            return null;
        }

        if (following) |pair_following| return .{ .first = current, .second = pair_following };
        if (previous) |pair_prev| return .{ .first = pair_prev, .second = current };
        return null;
    }

    const previous = try wordSpanEndingBefore(engine, position);
    const following = try wordSpanStartingAtOrAfter(engine, position);
    if (previous != null and following != null) {
        return .{ .first = previous.?, .second = following.? };
    }

    if (following) |first| {
        if (try wordSpanStartingAtOrAfter(engine, first.end)) |second| {
            return .{ .first = first, .second = second };
        }
        return null;
    }

    if (previous) |second| {
        if (try wordSpanEndingBefore(engine, second.start)) |first| {
            return .{ .first = first, .second = second };
        }
    }
    return null;
}

fn wordSpanContaining(engine: anytype, position: u32) !?Span {
    if (position >= engine.graphemeCount()) return null;

    var cursor = try engine.graphemeCursor(position);
    if (!cursor.valid or currentIsWhitespace(&cursor)) return null;

    var left = cursor;
    while (left.retreat() and !currentIsWhitespace(&left)) {}
    const start: u32 = if (!left.valid) 0 else left.position + 1;

    var right = try engine.graphemeCursor(position);
    while (right.advance() and !currentIsWhitespace(&right)) {}
    return .{ .start = start, .end = right.position };
}

fn wordSpanStartingAtOrAfter(engine: anytype, position: u32) !?Span {
    var cursor = try engine.graphemeCursor(@min(position, engine.graphemeCount()));
    while (cursor.valid and currentIsWhitespace(&cursor)) {
        _ = cursor.advance();
    }
    if (!cursor.valid) return null;

    const start = cursor.position;
    while (cursor.advance() and !currentIsWhitespace(&cursor)) {}
    return .{ .start = start, .end = cursor.position };
}

fn wordSpanEndingBefore(engine: anytype, position: u32) !?Span {
    var cursor = try engine.graphemeCursor(@min(position, engine.graphemeCount()));
    if (!cursor.retreat()) return null;

    while (cursor.valid and currentIsWhitespace(&cursor)) {
        if (!cursor.retreat()) return null;
    }

    const end = cursor.position + 1;
    while (cursor.retreat() and !currentIsWhitespace(&cursor)) {}
    const start: u32 = if (!cursor.valid) 0 else cursor.position + 1;
    return .{ .start = start, .end = end };
}

fn isWordBefore(engine: anytype, position: u32) !bool {
    if (position == 0) return false;

    var cursor = try engine.graphemeCursor(position);
    if (cursor.valid and !currentIsWhitespace(&cursor)) return false;

    var previous = try engine.graphemeCursor(position);
    return previous.retreat() and previous.valid and !currentIsWhitespace(&previous);
}
