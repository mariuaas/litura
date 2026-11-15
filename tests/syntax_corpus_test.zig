//! Syntax views agree with recomputation across a corpus of substantially different
//! grammars: test-only fixtures pinned in `build.zig.zon` (`-Dsyntax-corpus=true`).
//!
//! Method: every example of each grammar's own test corpus, and a larger hand-written
//! sample, goes through seeded random editing: copies of the document's own text,
//! deletions, replacements, Unicode fragments that resegment graphemes, multi-operation
//! transactions, multi-cursor composites, undo and redo. Views are refreshed either
//! uninterrupted or under budgets that halt parses, with edits arriving while a parse is
//! halted. After every refresh the views are compared with a fresh engine parsing the
//! same text: exactly when that text parses without errors, and otherwise for coherence,
//! because Tree-sitter's error recovery depends on the trees it reuses and on where a
//! halted parse resumed. Finally every edit is undone, and the original text must parse
//! as it did. Seeds are fixed; a failure names the grammar, document and seed.
//!
//! Tree-sitter's incremental parse can itself differ from a fresh parse of error-free
//! text after several edits (observed with tree-sitter-ocaml's quoted strings). So beside
//! the provider runs an oracle: a raw Tree-sitter tree given one edit per committed block,
//! derived independently from the texts before and after, and reparsed whenever the
//! provider's views become current. A difference from the fresh parse that the oracle
//! reproduces exactly is Tree-sitter's, and is counted and reported; any other is a
//! failure.
const std = @import("std");
const litura = @import("litura");
const corpus = @import("syntax_corpus");
const options = @import("syntax_corpus_options");
const support = @import("support.zig");
const BufferEngine = litura.BufferEngine;
const TreeSitter = litura.tree_sitter.TreeSitterTokenProvider;
const Grammar = litura.tree_sitter.Grammar;
const views = litura.views;
const types = litura.types;
const allocator = std.testing.allocator;

const base_seed: u64 = 0x5eed_c0de;

/// Halts a refresh after a fixed number of progress checks.
const StepBudget = struct {
    remaining: u32,

    fn budget(self: *StepBudget) views.RefreshBudget {
        return .{ .context = self, .exhausted = exhausted };
    }

    fn exhausted(context: ?*anyopaque) bool {
        const self: *StepBudget = @ptrCast(@alignCast(context.?));
        if (self.remaining == 0) return true;
        self.remaining -= 1;
        return false;
    }
};

/// What a run exercised, for the report.
const Stats = struct {
    documents: usize = 0,
    steps: usize = 0,
    exact: usize = 0,
    with_errors: usize = 0,
    halts: usize = 0,
    clean_originals: usize = 0,
    /// Exact comparisons where Tree-sitter's own incremental parse differed from fresh.
    upstream_divergences: usize = 0,

    fn add(self: *Stats, other: Stats) void {
        inline for (std.meta.fields(Stats)) |field| {
            @field(self, field.name) += @field(other, field.name);
        }
    }
};

const RawParser = @FieldType(TreeSitter, "parser");
const RawTree = @typeInfo(@FieldType(TreeSitter, "tree")).optional.child;

