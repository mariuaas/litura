const std = @import("std");
const litura = @import("litura");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var document = try litura.BufferEngine.initFromText(allocator, "Hello", null);
    defer document.deinit();

    // A session owns its selections: here, one caret at the end of the text.
    var created = try document.createSession(.{
        .id = .{ .value = 1 },
        .origin = document.revision,
        .selections = &.{.{ .start = .{ .new = .{ .position = 5 } } }},
    });
    defer created.deinit(allocator);
    const session = created.lifecycle.change.session_created.session;
    const cursor = created.lifecycle.change.session_created.selections[0].start.anchor;

    // Insert text and place the caret after it in one transition.
    var result = try document.submit(.{
        .id = .{ .value = 2 },
        .origin = document.revision,
        .label = "insert",
        .payload = .{ .composite = .{ .parts = &.{
            .{
                .buffer_mutation = .{
                    .ops = &.{.{ .insert = .{ .pos = 5, .text = ", Litura!" } }},
                },
            },
            .{
                .interaction_mutation = .{
                    .session_id = session,
                    .origin = 0,
                    .ops = &.{.{ .set_selections = .{
                        .selections = &.{.{ .start = .{ .move = .{
                            .anchor = cursor,
                            .to = .{ .edit = .{ .op = 0 } },
                        } } }},
                    } }},
                },
            },
        } } },
    });
    defer result.deinit(allocator);
    const block = result.committed;

    const text = try document.getText();
    defer allocator.free(text);
    std.debug.assert(std.mem.eql(u8, text, "Hello, Litura!"));
    std.debug.assert((try document.queryAnchor(cursor)).position == document.graphemeCount());
    if (comptime litura.tree_sitter_enabled) {
        std.debug.assert(
            try litura.tree_sitter.TreeSitterTokenProvider.attachBuiltin(&document, "lua"),
        );
        const spans = try document.queryTokenSpans(0, document.graphemeCount(), document.revision);
        defer allocator.free(spans);
    }
    std.debug.print(
        "{s} (revision {d}, block {d})\n",
        .{ text, document.revision, block.sequence() },
    );
}
