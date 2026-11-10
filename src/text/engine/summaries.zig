//! Composable grapheme, word-run, newline and bracket summaries.

const std = @import("std");
const Properties = @import("zg_properties");
const Words = @import("zg_words");
const segmentation = @import("text_segmentation.zig");
const Segmenter = segmentation.Segmenter;

/// Summary of maximal non-whitespace runs within a span.
pub const WordRunSummary = struct {
    is_empty: bool,
    runs: u32,
    starts_word: bool,
    ends_word: bool,

    pub const empty: WordRunSummary = .{
        .is_empty = true,
        .runs = 0,
        .starts_word = false,
        .ends_word = false,
    };

    pub fn merge(left: WordRunSummary, right: WordRunSummary) WordRunSummary {
        if (left.is_empty) return right;
        if (right.is_empty) return left;
        const bridge: u32 = if (left.ends_word and right.starts_word) 1 else 0;
        return .{
            .is_empty = false,
            .runs = left.runs + right.runs - bridge,
            .starts_word = left.starts_word,
            .ends_word = right.ends_word,
        };
    }
};

pub const BracketDepth = struct {
    net: i32,
    p_min: i32,
    p_max: i32,

    pub const empty: BracketDepth = .{
        .net = 0,
        .p_min = 0,
        .p_max = 0,
    };

    pub fn merge(left: BracketDepth, right: BracketDepth) BracketDepth {
        return .{
            .net = left.net + right.net,
            .p_min = @min(left.p_min, left.net + right.p_min),
            .p_max = @max(left.p_max, left.net + right.p_max),
        };
    }
};

/// Bracket-depth summaries over generic and typed (), [], and {} streams.
/// `net`/`p_min` mirror the spec's generic bracket summary for compatibility.
pub const BracketSummary = struct {
    net: i32,
    p_min: i32,
    p_max: i32,
    paren: BracketDepth,
    square: BracketDepth,
    curly: BracketDepth,

    pub const empty: BracketSummary = .{
        .net = 0,
        .p_min = 0,
        .p_max = 0,
        .paren = BracketDepth.empty,
        .square = BracketDepth.empty,
        .curly = BracketDepth.empty,
    };

    pub fn merge(left: BracketSummary, right: BracketSummary) BracketSummary {
        const generic_left: BracketDepth = .{ .net = left.net, .p_min = left.p_min, .p_max = left.p_max };
        const generic_right: BracketDepth = .{ .net = right.net, .p_min = right.p_min, .p_max = right.p_max };
        const generic = BracketDepth.merge(generic_left, generic_right);
        return .{
            .net = generic.net,
            .p_min = generic.p_min,
            .p_max = generic.p_max,
            .paren = BracketDepth.merge(left.paren, right.paren),
            .square = BracketDepth.merge(left.square, right.square),
            .curly = BracketDepth.merge(left.curly, right.curly),
        };
    }
};

/// Fixed summary carried by pieces and tree nodes.
/// `graphemes` is the editor coordinate measure; `bytes` is UTF-8 byte length.
pub const Summary = struct {
    graphemes: u32,
    bytes: u32,
    newlines: u32,
    words: WordRunSummary,
    brackets: BracketSummary,

    pub const empty: Summary = .{
        .graphemes = 0,
        .bytes = 0,
        .newlines = 0,
        .words = WordRunSummary.empty,
        .brackets = BracketSummary.empty,
    };

    /// Compute a summary from a UTF-8 string.
    /// Uses zg Words for Unicode-correct word boundary detection and
    /// zg Properties for whitespace classification.
    pub fn fromText(seg: *const Segmenter, text: []const u8) Summary {
        if (asciiSummary(text)) |summary| return summary;

        var grapheme_count: u32 = 0;
        var newline_count: u32 = 0;
        var iter = seg.iterator(text);
        while (iter.next()) |cluster| {
            grapheme_count += 1;
            if (cluster.len == 1 and cluster[0] == '\n') newline_count += 1;
        }

        return .{
            .graphemes = grapheme_count,
            .bytes = @intCast(text.len),
            .newlines = newline_count,
            .words = wordRunSummary(text),
            .brackets = bracketSummary(seg, text),
        };
    }

    pub fn merge(left: Summary, right: Summary) Summary {
        return .{
            .graphemes = left.graphemes + right.graphemes,
            .bytes = left.bytes + right.bytes,
            .newlines = left.newlines + right.newlines,
            .words = WordRunSummary.merge(left.words, right.words),
            .brackets = BracketSummary.merge(left.brackets, right.brackets),
        };
    }
};

