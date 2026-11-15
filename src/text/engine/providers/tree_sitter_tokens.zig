//! Shared Tree-sitter parse state exposed through token and syntax facades.

const std = @import("std");
const ts = @import("../../tree_sitter/api.zig");
const views = @import("../views.zig");
const BufferEngine = @import("../buffer_engine.zig").BufferEngine;
const buffer_types = @import("../buffer_types.zig");
const events = @import("../events.zig");

const lua_highlights_query = @embedFile("../../tree_sitter/queries/lua_highlights.scm");
const zig_highlights_query = @embedFile("../../tree_sitter/queries/zig_highlights.scm");
const tokens_facade_name = "tree-sitter/tokens";
const syntax_facade_name = "tree-sitter/syntax";
const tokens_view = "tokens";
const syntax_view = "syntax";

/// A Tree-sitter language, as a generated parser's `tree_sitter_<name>()` returns it.
pub const Language = ts.Language;

/// A grammar the provider parses and highlights with. Providers keep a pointer to it, so
/// it must outlive every provider attached with it; a `const` declaration does.
pub const Grammar = struct {
    /// Names the grammar for `attachBuiltin`.
    name: []const u8,
    /// Identifies the provider in syntax node references (`SyntaxNodeRef.provider`).
    provider_name: []const u8,
    /// The generated parser's language function.
    language: *const fn () callconv(.c) *const Language,
    /// A highlight query for the language. Captures map to token kinds by their names;
    /// `#eq?`, `#any-of?` and a few `#match?` patterns are evaluated, and any other
    /// predicate is treated as satisfied.
    highlights_query: []const u8,
};

/// The grammars this package builds in.
pub const builtin_grammars = [_]Grammar{
    .{
        .name = "lua",
        .provider_name = "tree-sitter-lua",
        .language = ts.tree_sitter_lua,
        .highlights_query = lua_highlights_query,
    },
    .{
        .name = "zig",
        .provider_name = "tree-sitter-zig",
        .language = ts.tree_sitter_zig,
        .highlights_query = zig_highlights_query,
    },
};

fn builtinGrammar(language_name: []const u8) ?*const Grammar {
    for (&builtin_grammars) |*grammar| {
        if (std.mem.eql(u8, grammar.name, language_name)) return grammar;
    }
    return null;
}

fn coreFrom(ptr: *anyopaque) *TreeSitterTokenProvider {
    return @ptrCast(@alignCast(ptr));
}

fn noopDiagnosticList(
    _: *anyopaque,
    allocator: std.mem.Allocator,
    _: *anyopaque,
    _: ?u32,
    _: ?u32,
    _: u32,
) ![]const views.Diagnostic {
    return try allocator.alloc(views.Diagnostic, 0);
}

fn noopSemanticTokens(
    _: *anyopaque,
    allocator: std.mem.Allocator,
    _: *anyopaque,
    _: u32,
    _: u32,
    _: u32,
) ![]const views.SemanticToken {
    return try allocator.alloc(views.SemanticToken, 0);
}

fn noopEnclosingNode(_: *anyopaque, _: *anyopaque, _: u32, _: u32) !?views.SyntaxNodeInfo {
    return null;
}

fn noopNodeInfo(_: *anyopaque, _: *anyopaque, _: views.SyntaxNodeRef) !views.SyntaxNodeInfo {
    return error.KeyError;
}

fn noopTypeAt(_: *anyopaque, _: *anyopaque, _: u32, _: u32) !?views.TypeInfo {
    return null;
}

fn noopHoverAt(_: *anyopaque, _: *anyopaque, _: u32, _: u32) !?views.HoverInfo {
    return null;
}

fn noopSymbolCapabilities(_: *anyopaque) ?buffer_types.SymbolCapabilities {
    return null;
}

fn noopDefinition(_: *anyopaque, _: *anyopaque, _: u32, _: u32) !views.DefinitionResult {
    return .not_supported;
}

fn noopReferences(_: *anyopaque, _: *anyopaque, _: u32, _: u32) !views.ReferencesResult {
    return .not_supported;
}

fn noopRenamePrepare(_: *anyopaque, _: *anyopaque, _: u32, _: u32) !views.RenamePrepareResult {
    return .not_supported;
}

fn noopTokenSpans(
    _: *anyopaque,
    allocator: std.mem.Allocator,
    _: *anyopaque,
    _: u32,
    _: u32,
    _: u32,
) ![]const views.TokenSpan {
    return try allocator.alloc(views.TokenSpan, 0);
}

fn deinitCore(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    coreFrom(ptr).deinit(allocator);
}

