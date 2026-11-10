//! Piece-table edits, navigation and search through the public package.
const std = @import("std");
const litura = @import("litura");
const piece_table = litura.piece_table;
const PieceTable = piece_table.PieceTable;
const Summary = litura.summaries.Summary;
const min_leaf_pieces = piece_table.nodes.min_leaf_pieces;
const LineCol = piece_table.LineCol;

fn expectTableText(table: *const PieceTable, expected: []const u8) !void {
    const text = try table.getText();
    defer table.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

fn expectSummaryMatchesText(table: *const PieceTable, expected: []const u8) !void {
    const expected_summary = Summary.fromText(&table.seg, expected);
    try std.testing.expectEqual(expected_summary, table.root.summary());
    try std.testing.expectEqual(expected_summary.graphemes, table.graphemeCount());
    try std.testing.expectEqual(expected_summary.bytes, table.byteCount());
    try std.testing.expectEqual(expected_summary.newlines + 1, table.lineCount());
    try std.testing.expectEqual(expected_summary.words.runs, table.wordCount());
}

test "graphemeAt is correct after multibyte grapheme in same piece" {
    // Repro for cluster_byte/grapheme-index confusion: piece "a👋🏽b" has the
    // byte offset to "b" as 9 (4+5 bytes), but graphemeAt must not pass that
    // byte count to splitAtGrapheme (which expects a grapheme index).
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("a\u{1F44B}\u{1F3FD}b");
    try std.testing.expectEqual(@as(u32, 3), table.graphemeCount());
    try std.testing.expectEqualStrings("a", try table.graphemeAt(0));
    try std.testing.expectEqualStrings("\u{1F44B}\u{1F3FD}", try table.graphemeAt(1));
    try std.testing.expectEqualStrings("b", try table.graphemeAt(2));
}

test "piece table initializes from text" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("hello world");

    try expectTableText(&table, "hello world");
    try std.testing.expectEqual(@as(u32, 11), table.graphemeCount());
    try std.testing.expectEqual(@as(u32, 11), table.byteCount());
    try std.testing.expectEqual(@as(u32, 2), table.wordCount());
    try std.testing.expectEqual(@as(u32, 1), table.lineCount());
}

test "piece table inserts at middle start and end" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("helo");
    try table.insert(3, "l");
    try table.insert(0, "well ");
    try table.insert(table.graphemeCount(), " world");

    try expectTableText(&table, "well hello world");
    try expectSummaryMatchesText(&table, "well hello world");
}

test "piece table insert splits overflowing root leaf" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("");
    for ("abcdefg") |ch| {
        try table.insert(table.graphemeCount(), &[_]u8{ch});
    }

    try expectTableText(&table, "abcdefg");
    try expectSummaryMatchesText(&table, "abcdefg");

    switch (table.root) {
        .internal => |root| {
            try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
            try std.testing.expect(root.children.items[0].summary().graphemes >= min_leaf_pieces);
            try std.testing.expect(root.children.items[1].summary().graphemes >= min_leaf_pieces);
        },
        .leaf => return error.TestUnexpectedResult,
    }
}

test "piece table delete normalizes root after pruning subtree" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("");
    for ("abcdefg") |ch| {
        try table.insert(table.graphemeCount(), &[_]u8{ch});
    }

    try table.delete(1, 7);
    try expectTableText(&table, "a");
    try expectSummaryMatchesText(&table, "a");

    switch (table.root) {
        .leaf => |root| try std.testing.expectEqual(@as(usize, 1), root.pieces.items.len),
        .internal => return error.TestUnexpectedResult,
    }
}

test "piece table merges word summaries across adjacent pieces" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("hel");
    try table.insert(3, "lo");

    try expectTableText(&table, "hello");
    try std.testing.expectEqual(@as(u32, 1), table.wordCount());
}

test "piece table handles unicode grapheme inserts" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("ab");
    try table.insert(1, "\u{1F44B}\u{1F3FD}");
    try table.insert(table.graphemeCount(), "e\u{0301}");

    try expectTableText(&table, "a\u{1F44B}\u{1F3FD}be\u{0301}");
    try std.testing.expectEqual(@as(u32, 4), table.graphemeCount());
    try std.testing.expectEqualStrings("\u{1F44B}\u{1F3FD}", try table.graphemeAt(1));
    try std.testing.expectEqualStrings("e\u{0301}", try table.graphemeAt(3));
    try expectSummaryMatchesText(&table, "a\u{1F44B}\u{1F3FD}be\u{0301}");
}