fn asciiWhitespace(ch: u8) bool {
    return switch (ch) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => true,
        else => false,
    };
}

fn applyBracketDepth(depth: *BracketDepth, delta: i32) void {
    depth.net += delta;
    depth.p_min = @min(depth.p_min, depth.net);
    depth.p_max = @max(depth.p_max, depth.net);
}

fn asciiSummary(text: []const u8) ?Summary {
    var grapheme_count: u32 = 0;
    var newline_count: u32 = 0;
    var word_runs: u32 = 0;
    var in_word = false;
    var starts_word = false;
    var ends_word = false;
    var first = true;

    var generic = BracketDepth.empty;
    var paren = BracketDepth.empty;
    var square = BracketDepth.empty;
    var curly = BracketDepth.empty;

    var index: usize = 0;
    while (index < text.len) {
        const ch = text[index];
        if (ch >= 0x80) return null;
        grapheme_count += 1;

        const crlf = ch == '\r' and index + 1 < text.len and text[index + 1] == '\n';
        if (ch == '\n') newline_count += 1;

        const is_word = !asciiWhitespace(ch);
        if (first) {
            starts_word = is_word;
            first = false;
        }
        if (is_word and !in_word) word_runs += 1;
        in_word = is_word;
        ends_word = is_word;

        switch (ch) {
            '(' => {
                applyBracketDepth(&generic, 1);
                applyBracketDepth(&paren, 1);
            },
            ')' => {
                applyBracketDepth(&generic, -1);
                applyBracketDepth(&paren, -1);
            },
            '[' => {
                applyBracketDepth(&generic, 1);
                applyBracketDepth(&square, 1);
            },
            ']' => {
                applyBracketDepth(&generic, -1);
                applyBracketDepth(&square, -1);
            },
            '{' => {
                applyBracketDepth(&generic, 1);
                applyBracketDepth(&curly, 1);
            },
            '}' => {
                applyBracketDepth(&generic, -1);
                applyBracketDepth(&curly, -1);
            },
            else => {},
        }

        index += if (crlf) 2 else 1;
    }

    return .{
        .graphemes = grapheme_count,
        .bytes = @intCast(text.len),
        .newlines = newline_count,
        .words = if (first) WordRunSummary.empty else .{
            .is_empty = false,
            .runs = word_runs,
            .starts_word = starts_word,
            .ends_word = ends_word,
        },
        .brackets = .{
            .net = generic.net,
            .p_min = generic.p_min,
            .p_max = generic.p_max,
            .paren = paren,
            .square = square,
            .curly = curly,
        },
    };
}

/// Classify a word segment using zg Properties.
fn segmentIsWhitespace(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    const seq_len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return false;
    if (seq_len > bytes.len) return false;
    const cp = std.unicode.utf8Decode(bytes[0..seq_len]) catch return false;
    return Properties.isWhitespace(cp);
}

fn depthFromDelta(delta: i32) BracketDepth {
    return .{
        .net = delta,
        .p_min = @min(@as(i32, 0), delta),
        .p_max = @max(@as(i32, 0), delta),
    };
}

