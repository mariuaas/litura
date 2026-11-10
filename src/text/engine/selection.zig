//! Selection text and liveness queries over caller-supplied engine views.

const std = @import("std");
const anchors = @import("anchors.zig");
const engine_view = @import("engine_view.zig");
const queries = @import("queries.zig");

pub const AnchorRange = struct {
    start: anchors.AnchorId,
    end: anchors.AnchorId,
};

pub const CursorSelection = struct {
    mark: anchors.AnchorId,
};

/// Accepts a caller-supplied engine satisfying engine_view.assertEngineView.
/// Owns the returned text through allocator; call SelectionInfo.deinit with it.
/// The engine must return text allocated by that same allocator.
pub fn queryAnchorRange(
    allocator: std.mem.Allocator,
    engine: anytype,
    anchor_range: AnchorRange,
) !queries.SelectionInfo {
    engine_view.assertEngineView(@TypeOf(engine));

    const start_anchor = try engine.queryAnchor(anchor_range.start);
    const end_anchor = try engine.queryAnchor(anchor_range.end);
    if (start_anchor.status == .dead or
        end_anchor.status == .dead or
        start_anchor.position == null or
        end_anchor.position == null)
    {
        return .{
            .start = null,
            .end = null,
            .status = .dead,
            .text = try allocator.alloc(u8, 0),
        };
    }

    const start = @min(start_anchor.position.?, end_anchor.position.?);
    const end = @max(start_anchor.position.?, end_anchor.position.?);
    if (start == end) {
        return .{
            .start = start,
            .end = end,
            .status = .collapsed,
            .text = try allocator.alloc(u8, 0),
        };
    }

    return .{
        .start = start,
        .end = end,
        .status = .live,
        .text = try engine.getTextRange(start, end),
    };
}

/// Queries the range between mark and cursor through a caller-supplied engine view.
/// Returned text is owned through allocator, with the same requirements as queryAnchorRange.
pub fn queryCursorSelection(
    allocator: std.mem.Allocator,
    engine: anytype,
    selection: CursorSelection,
    cursor_anchor: anchors.AnchorId,
) !queries.SelectionInfo {
    return queryAnchorRange(allocator, engine, .{
        .start = selection.mark,
        .end = cursor_anchor,
    });
}
