//! Document behavior exercised through the public package.
const std = @import("std");
const litura = @import("litura");
const buffer_types = litura.types;
const BufferEngine = litura.BufferEngine;
const anchors = litura.anchors;
const views = litura.views;
const BufferOp = litura.types.BufferOp;
const InteractionOp = litura.types.InteractionOp;
const Guard = litura.types.Guard;
const support = @import("support.zig");
const id = support.id;

fn testProviderDeinitNoop(_: *anyopaque, _: std.mem.Allocator) void {}

test "engine reports registered view capabilities and states" {
    const FakeProvider = struct {
        fn stateFor(_: *anyopaque, view: []const u8, revision: u32) views.ViewState {
            if (!std.mem.eql(u8, view, "tokens")) return views.ViewState.absent(view, revision);
            return .{ .view = view, .revision = revision, .kind = .available };
        }

        fn refresh(_: *anyopaque, engine: *anyopaque) views.ViewState {
            const typed_engine: *BufferEngine = @ptrCast(@alignCast(engine));
            return .{ .view = "tokens", .revision = typed_engine.revision, .kind = .available };
        }

        fn onBufferEvent(_: *anyopaque, _: *anyopaque, _: *anyopaque) void {}

        fn tokenSpans(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            _: *anyopaque,
            _: u32,
            _: u32,
            _: u32,
        ) ![]const views.TokenSpan {
            return try allocator.alloc(views.TokenSpan, 0);
        }

        fn diagnosticList(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            _: *anyopaque,
            _: ?u32,
            _: ?u32,
            _: u32,
        ) ![]const views.Diagnostic {
            return try allocator.alloc(views.Diagnostic, 0);
        }

        fn semanticTokens(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            _: *anyopaque,
            _: u32,
            _: u32,
            _: u32,
        ) ![]const views.SemanticToken {
            return try allocator.alloc(views.SemanticToken, 0);
        }

        fn enclosingNode(_: *anyopaque, _: *anyopaque, _: u32, _: u32) ?views.SyntaxNodeInfo {
            return null;
        }

        fn nodeInfo(
            _: *anyopaque,
            _: *anyopaque,
            _: views.SyntaxNodeRef,
        ) anyerror!views.SyntaxNodeInfo {
            return error.KeyError;
        }

        fn typeAt(_: *anyopaque, _: *anyopaque, _: u32, _: u32) anyerror!?views.TypeInfo {
            return null;
        }

        fn hoverAt(_: *anyopaque, _: *anyopaque, _: u32, _: u32) anyerror!?views.HoverInfo {
            return null;
        }

        fn symbolCapabilities(_: *anyopaque) ?buffer_types.SymbolCapabilities {
            return null;
        }

        fn definition(
            _: *anyopaque,
            _: *anyopaque,
            _: u32,
            _: u32,
        ) anyerror!views.DefinitionResult {
            return .not_supported;
        }

        fn references(
            _: *anyopaque,
            _: *anyopaque,
            _: u32,
            _: u32,
        ) anyerror!views.ReferencesResult {
            return .not_supported;
        }

        fn renamePrepare(
            _: *anyopaque,
            _: *anyopaque,
            _: u32,
            _: u32,
        ) anyerror!views.RenamePrepareResult {
            return .not_supported;
        }

        const vtable = views.ViewProvider.VTable{
            .name = "fake-tokens",
            .views = &[_][]const u8{"tokens"},
            .deinitFn = testProviderDeinitNoop,
            .stateForFn = stateFor,
            .refreshFn = refresh,
            .onBufferEventFn = onBufferEvent,
            .tokenSpansFn = tokenSpans,
            .diagnosticListFn = diagnosticList,
            .semanticTokensFn = semanticTokens,
            .enclosingNodeFn = enclosingNode,
            .nodeInfoFn = nodeInfo,
            .typeAtFn = typeAt,
            .hoverAtFn = hoverAt,
            .symbolCapabilitiesFn = symbolCapabilities,
            .definitionFn = definition,
            .referencesFn = references,
            .renamePrepareFn = renamePrepare,
        };
    };

    var engine = try BufferEngine.initFromText(std.testing.allocator, "def foo():\n", null);
    defer engine.deinit();
    var provider = views.ViewProvider{ .ptr = undefined, .vtable = &FakeProvider.vtable };
    provider.ptr = @ptrCast(&provider);
    try engine.registerViewProvider(provider);

    const capabilities = engine.queryCapabilities();
    try std.testing.expect(capabilities.symbol_capabilities == null);
    try std.testing.expectEqualStrings("tokens", capabilities.supported_views[3]);
    try std.testing.expectEqual(
        views.ViewStateKind.available,
        engine.queryViewState("tokens").kind,
    );
    try std.testing.expectEqual(views.ViewStateKind.absent, engine.queryViewState("syntax").kind);
}