fn bracketSummaryForCluster(cluster: []const u8) BracketSummary {
    if (cluster.len != 1) return BracketSummary.empty;
    var result = BracketSummary.empty;
    const generic_delta: i32 = switch (cluster[0]) {
        '(', '[', '{' => 1,
        ')', ']', '}' => -1,
        else => 0,
    };
    if (generic_delta != 0) {
        const generic = depthFromDelta(generic_delta);
        result.net = generic.net;
        result.p_min = generic.p_min;
        result.p_max = generic.p_max;
    }
    switch (cluster[0]) {
        '(' => result.paren = depthFromDelta(1),
        ')' => result.paren = depthFromDelta(-1),
        '[' => result.square = depthFromDelta(1),
        ']' => result.square = depthFromDelta(-1),
        '{' => result.curly = depthFromDelta(1),
        '}' => result.curly = depthFromDelta(-1),
        else => {},
    }
    return result;
}

fn bracketSummary(seg: *const Segmenter, text: []const u8) BracketSummary {
    var acc = BracketSummary.empty;
    var iter = seg.iterator(text);
    while (iter.next()) |cluster| {
        acc = BracketSummary.merge(acc, bracketSummaryForCluster(cluster));
    }
    return acc;
}

/// Compute word run summary using zg Words for Unicode-correct boundaries.
fn wordRunSummary(text: []const u8) WordRunSummary {
    var iter = Words.iterator(text);
    var runs: u32 = 0;
    var in_word = false;
    var starts_word = false;
    var ends_word = false;
    var first = true;

    while (iter.next()) |segment| {
        const is_word = !segmentIsWhitespace(segment.bytes(text));
        if (first) {
            starts_word = is_word;
            first = false;
        }
        if (is_word and !in_word) runs += 1;
        in_word = is_word;
        ends_word = is_word;
    }

    if (first) return WordRunSummary.empty;
    return .{
        .is_empty = false,
        .runs = runs,
        .starts_word = starts_word,
        .ends_word = ends_word,
    };
}

// --- tests ---

const TestCtx = struct {
    seg: Segmenter,

    fn init(allocator: std.mem.Allocator) !TestCtx {
        return .{
            .seg = try Segmenter.init(allocator),
        };
    }

    fn deinit(self: *TestCtx, allocator: std.mem.Allocator) void {
        self.seg.deinit(allocator);
    }

    fn summarize(self: *const TestCtx, text: []const u8) Summary {
        return Summary.fromText(&self.seg, text);
    }
};

test "empty summary constants" {
    const ws = WordRunSummary.empty;
    try std.testing.expect(ws.is_empty);
    try std.testing.expectEqual(@as(u32, 0), ws.runs);

    const s = Summary.empty;
    try std.testing.expectEqual(@as(u32, 0), s.graphemes);
    try std.testing.expectEqual(@as(u32, 0), s.bytes);
    try std.testing.expectEqual(@as(u32, 0), s.newlines);
    try std.testing.expect(s.words.is_empty);
    try std.testing.expectEqual(@as(i32, 0), s.brackets.net);
    try std.testing.expectEqual(@as(i32, 0), s.brackets.p_min);
    try std.testing.expectEqual(@as(i32, 0), s.brackets.p_max);
}

test "summarize single word" {
    const allocator = std.testing.allocator;
    var ctx = try TestCtx.init(allocator);
    defer ctx.deinit(allocator);

    const s = ctx.summarize("hello");
    try std.testing.expectEqual(@as(u32, 5), s.graphemes);
    try std.testing.expectEqual(@as(u32, 5), s.bytes);
    try std.testing.expectEqual(@as(u32, 0), s.newlines);
    try std.testing.expectEqual(@as(u32, 1), s.words.runs);
    try std.testing.expectEqual(@as(i32, 0), s.brackets.net);
    try std.testing.expectEqual(@as(i32, 0), s.brackets.p_min);
    try std.testing.expectEqual(@as(i32, 0), s.brackets.paren.net);
    try std.testing.expect(s.words.starts_word);
    try std.testing.expect(s.words.ends_word);
    try std.testing.expect(!s.words.is_empty);
}

