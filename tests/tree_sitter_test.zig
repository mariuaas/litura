//! Tree-sitter tokens and syntax through the optional public package API.
const std = @import("std");
const litura = @import("litura");
const support = @import("support.zig");
const buffer_types = litura.types;
const BufferEngine = litura.BufferEngine;
const TreeSitterTokenProvider = litura.tree_sitter.TreeSitterTokenProvider;
const views = litura.views;

test "tree-sitter zig tokens attach and query" {
    var engine = try BufferEngine.initFromText(
        std.testing.allocator,
        "const std = @import(\"std\");\npub fn main() void {\n    return;\n}\n",
        null,
    );
    defer engine.deinit();

    try std.testing.expect(try TreeSitterTokenProvider.attachBuiltin(&engine, "zig"));
    try std.testing.expectEqual(views.ViewStateKind.stale, engine.queryViewState("tokens").kind);
    try std.testing.expectError(
        error.ViewStale,
        engine.queryTokenSpans(0, engine.graphemeCount(), null),
    );
    _ = engine.refreshView("tokens", .unlimited);

    const spans = try engine.queryTokenSpans(0, engine.graphemeCount(), null);
    defer std.testing.allocator.free(spans);

    try std.testing.expect(spans.len > 0);
    try std.testing.expectEqual(
        views.ViewStateKind.available,
        engine.queryViewState("tokens").kind,
    );
    try std.testing.expectEqual(
        views.ViewStateKind.available,
        engine.queryViewState("syntax").kind,
    );

    var saw_keyword = false;
    var saw_function = false;
    for (spans) |span| {
        if (std.mem.eql(u8, span.style, "syntax:keyword")) saw_keyword = true;
        if (std.mem.eql(u8, span.style, "syntax:function")) saw_function = true;
    }
    try std.testing.expect(saw_keyword);
    try std.testing.expect(saw_function);
}

test "tree-sitter lua tokens attach and query" {
    var engine = try BufferEngine.initFromText(
        std.testing.allocator,
        "local x = 42\nprint(x)\n",
        null,
    );
    defer engine.deinit();

    try std.testing.expect(try TreeSitterTokenProvider.attachBuiltin(&engine, "lua"));
    try std.testing.expectEqual(views.ViewStateKind.stale, engine.queryViewState("tokens").kind);
    try std.testing.expectError(
        error.ViewStale,
        engine.queryTokenSpans(0, engine.graphemeCount(), null),
    );
    _ = engine.refreshView("tokens", .unlimited);

    const spans = try engine.queryTokenSpans(0, engine.graphemeCount(), null);
    defer std.testing.allocator.free(spans);

    try std.testing.expect(spans.len > 0);
    try std.testing.expectEqualStrings("syntax:keyword", spans[0].style);
    try std.testing.expectEqual(
        views.ViewStateKind.available,
        engine.queryViewState("tokens").kind,
    );
    try std.testing.expectEqual(
        views.ViewStateKind.available,
        engine.queryViewState("syntax").kind,
    );
}

test "tree-sitter lua tokens refresh after mutation" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "local x = 1\n", null);
    defer engine.deinit();

    try std.testing.expect(try TreeSitterTokenProvider.attachBuiltin(&engine, "lua"));
    _ = engine.refreshView("tokens", .unlimited);
    {
        const spans = try engine.queryTokenSpans(0, engine.graphemeCount(), null);
        defer std.testing.allocator.free(spans);
        try std.testing.expect(spans.len > 0);
    }

    try support.edit(&engine, &[_]buffer_types.BufferOp{
        .{ .insert = .{ .pos = engine.graphemeCount(), .text = "print(x)\n" } },
    });

    try std.testing.expectEqual(views.ViewStateKind.stale, engine.queryViewState("tokens").kind);
    try std.testing.expectEqual(
        views.ViewStateKind.available,
        engine.refreshView("tokens", .unlimited).kind,
    );
    const spans = try engine.queryTokenSpans(0, engine.graphemeCount(), null);
    defer std.testing.allocator.free(spans);
    try std.testing.expect(spans.len > 0);
    try std.testing.expectEqual(
        views.ViewStateKind.available,
        engine.queryViewState("tokens").kind,
    );
}