/// Tree-sitter driven directly, without Litura: one edit per committed block, derived
/// from the text before and after it, and a reparse when the provider's views catch up.
const Oracle = struct {
    parser: RawParser,
    tree: RawTree,
    text: []u8,

    fn init(grammar: *const Grammar, text: []const u8) !Oracle {
        var parser = try RawParser.create();
        errdefer parser.destroy();
        try parser.setLanguage(grammar.language());
        const owned = try allocator.dupe(u8, text);
        errdefer allocator.free(owned);
        return .{ .parser = parser, .tree = try parser.parseString(owned, null), .text = owned };
    }

    fn deinit(self: *Oracle) void {
        self.tree.destroy();
        self.parser.destroy();
        allocator.free(self.text);
    }

    /// Records the change from the last text to `now`, taking ownership of it, as one
    /// edit covering every byte that differs.
    fn record(self: *Oracle, now: []u8) void {
        const old = self.text;
        var prefix: usize = 0;
        while (prefix < old.len and prefix < now.len and old[prefix] == now[prefix]) prefix += 1;
        var suffix: usize = 0;
        while (suffix < old.len - prefix and suffix < now.len - prefix and
            old[old.len - 1 - suffix] == now[now.len - 1 - suffix]) suffix += 1;
        const start = pointOf(old, prefix);
        const old_end = pointOf(old, old.len - suffix);
        const new_end = pointOf(now, now.len - suffix);
        self.tree.edit(.{
            .start_byte = @intCast(prefix),
            .old_end_byte = @intCast(old.len - suffix),
            .new_end_byte = @intCast(now.len - suffix),
            .start_point = .{ .row = start.row, .column = start.column },
            .old_end_point = .{ .row = old_end.row, .column = old_end.column },
            .new_end_point = .{ .row = new_end.row, .column = new_end.column },
        });
        allocator.free(old);
        self.text = now;
    }

    fn reparse(self: *Oracle) !void {
        const next = try self.parser.parseString(self.text, self.tree);
        self.tree.destroy();
        self.tree = next;
    }

    fn pointOf(text: []const u8, byte: usize) struct { row: u32, column: u32 } {
        const prefix = text[0..byte];
        const line_start = if (std.mem.lastIndexOfScalar(u8, prefix, '\n')) |last| last + 1 else 0;
        return .{
            .row = @intCast(std.mem.count(u8, prefix, "\n")),
            .column = @intCast(byte - line_start),
        };
    }
};

fn provider(engine: *BufferEngine) *TreeSitter {
    return @ptrCast(@alignCast(engine.view_providers.get("syntax").?.ptr));
}

fn expectSameSpans(expected: []const views.TokenSpan, actual: []const views.TokenSpan) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |left, right| {
        try std.testing.expectEqual(left.start, right.start);
        try std.testing.expectEqual(left.end, right.end);
        try std.testing.expectEqualStrings(left.kind, right.kind);
    }
}

const Outcome = enum {
    /// The text parses without errors, and the views equal a fresh parse's.
    exact,
    /// The text parses without errors, but Tree-sitter's own incremental parse differs.
    upstream_divergence,
    /// The text has syntax errors; the views are coherent with the provider's tree.
    with_errors,
};

