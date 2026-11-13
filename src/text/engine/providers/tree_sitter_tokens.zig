//! Shared Tree-sitter parse state exposed through token and syntax facades.

const std = @import("std");
const ts = @import("../../tree_sitter/api.zig");
const views = @import("../views.zig");
const BufferEngine = @import("../buffer_engine.zig").BufferEngine;
const buffer_types = @import("../buffer_types.zig");
const text_segmentation = @import("../text_segmentation.zig");

const lua_highlights_query = @embedFile("../../tree_sitter/queries/lua_highlights.scm");
const zig_highlights_query = @embedFile("../../tree_sitter/queries/zig_highlights.scm");
const fennel_highlights_query = @embedFile("../../tree_sitter/queries/fennel_highlights.scm");
const tokens_facade_name = "tree-sitter/tokens";
const syntax_facade_name = "tree-sitter/syntax";
const tokens_view = "tokens";
const syntax_view = "syntax";

const LanguageSpec = struct {
    name: []const u8,
    provider_name: []const u8,
    languageFn: *const fn () *const ts.Language,
    highlights_query: []const u8,

    fn language(self: LanguageSpec) *const ts.Language {
        return self.languageFn();
    }
};

fn luaLanguageSpec() *const ts.Language {
    return ts.luaLanguage();
}

fn zigLanguageSpec() *const ts.Language {
    return ts.zigLanguage();
}

fn fennelLanguageSpec() *const ts.Language {
    return ts.fennelLanguage();
}

const language_specs = [_]LanguageSpec{
    .{
        .name = "lua",
        .provider_name = "tree-sitter-lua",
        .languageFn = luaLanguageSpec,
        .highlights_query = lua_highlights_query,
    },
    .{
        .name = "zig",
        .provider_name = "tree-sitter-zig",
        .languageFn = zigLanguageSpec,
        .highlights_query = zig_highlights_query,
    },
    .{
        .name = "fennel",
        .provider_name = "tree-sitter-fennel",
        .languageFn = fennelLanguageSpec,
        .highlights_query = fennel_highlights_query,
    },
};