test "tree-sitter lua syntax view resolves enclosing node and ref round trip" {
    const source = "function foo()\n  return 1\nend\n";
    var engine = try BufferEngine.initFromText(std.testing.allocator, source, null);
    defer engine.deinit();

    try std.testing.expect(try TreeSitterTokenProvider.attachBuiltin(&engine, "lua"));
    try std.testing.expectEqual(views.ViewStateKind.stale, engine.queryViewState("syntax").kind);
    try std.testing.expectError(error.ViewStale, engine.queryEnclosingSyntaxNode(0, null));
    _ = engine.refreshView("syntax", .unlimited);

    const return_pos = try engine.lineColToPosition(1, 2);
    const node = (try engine.queryEnclosingSyntaxNode(
        return_pos,
        null,
    )) orelse return error.TestExpectedEqual;
    try std.testing.expect(node.end > node.start);
    try std.testing.expect(node.is_named);
    try std.testing.expectEqualStrings("tree-sitter-lua", node.ref.provider);
    try std.testing.expectEqual(engine.revision, node.ref.revision);
    try std.testing.expect(node.ref.id > 0);

    const again = try engine.querySyntaxNodeInfo(node.ref);
    try std.testing.expectEqualStrings(node.kind, again.kind);
    try std.testing.expectEqual(node.start, again.start);
    try std.testing.expectEqual(node.end, again.end);
    try std.testing.expectEqual(
        views.ViewStateKind.available,
        engine.queryViewState("syntax").kind,
    );
}

test "tree-sitter syntax refs survive multiple queries at same revision" {
    const source = "function foo()\n  return 1\nend\n";
    var engine = try BufferEngine.initFromText(std.testing.allocator, source, null);
    defer engine.deinit();

    try std.testing.expect(try TreeSitterTokenProvider.attachBuiltin(&engine, "lua"));
    _ = engine.refreshView("syntax", .unlimited);
    const return_pos = try engine.lineColToPosition(1, 2);
    const first = (try engine.queryEnclosingSyntaxNode(return_pos, null)).?;
    const second_pos = try engine.lineColToPosition(0, 9);
    const second = (try engine.queryEnclosingSyntaxNode(second_pos, null)).?;

    const first_again = try engine.querySyntaxNodeInfo(first.ref);
    try std.testing.expectEqualStrings(first.kind, first_again.kind);
    try std.testing.expectEqual(first.start, first_again.start);
    try std.testing.expectEqual(first.end, first_again.end);

    const second_again = try engine.querySyntaxNodeInfo(second.ref);
    try std.testing.expectEqualStrings(second.kind, second_again.kind);
    try std.testing.expectEqual(second.start, second_again.start);
    try std.testing.expectEqual(second.end, second_again.end);
}

test "tree-sitter syntax refs reject stale revisions" {
    const source = "function foo()\nend\n";
    var engine = try BufferEngine.initFromText(std.testing.allocator, source, null);
    defer engine.deinit();

    try std.testing.expect(try TreeSitterTokenProvider.attachBuiltin(&engine, "lua"));
    _ = engine.refreshView("syntax", .unlimited);
    const pos = try engine.lineColToPosition(0, 9);
    const node = (try engine.queryEnclosingSyntaxNode(pos, null)).?;
    try support.edit(&engine, &[_]buffer_types.BufferOp{
        .{ .insert = .{ .pos = engine.graphemeCount(), .text = "\n" } },
    });
    try std.testing.expectError(error.InvalidArgument, engine.querySyntaxNodeInfo(node.ref));
    // Refreshing makes the view current again, but not the old reference.
    _ = engine.refreshView("syntax", .unlimited);
    try std.testing.expectError(error.InvalidArgument, engine.querySyntaxNodeInfo(node.ref));
}

test "tree-sitter registers tokens and syntax as separate view facades" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "local x = 1\n", null);
    defer engine.deinit();

    try std.testing.expect(try TreeSitterTokenProvider.attachBuiltin(&engine, "lua"));
    try std.testing.expect(engine.hasViewProvider("tokens"));
    try std.testing.expect(engine.hasViewProvider("syntax"));
    try std.testing.expectEqual(views.ViewStateKind.stale, engine.queryViewState("tokens").kind);
    try std.testing.expectEqual(views.ViewStateKind.stale, engine.queryViewState("syntax").kind);

    // One shared parse: refreshing either facade makes both current.
    _ = engine.refreshView("tokens", .unlimited);
    const spans = try engine.queryTokenSpans(0, engine.graphemeCount(), null);
    defer std.testing.allocator.free(spans);
    const pos = try engine.lineColToPosition(0, 0);
    _ = try engine.queryEnclosingSyntaxNode(pos, null);
    try std.testing.expectEqual(
        views.ViewStateKind.available,
        engine.queryViewState("tokens").kind,
    );
    try std.testing.expectEqual(
        views.ViewStateKind.available,
        engine.queryViewState("syntax").kind,
    );
}

