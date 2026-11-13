//! Derived document views and the provider callback contract.

const std = @import("std");
const buffer_types = @import("buffer_types.zig");
const events = @import("events.zig");
const BufferEngine = @import("buffer_engine.zig").BufferEngine;

/// Whether a block passed to onBufferEvent changed the document text. Interaction and
/// lifecycle blocks do not, so views derived from text stay current across them.
pub fn changesText(block: *anyopaque) bool {
    const typed: *const events.Block = @ptrCast(@alignCast(block));
    return switch (typed.*) {
        .transition => |transition| transition.edit != null,
        .lifecycle => false,
    };
}

pub const ViewStateKind = enum {
    available,
    absent,
    stale,
    partial,
    unavailable,
};

/// Borrows view and message strings from the provider; no ownership is transferred.
pub const ViewState = struct {
    view: []const u8,
    revision: ?u32,
    kind: ViewStateKind,
    message: []const u8 = "",

    pub fn absent(view: []const u8, revision: u32) ViewState {
        return .{
            .view = view,
            .revision = revision,
            .kind = .absent,
        };
    }
};

pub const TokenSpan = struct {
    start: u32,
    end: u32,
    kind: []const u8,
    style: []const u8,
};

pub const Diagnostic = struct {
    start: u32,
    end: u32,
    severity: u8,
    code: ?[]const u8 = null,
    source: []const u8,
    message: []const u8,
};

pub const SemanticToken = struct {
    start: u32,
    end: u32,
    type_name: []const u8,
    modifiers: []const []const u8,
};

/// Borrows provider identity and a provider-owned path at one document revision.
/// For the Tree-sitter provider, refresh or destruction invalidates the path.
pub const SyntaxNodeRef = struct {
    provider: []const u8,
    revision: u32,
    path: []const u32,
};

pub const SyntaxNodeInfo = struct {
    ref: SyntaxNodeRef,
    kind: []const u8,
    start: u32,
    end: u32,
    is_named: bool = true,
};

pub const TypeInfo = struct {
    start: u32,
    end: u32,
    type_text: []const u8,
    source: []const u8,
};

pub const HoverInfo = struct {
    start: u32,
    end: u32,
    content: []const u8,
    source: []const u8,
};

pub const Location = struct {
    external_path: ?[]const u8 = null,
    range: buffer_types.Range,
};

pub const RenameInfo = struct {
    start: u32,
    end: u32,
    placeholder: []const u8,
};

pub const DefinitionResult = union(enum) {
    not_supported,
    none,
    locations: []const Location,
};

pub const ReferencesResult = union(enum) {
    not_supported,
    locations: []const Location,
};

pub const RenamePrepareResult = union(enum) {
    not_supported,
    none,
    rename: RenameInfo,
};

