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

/// How much work a refresh may do before returning (SPEC §2). A provider polls
/// `exhausted` while it works; when it returns true, the provider stops, keeps its
/// progress, and reports the view stale. A later refresh resumes, or starts over if the
/// document changed meanwhile. The host decides how much work fits: a deadline, a
/// step count, or anything else its callback measures. Litura owns no clock.
pub const RefreshBudget = struct {
    context: ?*anyopaque = null,
    exhausted: ?*const fn (context: ?*anyopaque) bool = null,

    pub const unlimited: RefreshBudget = .{};

    pub fn isExhausted(self: RefreshBudget) bool {
        const check = self.exhausted orelse return false;
        return check(self.context);
    }
};

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

/// A syntax node at one revision (SPEC §2.0.2): a plain value the provider can resolve
/// while that revision is current. `id` is opaque; it needs no storage, so references
/// can be kept and copied freely and never accumulate in the provider.
pub const SyntaxNodeRef = struct {
    provider: []const u8,
    revision: u32,
    id: u32,
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
        refreshFn: *const fn (ptr: *anyopaque, engine: *anyopaque, budget: RefreshBudget) ViewState,
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
        /// The smallest node whose range contains the graphemes `[start, end)`, preferring
        /// named nodes, or null if none does. The range is empty only at the end of the
        /// text; the engine turns an empty range elsewhere into its grapheme.
        enclosingNodeFn: *const fn (
            ptr: *anyopaque,
            engine: *anyopaque,
            start: u32,
            end: u32,
            revision: u32,
        ) anyerror!?SyntaxNodeInfo,
        nodeInfoFn: *const fn (
            ptr: *anyopaque,
            engine: *anyopaque,
            ref: SyntaxNodeRef,
        ) anyerror!SyntaxNodeInfo,
        /// The node's immediate parent, whatever its kind or range, or null at the root.
        parentNodeFn: *const fn (
            ptr: *anyopaque,
            engine: *anyopaque,
            ref: SyntaxNodeRef,
        ) anyerror!?SyntaxNodeInfo,
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

    /// Brings the provider's views to the engine's current revision, doing at most what
    /// `budget` allows. Returns the resulting state; a view that is not yet current is
    /// reported `stale` with the revision it last completed.
    pub fn refresh(self: ViewProvider, engine: *anyopaque, budget: RefreshBudget) ViewState {
        return self.vtable.refreshFn(self.ptr, engine, budget);
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
        start: u32,
        end: u32,
        revision: u32,
    ) !?SyntaxNodeInfo {
        return self.vtable.enclosingNodeFn(self.ptr, engine, start, end, revision);
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

    pub fn parentNode(self: ViewProvider, engine: *anyopaque, ref: SyntaxNodeRef) !?SyntaxNodeInfo {
        return self.vtable.parentNodeFn(self.ptr, engine, ref);
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
        .parentNodeFn = parentNode,
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

    fn refresh(ptr: *anyopaque, engine: *anyopaque, _: RefreshBudget) ViewState {
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

    fn enclosingNode(_: *anyopaque, _: *anyopaque, _: u32, _: u32, _: u32) !?SyntaxNodeInfo {
        return null;
    }

    fn nodeInfo(ptr: *anyopaque, engine: *anyopaque, ref: SyntaxNodeRef) !SyntaxNodeInfo {
        _ = ptr;
        _ = engine;
        _ = ref;
        return error.KeyError;
    }

    fn parentNode(_: *anyopaque, _: *anyopaque, _: SyntaxNodeRef) anyerror!?SyntaxNodeInfo {
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