test "tree-sitter attachTokensBuiltin registers tokens only" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "local x = 1\n", null);
    defer engine.deinit();

    try std.testing.expect(try TreeSitterTokenProvider.attachTokensBuiltin(&engine, "lua"));
    try std.testing.expect(engine.hasViewProvider("tokens"));
    try std.testing.expect(!engine.hasViewProvider("syntax"));

    _ = engine.refreshView("tokens", .unlimited);
    const spans = try engine.queryTokenSpans(0, engine.graphemeCount(), null);
    defer std.testing.allocator.free(spans);
    try std.testing.expect(spans.len > 0);
}

test "tree-sitter attachSyntaxBuiltin registers syntax only" {
    const source = "function foo()\nend\n";
    var engine = try BufferEngine.initFromText(std.testing.allocator, source, null);
    defer engine.deinit();

    try std.testing.expect(try TreeSitterTokenProvider.attachSyntaxBuiltin(&engine, "lua"));
    try std.testing.expect(!engine.hasViewProvider("tokens"));
    try std.testing.expect(engine.hasViewProvider("syntax"));

    _ = engine.refreshView("syntax", .unlimited);
    const pos = try engine.lineColToPosition(0, 9);
    const node = (try engine.queryEnclosingSyntaxNode(pos, null)).?;
    try std.testing.expectEqualStrings("tree-sitter-lua", node.ref.provider);
}

test "tree-sitter bundled attach refuses partially occupied slots" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "local x = 1\n", null);
    defer engine.deinit();

    try std.testing.expect(try TreeSitterTokenProvider.attachTokensBuiltin(&engine, "lua"));
    try std.testing.expect(!(try TreeSitterTokenProvider.attachBuiltin(&engine, "lua")));
    try std.testing.expect(!(try TreeSitterTokenProvider.attachSyntaxBuiltin(&engine, "lua")));
    try std.testing.expect(!engine.hasViewProvider("syntax"));
}

test "tree-sitter syntax facade can coexist with another tokens provider" {
    const source = "abc\n";
    var engine = try BufferEngine.initFromText(std.testing.allocator, source, null);
    defer engine.deinit();

    var static_provider = views.StaticTokenProvider{
        .spans = &.{.{ .start = 0, .end = 3, .kind = "text", .style = "plain" }},
        .revision = 0,
        .stale = false,
    };
    try engine.registerViewProvider(static_provider.provider());
    try std.testing.expect(try TreeSitterTokenProvider.attachSyntaxBuiltin(&engine, "lua"));
    _ = engine.refreshView("syntax", .unlimited);

    const spans = try engine.queryTokenSpans(0, engine.graphemeCount(), null);
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqualStrings("plain", spans[0].style);

    const node = (try engine.queryEnclosingSyntaxNode(0, null)).?;
    try std.testing.expect(node.end > node.start);
}

test "tree-sitter lua unsupported language is ignored" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "plain text\n", null);
    defer engine.deinit();

    try std.testing.expect(!(try TreeSitterTokenProvider.attachBuiltin(&engine, "text")));
    const spans = try engine.queryTokenSpans(0, engine.graphemeCount(), null);
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 0), spans.len);
}

test "tree-sitter enclosing node is null for text before the first token" {
    // The root node starts at the first token; leading whitespace is inside no node.
    var engine = try BufferEngine.initFromText(std.testing.allocator, "\n\n  local x = 1\n", null);
    defer engine.deinit();
    try std.testing.expect(try TreeSitterTokenProvider.attachBuiltin(&engine, "lua"));
    _ = engine.refreshView("syntax", .unlimited);
    const leading = try engine.queryEnclosingSyntaxNode(0, null);
    try std.testing.expectEqual(@as(?views.SyntaxNodeInfo, null), leading);
    const inside = (try engine.queryEnclosingSyntaxNode(4, null)).?;
    try std.testing.expect(inside.start <= 4 and inside.end > 4);
}
