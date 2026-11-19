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

test "tree-sitter range queries find the node enclosing sibling nodes" {
    // `alpha, beta` spans two arguments; no single grapheme's smallest node is their list.
    const source = "print(alpha, beta)\nx = 1\n";
    var engine = try BufferEngine.initFromText(std.testing.allocator, source, null);
    defer engine.deinit();
    try std.testing.expect(try TreeSitterTokenProvider.attachBuiltin(&engine, "lua"));
    _ = engine.refreshView("syntax", .unlimited);

    const arguments = (try engine.queryEnclosingSyntaxNodeRange(6, 17, null)).?;
    try std.testing.expectEqualStrings("arguments", arguments.kind);
    try std.testing.expectEqual(@as(u32, 5), arguments.start);
    try std.testing.expectEqual(@as(u32, 18), arguments.end);
    const call = (try engine.querySyntaxNodeParent(arguments.ref)).?;
    try std.testing.expectEqualStrings("function_call", call.kind);

    // An empty range asks about one grapheme, exactly as the point query does.
    const point = (try engine.queryEnclosingSyntaxNode(19, null)).?;
    const empty = (try engine.queryEnclosingSyntaxNodeRange(19, 19, null)).?;
    const single = (try engine.queryEnclosingSyntaxNodeRange(19, 20, null)).?;
    try std.testing.expectEqual(point.ref.id, empty.ref.id);
    try std.testing.expectEqual(point.ref.id, single.ref.id);

    try std.testing.expectError(error.InvalidRange, engine.queryEnclosingSyntaxNodeRange(4, 3, null));
    try std.testing.expectError(
        error.OutOfRange,
        engine.queryEnclosingSyntaxNodeRange(0, engine.graphemeCount() + 1, null),
    );
}

test "tree-sitter parents are reported faithfully, including same-range ancestors" {
    const source = "print(alpha, beta)\nx = 1\n";
    var engine = try BufferEngine.initFromText(std.testing.allocator, source, null);
    defer engine.deinit();
    try std.testing.expect(try TreeSitterTokenProvider.attachBuiltin(&engine, "lua"));
    _ = engine.refreshView("syntax", .unlimited);

    // `x` is an identifier inside a variable list with exactly its range: a range query
    // stops at the identifier, and only the parent query reaches the list.
    const name = (try engine.queryEnclosingSyntaxNode(19, null)).?;
    try std.testing.expectEqualStrings("identifier", name.kind);
    const list = (try engine.querySyntaxNodeParent(name.ref)).?;
    try std.testing.expectEqualStrings("variable_list", list.kind);
    try std.testing.expectEqual(name.start, list.start);
    try std.testing.expectEqual(name.end, list.end);
    const statement = (try engine.querySyntaxNodeParent(list.ref)).?;
    try std.testing.expectEqualStrings("assignment_statement", statement.kind);

    // The chain ends at the root, whose parent is absent, not an error.
    var current = statement;
    while (try engine.querySyntaxNodeParent(current.ref)) |parent| current = parent;
    try std.testing.expectEqual(@as(u32, 0), current.ref.id);

    // References the provider does not know are errors.
    var unknown = name.ref;
    unknown.id = 1 << 30;
    try std.testing.expectError(error.KeyError, engine.querySyntaxNodeParent(unknown));
    var foreign = name.ref;
    foreign.provider = "tree-sitter-zig";
    try std.testing.expectError(error.KeyError, engine.querySyntaxNodeParent(foreign));

    // After an edit, old references are rejected and stale views are not queried.
    try support.edit(&engine, &.{.{ .insert = .{ .pos = 0, .text = "\n" } }});
    try std.testing.expectError(error.InvalidArgument, engine.querySyntaxNodeParent(name.ref));
    try std.testing.expectError(error.ViewStale, engine.queryEnclosingSyntaxNodeRange(0, 3, null));
}