/// Checks the views of `engine` against a fresh parse of its text. Exact when that parse
/// has no errors, unless `oracle` shows Tree-sitter's own incremental parse differs the
/// same way (counted in `stats`); otherwise checks that the views are coherent with the
/// provider's own tree.
fn check(
    engine: *BufferEngine,
    grammar: *const Grammar,
    random: std.Random,
    oracle: *Oracle,
    stats: *Stats,
) !Outcome {
    const text = try engine.getText();
    defer allocator.free(text);
    const count = engine.graphemeCount();

    // The views describe the current revision, and the tree covers the whole text.
    const state = engine.queryViewState("syntax");
    try std.testing.expectEqual(views.ViewStateKind.available, state.kind);
    try std.testing.expectEqual(@as(?u32, engine.revision), state.revision);
    const root = provider(engine).tree.?.rootNode();
    try std.testing.expectEqual(@as(u32, @intCast(text.len)), root.endByte());

    var reference = try BufferEngine.initFromText(allocator, text, null);
    defer reference.deinit();
    try std.testing.expect(try TreeSitter.attach(&reference, grammar));
    _ = reference.refreshView("syntax", .unlimited);
    const reference_root = provider(&reference).tree.?.rootNode();
    var exact = !reference_root.hasError();
    var diverged = false;

    if (exact) {
        const incremental = try root.toSexp(allocator);
        defer allocator.free(incremental);
        const fresh = try reference_root.toSexp(allocator);
        defer allocator.free(fresh);
        if (!std.mem.eql(u8, fresh, incremental)) {
            const raw = try oracle.tree.rootNode().toSexp(allocator);
            defer allocator.free(raw);
            // Not reproduced by Tree-sitter alone: the difference is Litura's.
            try std.testing.expectEqualStrings(raw, incremental);
            stats.upstream_divergences += 1;
            std.debug.print(
                "upstream divergence in {s}: text {f}\n",
                .{ grammar.name, std.zig.fmtString(text) },
            );
            // The views still answer from the provider's tree, so check them for coherence.
            exact = false;
            diverged = true;
        }
    }

    const whole = try engine.queryTokenSpans(0, count, null);
    defer allocator.free(whole);
    var covered: u32 = 0;
    for (whole) |span| {
        // Ordered, disjoint, non-empty and inside the text.
        try std.testing.expect(span.start >= covered);
        try std.testing.expect(span.end > span.start);
        try std.testing.expect(span.end <= count);
        covered = span.end;
    }
    if (exact) {
        const fresh = try reference.queryTokenSpans(0, count, null);
        defer allocator.free(fresh);
        try expectSameSpans(fresh, whole);
    }

    for (0..3) |_| {
        // A window's spans are the whole document's spans that intersect it.
        const start = random.uintAtMost(u32, count);
        const end = start + random.uintAtMost(u32, count - start);
        const window = try engine.queryTokenSpans(start, end, null);
        defer allocator.free(window);
        var restricted: std.ArrayListUnmanaged(views.TokenSpan) = .empty;
        defer restricted.deinit(allocator);
        for (whole) |span| {
            if (span.end > start and span.start < end) try restricted.append(allocator, span);
        }
        try expectSameSpans(restricted.items, window);

        const position = random.uintAtMost(u32, count);
        const node = (try engine.queryEnclosingSyntaxNode(position, null)) orelse continue;
        // The reference resolves to a node of the provider's tree with the same kind and
        // range, and that node contains the grapheme.
        var remaining = node.ref.id;
        const resolved = preorderNode(root, &remaining).?;
        try std.testing.expectEqualStrings(resolved.type(), node.kind);
        try std.testing.expectEqual(
            try engine.table.positionAtByte(resolved.startByte(), .down),
            node.start,
        );
        try std.testing.expectEqual(
            try engine.table.positionAtByte(resolved.endByte(), .up),
            node.end,
        );
        try std.testing.expect(node.start <= position);
        try std.testing.expect(node.end >= position);
        const again = try engine.querySyntaxNodeInfo(node.ref);
        try std.testing.expectEqualStrings(node.kind, again.kind);
        try std.testing.expectEqual(node.start, again.start);
        if (exact) {
            const fresh = (try reference.queryEnclosingSyntaxNode(position, null)).?;
            try std.testing.expectEqualStrings(fresh.kind, node.kind);
            try std.testing.expectEqual(fresh.start, node.start);
            try std.testing.expectEqual(fresh.end, node.end);
            try std.testing.expectEqual(fresh.ref.id, node.ref.id);
        }
    }
    if (diverged) return .upstream_divergence;
    return if (exact) .exact else .with_errors;
}

/// The node `remaining.*` steps into a preorder walk of visible nodes from `node`: the
/// meaning of a node reference's id, computed independently of the provider.
fn preorderNode(node: anytype, remaining: *u32) ?@TypeOf(node) {
    if (remaining.* == 0) return node;
    remaining.* -= 1;
    var index: u32 = 0;
    while (index < node.childCount()) : (index += 1) {
        if (preorderNode(node.child(index), remaining)) |found| return found;
    }
    return null;
}

const unicode_fragments = [_][]const u8{
    "e\u{0301}", "\u{0301}", "\r\n", "\n", "\t", "\u{1f44d}\u{1f3fd}", "\u{1f1f3}\u{1f1f4}", "\u{00e9}",
};

