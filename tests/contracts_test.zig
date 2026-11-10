//! Regression coverage added during the structural cleanup.
const std = @import("std");
const litura = @import("litura");

test "direct anchor movement preserves the current interaction revision" {
    // Characterize the existing low-level behavior; revision routing is a separate change.
    var document = try litura.BufferEngine.initFromText(std.testing.allocator, "abc", null);
    defer document.deinit();
    const cursor = try document.createAnchor(0, .sticky);
    const session = try document.createSession(&.{cursor});
    const revision = try document.interactionRevision(session);
    try document.moveAnchor(cursor, 2);
    try std.testing.expectEqual(@as(?u32, 2), (try document.queryAnchor(cursor)).position);
    try std.testing.expectEqual(revision, try document.interactionRevision(session));
}

test "static token refresh advances by one even when the requested revision skips" {
    // Keep this provider's current refresh behavior visible until its contract is revised.
    var document = try litura.BufferEngine.init(std.testing.allocator);
    defer document.deinit();
    var provider = litura.views.StaticTokenProvider{ .spans = &.{} };
    try document.registerViewProvider(provider.provider());
    var first = try document.apply(&.{.{ .insert = .{ .pos = 0, .text = "a" } }}, "test", "insert");
    defer first.deinit(std.testing.allocator);
    var second = try document.apply(&.{.{ .insert = .{ .pos = 1, .text = "b" } }}, "test", "insert");
    defer second.deinit(std.testing.allocator);
    const state = document.refreshView("tokens");
    try std.testing.expectEqual(@as(?u32, 1), state.revision);
    try std.testing.expectEqual(@as(u32, 2), document.revision);
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
