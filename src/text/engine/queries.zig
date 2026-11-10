//! Document query records; owning results release their slices in deinit.

const std = @import("std");
const anchors = @import("anchors.zig");

pub const PositionInfo = struct {
    position: u32,
    line: u32,
    col: u32,
    line_start: u32,
    line_end: u32,
    line_end_with_newline: u32,
};

/// Owns its text or rows. Call deinit with the allocator used by the query.
/// A shallow copy shares ownership and must not be deinitialized twice.
pub const LineInfo = struct {
    line: u32,
    start: u32,
    end: u32,
    end_with_newline: u32,
    text: []u8,

    pub fn deinit(self: *LineInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

/// Owns its text or rows. Call deinit with the allocator used by the query.
/// A shallow copy shares ownership and must not be deinitialized twice.
pub const RegionLineInfo = struct {
    line: u32,
    full_start: u32,
    full_end: u32,
    end_with_newline: u32,
    slice_start: u32,
    slice_end: u32,
    horizontal_col: u32,
    truncated_left: bool,
    truncated_right: bool,
    text: []u8,

    pub fn deinit(self: *RegionLineInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

/// Owns its text or rows. Call deinit with the allocator used by the query.
/// A shallow copy shares ownership and must not be deinitialized twice.
pub const RegionInfo = struct {
    revision: u32,
    line_count: u32,
    start_line: u32,
    horizontal_col: u32,
    max_graphemes_per_row: u32,
    budget_exhausted: bool,
    rows: []RegionLineInfo,

    pub fn deinit(self: *RegionInfo, allocator: std.mem.Allocator) void {
        for (self.rows) |*row| row.deinit(allocator);
        allocator.free(self.rows);
        self.* = undefined;
    }
};

pub const AnchorInfo = struct {
    id: anchors.AnchorId,
    position: ?u32,
    stickiness: anchors.AnchorStickiness,
    status: anchors.AnchorStatus,
};

/// Owns its text or rows. Call deinit with the allocator used by the query.
/// A shallow copy shares ownership and must not be deinitialized twice.
pub const SelectionInfo = struct {
    start: ?u32,
    end: ?u32,
    status: anchors.RangeStatus,
    text: []u8,

    pub fn deinit(self: *SelectionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

/// Owns its text or rows. Call deinit with the allocator used by the query.
/// A shallow copy shares ownership and must not be deinitialized twice.
pub const SearchMatch = struct {
    start: u32,
    end: u32,
    text: []u8,

    pub fn deinit(self: *SearchMatch, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

test "selection info deinit frees owned text" {
    const allocator = std.testing.allocator;
    var info = SelectionInfo{
        .start = 1,
        .end = 3,
        .status = .live,
        .text = try allocator.dupe(u8, "hi"),
    };
    info.deinit(allocator);
}