const Workload = struct {
    engine: *BufferEngine,
    random: std.Random,
    budgeted: bool,
    stats: *Stats,
    oracle: *Oracle,
    /// Whether edits may arrive while a parse is halted. Off around the original text,
    /// which the run compares before editing and after undoing every edit.
    interleave: bool = false,
    /// Whether to make only edits that usually keep the program valid, so that most
    /// comparisons are exact.
    neutral_only: bool = false,

    fn submit(self: *Workload, payload: types.IntentPayload) !void {
        var result = try self.engine.submit(
            .{ .id = support.id, .origin = self.engine.revision, .payload = payload },
        );
        result.deinit(allocator);
        self.oracle.record(try self.engine.getText());
        // An edit makes the views stale, and stale views are never served.
        if (self.engine.queryViewState("syntax").kind == .stale) {
            try std.testing.expectError(error.ViewStale, self.engine.queryTokenSpans(0, 0, null));
        }
    }

    /// A random range of up to `limit` graphemes inside the text.
    fn range(self: *Workload, limit: u32) struct { u32, u32 } {
        const count = self.engine.graphemeCount();
        const start = self.random.uintAtMost(u32, count);
        return .{ start, start + self.random.uintAtMost(u32, @min(limit, count - start)) };
    }

    /// Text to insert: a copy of part of the document, or a Unicode fragment.
    fn fragment(self: *Workload, storage: *std.ArrayListUnmanaged(u8)) ![]const u8 {
        if (self.random.uintLessThan(u8, 3) == 0) {
            return unicode_fragments[self.random.uintLessThan(usize, unicode_fragments.len)];
        }
        const start, const end = self.range(16);
        const text = try self.engine.getTextRange(start, end);
        defer allocator.free(text);
        storage.clearRetainingCapacity();
        try storage.appendSlice(allocator, text);
        return storage.items;
    }

    /// A position just after a space that follows a token, mid-line: one more space
    /// there keeps most programs in these languages valid while shifting the columns of
    /// what follows. Null if the text has none.
    fn neutralPosition(self: *Workload) !?u32 {
        const text = try self.engine.getText();
        defer allocator.free(text);
        if (text.len < 2) return null;
        const from = self.random.uintLessThan(usize, text.len);
        for (0..text.len) |offset| {
            const index = (from + offset) % text.len;
            if (index == 0 or text[index] != ' ') continue;
            const before = text[index - 1];
            if (before == ' ' or before == '\t' or before == '\n' or before == '\r') continue;
            return try self.engine.table.positionAtByte(@intCast(index + 1), .down);
        }
        return null;
    }

    fn step(self: *Workload) !void {
        var storage: [4]std.ArrayListUnmanaged(u8) = .{ .empty, .empty, .empty, .empty };
        defer for (&storage) |*buffer| buffer.deinit(allocator);
        var ops: [4]types.BufferOp = undefined;
        self.stats.steps += 1;
        const choice = if (self.neutral_only)
            ([_]u8{ 10, 10, 11, 11, 6, 7 })[self.random.uintLessThan(usize, 6)]
        else
            self.random.uintLessThan(u8, 13);
        switch (choice) {
            0, 1, 2 => {
                const start, const end = self.range(8);
                ops[0] = if (self.random.boolean())
                    .{
                        .replace = .{
                            .start = start,
                            .end = end,
                            .text = try self.fragment(&storage[0]),
                        },
                    }
                else
                    .{ .delete = .{ .start = start, .end = end } };
                if (ops[0] == .delete and start == end) {
                    ops[0] = .{
                        .insert = .{ .pos = start, .text = try self.fragment(&storage[0]) },
                    };
                }
                try self.submit(.{ .buffer_mutation = .{ .ops = ops[0..1] } });
            },
            3, 4 => {
                // Distant inserts in one transaction; descending positions stay valid.
                const count = 2 + self.random.uintLessThan(usize, 3);
                var limit = self.engine.graphemeCount();
                for (ops[0..count], storage[0..count]) |*op, *buffer| {
                    const at = self.random.uintAtMost(u32, limit);
                    op.* = .{ .insert = .{ .pos = at, .text = try self.fragment(buffer) } };
                    limit = at;
                }
                try self.submit(.{ .buffer_mutation = .{ .ops = ops[0..count] } });
            },
            5 => {
                // A multi-cursor edit with a caret placed after the inserted text.
                const session, const cursor = try support.caret(
                    self.engine,
                    self.engine.graphemeCount() / 2,
                );
                defer support.dropSession(self.engine, session) catch {};
                const at = self.random.uintAtMost(u32, self.engine.graphemeCount());
                const first = try self.fragment(&storage[0]);
                const second = try self.fragment(&storage[1]);
                try self.submit(.{ .composite = .{ .parts = &.{
                    .{ .buffer_mutation = .{ .ops = &.{
                        .{ .insert = .{ .pos = at, .text = first } },
                        .{ .insert = .{ .pos = 0, .text = second } },
                    } } },
                    .{
                        .interaction_mutation = .{
                            .session_id = session,
                            .origin = 0,
                            .ops = &.{.{ .set_selections = .{
                                .selections = &.{
                                    support.placeSpec(cursor, .{ .edit = .{ .op = 0 } }, null),
                                },
                            } }},
                        },
                    },
                } } });
            },
            6, 12 => try self.submit(.{ .undo = .{} }),
            7 => try self.submit(.{ .redo = .{} }),
            10, 11 => {
                // Edits that usually keep the program valid, alone or several in one
                // transaction at descending positions.
                const count: usize = if (self.random.boolean()) 1 else 2 + self.random.uintLessThan(
                    usize,
                    3,
                );
                var used: usize = 0;
                var limit: u32 = std.math.maxInt(u32);
                for (0..count) |_| {
                    const at = (try self.neutralPosition()) orelse break;
                    if (at >= limit) continue;
                    ops[used] = .{ .insert = .{ .pos = at, .text = " " } };
                    used += 1;
                    limit = at;
                }
                if (used == 0) return;
                try self.submit(.{ .buffer_mutation = .{ .ops = ops[0..used] } });
            },
            else => {
                ops[0] = .{
                    .insert = .{ .pos = self.range(0)[0], .text = try self.fragment(&storage[0]) },
                };
                try self.submit(.{ .buffer_mutation = .{ .ops = ops[0..1] } });
            },
        }
    }

    /// Refreshes until current. Under a budget, parses halt and edits sometimes arrive
    /// while one is halted, as when typing; they stop after a while, as when it pauses.
    fn refresh(self: *Workload) !void {
        if (!self.budgeted) {
            const state = self.engine.refreshView("syntax", .unlimited);
            try std.testing.expectEqual(views.ViewStateKind.available, state.kind);
            return self.oracle.reparse();
        }
        for (0..100_000) |call| {
            var budget = StepBudget{ .remaining = self.random.uintAtMost(u32, 6) };
            const state = self.engine.refreshView("syntax", budget.budget());
            if (state.kind == .available) return self.oracle.reparse();
            try std.testing.expectEqual(views.ViewStateKind.stale, state.kind);
            try std.testing.expectError(error.ViewStale, self.engine.queryTokenSpans(0, 0, null));
            self.stats.halts += 1;
            if (self.interleave and call < 20 and self.random.uintLessThan(
                u8,
                4,
            ) == 0) try self.step();
        }
        return error.RefreshNeverCompleted;
    }
};

