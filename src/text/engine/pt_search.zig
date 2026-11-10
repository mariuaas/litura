//! Byte-exact grapheme-pattern search over piece-table cursors.

const std = @import("std");
const PieceTable = @import("piece_table.zig").PieceTable;

fn buildKmpTable(allocator: std.mem.Allocator, pattern: []const []const u8) ![]usize {
    const lps = try allocator.alloc(usize, pattern.len);
    errdefer allocator.free(lps);
    if (pattern.len == 0) return lps;

    @memset(lps, 0);
    var len: usize = 0;
    var i: usize = 1;
    while (i < pattern.len) {
        if (std.mem.eql(u8, pattern[i], pattern[len])) {
            len += 1;
            lps[i] = len;
            i += 1;
        } else if (len > 0) {
            len = lps[len - 1];
        } else {
            lps[i] = 0;
            i += 1;
        }
    }

    return lps;
}

pub fn findNext(table: *const PieceTable, pattern_text: []const u8, start: u32) !?u32 {
    try table.validatePosition(start);

    const pattern = try table.patternClusters(pattern_text);
    defer table.allocator.free(pattern);
    if (pattern.len == 0) return start;

    const lps = try buildKmpTable(table.allocator, pattern);
    defer table.allocator.free(lps);

    var matched: usize = 0;
    var cursor = try table.graphemeCursor(start);
    while (cursor.valid) {
        const cluster = try cursor.current();
        while (matched > 0 and !std.mem.eql(u8, cluster, pattern[matched])) {
            matched = lps[matched - 1];
        }
        if (!std.mem.eql(u8, cluster, pattern[matched])) {
            _ = cursor.advance();
            continue;
        }

        matched += 1;
        if (matched == pattern.len) {
            return cursor.position + 1 - @as(u32, @intCast(pattern.len));
        }
        _ = cursor.advance();
    }

    return null;
}

pub fn findPrevious(table: *const PieceTable, pattern_text: []const u8, start: ?u32) !?u32 {
    const search_start = start orelse table.graphemeCount();
    try table.validatePosition(search_start);

    const pattern = try table.patternClusters(pattern_text);
    defer table.allocator.free(pattern);
    if (pattern.len == 0) return search_start;

    const lps = try buildKmpTable(table.allocator, pattern);
    defer table.allocator.free(lps);

    const pattern_len: u32 = @intCast(pattern.len);
    const stop_before = @min(table.graphemeCount(), search_start + pattern_len - 1);
    var last_match: ?u32 = null;
    var matched: usize = 0;
    var cursor = try table.graphemeCursor(0);

    while (cursor.valid and cursor.position < stop_before) {
        const cluster = try cursor.current();
        while (matched > 0 and !std.mem.eql(u8, cluster, pattern[matched])) {
            matched = lps[matched - 1];
        }
        if (std.mem.eql(u8, cluster, pattern[matched])) {
            matched += 1;
            if (matched == pattern.len) {
                const match_start = cursor.position + 1 - pattern_len;
                if (match_start < search_start) {
                    last_match = match_start;
                }
                matched = lps[matched - 1];
            }
        }
        _ = cursor.advance();
    }

    return last_match;
}