/// Borrows an implementation pointer and callback table. View names must remain valid
/// for the entire registration. Successful registration transfers deinit responsibility
/// to the engine, which calls it once per unique implementation pointer.
/// The block passed to onBufferEvent is borrowed only for the callback duration.
/// Token/diagnostic/semantic-token result arrays use the supplied allocator; nested
/// strings and syntax/type/hover/symbol results retain provider-defined lifetimes.
pub const ViewProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: []const u8,
        views: []const []const u8,
        deinitFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
        stateForFn: *const fn (ptr: *anyopaque, view: []const u8, revision: u32) ViewState,
        refreshFn: *const fn (ptr: *anyopaque, engine: *anyopaque) ViewState,
        /// `block` points to a `*const events.Block`.
        onBufferEventFn: *const fn (ptr: *anyopaque, engine: *anyopaque, block: *anyopaque) void,
        tokenSpansFn: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            engine: *anyopaque,
            start: u32,
            end: u32,
            revision: u32,
        ) anyerror![]const TokenSpan,
        diagnosticListFn: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            engine: *anyopaque,
            start: ?u32,
            end: ?u32,
            revision: u32,
        ) anyerror![]const Diagnostic,
        semanticTokensFn: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            engine: *anyopaque,
            start: u32,
            end: u32,
            revision: u32,
        ) anyerror![]const SemanticToken,
        enclosingNodeFn: *const fn (
            ptr: *anyopaque,
            engine: *anyopaque,
            position: u32,
            revision: u32,
        ) ?SyntaxNodeInfo,
        nodeInfoFn: *const fn (
            ptr: *anyopaque,
            engine: *anyopaque,
            ref: SyntaxNodeRef,
        ) anyerror!SyntaxNodeInfo,
        typeAtFn: *const fn (
            ptr: *anyopaque,
            engine: *anyopaque,
            position: u32,
            revision: u32,
        ) anyerror!?TypeInfo,
        hoverAtFn: *const fn (
            ptr: *anyopaque,
            engine: *anyopaque,
            position: u32,
            revision: u32,
        ) anyerror!?HoverInfo,
        symbolCapabilitiesFn: *const fn (ptr: *anyopaque) ?buffer_types.SymbolCapabilities,
        definitionFn: *const fn (
            ptr: *anyopaque,
            engine: *anyopaque,
            position: u32,
            revision: u32,
        ) anyerror!DefinitionResult,
        referencesFn: *const fn (
            ptr: *anyopaque,
            engine: *anyopaque,
            position: u32,
            revision: u32,
        ) anyerror!ReferencesResult,
        renamePrepareFn: *const fn (
            ptr: *anyopaque,
            engine: *anyopaque,
            position: u32,
            revision: u32,
        ) anyerror!RenamePrepareResult,
    };

    pub fn deinit(self: ViewProvider, allocator: std.mem.Allocator) void {
        self.vtable.deinitFn(self.ptr, allocator);
    }

    pub fn name(self: ViewProvider) []const u8 {
        return self.vtable.name;
    }

    pub fn views(self: ViewProvider) []const []const u8 {
        return self.vtable.views;
    }

    pub fn stateFor(self: ViewProvider, view: []const u8, revision: u32) ViewState {
        return self.vtable.stateForFn(self.ptr, view, revision);
    }

    pub fn refresh(self: ViewProvider, engine: *anyopaque) ViewState {
        return self.vtable.refreshFn(self.ptr, engine);
    }

    /// Hands the provider a published block, once per distinct provider, after the
    /// whole transition or lifecycle request is published. `block` points to a
    /// `*const events.Block`, borrowed for the call. Notification cannot fail, so work
    /// that can (reparsing, for instance) belongs in `refresh`; a provider that cannot
    /// keep up reports a stale state instead. The provider may read the engine but must
    /// not change it: every state-changing entry point returns error.ReentrantMutation.
    pub fn onBufferEvent(self: ViewProvider, engine: *anyopaque, block: *anyopaque) void {
        self.vtable.onBufferEventFn(self.ptr, engine, block);
    }

    pub fn tokenSpans(
        self: ViewProvider,
        allocator: std.mem.Allocator,
        engine: *anyopaque,
        start: u32,
        end: u32,
        revision: u32,
    ) ![]const TokenSpan {
        return self.vtable.tokenSpansFn(self.ptr, allocator, engine, start, end, revision);
    }

    pub fn enclosingNode(
        self: ViewProvider,
        engine: *anyopaque,
        position: u32,
        revision: u32,
    ) ?SyntaxNodeInfo {
        return self.vtable.enclosingNodeFn(self.ptr, engine, position, revision);
    }

    pub fn diagnosticList(
        self: ViewProvider,
        allocator: std.mem.Allocator,
        engine: *anyopaque,
        start: ?u32,
        end: ?u32,
        revision: u32,
    ) ![]const Diagnostic {
        return self.vtable.diagnosticListFn(self.ptr, allocator, engine, start, end, revision);
    }

    pub fn semanticTokens(
        self: ViewProvider,
        allocator: std.mem.Allocator,
        engine: *anyopaque,
        start: u32,
        end: u32,
        revision: u32,
    ) ![]const SemanticToken {
        return self.vtable.semanticTokensFn(self.ptr, allocator, engine, start, end, revision);
    }

    pub fn nodeInfo(self: ViewProvider, engine: *anyopaque, ref: SyntaxNodeRef) !SyntaxNodeInfo {
        return self.vtable.nodeInfoFn(self.ptr, engine, ref);
    }

    pub fn typeAt(self: ViewProvider, engine: *anyopaque, position: u32, revision: u32) !?TypeInfo {
        return self.vtable.typeAtFn(self.ptr, engine, position, revision);
    }

    pub fn hoverAt(
        self: ViewProvider,
        engine: *anyopaque,
        position: u32,
        revision: u32,
    ) !?HoverInfo {
        return self.vtable.hoverAtFn(self.ptr, engine, position, revision);
    }

    pub fn symbolCapabilities(self: ViewProvider) ?buffer_types.SymbolCapabilities {
        return self.vtable.symbolCapabilitiesFn(self.ptr);
    }

    pub fn definition(
        self: ViewProvider,
        engine: *anyopaque,
        position: u32,
        revision: u32,
    ) !DefinitionResult {
        return self.vtable.definitionFn(self.ptr, engine, position, revision);
    }

    pub fn references(
        self: ViewProvider,
        engine: *anyopaque,
        position: u32,
        revision: u32,
    ) !ReferencesResult {
        return self.vtable.referencesFn(self.ptr, engine, position, revision);
    }

    pub fn renamePrepare(
        self: ViewProvider,
        engine: *anyopaque,
        position: u32,
        revision: u32,
    ) !RenamePrepareResult {
        return self.vtable.renamePrepareFn(self.ptr, engine, position, revision);
    }
};