/// Edits `text` for `steps` random steps under each refresh mode, then undoes every edit.
fn runDocument(
    grammar: *const Grammar,
    text: []const u8,
    seed: u64,
    steps: usize,
    stats: *Stats,
) !void {
    for ([_]bool{ false, true }) |budgeted| {
        var engine = try BufferEngine.initFromText(allocator, text, null);
        defer engine.deinit();
        try std.testing.expect(try TreeSitter.attach(&engine, grammar));
        var prng = std.Random.DefaultPrng.init(seed);
        var oracle = try Oracle.init(grammar, text);
        defer oracle.deinit();
        var workload = Workload{
            .engine = &engine,
            .random = prng.random(),
            .budgeted = budgeted,
            .stats = stats,
            .oracle = &oracle,
        };
        stats.documents += 1;

        try workload.refresh();
        const original = try check(&engine, grammar, workload.random, &oracle, stats);
        const clean = original != .with_errors;
        stats.clean_originals += @intFromBool(clean);
        workload.interleave = true;
        for (0..steps) |_| {
            try workload.step();
            try workload.refresh();
            switch (try check(&engine, grammar, workload.random, &oracle, stats)) {
                .exact => stats.exact += 1,
                .with_errors => stats.with_errors += 1,
                .upstream_divergence => {},
            }
        }

        // Undoing every edit restores the original, which parses as it did at first.
        workload.interleave = false;
        while (engine.undo_stack.items.len > 0) try workload.submit(.{ .undo = .{} });
        try workload.refresh();
        try support.expectText(&engine, text);
        const restored = try check(&engine, grammar, workload.random, &oracle, stats);
        try std.testing.expectEqual(clean, restored != .with_errors);

        // Edits that keep the program valid, so that the comparisons are exact: spaces
        // between tokens, alone and several per transaction, with undo, redo and halts.
        workload.neutral_only = true;
        workload.interleave = true;
        for (0..steps / 2) |_| {
            try workload.step();
            try workload.refresh();
            switch (try check(&engine, grammar, workload.random, &oracle, stats)) {
                .exact => stats.exact += 1,
                .with_errors => stats.with_errors += 1,
                .upstream_divergence => {},
            }
        }
    }
}

