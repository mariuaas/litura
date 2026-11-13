//! Span resolution accepts both native and caller-supplied engine views.
const std = @import("std");
const litura = @import("litura");
const anchors = litura.anchors;
const queries = litura.queries;
const selection = litura.selection;
const Span = litura.spans.Span;
const SpanPair = litura.spans.SpanPair;
const wordLeftPosition = litura.spans.wordLeftPosition;
const wordRightPosition = litura.spans.wordRightPosition;
const lineSpanAt = litura.spans.lineSpanAt;
const lineTailSpanAt = litura.spans.lineTailSpanAt;
const selectionSpanForCursor = litura.spans.selectionSpanForCursor;
const searchMatchSpanAt = litura.spans.searchMatchSpanAt;
const wordSpanAt = litura.spans.wordSpanAt;
const transposeWordPair = litura.spans.transposeWordPair;

const FakeCursor = struct {
    text: []const u8,
    position: u32,
    valid: bool,

    pub fn current(self: *const @This()) ![]const u8 {
        if (!self.valid or self.position >= self.text.len) return error.OutOfRange;
        return self.text[self.position .. self.position + 1];
    }

    pub fn advance(self: *@This()) bool {
        if (!self.valid) return false;
        if (self.position + 1 >= self.text.len) {
            self.valid = false;
            self.position = @intCast(self.text.len);
            return false;
        }
        self.position += 1;
        return true;
    }

    pub fn retreat(self: *@This()) bool {
        if (!self.valid) {
            if (self.position == self.text.len and self.position > 0) {
                self.position -= 1;
                self.valid = true;
                return true;
            }
            return false;
        }
        if (self.position == 0) {
            self.valid = false;
            return false;
        }
        self.position -= 1;
        return true;
    }
};

const FakeEngine = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    anchor_infos: []const queries.AnchorInfo = &.{},

    pub fn queryAnchor(self: *const @This(), anchor_id: anchors.AnchorId) !queries.AnchorInfo {
        for (self.anchor_infos) |info| {
            if (info.id.value == anchor_id.value) return info;
        }
        return error.KeyError;
    }

    pub fn queryPosition(self: *const @This(), pos: u32) !queries.PositionInfo {
        if (pos > self.text.len) return error.OutOfRange;

        var line: u32 = 0;
        var line_start: u32 = 0;
        var index: u32 = 0;
        while (index < pos) : (index += 1) {
            if (self.text[index] == '\n') {
                line += 1;
                line_start = index + 1;
            }
        }

        var line_end: u32 = line_start;
        while (line_end < self.text.len and self.text[line_end] != '\n') : (line_end += 1) {}
        const line_end_with_newline = if (line_end < self.text.len) line_end + 1 else line_end;

        return .{
            .position = pos,
            .line = line,
            .col = pos - line_start,
            .line_start = line_start,
            .line_end = line_end,
            .line_end_with_newline = line_end_with_newline,
        };
    }

    pub fn graphemeCount(self: *const @This()) u32 {
        return @intCast(self.text.len);
    }

    pub fn graphemeCursor(self: *const @This(), pos: u32) !FakeCursor {
        if (pos > self.text.len) return error.OutOfRange;
        return .{
            .text = self.text,
            .position = pos,
            .valid = pos < self.text.len,
        };
    }

    pub fn getTextRange(self: *const @This(), start: u32, end: u32) ![]u8 {
        if (start > end or end > self.text.len) return error.OutOfRange;
        return try self.allocator.dupe(u8, self.text[start..end]);
    }

    pub fn findNext(self: *const @This(), query: []const u8, start: u32) !?u32 {
        if (start > self.text.len) return error.OutOfRange;
        const match = std.mem.indexOfPos(u8, self.text, start, query) orelse return null;
        return @intCast(match);
    }
};

test "word span resolver follows cursor traversal rules" {
    var engine = FakeEngine{
        .allocator = std.testing.allocator,
        .text = "one\n  two.three",
    };

    try std.testing.expectEqual(@as(?Span, .{ .start = 0, .end = 3 }), try wordSpanAt(&engine, 0));
    try std.testing.expectEqual(@as(?Span, .{ .start = 6, .end = 15 }), try wordSpanAt(&engine, 4));
    try std.testing.expectEqual(
        @as(?Span, .{ .start = 6, .end = 15 }),
        try wordSpanAt(&engine, engine.graphemeCount()),
    );
    try std.testing.expectEqual(@as(u32, 6), try wordLeftPosition(&engine, engine.graphemeCount()));
    try std.testing.expectEqual(@as(u32, 3), try wordRightPosition(&engine, 0));
}