test "piece table deletes ranges across pieces" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("abcdef");
    try table.insert(3, "XY");
    try table.delete(2, 6);

    try expectTableText(&table, "abef");
    try expectSummaryMatchesText(&table, "abef");
}

test "piece table getTextRange slices by grapheme offsets" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("a\u{1F44B}\u{1F3FD}bc");
    try table.insert(2, "Z");

    const text = try table.getTextRange(1, 4);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("\u{1F44B}\u{1F3FD}Zb", text);
}

test "piece table validates positions and ranges" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("abc");

    try std.testing.expectError(error.OutOfRange, table.insert(4, "!"));
    try std.testing.expectError(error.InvalidRange, table.delete(2, 1));
    try std.testing.expectError(error.OutOfRange, table.delete(0, 4));
    try std.testing.expectError(error.OutOfRange, table.graphemeAt(3));
}

test "empty table has sane initial state" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("");
    try std.testing.expectEqual(@as(u32, 0), table.graphemeCount());
    try std.testing.expectEqual(@as(u32, 0), table.byteCount());
    try std.testing.expectEqual(@as(u32, 1), table.lineCount()); // always at least 1 line
    try std.testing.expectEqual(@as(u32, 0), table.wordCount());
    try expectTableText(&table, "");
}

test "insert into empty table" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("");
    try table.insert(0, "hi");
    try expectTableText(&table, "hi");
    try expectSummaryMatchesText(&table, "hi");
}

test "delete entire content" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("hello");
    try table.delete(0, 5);
    try expectTableText(&table, "");
    try std.testing.expectEqual(@as(u32, 0), table.graphemeCount());
    try std.testing.expectEqual(@as(u32, 1), table.lineCount());
}

test "delete at piece boundaries — exact left edge" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    // original: "abc", insert splits into two pieces around pos 1
    try table.initFromText("abc");
    try table.insert(1, "X");
    // pieces: ["a", "X", "bc"] conceptually
    try table.delete(0, 1); // delete exactly the first grapheme of first piece
    try expectTableText(&table, "Xbc");
    try expectSummaryMatchesText(&table, "Xbc");
}

test "delete at piece boundaries — exact right edge" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("abc");
    try table.insert(1, "X");
    try table.delete(1, 2); // delete the inserted "X"
    try expectTableText(&table, "abc");
    try expectSummaryMatchesText(&table, "abc");
}

test "delete spanning all pieces" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("abc");
    try table.insert(1, "XY");
    try table.insert(4, "Z");
    // text is "aXYbcZ"
    try table.delete(0, 6);
    try expectTableText(&table, "");
    try std.testing.expectEqual(@as(u32, 0), table.graphemeCount());
}

test "graphemeAt across piece boundary" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("abc");
    try table.insert(1, "X");
    // pieces: "a" | "X" | "bc"
    try std.testing.expectEqualStrings("a", try table.graphemeAt(0));
    try std.testing.expectEqualStrings("X", try table.graphemeAt(1));
    try std.testing.expectEqualStrings("b", try table.graphemeAt(2));
    try std.testing.expectEqualStrings("c", try table.graphemeAt(3));
}

test "lineCount tracks newlines across pieces" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("line one\n");
    try std.testing.expectEqual(@as(u32, 2), table.lineCount());

    try table.insert(table.graphemeCount(), "line two\n");
    try std.testing.expectEqual(@as(u32, 3), table.lineCount());

    try table.delete(8, 9); // remove first newline
    try std.testing.expectEqual(@as(u32, 2), table.lineCount());
    try expectSummaryMatchesText(&table, "line oneline two\n");
}

test "wordCount across piece boundaries" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    // "foo" and "bar" are separate inserts — the bridge rule must produce 1 run
    try table.initFromText("foo");
    try table.insert(3, "bar");
    try std.testing.expectEqual(@as(u32, 1), table.wordCount());

    // inserting a space between them splits into 2 runs
    try table.insert(3, " ");
    try std.testing.expectEqual(@as(u32, 2), table.wordCount());
}

test "summary invariant: matches recomputed summary after each mutation" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("hello world\n");
    try expectSummaryMatchesText(&table, "hello world\n");

    try table.insert(5, ",");
    try expectSummaryMatchesText(&table, "hello, world\n");

    try table.delete(0, 6);
    try expectSummaryMatchesText(&table, " world\n");

    try table.insert(0, "bye");
    try expectSummaryMatchesText(&table, "bye world\n");

    try table.delete(3, 4); // remove the space between "bye" and "world"
    try expectSummaryMatchesText(&table, "byeworld\n");
}