/// The examples of a Tree-sitter test corpus file that apply to `language`: the code
/// between each header and the last dashed divider before the next header.
fn corpusExamples(
    file: []const u8,
    language: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(allocator);
    var iterator = std.mem.splitScalar(u8, file, '\n');
    while (iterator.next()) |line| try lines.append(allocator, std.mem.trimEnd(u8, line, "\r"));

    var index: usize = 0;
    while (index < lines.items.len) {
        if (!isRule(lines.items[index], '=')) {
            index += 1;
            continue;
        }
        // The header: title and attribute lines up to the closing rule.
        var skip = false;
        var cursor = index + 1;
        while (cursor < lines.items.len and !isRule(lines.items[cursor], '=')) : (cursor += 1) {
            const line = lines.items[cursor];
            if (std.mem.eql(u8, line, ":skip")) skip = true;
            if (std.mem.startsWith(u8, line, ":language(")) {
                const close = std.mem.indexOfScalar(u8, line, ')') orelse line.len;
                const name = line[":language(".len..close];
                if (!std.mem.eql(u8, name, language)) skip = true;
            }
        }
        const body = cursor + 1;
        var next = body;
        while (next < lines.items.len) : (next += 1) {
            if (isRule(lines.items[next], '=') and hasClosingRule(lines.items, next)) break;
        }
        var divider: ?usize = null;
        for (body..next) |line_index| {
            if (isRule(lines.items[line_index], '-')) divider = line_index;
        }
        if (divider) |end| {
            if (!skip and end > body) {
                const first = lines.items[body];
                const last = lines.items[end - 1];
                const start_offset = @intFromPtr(first.ptr) - @intFromPtr(file.ptr);
                const end_offset = @intFromPtr(last.ptr) - @intFromPtr(file.ptr) + last.len;
                try out.append(allocator, file[start_offset..end_offset]);
            }
        }
        index = next;
    }
}

fn isRule(line: []const u8, char: u8) bool {
    var count: usize = 0;
    while (count < line.len and line[count] == char) count += 1;
    // A rule may carry a suffix after its marks, as in `===|||`.
    return count >= 3 and std.mem.indexOfScalar(u8, line[count..], ' ') == null;
}

/// Whether the rule at `index` opens a header: a title follows, then a closing rule.
fn hasClosingRule(lines: []const []const u8, index: usize) bool {
    var cursor = index + 1;
    while (cursor < lines.len and cursor < index + 8) : (cursor += 1) {
        if (isRule(lines[cursor], '=')) return cursor > index + 1;
        if (lines[cursor].len == 0) return false;
    }
    return false;
}