test "registerViewProviders rejects conflicting batch during preflight" {
    const Provider = struct {
        fn syntaxProvider(self: *@This()) views.ViewProvider {
            return .{ .ptr = self, .vtable = &syntax_vtable };
        }

        fn tokensProvider(self: *@This()) views.ViewProvider {
            return .{ .ptr = self, .vtable = &tokens_vtable };
        }

        fn stateFor(_: *anyopaque, view: []const u8, revision: u32) views.ViewState {
            return .{ .view = view, .revision = revision, .kind = .available };
        }

        fn refresh(_: *anyopaque, engine: *anyopaque) views.ViewState {
            const typed_engine: *BufferEngine = @ptrCast(@alignCast(engine));
            return .{ .view = "syntax", .revision = typed_engine.revision, .kind = .available };
        }

        fn onBufferEvent(_: *anyopaque, _: *anyopaque, _: *anyopaque) void {}

        fn tokenSpans(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            _: *anyopaque,
            _: u32,
            _: u32,
            _: u32,
        ) ![]const views.TokenSpan {
            return try allocator.alloc(views.TokenSpan, 0);
        }

        fn diagnosticList(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            _: *anyopaque,
            _: ?u32,
            _: ?u32,
            _: u32,
        ) ![]const views.Diagnostic {
            return try allocator.alloc(views.Diagnostic, 0);
        }

        fn semanticTokens(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            _: *anyopaque,
            _: u32,
            _: u32,
            _: u32,
        ) ![]const views.SemanticToken {
            return try allocator.alloc(views.SemanticToken, 0);
        }

        fn enclosingNode(_: *anyopaque, _: *anyopaque, _: u32, _: u32) ?views.SyntaxNodeInfo {
            return null;
        }

        fn nodeInfo(
            _: *anyopaque,
            _: *anyopaque,
            _: views.SyntaxNodeRef,
        ) anyerror!views.SyntaxNodeInfo {
            return error.KeyError;
        }

        fn typeAt(_: *anyopaque, _: *anyopaque, _: u32, _: u32) anyerror!?views.TypeInfo {
            return null;
        }

        fn hoverAt(_: *anyopaque, _: *anyopaque, _: u32, _: u32) anyerror!?views.HoverInfo {
            return null;
        }

        fn symbolCapabilities(_: *anyopaque) ?buffer_types.SymbolCapabilities {
            return null;
        }

        fn definition(
            _: *anyopaque,
            _: *anyopaque,
            _: u32,
            _: u32,
        ) anyerror!views.DefinitionResult {
            return .not_supported;
        }

        fn references(
            _: *anyopaque,
            _: *anyopaque,
            _: u32,
            _: u32,
        ) anyerror!views.ReferencesResult {
            return .not_supported;
        }

        fn renamePrepare(
            _: *anyopaque,
            _: *anyopaque,
            _: u32,
            _: u32,
        ) anyerror!views.RenamePrepareResult {
            return .not_supported;
        }

        const syntax_vtable = views.ViewProvider.VTable{
            .name = "syntax-only",
            .views = &[_][]const u8{"syntax"},
            .deinitFn = testProviderDeinitNoop,
            .stateForFn = stateFor,
            .refreshFn = refresh,
            .onBufferEventFn = onBufferEvent,
            .tokenSpansFn = tokenSpans,
            .diagnosticListFn = diagnosticList,
            .semanticTokensFn = semanticTokens,
            .enclosingNodeFn = enclosingNode,
            .nodeInfoFn = nodeInfo,
            .typeAtFn = typeAt,
            .hoverAtFn = hoverAt,
            .symbolCapabilitiesFn = symbolCapabilities,
            .definitionFn = definition,
            .referencesFn = references,
            .renamePrepareFn = renamePrepare,
        };

        const tokens_vtable = views.ViewProvider.VTable{
            .name = "tokens-only",
            .views = &[_][]const u8{"tokens"},
            .deinitFn = testProviderDeinitNoop,
            .stateForFn = stateFor,
            .refreshFn = refresh,
            .onBufferEventFn = onBufferEvent,
            .tokenSpansFn = tokenSpans,
            .diagnosticListFn = diagnosticList,
            .semanticTokensFn = semanticTokens,
            .enclosingNodeFn = enclosingNode,
            .nodeInfoFn = nodeInfo,
            .typeAtFn = typeAt,
            .hoverAtFn = hoverAt,
            .symbolCapabilitiesFn = symbolCapabilities,
            .definitionFn = definition,
            .referencesFn = references,
            .renamePrepareFn = renamePrepare,
        };
    };

    var engine = try BufferEngine.initFromText(std.testing.allocator, "abc", null);
    defer engine.deinit();

    var existing_tokens = Provider{};
    try engine.registerViewProvider(existing_tokens.tokensProvider());

    var syntax_provider = Provider{};
    var conflicting_tokens = Provider{};
    try std.testing.expectError(
        error.AlreadyExists,
        engine.registerViewProviders(&.{
            syntax_provider.syntaxProvider(),
            conflicting_tokens.tokensProvider(),
        }),
    );

    try std.testing.expectEqual(
        views.ViewStateKind.available,
        engine.queryViewState("tokens").kind,
    );
    try std.testing.expectEqual(views.ViewStateKind.absent, engine.queryViewState("syntax").kind);
}