test "summary invariant: bracket depth survives piece edits" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("function f() return ({[1] = true}) end");
    try expectSummaryMatchesText(&table, "function f() return ({[1] = true}) end");
    try std.testing.expectEqual(@as(i32, 0), table.root.summary().brackets.net);
    try std.testing.expectEqual(@as(i32, 0), table.root.summary().brackets.p_min);

    try table.insert(0, ")");
    try expectSummaryMatchesText(&table, ")function f() return ({[1] = true}) end");
    try std.testing.expectEqual(@as(i32, -1), table.root.summary().brackets.p_min);

    try table.delete(0, 1);
    try table.insert(table.graphemeCount(), "(");
    try expectSummaryMatchesText(&table, "function f() return ({[1] = true}) end(");
    try std.testing.expectEqual(@as(i32, 1), table.root.summary().brackets.net);
    try std.testing.expectEqual(@as(i32, 0), table.root.summary().brackets.p_min);
}

test "matchBracketAt uses typed bracket summaries" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("a([{}]) b ()");

    const outer = (try table.matchBracketAt(1)).?;
    try std.testing.expectEqual(@as(u32, 1), outer.start);
    try std.testing.expectEqual(@as(u32, 6), outer.end);

    const square = (try table.matchBracketAt(2)).?;
    try std.testing.expectEqual(@as(u32, 2), square.start);
    try std.testing.expectEqual(@as(u32, 5), square.end);

    const curly = (try table.matchBracketAt(3)).?;
    try std.testing.expectEqual(@as(u32, 3), curly.start);
    try std.testing.expectEqual(@as(u32, 4), curly.end);

    const close = (try table.matchBracketAt(6)).?;
    try std.testing.expectEqual(@as(u32, 1), close.start);
    try std.testing.expectEqual(@as(u32, 6), close.end);

    const later = (try table.matchBracketAt(10)).?;
    try std.testing.expectEqual(@as(u32, 10), later.start);
    try std.testing.expectEqual(@as(u32, 11), later.end);
}

test "matchBracketAt matches crossed text by bracket class" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("([)]");
    const paren = (try table.matchBracketAt(0)).?;
    try std.testing.expectEqual(@as(u32, 0), paren.start);
    try std.testing.expectEqual(@as(u32, 2), paren.end);
    const square = (try table.matchBracketAt(1)).?;
    try std.testing.expectEqual(@as(u32, 1), square.start);
    try std.testing.expectEqual(@as(u32, 3), square.end);
}

test "getTextRange across piece boundary with multibyte" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    // graphemes: H(0) e\u{301}(1) l(2) l(3) o(4)
    try table.initFromText("He\u{0301}llo");
    try table.insert(2, "\u{1F44B}"); // insert wave emoji at grapheme 2

    // graphemes: H(0) é(1) 👋(2) l(3) l(4) o(5)
    const text = try table.getTextRange(1, 4);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("e\u{0301}\u{1F44B}l", text);
}

test "line navigation basic multiline document" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("alpha\nbravo\ncharlie");

    try std.testing.expectEqual(@as(u32, 3), table.lineCount());
    try std.testing.expectEqual(@as(u32, 0), try table.lineStart(0));
    try std.testing.expectEqual(@as(u32, 6), try table.lineStart(1));
    try std.testing.expectEqual(@as(u32, 12), try table.lineStart(2));
    try std.testing.expectEqual(table.graphemeCount(), try table.lineStart(3));

    try std.testing.expectEqual(@as(u32, 5), try table.lineEnd(0, false));
    try std.testing.expectEqual(@as(u32, 6), try table.lineEnd(0, true));
    try std.testing.expectEqual(@as(u32, 11), try table.lineEnd(1, false));
    try std.testing.expectEqual(@as(u32, 12), try table.lineEnd(1, true));
    try std.testing.expectEqual(table.graphemeCount(), try table.lineEnd(2, false));
}

test "line navigation tracks edits across pieces" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("one\nthree");
    try table.insert(4, "two\n");
    try table.insert(table.graphemeCount(), "\nfour");

    try std.testing.expectEqual(@as(u32, 4), table.lineCount());
    try std.testing.expectEqual(@as(u32, 4), try table.lineStart(1));
    try std.testing.expectEqual(@as(u32, 8), try table.lineStart(2));
    try std.testing.expectEqual(@as(u32, 14), try table.lineStart(3));

    try table.delete(3, 4);
    try std.testing.expectEqual(@as(u32, 3), table.lineCount());
    try std.testing.expectEqual(@as(u32, 7), try table.lineStart(1));
    try expectSummaryMatchesText(&table, "onetwo\nthree\nfour");
}