/// Fixed token spans for one document revision. Borrows spans and their strings; the
/// instance must outlive its registration. Its deinit callback is a no-op. The spans
/// cannot follow edits: once the engine moves past `revision`, the provider reports
/// itself stale, and refresh keeps it stale rather than relabelling old spans as
/// current. Replace `spans` and `revision` to describe a new revision.
pub const StaticTokenProvider = struct {
    spans: []const TokenSpan,
    revision: u32 = 0,
    stale: bool = false,

    fn deinitNoop(_: *anyopaque, _: std.mem.Allocator) void {}

    const vtable = ViewProvider.VTable{
        .name = "static",
        .views = &[_][]const u8{"tokens"},
        .deinitFn = deinitNoop,
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

    pub fn provider(self: *StaticTokenProvider) ViewProvider {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn stateFor(ptr: *anyopaque, view: []const u8, revision: u32) ViewState {
        const self: *StaticTokenProvider = @ptrCast(@alignCast(ptr));
        if (!std.mem.eql(u8, view, "tokens")) {
            return ViewState.absent(view, revision);
        }
        if (self.revision != revision or self.stale) {
            return .{
                .view = view,
                .revision = self.revision,
                .kind = .stale,
            };
        }
        return .{
            .view = view,
            .revision = revision,
            .kind = .available,
        };
    }

    fn refresh(ptr: *anyopaque, engine: *anyopaque) ViewState {
        const self: *StaticTokenProvider = @ptrCast(@alignCast(ptr));
        const document: *const BufferEngine = @ptrCast(@alignCast(engine));
        // Only the revision the spans were written for can be served as available.
        self.stale = document.revision != self.revision;
        return .{
            .view = "tokens",
            .revision = self.revision,
            .kind = if (self.stale) .stale else .available,
        };
    }

    fn onBufferEvent(ptr: *anyopaque, engine: *anyopaque, block: *anyopaque) void {
        _ = engine;
        const self: *StaticTokenProvider = @ptrCast(@alignCast(ptr));
        if (changesText(block)) self.stale = true;
    }

    fn tokenSpans(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        engine: *anyopaque,
        start: u32,
        end: u32,
        revision: u32,
    ) ![]const TokenSpan {
        _ = engine;
        const self: *StaticTokenProvider = @ptrCast(@alignCast(ptr));
        if (revision != self.revision or self.stale) {
            return &[_]TokenSpan{};
        }

        var results: std.ArrayListUnmanaged(TokenSpan) = .empty;
        errdefer results.deinit(allocator);
        for (self.spans) |span| {
            if (@max(span.start, start) < @min(span.end, end)) {
                try results.append(allocator, span);
            }
        }
        return results.toOwnedSlice(allocator);
    }

    fn enclosingNode(
        ptr: *anyopaque,
        engine: *anyopaque,
        position: u32,
        revision: u32,
    ) ?SyntaxNodeInfo {
        _ = ptr;
        _ = engine;
        _ = position;
        _ = revision;
        return null;
    }

    fn nodeInfo(ptr: *anyopaque, engine: *anyopaque, ref: SyntaxNodeRef) !SyntaxNodeInfo {
        _ = ptr;
        _ = engine;
        _ = ref;
        return error.KeyError;
    }

    fn typeAt(ptr: *anyopaque, engine: *anyopaque, position: u32, revision: u32) !?TypeInfo {
        _ = ptr;
        _ = engine;
        _ = position;
        _ = revision;
        return null;
    }

    fn hoverAt(ptr: *anyopaque, engine: *anyopaque, position: u32, revision: u32) !?HoverInfo {
        _ = ptr;
        _ = engine;
        _ = position;
        _ = revision;
        return null;
    }

    fn symbolCapabilities(ptr: *anyopaque) ?buffer_types.SymbolCapabilities {
        _ = ptr;
        return null;
    }

    fn definition(
        ptr: *anyopaque,
        engine: *anyopaque,
        position: u32,
        revision: u32,
    ) !DefinitionResult {
        _ = ptr;
        _ = engine;
        _ = position;
        _ = revision;
        return .not_supported;
    }

    fn references(
        ptr: *anyopaque,
        engine: *anyopaque,
        position: u32,
        revision: u32,
    ) !ReferencesResult {
        _ = ptr;
        _ = engine;
        _ = position;
        _ = revision;
        return .not_supported;
    }

    fn renamePrepare(
        ptr: *anyopaque,
        engine: *anyopaque,
        position: u32,
        revision: u32,
    ) !RenamePrepareResult {
        _ = ptr;
        _ = engine;
        _ = position;
        _ = revision;
        return .not_supported;
    }

    fn diagnosticList(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        engine: *anyopaque,
        start: ?u32,
        end: ?u32,
        revision: u32,
    ) ![]const Diagnostic {
        _ = ptr;
        _ = allocator;
        _ = engine;
        _ = start;
        _ = end;
        _ = revision;
        return &.{};
    }

    fn semanticTokens(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        engine: *anyopaque,
        start: u32,
        end: u32,
        revision: u32,
    ) ![]const SemanticToken {
        _ = ptr;
        _ = allocator;
        _ = engine;
        _ = start;
        _ = end;
        _ = revision;
        return &.{};
    }
};

test "StaticTokenProvider basic functionality" {
    const allocator = std.testing.allocator;
    const spans = [_]TokenSpan{
        .{ .start = 0, .end = 5, .kind = "keyword", .style = "bold" },
        .{ .start = 6, .end = 10, .kind = "identifier", .style = "normal" },
    };

    var static_provider = StaticTokenProvider{ .spans = &spans };
    var prov = static_provider.provider();

    try std.testing.expectEqualStrings("static", prov.name());
    try std.testing.expectEqualStrings("tokens", prov.views()[0]);

    const state = prov.stateFor("tokens", 0);
    try std.testing.expectEqual(ViewStateKind.available, state.kind);

    const tokens = try prov.tokenSpans(allocator, undefined, 2, 8, 0);
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqual(@as(u32, 0), tokens[0].start);
    try std.testing.expectEqual(@as(u32, 6), tokens[1].start);
}
