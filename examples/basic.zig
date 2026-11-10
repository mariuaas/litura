const std = @import("std");
const litura = @import("litura");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var document = try litura.BufferEngine.initFromText(allocator, "Hello", null);
    defer document.deinit();
    const cursor = try document.createAnchor(5, .sticky);
    _ = try document.createSession(&.{cursor});
    var event = try document.apply(&.{.{ .insert = .{ .pos = 5, .text = ", Litura!" } }}, "example", "insert");
    defer event.deinit(allocator);
    const text = try document.getText();
    defer allocator.free(text);
    std.debug.assert(std.mem.eql(u8, text, "Hello, Litura!"));
    std.debug.assert((try document.queryAnchor(cursor)).position == document.graphemeCount());
    if (comptime litura.tree_sitter_enabled) {
        std.debug.assert(try litura.tree_sitter.TreeSitterTokenProvider.attachBuiltin(&document, "lua"));
        const spans = try document.queryTokenSpans(0, document.graphemeCount(), document.revision);
        defer allocator.free(spans);
    }
    std.debug.print("{s} (revision {d})\n", .{ text, document.revision });
}