test "BufferEngine init and deinit" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "hello world", null);
    defer engine.deinit();

    try std.testing.expectEqual(@as(u32, 11), engine.graphemeCount());
    const info = try engine.queryPosition(6);
    try std.testing.expectEqual(@as(u32, 0), info.line);
    try std.testing.expectEqual(@as(u32, 6), info.col);
}

test "queryRegion clips visible rows before copying text" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "abcdef\nshort\nxyz", null);
    defer engine.deinit();

    var region = try engine.queryRegion(0, 2, 2, 3, 5);
    defer region.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0), region.start_line);
    try std.testing.expectEqual(@as(u32, 3), region.line_count);
    try std.testing.expect(region.budget_exhausted);
    try std.testing.expectEqual(@as(usize, 2), region.rows.len);

    try std.testing.expectEqual(@as(u32, 0), region.rows[0].line);
    try std.testing.expectEqual(@as(u32, 0), region.rows[0].full_start);
    try std.testing.expectEqual(@as(u32, 6), region.rows[0].full_end);
    try std.testing.expectEqual(@as(u32, 2), region.rows[0].slice_start);
    try std.testing.expectEqual(@as(u32, 5), region.rows[0].slice_end);
    try std.testing.expect(region.rows[0].truncated_left);
    try std.testing.expect(region.rows[0].truncated_right);
    try std.testing.expectEqualStrings("cde", region.rows[0].text);

    try std.testing.expectEqual(@as(u32, 1), region.rows[1].line);
    try std.testing.expectEqual(@as(u32, 7), region.rows[1].full_start);
    try std.testing.expectEqual(@as(u32, 12), region.rows[1].full_end);
    try std.testing.expectEqual(@as(u32, 9), region.rows[1].slice_start);
    try std.testing.expectEqual(@as(u32, 11), region.rows[1].slice_end);
    try std.testing.expect(region.rows[1].truncated_left);
    try std.testing.expect(region.rows[1].truncated_right);
    try std.testing.expectEqualStrings("or", region.rows[1].text);
}

test "buffer engine lifecycle flags track dirty undo and redo state" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "abc", null);
    defer engine.deinit();

    try std.testing.expect(!engine.dirty());
    try std.testing.expect(!engine.canUndo());
    try std.testing.expect(!engine.canRedo());

    try support.edit(&engine, &[_]BufferOp{.{ .insert = .{ .pos = 1, .text = "X" } }});
    try std.testing.expect(engine.dirty());
    try std.testing.expect(engine.canUndo());
    try std.testing.expect(!engine.canRedo());

    try support.undo(&engine);
    try std.testing.expect(engine.canRedo());
}

test "buffer engine fromFile reads existing file and tracks path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "buffer.txt", .data = "hello\nworld" });

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/buffer.txt", .{dir_buf[0..dir_len]});

    var engine = try BufferEngine.fromFile(allocator, path);
    defer engine.deinit();

    const text = try engine.getText();
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello\nworld", text);
    try std.testing.expectEqualStrings(path, engine.path.?);
    try std.testing.expect(!engine.dirty());
}