test "positionToLineCol and lineColToPosition round trip" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("alpha\nbravo\n");

    try std.testing.expectEqual(LineCol{ .line = 0, .col = 5 }, try table.positionToLineCol(5));
    try std.testing.expectEqual(LineCol{ .line = 1, .col = 0 }, try table.positionToLineCol(6));
    try std.testing.expectEqual(LineCol{ .line = 1, .col = 2 }, try table.positionToLineCol(8));
    try std.testing.expectEqual(LineCol{ .line = 2, .col = 0 }, try table.positionToLineCol(table.graphemeCount()));

    try std.testing.expectEqual(@as(u32, 8), try table.lineColToPosition(1, 2));
    try std.testing.expectEqual(@as(u32, 11), try table.lineColToPosition(1, 99));
    try std.testing.expectEqual(table.graphemeCount(), try table.lineColToPosition(2, 99));
}

test "newlineCountBefore validates positions and counts prefixes" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("a\nb\nc");
    try table.insert(2, "x\n");

    try std.testing.expectEqual(@as(u32, 0), try table.newlineCountBefore(0));
    try std.testing.expectEqual(@as(u32, 1), try table.newlineCountBefore(2));
    try std.testing.expectEqual(@as(u32, 2), try table.newlineCountBefore(4));
    try std.testing.expectEqual(@as(u32, 3), try table.newlineCountBefore(table.graphemeCount()));
    try std.testing.expectError(error.OutOfRange, table.newlineCountBefore(table.graphemeCount() + 1));
}

test "line navigation validates line bounds" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("abc");

    try std.testing.expectEqual(@as(u32, 0), try table.lineStart(0));
    try std.testing.expectEqual(table.graphemeCount(), try table.lineStart(1));
    try std.testing.expectError(error.OutOfRange, table.lineStart(2));
    try std.testing.expectError(error.OutOfRange, table.lineEnd(1, false));
    try std.testing.expectError(error.OutOfRange, table.lineColToPosition(1, 0));
}

test "grapheme cursor walks forward without materializing text" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("");
    try table.insert(table.graphemeCount(), "a\u{1F44B}\u{1F3FD}");
    try table.insert(table.graphemeCount(), " b\n");
    try table.insert(table.graphemeCount(), "cd");
    try table.insert(table.graphemeCount(), " ef");

    var cursor = try table.graphemeCursor(0);
    const expected = [_][]const u8{ "a", "\u{1F44B}\u{1F3FD}", " ", "b", "\n", "c", "d", " ", "e", "f" };
    var index: usize = 0;
    while (cursor.valid) {
        try std.testing.expect(index < expected.len);
        try std.testing.expectEqualStrings(expected[index], try cursor.current());
        _ = cursor.advance();
        index += 1;
    }
    try std.testing.expectEqual(expected.len, index);
    try std.testing.expectEqual(table.graphemeCount(), cursor.position);
}

test "grapheme cursor walks backward from end" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("ab");
    try table.insert(1, "\u{1F44B}\u{1F3FD}");
    try table.insert(table.graphemeCount(), "c");

    var cursor = try table.graphemeCursor(table.graphemeCount());
    const expected = [_][]const u8{ "c", "b", "\u{1F44B}\u{1F3FD}", "a" };
    for (expected) |cluster| {
        try std.testing.expect(cursor.retreat());
        try std.testing.expect(cursor.valid);
        try std.testing.expectEqualStrings(cluster, try cursor.current());
    }
    try std.testing.expect(!cursor.retreat());
    try std.testing.expect(!cursor.valid);
    try std.testing.expectEqual(@as(u32, 0), cursor.position);
}

test "grapheme cursor can start inside split document" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("alpha");
    try table.insert(5, " beta");
    try table.insert(0, "->");

    var cursor = try table.graphemeCursor(3);
    try std.testing.expectEqualStrings("l", try cursor.current());
    try std.testing.expect(cursor.advance());
    try std.testing.expectEqualStrings("p", try cursor.current());
    try std.testing.expect(cursor.retreat());
    try std.testing.expectEqualStrings("l", try cursor.current());
}

