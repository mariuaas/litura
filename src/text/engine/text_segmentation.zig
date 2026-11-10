//! Unicode grapheme iteration, splitting and byte-offset maps backed by zg.

const std = @import("std");
const Graphemes = @import("zg_graphemes");

pub const Split = struct {
    left: []const u8,
    right: []const u8,
};

/// Count grapheme clusters in text without constructing a segmenter.
pub fn graphemeCount(text: []const u8) usize {
    var iter = Graphemes.iterator(text);
    var n: usize = 0;
    while (iter.next()) |_| n += 1;
    return n;
}

/// Iterate grapheme clusters as byte slices of the source string.
pub fn graphemeIterator(text: []const u8) ClusterIterator {
    return .{ .inner = Graphemes.iterator(text), .text = text };
}

/// Split text at a grapheme-cluster offset, returning two slices of the
/// original string. Returns error.OutOfRange if offset > grapheme count.
pub fn splitAtGraphemeOffset(
    text: []const u8,
    offset: usize,
) error{OutOfRange}!Split {
    var iter = Graphemes.iterator(text);
    var i: usize = 0;
    while (iter.next()) |gc| : (i += 1) {
        if (i == offset) {
            return .{ .left = text[0..gc.offset], .right = text[gc.offset..] };
        }
    }
    // offset == count is valid (split at end)
    if (i == offset) return .{ .left = text, .right = text[text.len..] };
    return error.OutOfRange;
}

/// Thin wrapper around zg's stateless grapheme iterator.
pub const Segmenter = struct {
    pub fn init(allocator: std.mem.Allocator) !Segmenter {
        _ = allocator;
        return .{};
    }

    pub fn deinit(self: *Segmenter, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    /// Iterate grapheme clusters as byte slices of the source string.
    pub fn iterator(self: *const Segmenter, text: []const u8) ClusterIterator {
        _ = self;
        return graphemeIterator(text);
    }

    /// Count grapheme clusters in text.
    pub fn count(self: *const Segmenter, text: []const u8) usize {
        _ = self;
        return graphemeCount(text);
    }

    /// Split text at a grapheme-cluster offset, returning two slices of the
    /// original string.
    /// Returns error.OutOfRange if offset > grapheme count.
    pub fn splitAtGrapheme(
        self: *const Segmenter,
        text: []const u8,
        offset: usize,
    ) error{OutOfRange}!Split {
        _ = self;
        return splitAtGraphemeOffset(text, offset);
    }

    /// Build a grapheme-index → byte-offset map for text.
    ///
    /// map[i] is the byte offset of the start of grapheme cluster i.
    /// map[n] (the sentinel) equals text.len.
    ///
    /// Caller owns the returned slice.
    pub fn graphemeToByteMap(
        self: *const Segmenter,
        allocator: std.mem.Allocator,
        text: []const u8,
    ) ![]u32 {
        _ = self;
        var offsets: std.ArrayListUnmanaged(u32) = .empty;
        errdefer offsets.deinit(allocator);
        try offsets.append(allocator, 0);
        var iter = Graphemes.iterator(text);
        while (iter.next()) |gc| {
            try offsets.append(allocator, gc.offset + gc.len);
        }
        return offsets.toOwnedSlice(allocator);
    }
};

/// Yields grapheme clusters as byte slices into the source string.
pub const ClusterIterator = struct {
    inner: Graphemes.Iterator,
    text: []const u8,

    pub fn next(self: *ClusterIterator) ?[]const u8 {
        const gc = self.inner.next() orelse return null;
        return self.text[gc.offset .. gc.offset + gc.len];
    }
};

// --- tests ---

test "ascii: count equals character count" {
    const allocator = std.testing.allocator;
    var seg = try Segmenter.init(allocator);
    defer seg.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), seg.count("Hello"));
    try std.testing.expectEqual(@as(usize, 0), seg.count(""));
}

test "combining accent forms one grapheme cluster" {
    const allocator = std.testing.allocator;
    var seg = try Segmenter.init(allocator);
    defer seg.deinit(allocator);

    // H + e + combining acute → 2 graphemes despite 4 UTF-8 bytes
    try std.testing.expectEqual(@as(usize, 2), seg.count("He\u{0301}"));
}

test "emoji counts as one grapheme cluster" {
    const allocator = std.testing.allocator;
    var seg = try Segmenter.init(allocator);
    defer seg.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), seg.count("Hi \u{1F60A}"));
}

test "iterator yields cluster bytes" {
    const allocator = std.testing.allocator;
    var seg = try Segmenter.init(allocator);
    defer seg.deinit(allocator);

    var iter = seg.iterator("He\u{0301}");
    try std.testing.expectEqualStrings("H", iter.next().?);
    try std.testing.expectEqualStrings("e\u{0301}", iter.next().?);
    try std.testing.expect(iter.next() == null);
}

test "splitAtGrapheme ascii" {
    const allocator = std.testing.allocator;
    var seg = try Segmenter.init(allocator);
    defer seg.deinit(allocator);

    const result = try seg.splitAtGrapheme("Hello", 2);
    try std.testing.expectEqualStrings("He", result.left);
    try std.testing.expectEqualStrings("llo", result.right);
}

test "splitAtGrapheme at start and end" {
    const allocator = std.testing.allocator;
    var seg = try Segmenter.init(allocator);
    defer seg.deinit(allocator);

    const at_start = try seg.splitAtGrapheme("Hi", 0);
    try std.testing.expectEqualStrings("", at_start.left);
    try std.testing.expectEqualStrings("Hi", at_start.right);

    const at_end = try seg.splitAtGrapheme("Hi", 2);
    try std.testing.expectEqualStrings("Hi", at_end.left);
    try std.testing.expectEqualStrings("", at_end.right);
}

test "splitAtGrapheme with multibyte cluster" {
    const allocator = std.testing.allocator;
    var seg = try Segmenter.init(allocator);
    defer seg.deinit(allocator);

    // "He\u{0301}" — split at grapheme 1 cuts between H and e+accent
    const result = try seg.splitAtGrapheme("He\u{0301}", 1);
    try std.testing.expectEqualStrings("H", result.left);
    try std.testing.expectEqualStrings("e\u{0301}", result.right);
}

test "splitAtGrapheme out of range returns error" {
    const allocator = std.testing.allocator;
    var seg = try Segmenter.init(allocator);
    defer seg.deinit(allocator);

    try std.testing.expectError(error.OutOfRange, seg.splitAtGrapheme("Hi", 5));
}

test "graphemeToByteMap ascii" {
    const allocator = std.testing.allocator;
    var seg = try Segmenter.init(allocator);
    defer seg.deinit(allocator);

    const map = try seg.graphemeToByteMap(allocator, "Hi!");
    defer allocator.free(map);

    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, map);
}

test "graphemeToByteMap with multibyte emoji" {
    const allocator = std.testing.allocator;
    var seg = try Segmenter.init(allocator);
    defer seg.deinit(allocator);

    // "Hi 😊": H(1) i(1) space(1) 😊(4) = 7 bytes, 4 graphemes → 5 entries
    const map = try seg.graphemeToByteMap(allocator, "Hi \u{1F60A}");
    defer allocator.free(map);

    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 7 }, map);
}

test "graphemeToByteMap with combining sequence" {
    const allocator = std.testing.allocator;
    var seg = try Segmenter.init(allocator);
    defer seg.deinit(allocator);

    // "He\u{0301}": H(1) + e+accent(3) = 4 bytes, 2 graphemes → 3 entries
    const map = try seg.graphemeToByteMap(allocator, "He\u{0301}");
    defer allocator.free(map);

    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 4 }, map);
}