test "buffer engine fromFile initializes empty buffer for missing file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/missing.txt", .{dir_buf[0..dir_len]});

    var engine = try BufferEngine.fromFile(allocator, path);
    defer engine.deinit();

    try std.testing.expectEqual(@as(u32, 0), engine.graphemeCount());
    try std.testing.expectEqualStrings(path, engine.path.?);
    try std.testing.expect(!engine.dirty());
}

test "buffer engine save writes current text and clears dirty state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/saved.txt", .{dir_buf[0..dir_len]});

    var engine = try BufferEngine.initFromText(allocator, "alpha", null);
    defer engine.deinit();

    try support.edit(&engine, &[_]BufferOp{.{ .insert = .{ .pos = 5, .text = "!" } }});
    try std.testing.expect(engine.dirty());

    try engine.save(path);
    try std.testing.expect(!engine.dirty());
    try std.testing.expectEqualStrings(path, engine.path.?);

    const saved = try tmp.dir.readFileAlloc(std.testing.io, "saved.txt", allocator, .limited(1024));
    defer allocator.free(saved);
    try std.testing.expectEqualStrings("alpha!", saved);
}

test "a failed save keeps the stored path and saved revision" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "alpha", "kept.txt");
    defer engine.deinit();
    try support.edit(&engine, &[_]BufferOp{.{ .insert = .{ .pos = 5, .text = "!" } }});

    try std.testing.expect(std.meta.isError(engine.save("missing-directory/never/saved.txt")));
    try std.testing.expectEqualStrings("kept.txt", engine.path.?);
    try std.testing.expectEqual(@as(u32, 0), engine.saved_revision);
    try std.testing.expect(engine.dirty());
}

test "buffer engine save without path fails" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "alpha", null);
    defer engine.deinit();

    try std.testing.expectError(error.InvalidArgument, engine.save(null));
}

test "BufferEngine delegates search to piece table" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "abc abc", null);
    defer engine.deinit();

    var next_0 = (try engine.findNext("abc", 0)).?;
    defer next_0.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), next_0.start);
    try std.testing.expectEqual(@as(u32, 3), next_0.end);
    try std.testing.expectEqualStrings("abc", next_0.text);

    var next_1 = (try engine.findNext("abc", 1)).?;
    defer next_1.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 4), next_1.start);
    try std.testing.expectEqual(@as(u32, 7), next_1.end);

    var prev_end = (try engine.findPrevious("abc", null)).?;
    defer prev_end.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 4), prev_end.start);
    try std.testing.expectEqual(@as(u32, 7), prev_end.end);

    var prev_mid = (try engine.findPrevious("abc", 4)).?;
    defer prev_mid.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), prev_mid.start);
    try std.testing.expectEqual(@as(u32, 3), prev_mid.end);
}

test "buffer engine search rejects empty query" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "abc", null);
    defer engine.deinit();

    try std.testing.expectError(error.InvalidArgument, engine.findNext("", 0));
    try std.testing.expectError(error.InvalidArgument, engine.findPrevious("", null));
}

test "a committed buffer mutation reports its revisions in its block" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "abc", null);
    defer engine.deinit();

    var block = try support.editBlock(
        &engine,
        &[_]BufferOp{.{ .insert = .{ .pos = 1, .text = "X" } }},
    );
    defer block.deinit(std.testing.allocator);
    const event = block.transition.edit.?;
    try std.testing.expectEqual(@as(u32, 0), event.old_revision);
    try std.testing.expectEqual(@as(u32, 1), event.new_revision);
    try std.testing.expectEqual(litura.events.EditClass.insert, event.edit_class);

    const text = try engine.getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("aXbc", text);
}

test "a buffer mutation without operations is rejected" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "abc", null);
    defer engine.deinit();

    var result = try engine.submit(
        .{
            .id = id,
            .origin = engine.revision,
            .payload = .{ .buffer_mutation = .{ .ops = &.{} } },
        },
    );
    try support.expectRejected(&engine, &result, .invalid, "apply requires at least one operation");
    try std.testing.expectEqual(@as(u64, 0), engine.next_sequence);
}