test "findNext finds matches across piece boundaries" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("alpha");
    try table.insert(5, " beta");
    try table.insert(10, " gamma");

    try std.testing.expectEqual(@as(?u32, 4), try table.findNext("a b", 0));
    try std.testing.expectEqual(@as(?u32, 10), try table.findNext(" gamma", 5));
    try std.testing.expectEqual(@as(?u32, null), try table.findNext("delta", 0));
    try std.testing.expectEqual(@as(?u32, 3), try table.findNext("", 3));
}

test "findNext handles overlapping grapheme patterns" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("");
    try table.insert(0, "aba");
    try table.insert(3, "ba");

    try std.testing.expectEqual(@as(?u32, 0), try table.findNext("aba", 0));
    try std.testing.expectEqual(@as(?u32, 2), try table.findNext("aba", 1));
}

test "findPrevious returns last match before start" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("one two one two");
    try table.insert(7, " middle");

    try std.testing.expectEqual(@as(?u32, 19), try table.findPrevious("two", null));
    try std.testing.expectEqual(@as(?u32, 4), try table.findPrevious("two", 15));
    try std.testing.expectEqual(@as(?u32, null), try table.findPrevious("two", 4));
    try std.testing.expectEqual(@as(?u32, 6), try table.findPrevious("", 6));
}

test "findPrevious handles overlapping grapheme patterns" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("ababa");

    try std.testing.expectEqual(@as(?u32, 2), try table.findPrevious("aba", null));
    try std.testing.expectEqual(@as(?u32, 0), try table.findPrevious("aba", 2));
}

test "find search is byte-exact over unicode grapheme clusters" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("caf\u{00E9} cafe\u{0301}");
    try table.insert(5, "\u{1F44B}\u{1F3FD}");

    try std.testing.expectEqual(@as(?u32, 3), try table.findNext("\u{00E9}", 0));
    try std.testing.expectEqual(@as(?u32, 9), try table.findNext("e\u{0301}", 0));
    try std.testing.expectEqual(@as(?u32, 5), try table.findNext("\u{1F44B}\u{1F3FD}", 0));
    try std.testing.expectEqual(@as(?u32, null), try table.findNext("\u{00E9}\u{1F44B}\u{1F3FD}", 4));
}

test "reinitialize reuses table cleanly" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    try table.initFromText("first");
    try table.insert(5, " content");
    try table.initFromText("second");

    try expectTableText(&table, "second");
    try expectSummaryMatchesText(&table, "second");
    try std.testing.expectEqual(@as(u32, 6), table.graphemeCount());
}

test "cursor advances across multi-level internal tree" {
    // 16 single-char inserts force a 2-level tree: root Internal -> 2 Internals -> Leaves.
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    const text = "abcdefghijklmnop";
    try table.initFromText("");
    for (text) |ch| try table.insert(table.graphemeCount(), &[_]u8{ch});

    // Verify 2-level tree shape.
    switch (table.root) {
        .leaf => return error.TestUnexpectedResult,
        .internal => |root| {
            for (root.children.items) |child| {
                switch (child) {
                    .leaf => return error.TestUnexpectedResult,
                    .internal => {},
                }
            }
        },
    }

    // Forward traversal must visit every grapheme in order.
    var cursor = try table.graphemeCursor(0);
    for (text, 0..) |ch, i| {
        try std.testing.expect(cursor.valid);
        try std.testing.expectEqual(@as(u32, @intCast(i)), cursor.position);
        const cluster = try cursor.current();
        try std.testing.expectEqual(@as(u8, ch), cluster[0]);
        _ = cursor.advance();
    }
    try std.testing.expect(!cursor.valid);
}

test "cursor retreats across multi-level internal tree" {
    const allocator = std.testing.allocator;
    var table = try PieceTable.init(allocator);
    defer table.deinit();

    const text = "abcdefghijklmnop";
    try table.initFromText("");
    for (text) |ch| try table.insert(table.graphemeCount(), &[_]u8{ch});

    // Backward traversal from end must visit every grapheme in reverse.
    var cursor = try table.graphemeCursor(table.graphemeCount());
    var i: usize = text.len;
    while (i > 0) {
        i -= 1;
        const moved = cursor.retreat();
        try std.testing.expect(moved);
        try std.testing.expectEqual(@as(u32, @intCast(i)), cursor.position);
        const cluster = try cursor.current();
        try std.testing.expectEqual(@as(u8, text[i]), cluster[0]);
    }
    try std.testing.expect(!cursor.retreat());
}
