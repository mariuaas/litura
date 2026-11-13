//! Document behavior exercised through the public package.
const std = @import("std");
const litura = @import("litura");
const support = @import("support.zig");
const buffer_types = litura.types;
const BufferEngine = litura.BufferEngine;
const views = litura.views;
const BufferOp = litura.types.BufferOp;

fn testProviderDeinitNoop(_: *anyopaque, _: std.mem.Allocator) void {}

test "view provider registration rejects overlapping views atomically" {
    const Provider = struct {
        fn tokensProvider(self: *@This()) views.ViewProvider {
            return .{ .ptr = self, .vtable = &tokens_vtable };
        }

        fn overlappingProvider(self: *@This()) views.ViewProvider {
            return .{ .ptr = self, .vtable = &overlapping_vtable };
        }

        fn stateFor(_: *anyopaque, view: []const u8, revision: u32) views.ViewState {
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

        const tokens_vtable = views.ViewProvider.VTable{
            .name = "tokens-provider",
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

        const overlapping_vtable = views.ViewProvider.VTable{
            .name = "tokens-syntax-provider",
            .views = &[_][]const u8{ "tokens", "syntax" },
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

    var token_provider = Provider{};
    try engine.registerViewProvider(token_provider.tokensProvider());

    var overlapping_provider = Provider{};
    try std.testing.expectError(
        error.AlreadyExists,
        engine.registerViewProvider(overlapping_provider.overlappingProvider()),
    );

    try std.testing.expectEqual(
        views.ViewStateKind.available,
        engine.queryViewState("tokens").kind,
    );
    try std.testing.expectEqual(views.ViewStateKind.absent, engine.queryViewState("syntax").kind);
}

test "mutation marks provider stale until token query refreshes" {
    const FakeProvider = struct {
        revision: u32 = 0,
        stale: bool = false,
        refreshes: u32 = 0,

        fn provider(self: *@This()) views.ViewProvider {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn stateFor(ptr: *anyopaque, view: []const u8, revision: u32) views.ViewState {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (!std.mem.eql(u8, view, "tokens") and !std.mem.eql(
                u8,
                view,
                "syntax",
            )) return views.ViewState.absent(view, revision);
            if (self.stale or self.revision != revision) {
                return .{ .view = view, .revision = self.revision, .kind = .stale };
            }
            return .{ .view = view, .revision = revision, .kind = .available };
        }

        fn refresh(ptr: *anyopaque, engine: *anyopaque) views.ViewState {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const typed_engine: *BufferEngine = @ptrCast(@alignCast(engine));
            self.revision = typed_engine.revision;
            self.stale = false;
            self.refreshes += 1;
            return .{ .view = "syntax", .revision = self.revision, .kind = .available };
        }

        fn onBufferEvent(ptr: *anyopaque, _: *anyopaque, _: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.stale = true;
        }

        fn tokenSpans(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            _: *anyopaque,
            _: u32,
            _: u32,
            _: u32,
        ) ![]const views.TokenSpan {
            var spans = try allocator.alloc(views.TokenSpan, 2);
            spans[0] = .{ .start = 0, .end = 3, .kind = "keyword", .style = "syntax:keyword" };
            spans[1] = .{
                .start = 4,
                .end = 7,
                .kind = "identifier",
                .style = "syntax:identifier",
            };
            return spans;
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

        fn enclosingNode(
            ptr: *anyopaque,
            engine: *anyopaque,
            _: u32,
            revision: u32,
        ) ?views.SyntaxNodeInfo {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            _ = self;
            const typed_engine: *BufferEngine = @ptrCast(@alignCast(engine));
            return .{
                .ref = .{ .provider = "fake-syntax", .revision = revision, .path = &[_]u32{0} },
                .kind = "function_definition",
                .start = 0,
                .end = typed_engine.graphemeCount(),
            };
        }

        fn nodeInfo(
            _: *anyopaque,
            engine: *anyopaque,
            ref: views.SyntaxNodeRef,
        ) anyerror!views.SyntaxNodeInfo {
            const typed_engine: *BufferEngine = @ptrCast(@alignCast(engine));
            if (ref.revision != typed_engine.revision) return error.InvalidArgument;
            return .{
                .ref = ref,
                .kind = "function_definition",
                .start = 0,
                .end = typed_engine.graphemeCount(),
            };
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
            .name = "fake-syntax",
            .views = &[_][]const u8{ "tokens", "syntax" },
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
    var provider = FakeProvider{};
    try engine.registerViewProvider(provider.provider());

    try support.edit(
        &engine,
        &[_]BufferOp{.{ .insert = .{ .pos = engine.graphemeCount(), .text = "    return 1\n" } }},
    );
    try std.testing.expectEqual(views.ViewStateKind.stale, engine.queryViewState("tokens").kind);

    const spans = try engine.queryTokenSpans(0, engine.graphemeCount(), null);
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(u32, 1), provider.refreshes);
    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqual(
        views.ViewStateKind.available,
        engine.queryViewState("tokens").kind,
    );
}

test "token queries degrade when refreshed view is unavailable" {
    const UnavailableProvider = struct {
        fn provider(self: *@This()) views.ViewProvider {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn stateFor(_: *anyopaque, view: []const u8, revision: u32) views.ViewState {
            return .{ .view = view, .revision = revision, .kind = .stale };
        }

        fn refresh(_: *anyopaque, engine: *anyopaque) views.ViewState {
            const typed_engine: *BufferEngine = @ptrCast(@alignCast(engine));
            return .{ .view = "tokens", .revision = typed_engine.revision, .kind = .unavailable };
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
            _ = allocator;
            return error.TestUnexpectedResult;
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
            .name = "unavailable",
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
    var provider = UnavailableProvider{};
    try engine.registerViewProvider(provider.provider());

    const spans = try engine.queryTokenSpans(0, engine.graphemeCount(), null);
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 0), spans.len);
}

test "syntax node refs are revision scoped" {
    const FakeProvider = struct {
        revision: u32 = 0,
        stale: bool = false,

        fn provider(self: *@This()) views.ViewProvider {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn stateFor(ptr: *anyopaque, view: []const u8, revision: u32) views.ViewState {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (!std.mem.eql(u8, view, "syntax")) return views.ViewState.absent(view, revision);
            if (self.stale or self.revision != revision) return .{
                .view = view,
                .revision = self.revision,
                .kind = .stale,
            };
            return .{ .view = view, .revision = revision, .kind = .available };
        }

        fn refresh(ptr: *anyopaque, engine: *anyopaque) views.ViewState {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const typed_engine: *BufferEngine = @ptrCast(@alignCast(engine));
            self.revision = typed_engine.revision;
            self.stale = false;
            return .{ .view = "syntax", .revision = self.revision, .kind = .available };
        }

        fn onBufferEvent(ptr: *anyopaque, _: *anyopaque, _: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.stale = true;
        }

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

        fn enclosingNode(
            _: *anyopaque,
            engine: *anyopaque,
            _: u32,
            revision: u32,
        ) ?views.SyntaxNodeInfo {
            const typed_engine: *BufferEngine = @ptrCast(@alignCast(engine));
            return .{
                .ref = .{ .provider = "fake-syntax", .revision = revision, .path = &[_]u32{0} },
                .kind = "function_definition",
                .start = 0,
                .end = typed_engine.graphemeCount(),
            };
        }

        fn nodeInfo(
            _: *anyopaque,
            engine: *anyopaque,
            ref: views.SyntaxNodeRef,
        ) anyerror!views.SyntaxNodeInfo {
            const typed_engine: *BufferEngine = @ptrCast(@alignCast(engine));
            if (ref.revision != typed_engine.revision) return error.InvalidArgument;
            return .{
                .ref = ref,
                .kind = "function_definition",
                .start = 0,
                .end = typed_engine.graphemeCount(),
            };
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
            .name = "fake-syntax",
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
    };

    var engine = try BufferEngine.initFromText(std.testing.allocator, "def foo():\n", null);
    defer engine.deinit();
    var provider = FakeProvider{};
    try engine.registerViewProvider(provider.provider());

    const node = (try engine.queryEnclosingSyntaxNode(1, null)).?;
    try support.edit(
        &engine,
        &[_]BufferOp{.{ .insert = .{ .pos = engine.graphemeCount(), .text = "    return 1\n" } }},
    );
    try std.testing.expectError(error.InvalidArgument, engine.querySyntaxNodeInfo(node.ref));
}

test "type info queries route through provider state and refresh" {
    const FakeProvider = struct {
        revision: u32 = 0,
        stale: bool = false,
        refreshes: u32 = 0,

        fn provider(self: *@This()) views.ViewProvider {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn stateFor(ptr: *anyopaque, view: []const u8, revision: u32) views.ViewState {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (!std.mem.eql(u8, view, "type_info")) return views.ViewState.absent(view, revision);
            if (self.stale or self.revision != revision) return .{
                .view = view,
                .revision = self.revision,
                .kind = .stale,
            };
            return .{ .view = view, .revision = revision, .kind = .available };
        }

        fn refresh(ptr: *anyopaque, engine: *anyopaque) views.ViewState {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const typed_engine: *BufferEngine = @ptrCast(@alignCast(engine));
            self.revision = typed_engine.revision;
            self.stale = false;
            self.refreshes += 1;
            return .{ .view = "type_info", .revision = self.revision, .kind = .available };
        }

        fn onBufferEvent(ptr: *anyopaque, _: *anyopaque, _: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.stale = true;
        }

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

        fn typeAt(_: *anyopaque, _: *anyopaque, position: u32, _: u32) anyerror!?views.TypeInfo {
            if (position == 0) return .{
                .start = 0,
                .end = 3,
                .type_text = "Int",
                .source = "fake-types",
            };
            return null;
        }

        fn hoverAt(_: *anyopaque, _: *anyopaque, position: u32, _: u32) anyerror!?views.HoverInfo {
            if (position == 1) return .{
                .start = 0,
                .end = 3,
                .content = "`abc`: demo hover",
                .source = "fake-hover",
            };
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
            .name = "fake-type-info",
            .views = &[_][]const u8{"type_info"},
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
    var provider = FakeProvider{};
    try engine.registerViewProvider(provider.provider());

    const info = (try engine.queryTypeAt(0, null)).?;
    try std.testing.expectEqualStrings("Int", info.type_text);
    try std.testing.expectEqualStrings("fake-types", info.source);
    try std.testing.expectEqual(@as(u32, 0), provider.refreshes);

    try std.testing.expect((try engine.queryTypeAt(2, null)) == null);
    try support.edit(
        &engine,
        &[_]BufferOp{.{ .insert = .{ .pos = engine.graphemeCount(), .text = "x" } }},
    );
    _ = (try engine.queryTypeAt(0, null)).?;
    try std.testing.expectEqual(@as(u32, 1), provider.refreshes);
}

test "hover queries route through provider state and refresh" {
    const FakeProvider = struct {
        revision: u32 = 0,
        stale: bool = false,
        refreshes: u32 = 0,

        fn provider(self: *@This()) views.ViewProvider {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn stateFor(ptr: *anyopaque, view: []const u8, revision: u32) views.ViewState {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (!std.mem.eql(u8, view, "hover")) return views.ViewState.absent(view, revision);
            if (self.stale or self.revision != revision) return .{
                .view = view,
                .revision = self.revision,
                .kind = .stale,
            };
            return .{ .view = view, .revision = revision, .kind = .available };
        }

        fn refresh(ptr: *anyopaque, engine: *anyopaque) views.ViewState {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const typed_engine: *BufferEngine = @ptrCast(@alignCast(engine));
            self.revision = typed_engine.revision;
            self.stale = false;
            self.refreshes += 1;
            return .{ .view = "hover", .revision = self.revision, .kind = .available };
        }

        fn onBufferEvent(ptr: *anyopaque, _: *anyopaque, _: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.stale = true;
        }

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

        fn hoverAt(_: *anyopaque, _: *anyopaque, position: u32, _: u32) anyerror!?views.HoverInfo {
            if (position == 1) return .{
                .start = 0,
                .end = 3,
                .content = "`abc`: demo hover",
                .source = "fake-hover",
            };
            return null;
        }

        fn symbolCapabilities(_: *anyopaque) ?buffer_types.SymbolCapabilities {
            return .{ .definition = true, .references = true, .rename = true };
        }

        fn definition(
            _: *anyopaque,
            _: *anyopaque,
            position: u32,
            _: u32,
        ) anyerror!views.DefinitionResult {
            if (position == 0) return .none;
            return .{ .locations = &[_]views.Location{
                .{ .range = .{ .start = 0, .end = 3 } },
                .{ .external_path = "/tmp/other.zig", .range = .{ .start = 4, .end = 7 } },
            } };
        }

        fn references(
            _: *anyopaque,
            _: *anyopaque,
            position: u32,
            _: u32,
        ) anyerror!views.ReferencesResult {
            if (position == 0) return .{ .locations = &.{} };
            return .{ .locations = &[_]views.Location{
                .{ .range = .{ .start = 1, .end = 2 } },
            } };
        }

        fn renamePrepare(
            _: *anyopaque,
            _: *anyopaque,
            position: u32,
            _: u32,
        ) anyerror!views.RenamePrepareResult {
            if (position == 0) return .none;
            return .{ .rename = .{ .start = 0, .end = 3, .placeholder = "abc" } };
        }

        const vtable = views.ViewProvider.VTable{
            .name = "fake-hover",
            .views = &[_][]const u8{"hover"},
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
    var provider = FakeProvider{};
    try engine.registerViewProvider(provider.provider());

    const info = (try engine.queryHover(1, null)).?;
    try std.testing.expectEqualStrings("`abc`: demo hover", info.content);
    try std.testing.expectEqualStrings("fake-hover", info.source);
    try std.testing.expectEqual(@as(u32, 0), provider.refreshes);

    try std.testing.expect((try engine.queryHover(2, null)) == null);
    try support.edit(
        &engine,
        &[_]BufferOp{.{ .insert = .{ .pos = engine.graphemeCount(), .text = "x" } }},
    );
    _ = (try engine.queryHover(1, null)).?;
    try std.testing.expectEqual(@as(u32, 1), provider.refreshes);
}

test "symbols queries route through provider capabilities and result variants" {
    const FakeProvider = struct {
        revision: u32 = 0,
        stale: bool = false,

        fn provider(self: *@This()) views.ViewProvider {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn stateFor(ptr: *anyopaque, view: []const u8, revision: u32) views.ViewState {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (!std.mem.eql(u8, view, "symbols")) return views.ViewState.absent(view, revision);
            if (self.stale or self.revision != revision) return .{
                .view = view,
                .revision = self.revision,
                .kind = .stale,
            };
            return .{ .view = view, .revision = revision, .kind = .available };
        }

        fn refresh(ptr: *anyopaque, engine: *anyopaque) views.ViewState {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const typed_engine: *BufferEngine = @ptrCast(@alignCast(engine));
            self.revision = typed_engine.revision;
            self.stale = false;
            return .{ .view = "symbols", .revision = self.revision, .kind = .available };
        }

        fn onBufferEvent(ptr: *anyopaque, _: *anyopaque, _: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.stale = true;
        }

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

        fn symbolCapabilities(_: *anyopaque) ?buffer_types.SymbolCapabilities {
            return .{ .definition = true, .references = true, .rename = false };
        }

        fn definition(
            _: *anyopaque,
            _: *anyopaque,
            position: u32,
            _: u32,
        ) anyerror!views.DefinitionResult {
            if (position == 0) return .none;
            return .{ .locations = &[_]views.Location{
                .{ .range = .{ .start = 0, .end = 3 } },
                .{ .external_path = "/tmp/other.zig", .range = .{ .start = 4, .end = 7 } },
            } };
        }

        fn references(
            _: *anyopaque,
            _: *anyopaque,
            position: u32,
            _: u32,
        ) anyerror!views.ReferencesResult {
            if (position == 0) return .{ .locations = &.{} };
            return .{ .locations = &[_]views.Location{.{ .range = .{ .start = 1, .end = 2 } }} };
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
            .name = "fake-symbols",
            .views = &[_][]const u8{"symbols"},
            .deinitFn = testProviderDeinitNoop,
            .stateForFn = stateFor,
            .refreshFn = refresh,
            .onBufferEventFn = onBufferEvent,
            .tokenSpansFn = tokenSpans,
            .enclosingNodeFn = enclosingNode,
            .nodeInfoFn = nodeInfo,
            .typeAtFn = typeAt,
            .hoverAtFn = hoverAt,
            .diagnosticListFn = diagnosticList,
            .semanticTokensFn = semanticTokens,
            .symbolCapabilitiesFn = symbolCapabilities,
            .definitionFn = definition,
            .referencesFn = references,
            .renamePrepareFn = renamePrepare,
        };
    };

    var engine = try BufferEngine.initFromText(std.testing.allocator, "abc", null);
    defer engine.deinit();
    var provider = FakeProvider{};
    try engine.registerViewProvider(provider.provider());

    const capabilities = engine.queryCapabilities();
    try std.testing.expectEqualStrings("symbols", capabilities.supported_views[3]);
    try std.testing.expect(capabilities.symbol_capabilities != null);
    try std.testing.expect(capabilities.symbol_capabilities.?.definition);
    try std.testing.expect(capabilities.symbol_capabilities.?.references);
    try std.testing.expect(!capabilities.symbol_capabilities.?.rename);

    const definition_none = try engine.queryDefinition(0, null);
    try std.testing.expect(definition_none == .none);

    const definition_locations = try engine.queryDefinition(1, null);
    try std.testing.expectEqual(@as(usize, 2), definition_locations.locations.len);
    try std.testing.expect(definition_locations.locations[1].external_path != null);

    const references_empty = try engine.queryReferences(0, null);
    try std.testing.expectEqual(@as(usize, 0), references_empty.locations.len);

    const rename = try engine.queryRenamePrepare(1, null);
    try std.testing.expect(rename == .not_supported);
}
