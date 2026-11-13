//! Regression coverage added during the structural cleanup.
const std = @import("std");
const litura = @import("litura");
const support = @import("support.zig");

test "static token spans are served only for the revision they describe" {
    var document = try litura.BufferEngine.initFromText(std.testing.allocator, "abc", null);
    defer document.deinit();
    var provider = litura.views.StaticTokenProvider{
        .spans = &.{.{ .start = 0, .end = 3, .kind = "word", .style = "plain" }},
    };
    try document.registerViewProvider(provider.provider());

    // At revision 0 the spans describe the text.
    const ViewStateKind = litura.views.ViewStateKind;
    try std.testing.expectEqual(ViewStateKind.available, document.refreshView("tokens").kind);
    const current = try document.queryTokenSpans(0, 3, null);
    defer std.testing.allocator.free(current);
    try std.testing.expectEqual(@as(usize, 1), current.len);

    // After an edit the spans no longer match the text, and refresh cannot fix that.
    try support.edit(&document, &.{.{ .insert = .{ .pos = 0, .text = "xy" } }});
    const state = document.refreshView("tokens");
    try std.testing.expectEqual(ViewStateKind.stale, state.kind);
    try std.testing.expectEqual(@as(?u32, 0), state.revision);
    try std.testing.expectEqual(ViewStateKind.stale, document.queryViewState("tokens").kind);
    const stale = try document.queryTokenSpans(0, document.graphemeCount(), null);
    defer std.testing.allocator.free(stale);
    try std.testing.expectEqual(@as(usize, 0), stale.len);
}

test "Unicode offset maps release partial allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildOffsetMap, .{});
}

fn buildOffsetMap(allocator: std.mem.Allocator) !void {
    var segmenter = try litura.segmentation.Segmenter.init(allocator);
    defer segmenter.deinit(allocator);
    const offsets = try segmenter.graphemeToByteMap(allocator, "a🙂é\n");
    defer allocator.free(offsets);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 5, 8, 9 }, offsets);
}

test "bounded region queries free partial results on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, queryRegionAllocations, .{});
}

fn queryRegionAllocations(allocator: std.mem.Allocator) !void {
    // Isolate read-result allocations from the constructor's known failure paths.
    var document = try litura.BufferEngine.initFromText(std.testing.allocator, "a🙂\nsecond", null);
    defer document.deinit();
    document.allocator = allocator;
    document.table.allocator = allocator;
    defer {
        document.allocator = std.testing.allocator;
        document.table.allocator = std.testing.allocator;
    }
    var region = try document.queryRegion(0, 2, 0, 4, 8);
    defer region.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), region.rows.len);
    try std.testing.expectEqualStrings("a🙂", region.rows[0].text);
    try std.testing.expectEqualStrings("seco", region.rows[1].text);
    try std.testing.expectEqual(@as(u32, 0), document.revision);
}