test "submit rejects stale buffer origin" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "abc", null);
    defer engine.deinit();

    var result = try engine.submit(.{
        .id = id,
        .payload = .{
            .buffer_mutation = .{ .ops = &[_]BufferOp{.{ .insert = .{ .pos = 1, .text = "x" } }} },
        },
        .origin = 99,
    });
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .rejected => |report| {
            try std.testing.expectEqual(buffer_types.ValidationVerdict.stale, report.verdict);
            try std.testing.expectEqualStrings(
                "buffer revision 99 is stale; current revision is 0",
                report.message,
            );
        },
        else => return error.TestUnexpectedResult,
    }
}

test "submit applies interaction mutation and bumps one revision" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "abc", null);
    defer engine.deinit();

    const session_id, const cursor = try support.caret(&engine, 1);

    var result = try engine.submit(.{
        .id = id,
        .origin = engine.revision,
        .payload = .{ .interaction_mutation = .{
            .session_id = session_id,
            .origin = try engine.interactionRevision(session_id),
            .ops = &[_]InteractionOp{
                .{
                    .set_selections = .{
                        .selections = &.{support.placeSpec(cursor, .{ .position = 2 }, null)},
                    },
                },
                .{ .set_selections = .{ .selections = &.{
                    support.placeSpec(cursor, .{ .anchor = cursor }, .{ .position = 0 }),
                } } },
            },
        } },
    });
    defer result.deinit(std.testing.allocator);

    const transition = result.committed.transition;
    try std.testing.expectEqual(@as(?litura.events.EditEvent, null), transition.edit);
    try std.testing.expectEqual(@as(usize, 1), transition.interactions.len);
    const interaction = transition.interactions[0];
    try std.testing.expectEqual(@as(u32, session_id), interaction.session);
    try std.testing.expectEqual(@as(u32, 0), interaction.old_revision);
    try std.testing.expectEqual(@as(u32, 1), interaction.new_revision);

    try std.testing.expectEqual(@as(?u32, 2), (try engine.queryAnchor(cursor)).position);
    const mark = (try support.mark(&engine, session_id)).?;
    try std.testing.expectEqual(@as(?u32, 0), (try engine.queryAnchor(mark)).position);
}

test "submit blocks guarded buffer mutation" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "abcde", null);
    defer engine.deinit();

    const anchor_id = try engine.createAnchor(2, .weak);
    try support.edit(&engine, &[_]BufferOp{.{ .delete = .{ .start = 1, .end = 4 } }});

    const guards = [_]Guard{.{ .anchor_liveness = .{ .anchor = anchor_id } }};
    var result = try engine.submit(.{
        .id = id,
        .origin = engine.revision,
        .payload = .{
            .buffer_mutation = .{ .ops = &[_]BufferOp{.{ .insert = .{ .pos = 0, .text = "x" } }} },
        },
        .guards = &guards,
    });
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .rejected => |report| {
            try std.testing.expectEqual(buffer_types.ValidationVerdict.anchor_dead, report.verdict);
            try std.testing.expectEqualStrings("anchor 1 is not live", report.message);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "submit undo replays inverse ops in reverse mutation order" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "abcdef", null);
    defer engine.deinit();

    var apply_result = try engine.submit(.{
        .id = id,
        .origin = engine.revision,
        .payload = .{ .buffer_mutation = .{ .ops = &[_]BufferOp{
            .{ .delete = .{ .start = 1, .end = 3 } },
            .{ .replace = .{ .start = 2, .end = 4, .text = "Z" } },
        } } },
    });
    defer apply_result.deinit(std.testing.allocator);

    const changed = try engine.getText();
    defer std.testing.allocator.free(changed);
    try std.testing.expectEqualStrings("adZ", changed);

    var undo_result = try engine.submit(.{
        .id = id,
        .origin = engine.revision,
        .payload = .{ .undo = .{} },
        .label = "undo",
    });
    defer undo_result.deinit(std.testing.allocator);

    const restored = try engine.getText();
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings("abcdef", restored);
}