test "summarize two words" {
    const allocator = std.testing.allocator;
    var ctx = try TestCtx.init(allocator);
    defer ctx.deinit(allocator);

    const s = ctx.summarize("foo bar");
    try std.testing.expectEqual(@as(u32, 2), s.words.runs);
    try std.testing.expect(s.words.starts_word);
    try std.testing.expect(s.words.ends_word);
}

test "summarize leading and trailing whitespace" {
    const allocator = std.testing.allocator;
    var ctx = try TestCtx.init(allocator);
    defer ctx.deinit(allocator);

    const s = ctx.summarize("  word  ");
    try std.testing.expectEqual(@as(u32, 1), s.words.runs);
    try std.testing.expect(!s.words.starts_word);
    try std.testing.expect(!s.words.ends_word);
}

test "summarize counts newlines" {
    const allocator = std.testing.allocator;
    var ctx = try TestCtx.init(allocator);
    defer ctx.deinit(allocator);

    const s = ctx.summarize("a\nb\nc");
    try std.testing.expectEqual(@as(u32, 2), s.newlines);
    try std.testing.expectEqual(@as(u32, 5), s.graphemes);
}

test "summarize ascii CRLF preserves grapheme cluster semantics" {
    const allocator = std.testing.allocator;
    var ctx = try TestCtx.init(allocator);
    defer ctx.deinit(allocator);

    const s = ctx.summarize("a\r\nb");
    try std.testing.expectEqual(@as(u32, 3), s.graphemes);
    try std.testing.expectEqual(@as(u32, 4), s.bytes);
    try std.testing.expectEqual(@as(u32, 0), s.newlines);
    try std.testing.expectEqual(@as(u32, 2), s.words.runs);
}

test "summarize multibyte graphemes" {
    const allocator = std.testing.allocator;
    var ctx = try TestCtx.init(allocator);
    defer ctx.deinit(allocator);

    // "Hi 😊" — 4 graphemes, 7 bytes, 2 word runs
    const s = ctx.summarize("Hi \u{1F60A}");
    try std.testing.expectEqual(@as(u32, 4), s.graphemes);
    try std.testing.expectEqual(@as(u32, 7), s.bytes);
    try std.testing.expectEqual(@as(u32, 2), s.words.runs);
}

test "merge summaries" {
    const allocator = std.testing.allocator;
    var ctx = try TestCtx.init(allocator);
    defer ctx.deinit(allocator);

    const left = ctx.summarize("foo ");
    const right = ctx.summarize("bar");
    const merged = Summary.merge(left, right);

    try std.testing.expectEqual(@as(u32, 7), merged.graphemes);
    try std.testing.expectEqual(@as(u32, 2), merged.words.runs);
    try std.testing.expect(merged.words.starts_word);
    try std.testing.expect(merged.words.ends_word);
}

test "summarize bracket depth" {
    const allocator = std.testing.allocator;
    var ctx = try TestCtx.init(allocator);
    defer ctx.deinit(allocator);

    const balanced = ctx.summarize("a({[]})b");
    try std.testing.expectEqual(@as(i32, 0), balanced.brackets.net);
    try std.testing.expectEqual(@as(i32, 0), balanced.brackets.p_min);
    try std.testing.expectEqual(@as(i32, 0), balanced.brackets.paren.net);
    try std.testing.expectEqual(@as(i32, 0), balanced.brackets.square.net);
    try std.testing.expectEqual(@as(i32, 0), balanced.brackets.curly.net);

    const closes_first = ctx.summarize(")foo(");
    try std.testing.expectEqual(@as(i32, 0), closes_first.brackets.net);
    try std.testing.expectEqual(@as(i32, -1), closes_first.brackets.p_min);
    try std.testing.expectEqual(@as(i32, -1), closes_first.brackets.paren.p_min);

    const opens = ctx.summarize("(({");
    try std.testing.expectEqual(@as(i32, 3), opens.brackets.net);
    try std.testing.expectEqual(@as(i32, 0), opens.brackets.p_min);
    try std.testing.expectEqual(@as(i32, 2), opens.brackets.paren.net);
    try std.testing.expectEqual(@as(i32, 1), opens.brackets.curly.net);

    const mixed = ctx.summarize("([)]");
    try std.testing.expectEqual(@as(i32, 0), mixed.brackets.net);
    try std.testing.expectEqual(@as(i32, 0), mixed.brackets.paren.net);
    try std.testing.expectEqual(@as(i32, 0), mixed.brackets.square.net);
}