fn languageSpecFor(language_name: []const u8) ?*const LanguageSpec {
    for (&language_specs) |*spec| {
        if (std.mem.eql(u8, spec.name, language_name)) return spec;
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

fn noopEnclosingNode(_: *anyopaque, _: *anyopaque, _: u32, _: u32) ?views.SyntaxNodeInfo {
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

/// Shared tree-sitter parse state. Tokens and syntax are exposed through separate view facades.
pub const TreeSitterTokenProvider = struct {
    allocator: std.mem.Allocator,
    spec: *const LanguageSpec,
    parser: ts.Parser,
    query: ts.Query,
    cursor: ts.QueryCursor,
    segmenter: text_segmentation.Segmenter,
    tree: ?ts.Tree = null,
    text: ?[]u8 = null,
    grapheme_to_byte: ?[]u32 = null,
    spans: []views.TokenSpan = &.{},
    syntax_paths: std.ArrayListUnmanaged([]const u32) = .empty,
    revision: u32 = 0,
    stale: bool = true,

    pub fn create(
        allocator: std.mem.Allocator,
        spec: *const LanguageSpec,
    ) !*TreeSitterTokenProvider {
        const provider = try allocator.create(TreeSitterTokenProvider);
        errdefer allocator.destroy(provider);

        const language = spec.language();

        var parser = try ts.Parser.create();
        errdefer parser.destroy();
        try parser.setLanguage(language);

        var query = try ts.Query.create(language, spec.highlights_query);
        errdefer query.destroy();

        var cursor = try ts.QueryCursor.create();
        errdefer cursor.destroy();

        var segmenter = try text_segmentation.Segmenter.init(allocator);
        errdefer segmenter.deinit(allocator);

        provider.* = .{
            .allocator = allocator,
            .spec = spec,
            .parser = parser,
            .query = query,
            .cursor = cursor,
            .segmenter = segmenter,
        };
        return provider;
    }

    pub fn attachBuiltin(engine: *BufferEngine, language_name: []const u8) !bool {
        const spec = languageSpecFor(language_name) orelse return false;
        if (engine.hasViewProvider(tokens_view) or engine.hasViewProvider(syntax_view)) return false;

        const provider = try TreeSitterTokenProvider.create(engine.allocator, spec);
        errdefer provider.deinit(engine.allocator);

        try provider.registerViewProviders(engine);
        return true;
    }

    pub fn attachTokensBuiltin(engine: *BufferEngine, language_name: []const u8) !bool {
        const spec = languageSpecFor(language_name) orelse return false;
        if (engine.hasViewProvider(tokens_view)) return false;
        if (treeSitterSiblingFacadePresent(engine, syntax_view)) return false;

        const provider = try TreeSitterTokenProvider.create(engine.allocator, spec);
        errdefer provider.deinit(engine.allocator);

        engine.registerViewProvider(provider.tokensViewProvider()) catch |err| switch (err) {
            error.AlreadyExists => return false,
            else => return err,
        };
        return true;
    }

    pub fn attachSyntaxBuiltin(engine: *BufferEngine, language_name: []const u8) !bool {
        const spec = languageSpecFor(language_name) orelse return false;
        if (engine.hasViewProvider(syntax_view)) return false;
        if (treeSitterSiblingFacadePresent(engine, tokens_view)) return false;

        const provider = try TreeSitterTokenProvider.create(engine.allocator, spec);
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
        if (self.text) |text| allocator.free(text);
        if (self.grapheme_to_byte) |map| allocator.free(map);
        if (self.spans.len > 0) allocator.free(self.spans);
        for (self.syntax_paths.items) |path| allocator.free(path);
        self.syntax_paths.deinit(allocator);
        self.segmenter.deinit(allocator);
        self.cursor.destroy();
        self.query.destroy();
        self.parser.destroy();
        allocator.destroy(self);
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
        if (self.stale or self.revision != revision) {
            return .{
                .view = view,
                .revision = if (self.revision == 0) null else self.revision,
                .kind = .stale,
                .message = "tree-sitter views need refresh",
            };
        }
        return .{
            .view = view,
            .revision = self.revision,
            .kind = .available,
        };
    }

    fn tokensRefresh(ptr: *anyopaque, engine_ptr: *anyopaque) views.ViewState {
        return refreshView(coreFrom(ptr), engine_ptr, tokens_view);
    }

    fn syntaxRefresh(ptr: *anyopaque, engine_ptr: *anyopaque) views.ViewState {
        return refreshView(coreFrom(ptr), engine_ptr, syntax_view);
    }

    fn refreshView(
        self: *TreeSitterTokenProvider,
        engine_ptr: *anyopaque,
        view: []const u8,
    ) views.ViewState {
        const engine: *BufferEngine = @ptrCast(@alignCast(engine_ptr));

        self.rebuild(engine) catch |err| {
            self.stale = true;
            return .{
                .view = view,
                .revision = self.revision,
                .kind = .unavailable,
                .message = switch (err) {
                    error.OutOfMemory => "tree-sitter out of memory",
                    error.ParseFailed => "tree-sitter parse failed",
                },
            };
        };

        return .{
            .view = view,
            .revision = self.revision,
            .kind = .available,
        };
    }

    fn onBufferEvent(ptr: *anyopaque, _: *anyopaque, block: *anyopaque) void {
        const self: *TreeSitterTokenProvider = @ptrCast(@alignCast(ptr));
        if (views.changesText(block)) self.stale = true;
    }

    fn tokenSpans(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: *anyopaque,
        start: u32,
        end: u32,
        revision: u32,
    ) ![]const views.TokenSpan {
        const self: *TreeSitterTokenProvider = @ptrCast(@alignCast(ptr));
        if (self.stale or self.revision != revision) {
            return try allocator.alloc(views.TokenSpan, 0);
        }

        var results: std.ArrayListUnmanaged(views.TokenSpan) = .empty;
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
        _: *anyopaque,
        position: u32,
        revision: u32,
    ) ?views.SyntaxNodeInfo {
        const self: *TreeSitterTokenProvider = @ptrCast(@alignCast(ptr));
        if (self.stale or self.revision != revision) return null;
        const tree = self.tree orelse return null;
        const source = self.text orelse return null;
        const grapheme_to_byte = self.grapheme_to_byte orelse return null;

        const start_byte = graphemeStartByte(grapheme_to_byte, position);
        const end_byte = graphemeEndByte(grapheme_to_byte, position, @intCast(source.len));
        const root = tree.rootNode();
        var node = root.namedDescendantForByteRange(start_byte, end_byte);
        if (node.isNull() or !node.isNamed()) {
            node = root.descendantForByteRange(start_byte, end_byte);
        }
        if (node.isNull()) return null;

        return self.syntaxNodeInfoFromNode(root, node, revision) catch null;
    }

    fn nodeInfo(ptr: *anyopaque, _: *anyopaque, ref: views.SyntaxNodeRef) !views.SyntaxNodeInfo {
        const self: *TreeSitterTokenProvider = @ptrCast(@alignCast(ptr));
        if (!std.mem.eql(u8, ref.provider, self.spec.provider_name)) return error.KeyError;
        if (self.stale or self.revision != ref.revision) return error.InvalidArgument;
        const tree = self.tree orelse return error.KeyError;
        const root = tree.rootNode();
        const node = nodeAtPath(root, ref.path) orelse return error.KeyError;
        return try self.syntaxNodeInfoFromNode(root, node, ref.revision);
    }

    fn rebuild(self: *TreeSitterTokenProvider, engine: *BufferEngine) !void {
        const next_text = try engine.getText();
        errdefer self.allocator.free(next_text);

        const next_tree = try self.parser.parseString(next_text, null);
        errdefer {
            var doomed = next_tree;
            doomed.destroy();
        }

        const next_map = try self.segmenter.graphemeToByteMap(self.allocator, next_text);
        errdefer self.allocator.free(next_map);

        const next_spans = try self.buildSpans(next_text, next_tree, next_map);
        errdefer self.allocator.free(next_spans);

        if (self.tree) |*tree| tree.destroy();
        if (self.text) |text| self.allocator.free(text);
        if (self.grapheme_to_byte) |map| self.allocator.free(map);
        if (self.spans.len > 0) self.allocator.free(self.spans);

        self.tree = next_tree;
        self.text = next_text;
        self.grapheme_to_byte = next_map;
        self.spans = next_spans;
        for (self.syntax_paths.items) |path| self.allocator.free(path);
        self.syntax_paths.clearRetainingCapacity();
        self.revision = engine.revision;
        self.stale = false;
    }

    fn syntaxNodeInfoFromNode(
        self: *TreeSitterTokenProvider,
        root: ts.Node,
        node: ts.Node,
        revision: u32,
    ) !views.SyntaxNodeInfo {
        const grapheme_to_byte = self.grapheme_to_byte orelse return error.KeyError;
        const path = try pathFromRoot(self.allocator, root, node);
        defer self.allocator.free(path);
        const stored_path = try self.storeSyntaxPath(path);
        const start = graphemeIndexForStartByte(grapheme_to_byte, node.startByte());
        const end = graphemeIndexForEndByte(grapheme_to_byte, node.endByte());
        return .{
            .ref = .{
                .provider = self.spec.provider_name,
                .revision = revision,
                .path = stored_path,
            },
            .kind = node.type(),
            .start = start,
            .end = end,
            .is_named = node.isNamed(),
        };
    }

    fn storeSyntaxPath(self: *TreeSitterTokenProvider, path: []const u32) ![]const u32 {
        const stored = try self.allocator.dupe(u32, path);
        errdefer self.allocator.free(stored);
        try self.syntax_paths.append(self.allocator, stored);
        return stored;
    }

    fn pathFromRoot(allocator: std.mem.Allocator, root: ts.Node, target: ts.Node) ![]u32 {
        var stack = try std.ArrayListUnmanaged(u32).initCapacity(allocator, 8);
        errdefer stack.deinit(allocator);

        var current = target;
        while (!current.eql(root)) {
            if (current.isNull()) return error.InvalidNode;
            const parent = current.parent();
            if (parent.isNull()) return error.InvalidNode;
            const child_index = childIndex(parent, current) orelse return error.InvalidNode;
            try stack.append(allocator, child_index);
            current = parent;
        }

        std.mem.reverse(u32, stack.items);
        return stack.toOwnedSlice(allocator);
    }

    fn childIndex(parent: ts.Node, child: ts.Node) ?u32 {
        const count = parent.childCount();
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (parent.child(i).eql(child)) return i;
        }
        return null;
    }

    fn nodeAtPath(root: ts.Node, path: []const u32) ?ts.Node {
        var current = root;
        for (path) |child_index| {
            if (child_index >= current.childCount()) return null;
            current = current.child(child_index);
            if (current.isNull()) return null;
        }
        return current;
    }

    fn graphemeStartByte(grapheme_to_byte: []const u32, position: u32) u32 {
        if (grapheme_to_byte.len == 0) return 0;
        const idx = @min(position, grapheme_to_byte.len - 1);
        return grapheme_to_byte[idx];
    }

    fn graphemeEndByte(grapheme_to_byte: []const u32, position: u32, text_len: u32) u32 {
        if (grapheme_to_byte.len == 0) return text_len;
        const next = position + 1;
        if (next < grapheme_to_byte.len) return grapheme_to_byte[next];
        return text_len;
    }

    fn buildSpans(
        self: *TreeSitterTokenProvider,
        source: []const u8,
        tree: ts.Tree,
        grapheme_to_byte: []const u32,
    ) ![]views.TokenSpan {
        var raw_spans: std.ArrayListUnmanaged(views.TokenSpan) = .empty;
        errdefer raw_spans.deinit(self.allocator);

        self.cursor.exec(self.query, tree.rootNode());
        self.cursor.setByteRange(0, @intCast(source.len));

        while (self.cursor.nextMatch()) |match| {
            if (!self.matchPassesPredicates(match, source)) continue;
            for (match.captures) |capture| {
                const capture_name = self.query.captureNameForId(capture.index) orelse continue;
                const styled = classifyCapture(capture_name) orelse continue;
                const start = graphemeIndexForStartByte(grapheme_to_byte, capture.node.startByte());
                const end = graphemeIndexForEndByte(grapheme_to_byte, capture.node.endByte());
                if (end <= start) continue;
                try raw_spans.append(self.allocator, .{
                    .start = start,
                    .end = end,
                    .kind = styled.kind,
                    .style = styled.style,
                });
            }
        }

        if (raw_spans.items.len == 0) {
            return &.{};
        }

        std.mem.sort(views.TokenSpan, raw_spans.items, {}, struct {
            fn lessThan(_: void, a: views.TokenSpan, b: views.TokenSpan) bool {
                if (a.start != b.start) return a.start < b.start;
                if (a.end != b.end) return a.end > b.end;
                const a_priority = spanPriority(a);
                const b_priority = spanPriority(b);
                if (a_priority != b_priority) return a_priority > b_priority;
                return std.mem.order(u8, a.kind, b.kind) == .lt;
            }
        }.lessThan);

        var filtered: std.ArrayListUnmanaged(views.TokenSpan) = .empty;
        errdefer filtered.deinit(self.allocator);

        var covered_end: u32 = 0;
        for (raw_spans.items) |span| {
            if (span.start < covered_end) continue;
            try filtered.append(self.allocator, span);
            covered_end = span.end;
        }

        raw_spans.deinit(self.allocator);
        return filtered.toOwnedSlice(self.allocator);
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
        match: ts.Match,
        source: []const u8,
    ) bool {
        const steps = self.query.predicatesForPattern(match.pattern_index);
        if (steps.len == 0) return true;

        var index: usize = 0;
        while (index < steps.len) {
            const start = index;
            while (index < steps.len and steps[index].type != .done) : (index += 1) {}
            if (!self.evaluatePredicate(match, source, steps[start..index])) {
                return false;
            }
            index += 1;
        }
        return true;
    }

    fn evaluatePredicate(
        self: *TreeSitterTokenProvider,
        match: ts.Match,
        source: []const u8,
        steps: []const ts.QueryPredicateStep,
    ) bool {
        if (steps.len == 0 or steps[0].type != .string) return true;
        const name = self.query.stringValueForId(steps[0].value_id) orelse return true;

        if (isPredicateName(name, "eq?")) {
            if (steps.len != 3) return true;
            const lhs = self.predicateCaptureText(match, source, steps[1]) orelse return true;
            const rhs = self.predicateStringValue(steps[2]) orelse return true;
            return std.mem.eql(u8, lhs, rhs);
        }

        if (isPredicateName(name, "match?") or isPredicateName(name, "lua-match?")) {
            if (steps.len != 3) return true;
            const lhs = self.predicateCaptureText(match, source, steps[1]) orelse return true;
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
            const lhs = self.predicateCaptureText(match, source, steps[1]) orelse return true;
            for (steps[2..]) |step| {
                const option = self.predicateStringValue(step) orelse continue;
                if (std.mem.eql(u8, lhs, option)) return true;
            }
            return false;
        }

        return true;
    }

    fn predicateCaptureText(
        self: *TreeSitterTokenProvider,
        match: ts.Match,
        source: []const u8,
        step: ts.QueryPredicateStep,
    ) ?[]const u8 {
        if (step.type != .capture) return null;
        const capture_name = self.query.captureNameForId(step.value_id) orelse return null;
        for (match.captures) |capture| {
            const name = self.query.captureNameForId(capture.index) orelse continue;
            if (std.mem.eql(u8, name, capture_name)) {
                return capture.node.text(source);
            }
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

    fn graphemeIndexForStartByte(grapheme_to_byte: []const u32, byte: u32) u32 {
        return lowerBound(grapheme_to_byte, byte);
    }

    fn graphemeIndexForEndByte(grapheme_to_byte: []const u32, byte: u32) u32 {
        return lowerBound(grapheme_to_byte, byte);
    }

    fn lowerBound(values: []const u32, needle: u32) u32 {
        var low: usize = 0;
        var high: usize = values.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (values[mid] < needle) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return @intCast(@min(low, values.len - 1));
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

test "tree-sitter syntax path encodes unnamed nodes" {
    var parser = try ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(ts.luaLanguage());

    const source = "local x = 42\n";
    var tree = try parser.parseString(source, null);
    defer tree.destroy();

    const root = tree.rootNode();
    const unnamed = findFirstUnnamedNode(root) orelse return error.TestExpectedEqual;
    const path = try TreeSitterTokenProvider.pathFromRoot(std.testing.allocator, root, unnamed);
    defer std.testing.allocator.free(path);
    try std.testing.expect(path.len > 0);

    const resolved = TreeSitterTokenProvider.nodeAtPath(root, path) orelse return error.TestExpectedEqual;
    try std.testing.expect(resolved.eql(unnamed));
    try std.testing.expect(!unnamed.isNamed());
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
