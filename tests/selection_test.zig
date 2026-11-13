//! Selection queries accept caller-supplied engine views.
const std = @import("std");
const litura = @import("litura");
const anchors = litura.anchors;
const queries = litura.queries;
const queryAnchorRange = litura.selection.queryAnchorRange;

test "queryAnchorRange returns live selection text" {
    const DummyCursor = struct {
        valid: bool,
        position: u32,

        pub fn current(self: *const @This()) ![]const u8 {
            _ = self;
            return "";
        }

        pub fn advance(self: *@This()) bool {
            _ = self;
            return false;
        }

        pub fn retreat(self: *@This()) bool {
            _ = self;
            return false;
        }
    };

    const FakeEngine = struct {
        pub fn queryAnchor(self: *const @This(), anchor_id: anchors.AnchorId) !queries.AnchorInfo {
            _ = self;
            return switch (anchor_id.value) {
                1 => .{ .id = anchor_id, .position = 2, .stickiness = .weak, .status = .live },
                2 => .{ .id = anchor_id, .position = 5, .stickiness = .sticky, .status = .live },
                else => error.OutOfRange,
            };
        }

        pub fn queryPosition(self: *const @This(), pos: u32) !queries.PositionInfo {
            _ = self;
            return .{
                .position = pos,
                .line = 0,
                .col = pos,
                .line_start = 0,
                .line_end = 10,
                .line_end_with_newline = 10,
            };
        }

        pub fn graphemeCount(self: *const @This()) u32 {
            _ = self;
            return 10;
        }

        pub fn graphemeCursor(self: *const @This(), pos: u32) !DummyCursor {
            _ = self;
            _ = pos;
            return .{ .valid = false, .position = 0 };
        }

        pub fn getTextRange(self: *const @This(), start: u32, end: u32) ![]u8 {
            _ = self;
            try std.testing.expectEqual(@as(u32, 2), start);
            try std.testing.expectEqual(@as(u32, 5), end);
            return try std.testing.allocator.dupe(u8, "cde");
        }

        pub fn findNext(self: *const @This(), query: []const u8, start: u32) !?u32 {
            _ = self;
            _ = query;
            _ = start;
            return null;
        }
    };

    var engine = FakeEngine{};
    var info = try queryAnchorRange(std.testing.allocator, &engine, .{
        .start = .{ .value = 1 },
        .end = .{ .value = 2 },
    });
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?u32, 2), info.start);
    try std.testing.expectEqual(@as(?u32, 5), info.end);
    try std.testing.expectEqual(anchors.RangeStatus.live, info.status);
    try std.testing.expectEqualStrings("cde", info.text);
}

test "queryAnchorRange returns dead selection when anchor is dead" {
    const DummyCursor = struct {
        valid: bool,
        position: u32,

        pub fn current(self: *const @This()) ![]const u8 {
            _ = self;
            return "";
        }

        pub fn advance(self: *@This()) bool {
            _ = self;
            return false;
        }

        pub fn retreat(self: *@This()) bool {
            _ = self;
            return false;
        }
    };

    const FakeEngine = struct {
        pub fn queryAnchor(self: *const @This(), anchor_id: anchors.AnchorId) !queries.AnchorInfo {
            _ = self;
            return .{
                .id = anchor_id,
                .position = null,
                .stickiness = .weak,
                .status = if (anchor_id.value == 1) .dead else .live,
            };
        }

        pub fn queryPosition(self: *const @This(), pos: u32) !queries.PositionInfo {
            _ = self;
            return .{
                .position = pos,
                .line = 0,
                .col = pos,
                .line_start = 0,
                .line_end = 0,
                .line_end_with_newline = 0,
            };
        }

        pub fn graphemeCount(self: *const @This()) u32 {
            _ = self;
            return 0;
        }

        pub fn graphemeCursor(self: *const @This(), pos: u32) !DummyCursor {
            _ = self;
            _ = pos;
            return .{ .valid = false, .position = 0 };
        }

        pub fn getTextRange(self: *const @This(), start: u32, end: u32) ![]u8 {
            _ = self;
            _ = start;
            _ = end;
            return error.Unexpected;
        }

        pub fn findNext(self: *const @This(), query: []const u8, start: u32) !?u32 {
            _ = self;
            _ = query;
            _ = start;
            return null;
        }
    };

    var engine = FakeEngine{};
    var info = try queryAnchorRange(std.testing.allocator, &engine, .{
        .start = .{ .value = 1 },
        .end = .{ .value = 2 },
    });
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?u32, null), info.start);
    try std.testing.expectEqual(@as(?u32, null), info.end);
    try std.testing.expectEqual(anchors.RangeStatus.dead, info.status);
    try std.testing.expectEqualStrings("", info.text);
}