test "merge word summaries bridges adjacent words" {
    const allocator = std.testing.allocator;
    var ctx = try TestCtx.init(allocator);
    defer ctx.deinit(allocator);

    // "foo" ends_word=true, "bar" starts_word=true → bridge merges into 1 run
    const left = ctx.summarize("foo");
    const right = ctx.summarize("bar");
    const merged = Summary.merge(left, right);
    try std.testing.expectEqual(@as(u32, 1), merged.words.runs);
}

test "merge with empty is identity" {
    const allocator = std.testing.allocator;
    var ctx = try TestCtx.init(allocator);
    defer ctx.deinit(allocator);

    const s = ctx.summarize("hello");
    try std.testing.expectEqual(s, Summary.merge(s, Summary.empty));
    try std.testing.expectEqual(s, Summary.merge(Summary.empty, s));
}

// --- word semantics: pin Python-equivalent "maximal non-whitespace run" behaviour ---

test "word semantics: punctuation does not break a run" {
    // Python: no whitespace in "foo.bar" → 1 run. Our bridge logic must preserve this
    // regardless of how many segments zg_words emits.
    const allocator = std.testing.allocator;
    var ctx = try TestCtx.init(allocator);
    defer ctx.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), ctx.summarize("foo.bar").words.runs);
    try std.testing.expectEqual(@as(u32, 1), ctx.summarize("a_b").words.runs);
    try std.testing.expectEqual(@as(u32, 1), ctx.summarize("x/y").words.runs);
    try std.testing.expectEqual(@as(u32, 1), ctx.summarize("hello\u{1F44B}").words.runs);
}

test "word semantics: whitespace separates runs" {
    const allocator = std.testing.allocator;
    var ctx = try TestCtx.init(allocator);
    defer ctx.deinit(allocator);

    // comma is non-whitespace and bridges; the space is what breaks the run
    try std.testing.expectEqual(@as(u32, 2), ctx.summarize("foo, bar").words.runs);
    try std.testing.expectEqual(@as(u32, 2), ctx.summarize("one\n two").words.runs);
}

test "word semantics: starts_word and ends_word across punctuation" {
    const allocator = std.testing.allocator;
    var ctx = try TestCtx.init(allocator);
    defer ctx.deinit(allocator);

    const s = ctx.summarize("foo.bar");
    try std.testing.expect(s.words.starts_word);
    try std.testing.expect(s.words.ends_word);

    const t = ctx.summarize("  foo, bar  ");
    try std.testing.expect(!t.words.starts_word);
    try std.testing.expect(!t.words.ends_word);
}

// --- split/merge equivalence: summarize(a ++ b) == merge(summarize(a), summarize(b)) ---

fn checkSplitMerge(
    ctx: *const TestCtx,
    allocator: std.mem.Allocator,
    left: []const u8,
    right: []const u8,
) !void {
    const combined = try std.mem.concat(allocator, u8, &.{ left, right });
    defer allocator.free(combined);
    const whole = ctx.summarize(combined);
    const merged = Summary.merge(ctx.summarize(left), ctx.summarize(right));
    try std.testing.expectEqual(whole, merged);
}