test "syntax views agree with full reparsing across the grammar corpus" {
    var total: Stats = .{};
    for (&corpus.entries, 0..) |*entry, grammar_index| {
        var stats: Stats = .{};
        var examples: std.ArrayListUnmanaged([]const u8) = .empty;
        defer examples.deinit(allocator);
        for (entry.corpus) |file| try corpusExamples(file, entry.name, &examples);

        for (examples.items, 0..) |example, example_index| {
            const seed = base_seed ^ (grammar_index << 32) ^ example_index;
            runDocument(&entry.grammar, example, seed, options.steps, &stats) catch |err| {
                std.debug.print(
                    "\n{s} corpus example {d}, seed 0x{x}:\n{s}\n",
                    .{ entry.name, example_index, seed, example },
                );
                return err;
            };
        }
        // The hand-written sample, alone and repeated into a long document.
        var long: std.ArrayListUnmanaged(u8) = .empty;
        defer long.deinit(allocator);
        for (0..8) |_| try long.appendSlice(allocator, entry.sample);
        for ([_][]const u8{ entry.sample, long.items }, 0..) |document, sample_index| {
            const seed = base_seed ^ (grammar_index << 32) ^ (0xffff + sample_index);
            runDocument(&entry.grammar, document, seed, options.steps * 3, &stats) catch |err| {
                std.debug.print(
                    "\n{s} sample {d}, seed 0x{x}\n",
                    .{ entry.name, sample_index, seed },
                );
                return err;
            };
        }
        std.debug.print("corpus {s:<11} {s:<17} examples {d:>4}  ", .{
            entry.name, entry.version, examples.items.len,
        });
        std.debug.print("documents {d:>4}  steps {d:>6}  exact {d:>6}  with errors {d:>5}  ", .{
            stats.documents, stats.steps, stats.exact, stats.with_errors,
        });
        std.debug.print("halts {d:>6}  clean originals {d:>4}  upstream divergences {d}\n", .{
            stats.halts, stats.clean_originals, stats.upstream_divergences,
        });
        total.add(stats);
    }
    std.debug.print(
        "corpus total: {d} documents, {d} steps, {d} exact, {d} with errors, {d} halts, " ++
            "{d} upstream divergences\n",
        .{
            total.documents,
            total.steps,
            total.exact,
            total.with_errors,
            total.halts,
            total.upstream_divergences,
        },
    );
}

test "token and node queries over every corpus grammar survive allocation failure" {
    // Method: fail each allocation of a whole-document token query and a node query in
    // turn; each either succeeds with the correct answer or reports OutOfMemory, and
    // the view stays available.
    for (&corpus.entries) |*entry| {
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        var engine = try BufferEngine.initFromText(failing.allocator(), entry.sample, null);
        defer engine.deinit();
        try std.testing.expect(try TreeSitter.attach(&engine, &entry.grammar));
        _ = engine.refreshView("syntax", .unlimited);
        const expected = try engine.queryTokenSpans(0, engine.graphemeCount(), null);
        defer engine.allocator.free(expected);
        var fail_after: usize = 0;
        while (true) : (fail_after += 1) {
            failing.has_induced_failure = false;
            failing.fail_index = failing.alloc_index + fail_after;
            const spans = engine.queryTokenSpans(0, engine.graphemeCount(), null);
            const node = engine.queryEnclosingSyntaxNode(engine.graphemeCount() / 2, null);
            const failed = failing.has_induced_failure;
            failing.fail_index = std.math.maxInt(usize);
            if (spans) |result| {
                defer engine.allocator.free(result);
                if (!failed) {
                    try expectSameSpans(expected, result);
                    _ = try node;
                    break;
                }
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
            _ = node catch |err| try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(
                views.ViewStateKind.available,
                engine.queryViewState("syntax").kind,
            );
        }
    }
}