test "insert rebases anchors with stickiness" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "abc", null);
    defer engine.deinit();

    const before_doc = try engine.createAnchor(0, .sticky);
    const at_insert_weak = try engine.createAnchor(1, .weak);
    const at_insert_sticky = try engine.createAnchor(1, .sticky);
    const after_insert = try engine.createAnchor(2, .sticky);

    const ops = [_]BufferOp{.{ .insert = .{ .pos = 1, .text = "XY" } }};
    try support.edit(&engine, &ops);

    try std.testing.expectEqual(@as(?u32, 0), (try engine.queryAnchor(before_doc)).position);
    try std.testing.expectEqual(@as(?u32, 1), (try engine.queryAnchor(at_insert_weak)).position);
    try std.testing.expectEqual(@as(?u32, 3), (try engine.queryAnchor(at_insert_sticky)).position);
    try std.testing.expectEqual(@as(?u32, 4), (try engine.queryAnchor(after_insert)).position);
}

test "delete rebases and kills anchors" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "abcdef", null);
    defer engine.deinit();

    const before_delete = try engine.createAnchor(1, .sticky);
    const at_start = try engine.createAnchor(2, .sticky);
    const inside_delete = try engine.createAnchor(3, .sticky);
    const inside_delete_weak = try engine.createAnchor(3, .weak);
    const at_end = try engine.createAnchor(4, .sticky);
    const after_delete = try engine.createAnchor(5, .sticky);

    const ops = [_]BufferOp{.{ .delete = .{ .start = 2, .end = 4 } }};
    try support.edit(&engine, &ops);

    try std.testing.expectEqual(@as(?u32, 1), (try engine.queryAnchor(before_delete)).position);
    try std.testing.expectEqual(@as(?u32, 2), (try engine.queryAnchor(at_start)).position);

    const id_info = try engine.queryAnchor(inside_delete);
    try std.testing.expectEqual(@as(?u32, 2), id_info.position);
    try std.testing.expectEqual(anchors.HandleStatus.live, id_info.status);

    const idw_info = try engine.queryAnchor(inside_delete_weak);
    try std.testing.expectEqual(@as(?u32, null), idw_info.position);
    try std.testing.expectEqual(anchors.HandleStatus.dead, idw_info.status);

    try std.testing.expectEqual(@as(?u32, 2), (try engine.queryAnchor(at_end)).position);
    try std.testing.expectEqual(@as(?u32, 3), (try engine.queryAnchor(after_delete)).position);
}

test "multi op apply rebases anchors sequentially" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "abc", null);
    defer engine.deinit();

    const anchor_id = try engine.createAnchor(1, .sticky);

    const ops = [_]BufferOp{
        .{ .insert = .{ .pos = 0, .text = "x" } },
        .{ .delete = .{ .start = 1, .end = 2 } },
    };
    try support.edit(&engine, &ops);

    const text = try engine.getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("xbc", text);

    try std.testing.expectEqual(@as(?u32, 1), (try engine.queryAnchor(anchor_id)).position);
    try std.testing.expectEqual(@as(u32, 1), engine.revision);
}

test "dead anchors are inert under later edits" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "abcde", null);
    defer engine.deinit();

    const anchor_id = try engine.createAnchor(2, .weak);

    const ops = [_]BufferOp{.{ .delete = .{ .start = 1, .end = 4 } }};
    try support.edit(&engine, &ops);

    try std.testing.expectEqual(
        anchors.HandleStatus.dead,
        (try engine.queryAnchor(anchor_id)).status,
    );

    const ops2 = [_]BufferOp{.{ .insert = .{ .pos = 0, .text = "XYZ" } }};
    try support.edit(&engine, &ops2);

    try std.testing.expectEqual(
        anchors.HandleStatus.dead,
        (try engine.queryAnchor(anchor_id)).status,
    );
}

test "undo delete resurrects weak anchors from deletion metadata" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "abcdef", null);
    defer engine.deinit();

    const weak_anchor = try engine.createAnchor(3, .weak);

    const ops = [_]BufferOp{.{ .delete = .{ .start = 2, .end = 4 } }};
    try support.edit(&engine, &ops);

    try std.testing.expectEqual(@as(usize, 1), engine.undo_stack.items.len);
    try std.testing.expectEqual(@as(usize, 1), engine.undo_stack.items[0].deletion_metas.len);
    try std.testing.expectEqual(
        anchors.HandleStatus.dead,
        (try engine.queryAnchor(weak_anchor)).status,
    );

    try support.undo(&engine);

    const resurrected = try engine.queryAnchor(weak_anchor);
    try std.testing.expectEqual(anchors.HandleStatus.live, resurrected.status);
    try std.testing.expectEqual(@as(?u32, 3), resurrected.position);
    try std.testing.expectEqual(@as(?anchors.AnchorStickiness, .weak), resurrected.stickiness);

    try std.testing.expectEqual(@as(usize, 1), engine.redo_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), engine.redo_stack.items[0].deletion_metas.len);

    try support.redo(&engine);
    try std.testing.expectEqual(
        anchors.HandleStatus.dead,
        (try engine.queryAnchor(weak_anchor)).status,
    );
}