test "split/merge equivalence" {
    const allocator = std.testing.allocator;
    var ctx = try TestCtx.init(allocator);
    defer ctx.deinit(allocator);

    // word–word boundaries
    try checkSplitMerge(&ctx, allocator, "foo", "bar"); // adjacent: bridge to 1
    try checkSplitMerge(&ctx, allocator, "foo ", "bar"); // space on left
    try checkSplitMerge(&ctx, allocator, "foo", " bar"); // space on right
    try checkSplitMerge(&ctx, allocator, "foo", ",bar"); // punctuation on right
    try checkSplitMerge(&ctx, allocator, "foo,", "bar"); // punctuation on left
    // newline boundaries
    try checkSplitMerge(&ctx, allocator, "foo\n", "bar");
    try checkSplitMerge(&ctx, allocator, "\n", "bar");
    try checkSplitMerge(&ctx, allocator, "foo", "\nbar");
    try checkSplitMerge(&ctx, allocator, "one\ntwo\n", "three");
    // empty sides
    try checkSplitMerge(&ctx, allocator, "", "foo");
    try checkSplitMerge(&ctx, allocator, "foo", "");
    try checkSplitMerge(&ctx, allocator, "", "");
    // whitespace-only sides
    try checkSplitMerge(&ctx, allocator, "  ", "foo");
    try checkSplitMerge(&ctx, allocator, "foo", "  ");
    try checkSplitMerge(&ctx, allocator, "  ", "  ");
    // multibyte
    try checkSplitMerge(&ctx, allocator, "\u{1F60A}", "bar");
    try checkSplitMerge(&ctx, allocator, "foo", "\u{1F60A}");
    try checkSplitMerge(&ctx, allocator, "He\u{0301}", "llo");
    // multi-word each side
    try checkSplitMerge(&ctx, allocator, "foo bar", "baz qux");
    try checkSplitMerge(&ctx, allocator, "foo bar ", "baz qux");
    try checkSplitMerge(&ctx, allocator, "foo bar", " baz qux");
    // split mid-punctuation-run
    try checkSplitMerge(&ctx, allocator, "foo.", "bar");
    // bracket-depth boundaries
    try checkSplitMerge(&ctx, allocator, "(", ")");
    try checkSplitMerge(&ctx, allocator, ")", "(");
    try checkSplitMerge(&ctx, allocator, "({[", "]})");
    try checkSplitMerge(&ctx, allocator, "alpha(", "beta)");
    try checkSplitMerge(&ctx, allocator, "foo", ".bar");
}

// --- segment purity: validate the first-codepoint assumption in segmentIsWhitespace ---

test "zg_words segments are uniformly whitespace or non-whitespace" {
    // If this ever fails, segmentIsWhitespace needs to scan the whole segment.
    const allocator = std.testing.allocator;
    var ctx = try TestCtx.init(allocator);
    defer ctx.deinit(allocator);

    const texts = [_][]const u8{
        "foo bar",
        "foo.bar",
        "foo, bar",
        "a_b c_d",
        "hello\u{1F44B}world",
        "  leading",
        "trailing  ",
        "one\ntwo",
        "x/y z",
        "He\u{0301}llo wörld",
    };

    for (texts) |text| {
        var iter = Words.iterator(text);
        while (iter.next()) |segment| {
            const bytes = segment.bytes(text);
            if (bytes.len == 0) continue;
            const first_len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch continue;
            if (first_len > bytes.len) continue;
            const first_cp = std.unicode.utf8Decode(bytes[0..first_len]) catch continue;
            const first_is_ws = Properties.isWhitespace(first_cp);

            var i: usize = first_len;
            while (i < bytes.len) {
                const seq_len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch break;
                if (i + seq_len > bytes.len) break;
                const cp = std.unicode.utf8Decode(bytes[i .. i + seq_len]) catch break;
                try std.testing.expectEqual(first_is_ws, Properties.isWhitespace(cp));
                i += seq_len;
            }
        }
    }
}