test "line selection and search match helpers mirror editor helpers" {
    const anchor_infos = [_]queries.AnchorInfo{
        .{ .id = .{ .value = 1 }, .position = 5, .stickiness = .sticky, .status = .live },
        .{ .id = .{ .value = 2 }, .position = 1, .stickiness = .weak, .status = .live },
    };
    var engine = FakeEngine{
        .allocator = std.testing.allocator,
        .text = "alpha\nbeta\ngamma alpha",
        .anchor_infos = &anchor_infos,
    };

    try std.testing.expectEqual(
        Span{ .start = 6, .end = 10 },
        try lineSpanAt(&engine, 8, false),
    );
    try std.testing.expectEqual(
        @as(?Span, .{ .start = 8, .end = 10 }),
        try lineTailSpanAt(&engine, 8),
    );
    try std.testing.expectEqual(
        @as(?Span, .{ .start = 1, .end = 5 }),
        try selectionSpanForCursor(
            std.testing.allocator,
            &engine,
            selection.CursorSelection{ .mark = .{ .value = 2 } },
            .{ .value = 1 },
        ),
    );
    try std.testing.expectEqual(
        @as(?Span, .{ .start = 17, .end = 22 }),
        try searchMatchSpanAt(&engine, "alpha", 1),
    );
    try std.testing.expectEqual(@as(?Span, null), try searchMatchSpanAt(&engine, null, 0));
}

test "transpose word pair matches editor point rules" {
    var engine = FakeEngine{
        .allocator = std.testing.allocator,
        .text = "alpha beta gamma",
    };

    try std.testing.expectEqual(
        @as(
            ?SpanPair,
            .{ .first = .{ .start = 0, .end = 5 }, .second = .{ .start = 6, .end = 10 } },
        ),
        try transposeWordPair(&engine, 0),
    );
    try std.testing.expectEqual(
        @as(
            ?SpanPair,
            .{ .first = .{ .start = 6, .end = 10 }, .second = .{ .start = 11, .end = 16 } },
        ),
        try transposeWordPair(&engine, 8),
    );
    try std.testing.expectEqual(
        @as(
            ?SpanPair,
            .{ .first = .{ .start = 6, .end = 10 }, .second = .{ .start = 11, .end = 16 } },
        ),
        try transposeWordPair(&engine, 14),
    );
}

test "resolver helpers accept engine view proxy" {
    const anchor_infos = [_]queries.AnchorInfo{
        .{ .id = .{ .value = 1 }, .position = 10, .stickiness = .sticky, .status = .live },
        .{ .id = .{ .value = 2 }, .position = 6, .stickiness = .weak, .status = .live },
    };
    var inner = FakeEngine{
        .allocator = std.testing.allocator,
        .text = "alpha beta gamma",
        .anchor_infos = &anchor_infos,
    };
    const Proxy = struct {
        inner: *const FakeEngine,

        pub fn queryAnchor(self: *const @This(), anchor_id: anchors.AnchorId) !queries.AnchorInfo {
            return self.inner.queryAnchor(anchor_id);
        }

        pub fn queryPosition(self: *const @This(), pos: u32) !queries.PositionInfo {
            return self.inner.queryPosition(pos);
        }

        pub fn graphemeCount(self: *const @This()) u32 {
            return self.inner.graphemeCount();
        }

        pub fn graphemeCursor(self: *const @This(), pos: u32) !FakeCursor {
            return self.inner.graphemeCursor(pos);
        }

        pub fn getTextRange(self: *const @This(), start: u32, end: u32) ![]u8 {
            return self.inner.getTextRange(start, end);
        }

        pub fn findNext(self: *const @This(), query: []const u8, start: u32) !?u32 {
            return self.inner.findNext(query, start);
        }
    };
    var proxy = Proxy{ .inner = &inner };

    try std.testing.expectEqual(@as(?Span, .{ .start = 0, .end = 5 }), try wordSpanAt(&proxy, 0));
    try std.testing.expectEqual(
        @as(
            ?SpanPair,
            .{ .first = .{ .start = 6, .end = 10 }, .second = .{ .start = 11, .end = 16 } },
        ),
        try transposeWordPair(&proxy, 8),
    );
    try std.testing.expectEqual(
        @as(?Span, .{ .start = 6, .end = 10 }),
        try selectionSpanForCursor(
            std.testing.allocator,
            &proxy,
            selection.CursorSelection{ .mark = .{ .value = 2 } },
            .{ .value = 1 },
        ),
    );
}