fn treeSitterSiblingFacadePresent(engine: *BufferEngine, sibling_view: []const u8) bool {
    const expected: []const u8 = if (std.mem.eql(u8, sibling_view, tokens_view))
        tokens_facade_name
    else if (std.mem.eql(u8, sibling_view, syntax_view))
        syntax_facade_name
    else
        return false;
    const name = engine.viewProviderName(sibling_view) orelse return false;
    return std.mem.eql(u8, name, expected);
}

/// Shared Tree-sitter parse state, exposed through separate token and syntax facades.
///
/// The provider keeps the last completed parse tree. Each published edit is applied to
/// that tree as it arrives (`onBufferEvent`), using the byte and point coordinates of
/// the block's realized splices, so the next parse reuses everything the edit did not
/// touch. Parsing happens only in `refresh`, within the host's budget, and resumes
/// across calls; queries never parse. Both facades are current exactly when the tree
/// was parsed at the engine's revision, and they answer from that tree on demand: token
/// queries run the highlight query over the requested range only, and node references
/// are preorder indices, so the provider stores nothing per query.
///
/// A parse halted by the budget keeps going when the document changes: it reads a copy
/// of the text it started on, and the edits made meanwhile are queued and applied to its
/// tree when it completes. Abandoning it instead would let edits that arrive more often
/// than a parse can finish keep the views from ever catching up.
pub const TreeSitterTokenProvider = struct {
    allocator: std.mem.Allocator,
    grammar: *const Grammar,
    parser: ts.Parser,
    query: ts.Query,
    cursor: ts.QueryCursor,
    /// The last completed parse, edited forward by every text change since.
    tree: ?ts.Tree = null,
    /// The revision `tree` was parsed at; null before the first parse.
    parsed_revision: ?u32 = null,
    /// Text changed since `tree` was parsed.
    edited: bool = false,
    /// The parser holds a parse halted by the budget, of the text at `halted_revision`.
    halted: bool = false,
    halted_revision: u32 = 0,
    /// The text at `halted_revision`, copied when the parse halted, so that it can
    /// finish after the document moves on. Unused (empty) when the copy failed: the
    /// halted parse then reads the engine and is abandoned by the next edit.
    snapshot: std.ArrayListUnmanaged(u8) = .empty,
    has_snapshot: bool = false,
    /// Splices published since `halted_revision`, for the halted parse's tree.
    pending: std.ArrayListUnmanaged(events.RealizedSplice) = .empty,
    /// Why the last parse failed, if it did; cleared by the next edit or refresh.
    failure: ?[]const u8 = null,
    /// Capture text for highlight predicates; reused across queries.
    scratch: std.ArrayListUnmanaged(u8) = .empty,

    pub fn create(
        allocator: std.mem.Allocator,
        grammar: *const Grammar,
    ) !*TreeSitterTokenProvider {
        const provider = try allocator.create(TreeSitterTokenProvider);
        errdefer allocator.destroy(provider);

        const language = grammar.language();

        var parser = try ts.Parser.create();
        errdefer parser.destroy();
        try parser.setLanguage(language);

        var query = try ts.Query.create(language, grammar.highlights_query);
        errdefer query.destroy();

        const cursor = try ts.QueryCursor.create();

        provider.* = .{
            .allocator = allocator,
            .grammar = grammar,
            .parser = parser,
            .query = query,
            .cursor = cursor,
        };
        return provider;
    }

    /// Registers one provider for `grammar` as both the `tokens` and `syntax` views.
    /// Returns false, registering nothing, if either view already has a provider. Fails
    /// with error.InvalidQuery if the highlight query does not compile for the language.
    pub fn attach(engine: *BufferEngine, grammar: *const Grammar) !bool {
        if (engine.hasViewProvider(tokens_view) or engine.hasViewProvider(syntax_view)) return false;

        const provider = try TreeSitterTokenProvider.create(engine.allocator, grammar);
        errdefer provider.deinit(engine.allocator);

        try provider.registerViewProviders(engine);
        return true;
    }

    /// `attach` with the built-in grammar named `language_name`; false if there is none.
    pub fn attachBuiltin(engine: *BufferEngine, language_name: []const u8) !bool {
        const grammar = builtinGrammar(language_name) orelse return false;
        return attach(engine, grammar);
    }

    pub fn attachTokensBuiltin(engine: *BufferEngine, language_name: []const u8) !bool {
        const grammar = builtinGrammar(language_name) orelse return false;
        if (engine.hasViewProvider(tokens_view)) return false;
        if (treeSitterSiblingFacadePresent(engine, syntax_view)) return false;

        const provider = try TreeSitterTokenProvider.create(engine.allocator, grammar);
        errdefer provider.deinit(engine.allocator);

        engine.registerViewProvider(provider.tokensViewProvider()) catch |err| switch (err) {
            error.AlreadyExists => return false,
            else => return err,
        };
        return true;
    }

    pub fn attachSyntaxBuiltin(engine: *BufferEngine, language_name: []const u8) !bool {
        const grammar = builtinGrammar(language_name) orelse return false;
        if (engine.hasViewProvider(syntax_view)) return false;
        if (treeSitterSiblingFacadePresent(engine, tokens_view)) return false;

        const provider = try TreeSitterTokenProvider.create(engine.allocator, grammar);
        errdefer provider.deinit(engine.allocator);

        engine.registerViewProvider(provider.syntaxViewProvider()) catch |err| switch (err) {
            error.AlreadyExists => return false,
            else => return err,
        };
        return true;
    }

    fn registerViewProviders(self: *TreeSitterTokenProvider, engine: *BufferEngine) !void {
        try engine.registerViewProviders(&.{
            self.tokensViewProvider(),
            self.syntaxViewProvider(),
        });
    }

    pub fn tokensViewProvider(self: *TreeSitterTokenProvider) views.ViewProvider {
        return .{
            .ptr = self,
            .vtable = &tokens_vtable,
        };
    }

    pub fn syntaxViewProvider(self: *TreeSitterTokenProvider) views.ViewProvider {
        return .{
            .ptr = self,
            .vtable = &syntax_vtable,
        };
    }

    fn deinit(self: *TreeSitterTokenProvider, allocator: std.mem.Allocator) void {
        if (self.tree) |*tree| tree.destroy();
        self.scratch.deinit(allocator);
        self.snapshot.deinit(allocator);
        self.pending.deinit(allocator);
        self.cursor.destroy();
        self.query.destroy();
        self.parser.destroy();
        allocator.destroy(self);
    }

    /// The parse tree, when it describes the text at `revision`.
    fn currentTree(self: *const TreeSitterTokenProvider, revision: u32) ?ts.Tree {
        if (self.edited or self.parsed_revision != revision) return null;
        return self.tree;
    }

    fn tokensStateFor(ptr: *anyopaque, view: []const u8, revision: u32) views.ViewState {
        if (!std.mem.eql(u8, view, tokens_view)) return views.ViewState.absent(view, revision);
        return stateForView(coreFrom(ptr), view, revision);
    }

    fn syntaxStateFor(ptr: *anyopaque, view: []const u8, revision: u32) views.ViewState {
        if (!std.mem.eql(u8, view, syntax_view)) return views.ViewState.absent(view, revision);
        return stateForView(coreFrom(ptr), view, revision);
    }

    fn stateForView(
        self: *TreeSitterTokenProvider,
        view: []const u8,
        revision: u32,
    ) views.ViewState {
        if (self.failure) |message| {
            return .{
                .view = view,
                .revision = self.parsed_revision,
                .kind = .unavailable,
                .message = message,
            };
        }
        if (self.currentTree(revision) == null) {
            return .{
                .view = view,
                .revision = self.parsed_revision,
                .kind = .stale,
                .message = if (self.halted)
                    "tree-sitter parse in progress"
                else
                    "tree-sitter views need refresh",
            };
        }
        return .{ .view = view, .revision = revision, .kind = .available };
    }

    fn tokensRefresh(
        ptr: *anyopaque,
        engine_ptr: *anyopaque,
        budget: views.RefreshBudget,
    ) views.ViewState {
        return refreshView(coreFrom(ptr), engine_ptr, tokens_view, budget);
    }

    fn syntaxRefresh(
        ptr: *anyopaque,
        engine_ptr: *anyopaque,
        budget: views.RefreshBudget,
    ) views.ViewState {
        return refreshView(coreFrom(ptr), engine_ptr, syntax_view, budget);
    }

    /// Parses toward the current text, reusing the edited previous tree, until done or
    /// until `budget` is exhausted. A halted parse resumes on the next call, on the text it
    /// started with; once it completes, the edits made since are applied to its tree and
    /// parsing continues toward the current text. Tree-sitter allocates with its own
    /// allocator; the provider's allocator holds the copy of a halted parse's text.
    fn refreshView(
        self: *TreeSitterTokenProvider,
        engine_ptr: *anyopaque,
        view: []const u8,
        budget: views.RefreshBudget,
    ) views.ViewState {
        const engine: *const BufferEngine = @ptrCast(@alignCast(engine_ptr));
        if (self.currentTree(engine.revision) != null) return self.stateForView(view, engine.revision);
        self.failure = null;

        var budget_copy = budget;
        const progress: ?ts.Progress = if (budget.exhausted != null) .{
            .context = @ptrCast(&budget_copy),
            .halt = haltWhenExhausted,
        } else null;
        var first = true;
        while (self.currentTree(engine.revision) == null) : (first = false) {
            // A parse started on a spent budget would halt at once and copy the text.
            if (!first and budget_copy.isExhausted()) break;
            const input: ts.Input = if (self.halted and self.has_snapshot)
                .{ .context = @ptrCast(self), .read = readSnapshot }
            else
                .{ .context = @ptrCast(engine), .read = readChunk };
            const parsed = self.parser.parseInput(self.tree, input, progress) catch {
                self.abandonHalted();
                self.failure = "tree-sitter parse failed";
                break;
            };
            const next = parsed orelse {
                if (!self.halted) {
                    self.halted = true;
                    self.halted_revision = engine.revision;
                    self.copySnapshot(engine);
                }
                break;
            };
            if (self.tree) |*previous| previous.destroy();
            self.tree = next;
            self.parsed_revision = if (self.halted) self.halted_revision else engine.revision;
            self.edited = self.pending.items.len > 0;
            for (self.pending.items) |splice| applySplice(next, splice);
            self.pending.clearRetainingCapacity();
            self.halted = false;
            self.has_snapshot = false;
            self.snapshot.clearAndFree(self.allocator);
        }
        return self.stateForView(view, engine.revision);
    }

    /// Copies the current text for the parse that just halted. Without the copy, the
    /// parse can only continue while the text stays as it is.
    fn copySnapshot(self: *TreeSitterTokenProvider, engine: *const BufferEngine) void {
        const total = engine.table.byteCount();
        self.snapshot.clearRetainingCapacity();
        // Out of memory: no copy, so the next edit abandons the halted parse.
        self.snapshot.ensureTotalCapacity(self.allocator, total) catch return;
        var byte: u32 = 0;
        while (byte < total) {
            // In range: `byte` is below the text's length.
            const chunk = engine.table.chunkAtByte(byte) catch unreachable;
            self.snapshot.appendSliceAssumeCapacity(chunk);
            byte += @intCast(chunk.len);
        }
        self.has_snapshot = true;
    }

    /// Drops a halted parse. The previous tree takes the edits queued for the halted
    /// parse's tree instead, so the next parse starts from it.
    fn abandonHalted(self: *TreeSitterTokenProvider) void {
        if (!self.halted) return;
        self.parser.reset();
        self.halted = false;
        self.has_snapshot = false;
        self.snapshot.clearAndFree(self.allocator);
        if (self.tree) |tree| for (self.pending.items) |splice| applySplice(tree, splice);
        self.pending.clearRetainingCapacity();
    }

    fn applySplice(tree: ts.Tree, splice: events.RealizedSplice) void {
        tree.edit(.{
            .start_byte = splice.start_byte,
            .old_end_byte = splice.old_end_byte,
            .new_end_byte = splice.new_end_byte,
            .start_point = .{ .row = splice.start_point.row, .column = splice.start_point.column },
            .old_end_point = .{ .row = splice.old_end_point.row, .column = splice.old_end_point.column },
            .new_end_point = .{ .row = splice.new_end_point.row, .column = splice.new_end_point.column },
        });
    }

    fn haltWhenExhausted(context: *anyopaque) bool {
        const budget: *const views.RefreshBudget = @ptrCast(@alignCast(context));
        return budget.isExhausted();
    }

    fn readChunk(context: *const anyopaque, byte: u32) []const u8 {
        const engine: *const BufferEngine = @ptrCast(@alignCast(context));
        return engine.table.chunkAtByte(byte) catch "";
    }

    fn readSnapshot(context: *const anyopaque, byte: u32) []const u8 {
        const self: *const TreeSitterTokenProvider = @ptrCast(@alignCast(context));
        if (byte >= self.snapshot.items.len) return "";
        return self.snapshot.items[byte..];
    }

    /// Applies every realized splice of a text change to the tree, so that the next parse
    /// reuses the unchanged parts. While a parse is halted on a copy of the text, the
    /// splices are queued for its tree instead; if queuing fails, the halted parse is
    /// abandoned and the previous tree takes them.
    fn onBufferEvent(ptr: *anyopaque, _: *anyopaque, block_ptr: *anyopaque) void {
        const self: *TreeSitterTokenProvider = @ptrCast(@alignCast(ptr));
        const block: *const events.Block = @ptrCast(@alignCast(block_ptr));
        const edit = switch (block.*) {
            .transition => |transition| transition.edit orelse return,
            .lifecycle => return,
        };
        self.failure = null;
        self.edited = true;
        if (self.halted and self.has_snapshot) {
            // Out of memory falls through: the halted parse is abandoned instead.
            if (self.pending.appendSlice(self.allocator, edit.splices)) return else |_| {}
        }
        self.abandonHalted();
        const tree = self.tree orelse return;
        for (edit.splices) |splice| applySplice(tree, splice);
    }

    /// Highlight spans intersecting `[start, end)`, computed from the current tree for that
    /// range only. Captures are syntax nodes, so any two byte ranges are nested or
    /// disjoint, and both ends map to graphemes by rounding down, which keeps them so: a
    /// grapheme that straddles a token boundary belongs to the later token. Every span
    /// that could hide a span in the range therefore intersects the range too, and
    /// resolving overlaps among those captures gives exactly the spans that resolving them
    /// over the whole document gives inside the range. The caller owns the slice.
    fn tokenSpans(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        engine_ptr: *anyopaque,
        start: u32,
        end: u32,
        revision: u32,
    ) ![]const views.TokenSpan {
        const self: *TreeSitterTokenProvider = @ptrCast(@alignCast(ptr));
        const engine: *const BufferEngine = @ptrCast(@alignCast(engine_ptr));
        const tree = self.currentTree(revision) orelse return error.ViewStale;
        const start_byte = try engine.table.byteOffset(start);
        const end_byte = try engine.table.byteOffset(end);

        // Spans are collected in bytes, then all their ends are mapped to graphemes in one
        // ascending pass, which segments each piece of the range once.
        var spans: std.ArrayListUnmanaged(views.TokenSpan) = .empty;
        defer spans.deinit(allocator);
        self.cursor.setByteRange(start_byte, end_byte);
        self.cursor.exec(self.query, tree.rootNode());
        while (self.cursor.nextMatch()) |match| {
            if (!try self.matchPassesPredicates(engine, match)) continue;
            for (match.captures) |capture| {
                const capture_name = self.query.captureNameForId(capture.index) orelse continue;
                const styled = classifyCapture(capture_name) orelse continue;
                try spans.append(allocator, .{
                    .start = capture.node.startByte(),
                    .end = capture.node.endByte(),
                    .kind = styled.kind,
                    .style = styled.style,
                });
            }
        }

        const bytes = try allocator.alloc(u32, spans.items.len * 2);
        defer allocator.free(bytes);
        for (spans.items, 0..) |span, index| {
            bytes[2 * index] = span.start;
            bytes[2 * index + 1] = span.end;
        }
        std.mem.sort(u32, bytes, {}, std.sort.asc(u32));
        const positions = try allocator.dupe(u32, bytes);
        defer allocator.free(positions);
        try engine.table.positionsAtBytes(positions);

        var kept: usize = 0;
        for (spans.items) |span| {
            const span_start = positions[lowerBound(bytes, span.start)];
            const span_end = positions[lowerBound(bytes, span.end)];
            if (span_end <= span_start) continue;
            if (span_end <= start or span_start >= end) continue;
            spans.items[kept] = .{
                .start = span_start,
                .end = span_end,
                .kind = span.kind,
                .style = span.style,
            };
            kept += 1;
        }
        return resolveOverlaps(allocator, spans.items[0..kept]);
    }

    /// The index of the first item of ascending `items` that is at least `value`.
    fn lowerBound(items: []const u32, value: u32) usize {
        return std.sort.lowerBound(u32, items, value, struct {
            fn order(target: u32, item: u32) std.math.Order {
                return std.math.order(target, item);
            }
        }.order);
    }

    /// Orders spans and keeps, at each position, the first span by start, then by
    /// length, then by priority; spans starting inside a kept span are dropped.
    fn resolveOverlaps(allocator: std.mem.Allocator, raw: []views.TokenSpan) ![]views.TokenSpan {
        std.mem.sort(views.TokenSpan, raw, {}, struct {
            fn lessThan(_: void, a: views.TokenSpan, b: views.TokenSpan) bool {
                if (a.start != b.start) return a.start < b.start;
                if (a.end != b.end) return a.end > b.end;
                const a_priority = spanPriority(a);
                const b_priority = spanPriority(b);
                if (a_priority != b_priority) return a_priority > b_priority;
                return std.mem.order(u8, a.kind, b.kind) == .lt;
            }
        }.lessThan);
        var kept: usize = 0;
        var covered_end: u32 = 0;
        for (raw) |span| {
            if (span.start < covered_end) continue;
            raw[kept] = span;
            kept += 1;
            covered_end = span.end;
        }
        return allocator.dupe(views.TokenSpan, raw[0..kept]);
    }

    /// The smallest named node around the grapheme at `position`, or null if no node
    /// contains it, as for whitespace before the first token. Errors are reported, never
    /// folded into absence.
    fn enclosingNode(
        ptr: *anyopaque,
        engine_ptr: *anyopaque,
        position: u32,
        revision: u32,
    ) !?views.SyntaxNodeInfo {
        const self: *TreeSitterTokenProvider = @ptrCast(@alignCast(ptr));
        const engine: *const BufferEngine = @ptrCast(@alignCast(engine_ptr));
        const tree = self.currentTree(revision) orelse return error.ViewStale;
        const start_byte = try engine.table.byteOffset(position);
        const end_byte = if (position < engine.graphemeCount())
            try engine.table.byteOffset(position + 1)
        else
            start_byte;
        const root = tree.rootNode();
        var node = root.namedDescendantForByteRange(start_byte, end_byte);
        if (node.isNull() or !node.isNamed()) node = root.descendantForByteRange(start_byte, end_byte);
        if (node.isNull()) return null;
        // Tree-sitter answers with the root even when nothing contains the range: the
        // root starts at the first token, so text before it is inside no node.
        if (node.startByte() > start_byte or node.endByte() < end_byte) return null;
        const id = descendantIndexOf(root, node) orelse return error.InvalidNode;
        return try self.nodeInfoAt(engine, node, id, revision);
    }

    fn nodeInfo(
        ptr: *anyopaque,
        engine_ptr: *anyopaque,
        ref: views.SyntaxNodeRef,
    ) !views.SyntaxNodeInfo {
        const self: *TreeSitterTokenProvider = @ptrCast(@alignCast(ptr));
        const engine: *const BufferEngine = @ptrCast(@alignCast(engine_ptr));
        if (!std.mem.eql(u8, ref.provider, self.grammar.provider_name)) return error.KeyError;
        const tree = self.currentTree(ref.revision) orelse return error.InvalidArgument;
        const root = tree.rootNode();
        if (ref.id >= root.descendantCount()) return error.KeyError;
        var cursor = ts.TreeCursor.init(root);
        defer cursor.deinit();
        cursor.gotoDescendant(ref.id);
        return try self.nodeInfoAt(engine, cursor.node(), ref.id, ref.revision);
    }

    fn nodeInfoAt(
        self: *const TreeSitterTokenProvider,
        engine: *const BufferEngine,
        node: ts.Node,
        id: u32,
        revision: u32,
    ) !views.SyntaxNodeInfo {
        return .{
            .ref = .{ .provider = self.grammar.provider_name, .revision = revision, .id = id },
            .kind = node.type(),
            .start = try engine.table.positionAtByte(node.startByte(), .down),
            .end = try engine.table.positionAtByte(node.endByte(), .up),
            .is_named = node.isNamed(),
        };
    }

    /// `target`'s index in a preorder walk of visible nodes from `root`, found by
    /// descending through the children that contain it: time proportional to depth,
    /// since Tree-sitter balances long child lists.
    fn descendantIndexOf(root: ts.Node, target: ts.Node) ?u32 {
        var cursor = ts.TreeCursor.init(root);
        defer cursor.deinit();
        const start = target.startByte();
        const end = target.endByte();
        while (!cursor.node().eql(target)) {
            // An empty target can sit at the end of an ancestor, which the byte jump
            // would skip; scan those children from the first.
            const moved = if (start > 0 and start == end)
                cursor.gotoFirstChildForByte(start - 1)
            else
                cursor.gotoFirstChildForByte(start);
            if (!moved and !cursor.gotoFirstChild()) return null;
            while (true) {
                const child = cursor.node();
                if (child.eql(target)) break;
                const contains = child.startByte() <= start and child.endByte() >= end and
                    !(child.startByte() == child.endByte() and start != end);
                // Siblings cannot share a non-empty range, so for a non-empty target the
                // containing child is its ancestor; an empty one needs checking.
                if (contains and (start != end or isAncestor(child, target))) break;
                if (child.startByte() > start or !cursor.gotoNextSibling()) return null;
            }
        }
        return cursor.descendantIndex();
    }

    fn isAncestor(candidate: ts.Node, target: ts.Node) bool {
        var node = target.parent();
        while (!node.isNull()) : (node = node.parent()) {
            if (node.eql(candidate)) return true;
        }
        return false;
    }

    fn spanPriority(span: views.TokenSpan) u8 {
        if (startsWithCapture(span.kind, "function")) return 90;
        if (startsWithCapture(span.kind, "method")) return 90;
        if (startsWithCapture(span.kind, "keyword")) return 80;
        if (startsWithCapture(span.kind, "type")) return 70;
        if (startsWithCapture(span.kind, "string")) return 70;
        if (startsWithCapture(span.kind, "number")) return 70;
        if (startsWithCapture(span.kind, "constant")) return 60;
        if (startsWithCapture(span.kind, "variable")) return 50;
        return 40;
    }

    fn matchPassesPredicates(
        self: *TreeSitterTokenProvider,
        engine: *const BufferEngine,
        match: ts.Match,
    ) !bool {
        const steps = self.query.predicatesForPattern(match.pattern_index);
        if (steps.len == 0) return true;

        var index: usize = 0;
        while (index < steps.len) {
            const start = index;
            while (index < steps.len and steps[index].type != .done) : (index += 1) {}
            if (!try self.evaluatePredicate(engine, match, steps[start..index])) {
                return false;
            }
            index += 1;
        }
        return true;
    }

    fn evaluatePredicate(
        self: *TreeSitterTokenProvider,
        engine: *const BufferEngine,
        match: ts.Match,
        steps: []const ts.QueryPredicateStep,
    ) !bool {
        if (steps.len == 0 or steps[0].type != .string) return true;
        const name = self.query.stringValueForId(steps[0].value_id) orelse return true;

        if (isPredicateName(name, "eq?")) {
            if (steps.len != 3) return true;
            const lhs = (try self.predicateCaptureText(engine, match, steps[1])) orelse return true;
            const rhs = self.predicateStringValue(steps[2]) orelse return true;
            return std.mem.eql(u8, lhs, rhs);
        }

        if (isPredicateName(name, "match?") or isPredicateName(name, "lua-match?")) {
            if (steps.len != 3) return true;
            const lhs = (try self.predicateCaptureText(engine, match, steps[1])) orelse return true;
            const pattern = self.predicateStringValue(steps[2]) orelse return true;
            if (std.mem.eql(u8, pattern, "^[A-Z][A-Z_0-9]*$") or std.mem.eql(u8, pattern, "^[A-Z][A-Z_0-9]+$")) {
                return isUpperSnakeCase(lhs);
            }
            if (std.mem.eql(u8, pattern, "^[A-Z_][a-zA-Z0-9_]*")) {
                return isZigTypeName(lhs);
            }
            return true;
        }

        if (isPredicateName(name, "any-of?")) {
            if (steps.len < 3) return true;
            const lhs = (try self.predicateCaptureText(engine, match, steps[1])) orelse return true;
            for (steps[2..]) |step| {
                const option = self.predicateStringValue(step) orelse continue;
                if (std.mem.eql(u8, lhs, option)) return true;
            }
            return false;
        }

        return true;
    }

    /// The text of the predicate's capture, read from the piece table into the reused
    /// scratch buffer; valid until the next call.
    fn predicateCaptureText(
        self: *TreeSitterTokenProvider,
        engine: *const BufferEngine,
        match: ts.Match,
        step: ts.QueryPredicateStep,
    ) !?[]const u8 {
        if (step.type != .capture) return null;
        const capture_name = self.query.captureNameForId(step.value_id) orelse return null;
        for (match.captures) |capture| {
            const name = self.query.captureNameForId(capture.index) orelse continue;
            if (!std.mem.eql(u8, name, capture_name)) continue;
            self.scratch.clearRetainingCapacity();
            var byte = capture.node.startByte();
            const end = capture.node.endByte();
            while (byte < end) {
                const chunk = try engine.table.chunkAtByte(byte);
                const take = @min(chunk.len, end - byte);
                try self.scratch.appendSlice(self.allocator, chunk[0..take]);
                byte += @intCast(take);
            }
            return self.scratch.items;
        }
        return null;
    }

    fn predicateStringValue(
        self: *TreeSitterTokenProvider,
        step: ts.QueryPredicateStep,
    ) ?[]const u8 {
        if (step.type != .string) return null;
        return self.query.stringValueForId(step.value_id);
    }

    const StyledCapture = struct {
        kind: []const u8,
        style: []const u8,
    };

    fn classifyCapture(capture_name: []const u8) ?StyledCapture {
        if (startsWithCapture(capture_name, "comment")) return .{ .kind = capture_name, .style = "syntax:comment" };
        if (startsWithCapture(capture_name, "string")) return .{ .kind = capture_name, .style = "syntax:string" };
        if (startsWithCapture(capture_name, "number")) return .{ .kind = capture_name, .style = "syntax:number" };
        if (startsWithCapture(capture_name, "float")) return .{ .kind = capture_name, .style = "syntax:number" };
        if (startsWithCapture(capture_name, "character")) return .{ .kind = capture_name, .style = "syntax:string" };
        if (startsWithCapture(capture_name, "boolean")) return .{ .kind = capture_name, .style = "syntax:constant" };
        if (startsWithCapture(capture_name, "constant")) return .{ .kind = capture_name, .style = "syntax:constant" };
        if (startsWithCapture(capture_name, "keyword")) return .{ .kind = capture_name, .style = "syntax:keyword" };
        if (std.mem.eql(u8, capture_name, "conditional")) return .{ .kind = capture_name, .style = "syntax:keyword" };
        if (std.mem.eql(u8, capture_name, "repeat")) return .{ .kind = capture_name, .style = "syntax:keyword" };
        if (std.mem.eql(u8, capture_name, "label")) return .{ .kind = capture_name, .style = "syntax:keyword" };
        if (std.mem.eql(u8, capture_name, "preproc")) return .{ .kind = capture_name, .style = "syntax:keyword" };
        if (startsWithCapture(capture_name, "function")) return .{ .kind = capture_name, .style = "syntax:function" };
        if (startsWithCapture(capture_name, "type")) return .{ .kind = capture_name, .style = "syntax:identifier" };
        if (startsWithCapture(capture_name, "module")) return .{ .kind = capture_name, .style = "syntax:identifier" };
        if (startsWithCapture(capture_name, "method")) return .{ .kind = capture_name, .style = "syntax:function" };
        if (startsWithCapture(capture_name, "operator")) return .{ .kind = capture_name, .style = "syntax:operator" };
        if (startsWithCapture(capture_name, "punctuation")) return .{ .kind = capture_name, .style = "syntax:punctuation" };
        if (startsWithCapture(capture_name, "field")) return .{ .kind = capture_name, .style = "syntax:identifier" };
        if (startsWithCapture(capture_name, "parameter")) return .{ .kind = capture_name, .style = "syntax:identifier" };
        if (startsWithCapture(capture_name, "variable")) return .{ .kind = capture_name, .style = "syntax:identifier" };
        if (startsWithCapture(capture_name, "attribute")) return .{ .kind = capture_name, .style = "syntax:identifier" };
        if (startsWithCapture(capture_name, "constructor")) return .{ .kind = capture_name, .style = "syntax:identifier" };
        return null;
    }

    fn startsWithCapture(name: []const u8, prefix: []const u8) bool {
        return std.mem.eql(u8, name, prefix) or
            (name.len > prefix.len and std.mem.startsWith(u8, name, prefix) and name[prefix.len] == '.');
    }

    fn isPredicateName(name: []const u8, target: []const u8) bool {
        return std.mem.eql(u8, name, target) or (name.len == target.len + 1 and name[0] == '#' and std.mem.eql(u8, name[1..], target));
    }

    fn isUpperSnakeCase(text: []const u8) bool {
        if (text.len == 0) return false;
        if (!(text[0] >= 'A' and text[0] <= 'Z')) return false;
        for (text[1..]) |ch| {
            if ((ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_') continue;
            return false;
        }
        return true;
    }

    fn isZigTypeName(text: []const u8) bool {
        if (text.len == 0) return false;
        if (!((text[0] >= 'A' and text[0] <= 'Z') or text[0] == '_')) return false;
        for (text[1..]) |ch| {
            if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '_') continue;
            return false;
        }
        return true;
    }

    const tokens_vtable = views.ViewProvider.VTable{
        .name = tokens_facade_name,
        .views = &[_][]const u8{tokens_view},
        .deinitFn = deinitCore,
        .stateForFn = tokensStateFor,
        .refreshFn = tokensRefresh,
        .onBufferEventFn = onBufferEvent,
        .tokenSpansFn = tokenSpans,
        .diagnosticListFn = noopDiagnosticList,
        .semanticTokensFn = noopSemanticTokens,
        .enclosingNodeFn = noopEnclosingNode,
        .nodeInfoFn = noopNodeInfo,
        .typeAtFn = noopTypeAt,
        .hoverAtFn = noopHoverAt,
        .symbolCapabilitiesFn = noopSymbolCapabilities,
        .definitionFn = noopDefinition,
        .referencesFn = noopReferences,
        .renamePrepareFn = noopRenamePrepare,
    };

    const syntax_vtable = views.ViewProvider.VTable{
        .name = syntax_facade_name,
        .views = &[_][]const u8{syntax_view},
        .deinitFn = deinitCore,
        .stateForFn = syntaxStateFor,
        .refreshFn = syntaxRefresh,
        .onBufferEventFn = onBufferEvent,
        .tokenSpansFn = noopTokenSpans,
        .diagnosticListFn = noopDiagnosticList,
        .semanticTokensFn = noopSemanticTokens,
        .enclosingNodeFn = enclosingNode,
        .nodeInfoFn = nodeInfo,
        .typeAtFn = noopTypeAt,
        .hoverAtFn = noopHoverAt,
        .symbolCapabilitiesFn = noopSymbolCapabilities,
        .definitionFn = noopDefinition,
        .referencesFn = noopReferences,
        .renamePrepareFn = noopRenamePrepare,
    };
};

test "descendant indices identify unnamed and nested nodes" {
    var parser = try ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(ts.tree_sitter_lua());

    const source = "local x = { 1, { 2 } }\nlocal y = x\n";
    var tree = try parser.parseString(source, null);
    defer tree.destroy();

    // Every node's index, found by descent, leads back to that node.
    const root = tree.rootNode();
    var cursor = ts.TreeCursor.init(root);
    defer cursor.deinit();
    var index: u32 = 0;
    while (index < root.descendantCount()) : (index += 1) {
        cursor.gotoDescendant(index);
        const node = cursor.node();
        try std.testing.expectEqual(index, TreeSitterTokenProvider.descendantIndexOf(root, node).?);
    }
    try std.testing.expect(findFirstUnnamedNode(root) != null);
}

fn findFirstUnnamedNode(root: ts.Node) ?ts.Node {
    if (!root.isNamed()) return root;
    const count = root.childCount();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (findFirstUnnamedNode(root.child(i))) |node| return node;
    }
    return null;
}