test "undo replace resurrects weak anchors inside replaced span" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "abcdef", null);
    defer engine.deinit();

    const weak_anchor = try engine.createAnchor(3, .weak);

    const ops = [_]BufferOp{.{ .replace = .{ .start = 2, .end = 4, .text = "XY" } }};
    try support.edit(&engine, &ops);

    try std.testing.expectEqual(
        anchors.HandleStatus.dead,
        (try engine.queryAnchor(weak_anchor)).status,
    );
    try std.testing.expectEqual(@as(usize, 1), engine.undo_stack.items[0].deletion_metas.len);

    try support.undo(&engine);

    const resurrected = try engine.queryAnchor(weak_anchor);
    try std.testing.expectEqual(anchors.HandleStatus.live, resurrected.status);
    try std.testing.expectEqual(@as(?u32, 3), resurrected.position);
    try std.testing.expectEqual(@as(?anchors.AnchorStickiness, .weak), resurrected.stickiness);
}

test "multi-delete commit retains one deletion meta per deleted span" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "abcdef", null);
    defer engine.deinit();

    const c_anchor = try engine.createAnchor(2, .weak);
    const f_anchor = try engine.createAnchor(5, .weak);

    const ops = [_]BufferOp{
        .{ .delete = .{ .start = 1, .end = 3 } },
        .{ .delete = .{ .start = 2, .end = 4 } },
    };
    try support.edit(&engine, &ops);

    try std.testing.expectEqual(@as(usize, 2), engine.undo_stack.items[0].deletion_metas.len);
    try std.testing.expectEqual(
        anchors.HandleStatus.dead,
        (try engine.queryAnchor(c_anchor)).status,
    );
    try std.testing.expectEqual(
        anchors.HandleStatus.dead,
        (try engine.queryAnchor(f_anchor)).status,
    );

    try support.undo(&engine);

    const c_info = try engine.queryAnchor(c_anchor);
    try std.testing.expectEqual(anchors.HandleStatus.live, c_info.status);
    try std.testing.expectEqual(@as(?u32, 2), c_info.position);

    const f_info = try engine.queryAnchor(f_anchor);
    try std.testing.expectEqual(anchors.HandleStatus.live, f_info.status);
    try std.testing.expectEqual(@as(?u32, 5), f_info.position);
}

test "undo insert and redo" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "abc", null);
    defer engine.deinit();

    try support.edit(&engine, &.{.{ .insert = .{ .pos = 1, .text = "X" } }});
    var undone = try engine.submit(
        .{
            .id = .{ .value = 41 },
            .origin = engine.revision,
            .payload = .{ .undo = .{} },
            .label = "undo",
        },
    );
    defer undone.deinit(std.testing.allocator);
    try support.expectText(&engine, "abc");
    try std.testing.expectEqual(@as(u32, 2), engine.revision);
    try std.testing.expectEqual(@as(u128, 41), undone.committed.transition.intent.value);
    try std.testing.expectEqualStrings("undo", undone.committed.transition.label.?);
    try std.testing.expectEqual(@as(usize, 0), engine.undo_stack.items.len);
    try std.testing.expectEqual(@as(usize, 1), engine.redo_stack.items.len);

    try support.redo(&engine);
    try support.expectText(&engine, "aXbc");
    try std.testing.expectEqual(@as(u32, 3), engine.revision);
    try std.testing.expectEqual(@as(usize, 1), engine.undo_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), engine.redo_stack.items.len);
}

test "undo redo empty rejects" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "abc", null);
    defer engine.deinit();

    var undo = try engine.submit(
        .{ .id = id, .origin = engine.revision, .payload = .{ .undo = .{} } },
    );
    try support.expectRejected(&engine, &undo, .invalid, "nothing to undo");
    var redo = try engine.submit(
        .{ .id = id, .origin = engine.revision, .payload = .{ .redo = .{} } },
    );
    try support.expectRejected(&engine, &redo, .invalid, "nothing to redo");
    try std.testing.expectEqual(@as(u32, 0), engine.revision);
}
