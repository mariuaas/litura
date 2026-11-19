//! Syntax views across a corpus of substantially different grammars: test-only fixtures
//! pinned in `build.zig.zon` (`-Dsyntax-corpus=true`). The suite answers two questions
//! separately: does Litura integrate Tree-sitter's incremental operations correctly, and
//! does the Tree-sitter version provide structurally valid trees?
//!
//! Method: every example of each grammar's own test corpus, and a larger hand-written
//! sample, goes through seeded random editing: copies of the document's own text,
//! deletions, replacements, Unicode fragments that resegment graphemes, multi-operation
//! transactions, multi-cursor composites, undo and redo. Views are refreshed either
//! uninterrupted or under budgets that halt parses, with edits arriving between refresh
//! calls. Edits, the refresh schedule and the checks draw on separate random streams,
//! and nothing in the schedule depends on parser outcomes, so a seed
//! (`-Dsyntax-corpus-seed`) gives every Tree-sitter version the same edit trace; each
//! grammar's line reports a hash of its trace to confirm it.
//!
//! Integration: beside the provider runs a mirror, raw Tree-sitter driven through its API
//! by the same operations: the same splices, the same budgets in progress checks, a
//! snapshot for a halted parse, and splices queued while one is halted. The provider's
//! tree must equal the mirror's at every check, errors included, and after every refresh
//! call both must have halted or finished at the same point. A difference is
//! `error.IntegrationMismatch`, a Litura defect.
//!
//! Integrity: every check then walks the provider's tree (`syntax_oracle.zig`). A tree
//! whose children cannot be traversed as its summaries describe is identical to the
//! mirror's, so Tree-sitter produced it: `error.UpstreamInconsistentTree`, which fails
//! the run, because node references depend on those summaries whoever is at fault.
//!
//! Agreement: views are compared with a fresh engine parsing the same text, exactly when
//! that text parses without errors. Tree-sitter's incremental parse can differ from a
//! fresh one, depending on the edits and the interruptions it was given (observed with
//! OCaml quoted strings, Bash nested heredocs and C); since the provider's tree equals the
//! mirror's, such differences are Tree-sitter's and are counted, not failed. Otherwise
//! the views must be coherent with the provider's tree. Finally every edit is undone, and
//! the original text must parse as it did. A failure names the grammar, document and
//! seed; a failing grammar stops at its first failure, and the others still run.
const std = @import("std");
const litura = @import("litura");
const corpus = @import("syntax_corpus");
const options = @import("syntax_corpus_options");
const support = @import("support.zig");
const structure = @import("syntax_oracle.zig");
const BufferEngine = litura.BufferEngine;
const TreeSitter = litura.tree_sitter.TreeSitterTokenProvider;
const Grammar = litura.tree_sitter.Grammar;
const views = litura.views;
const types = litura.types;
const allocator = std.testing.allocator;

const base_seed: u64 = options.seed;

/// Halts a refresh after a fixed number of progress checks.
const StepBudget = struct {
    remaining: u32,

    fn budget(self: *StepBudget) views.RefreshBudget {
        return .{ .context = self, .exhausted = exhausted };
    }

    fn exhausted(context: ?*anyopaque) bool {
        const self: *StepBudget = @ptrCast(@alignCast(context.?));
        return self.poll();
    }

    fn haltParse(context: *anyopaque) bool {
        const self: *StepBudget = @ptrCast(@alignCast(context));
        return self.poll();
    }

    /// One progress check: true once the budget is spent.
    fn poll(self: *StepBudget) bool {
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
    /// Enclosing-range queries, and parent steps from their answers to the root.
    range_queries: usize = 0,
    parent_steps: usize = 0,
    /// Parent steps to a node with the same range as its child.
    same_range_parents: usize = 0,
    /// Every committed text in order, hashed: equal across Tree-sitter versions exactly
    /// when the edit traces are.
    trace: u64 = 0,

    fn add(self: *Stats, other: Stats) void {
        inline for (std.meta.fields(Stats)) |field| {
            if (comptime std.mem.eql(u8, field.name, "trace")) {
                self.trace = std.hash.Wyhash.hash(self.trace, std.mem.asBytes(&other.trace));
            } else {
                @field(self, field.name) += @field(other, field.name);
            }
        }
    }
};

const RawParser = @FieldType(TreeSitter, "parser");
const RawTree = @typeInfo(@FieldType(TreeSitter, "tree")).optional.child;

const RawParseInput = @typeInfo(@TypeOf(RawParser.parseInput)).@"fn".params;
const RawInput = RawParseInput[2].type.?;
const RawProgress = @typeInfo(RawParseInput[3].type.?).optional.child;

/// Raw Tree-sitter driven through its API by the operations of an incremental, budgeted
/// refresh, written from the protocol rather than from the provider:
///
/// - a block's splices edit the last completed tree, or are queued while a parse is
///   halted;
/// - a parse reads the current text; a halted parse resumes on the text it started with;
/// - the budget is consulted by Tree-sitter's progress callback, and once before each
///   further parse in the same refresh;
/// - when a halted parse completes, its tree takes the queued splices, and the refresh
///   goes on parsing toward the current text.
///
/// Given the same edits and the same budgets as the provider, Tree-sitter receives the
/// same operations, so the trees must be identical, errors included. Interruption points
/// are counts of progress checks, never time, so they are deterministic.
const Mirror = struct {
    parser: RawParser,
    /// The last completed parse.
    tree: ?RawTree = null,
    /// The document's current text, owned.
    text: []u8,
    /// Whether `tree` describes `text`.
    current: bool = false,
    /// The text a halted parse reads, owned; null when no parse is halted.
    halted: ?[]u8 = null,
    queued: std.ArrayListUnmanaged(litura.events.RealizedSplice) = .empty,

    fn init(grammar: *const Grammar, text: []const u8) !Mirror {
        var parser = try RawParser.create();
        errdefer parser.destroy();
        try parser.setLanguage(grammar.language());
        return .{ .parser = parser, .text = try allocator.dupe(u8, text) };
    }

    fn deinit(self: *Mirror) void {
        if (self.tree) |*tree| tree.destroy();
        self.parser.destroy();
        allocator.free(self.text);
        if (self.halted) |snapshot| allocator.free(snapshot);
        self.queued.deinit(allocator);
    }

    /// A committed block's splices, and the text after them, which it takes.
    fn edit(self: *Mirror, splices: []const litura.events.RealizedSplice, now: []u8) !void {
        allocator.free(self.text);
        self.text = now;
        if (splices.len == 0) return;
        self.current = false;
        if (self.halted != null) {
            try self.queued.appendSlice(allocator, splices);
        } else if (self.tree) |tree| {
            for (splices) |splice| applySplice(tree, splice);
        }
    }

    fn refresh(self: *Mirror, budget: ?*StepBudget) !void {
        var first = true;
        while (!self.current) : (first = false) {
            if (!first) if (budget) |steps| if (steps.poll()) break;
            var reader = Reader{ .text = self.halted orelse self.text };
            const input = RawInput{ .context = @ptrCast(&reader), .read = Reader.read };
            const progress: ?RawProgress = if (budget) |steps|
                .{ .context = @ptrCast(steps), .halt = StepBudget.haltParse }
            else
                null;
            const tree = try self.parser.parseInput(self.tree, input, progress) orelse {
                if (self.halted == null) self.halted = try allocator.dupe(u8, self.text);
                break;
            };
            if (self.tree) |*old| old.destroy();
            self.tree = tree;
            if (self.halted) |snapshot| {
                allocator.free(snapshot);
                self.halted = null;
                for (self.queued.items) |splice| applySplice(tree, splice);
                self.current = self.queued.items.len == 0;
                self.queued.clearRetainingCapacity();
            } else {
                self.current = true;
            }
        }
    }

    fn applySplice(tree: RawTree, splice: litura.events.RealizedSplice) void {
        tree.edit(.{
            .start_byte = splice.start_byte,
            .old_end_byte = splice.old_end_byte,
            .new_end_byte = splice.new_end_byte,
            .start_point = .{ .row = splice.start_point.row, .column = splice.start_point.column },
            .old_end_point = .{ .row = splice.old_end_point.row, .column = splice.old_end_point.column },
            .new_end_point = .{ .row = splice.new_end_point.row, .column = splice.new_end_point.column },
        });
    }

    const Reader = struct {
        text: []const u8,

        fn read(context: *const anyopaque, byte: u32) []const u8 {
            const self: *const Reader = @ptrCast(@alignCast(context));
            return if (byte >= self.text.len) "" else self.text[byte..];
        }
    };
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

/// Checks the views of `engine`. First the integration contract: the provider's tree is
/// identical to `mirror`'s, raw Tree-sitter given the same operations (else
/// error.IntegrationMismatch). Then the tree's integrity: a tree whose children cannot be
/// traversed as its summaries describe is Tree-sitter's output, so it fails with
/// error.UpstreamInconsistentTree. Then a fresh parse of the same text: exact when that
/// parse has no errors, with differences that the identical mirror shares counted as
/// Tree-sitter's divergences in `stats`; otherwise coherence with the provider's tree.
fn check(
    engine: *BufferEngine,
    grammar: *const Grammar,
    random: std.Random,
    mirror: *Mirror,
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
    {
        try std.testing.expect(mirror.current);
        const incremental = try root.toSexp(allocator);
        defer allocator.free(incremental);
        const raw = try mirror.tree.?.rootNode().toSexp(allocator);
        defer allocator.free(raw);
        if (!std.mem.eql(u8, raw, incremental)) {
            std.debug.print("{s}: integration mismatch; text {f}\nmirror   {s}\nprovider {s}\n", .{
                grammar.name, std.zig.fmtString(text), raw, incremental,
            });
            return error.IntegrationMismatch;
        }
    }
    var table = structure.Table.init(allocator, root) catch |err| {
        if (err != error.InconsistentTree) return err;
        // The mirror's tree is identical; is it inconsistent the same way?
        var mirror_table = structure.Table.init(allocator, mirror.tree.?.rootNode()) catch |mirror_err| {
            if (mirror_err != error.InconsistentTree) return mirror_err;
            std.debug.print("{s}: Tree-sitter produced an inconsistent tree; text {f}\n", .{
                grammar.name, std.zig.fmtString(text),
            });
            return error.UpstreamInconsistentTree;
        };
        mirror_table.deinit(allocator);
        std.debug.print("{s}: identical trees, but only the provider's is inconsistent\n", .{
            grammar.name,
        });
        return error.IntegrationMismatch;
    };
    defer table.deinit(allocator);

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
            // The mirror's tree is identical (checked above): Tree-sitter's divergence.
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
        try std.testing.expect(node.ref.id < table.kind.len);
        try std.testing.expectEqualStrings(table.kind[node.ref.id], node.kind);
        try std.testing.expectEqual(
            try engine.table.positionAtByte(table.start[node.ref.id], .down),
            node.start,
        );
        try std.testing.expectEqual(
            try engine.table.positionAtByte(table.end[node.ref.id], .up),
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
    // Structure: the smallest node around random ranges, and its ancestry to the root,
    // against the independent walk of the provider's tree.
    for (0..3) |_| {
        if (count == 0) break;
        const start = random.uintLessThan(u32, count);
        const rest = count - start - 1;
        const longest = if (random.uintLessThan(u8, 4) == 0) rest else @min(rest, 40);
        const end = start + 1 + random.uintAtMost(u32, longest);
        const node = try engine.queryEnclosingSyntaxNodeRange(start, end, null);
        const start_byte = try engine.table.byteOffset(start);
        const end_byte = try engine.table.byteOffset(end);
        const id: ?u32 = if (node) |found| found.ref.id else null;
        try std.testing.expectEqual(table.enclosing(start_byte, end_byte), id);
        stats.range_queries += 1;
        if (exact) {
            const fresh = try reference.queryEnclosingSyntaxNodeRange(start, end, null);
            try std.testing.expectEqual(if (fresh) |found| found.ref.id else null, id);
        }

        var current = node orelse continue;
        while (try engine.querySyntaxNodeParent(current.ref)) |parent| {
            try std.testing.expectEqual(table.parent[current.ref.id], parent.ref.id);
            const parent_start = try engine.table.positionAtByte(table.start[parent.ref.id], .down);
            const parent_end = try engine.table.positionAtByte(table.end[parent.ref.id], .up);
            try std.testing.expectEqual(parent_start, parent.start);
            try std.testing.expectEqual(parent_end, parent.end);
            try std.testing.expectEqual(table.named[parent.ref.id], parent.is_named);
            try std.testing.expect(parent.start <= current.start and parent.end >= current.end);
            stats.parent_steps += 1;
            const same_range = parent.start == current.start and parent.end == current.end;
            stats.same_range_parents += @intFromBool(same_range);
            current = parent;
        }
        try std.testing.expectEqual(@as(?u32, null), table.parent[current.ref.id]);
    }
    if (diverged) return .upstream_divergence;
    return if (exact) .exact else .with_errors;
}

const unicode_fragments = [_][]const u8{
    "e\u{0301}", "\u{0301}", "\r\n", "\n", "\t", "\u{1f44d}\u{1f3fd}", "\u{1f1f3}\u{1f1f4}", "\u{00e9}",
};

/// Edits a document and refreshes its views on a schedule fixed in advance. Edits draw
/// only on `edits` and the document's text, which depends only on the edits; refresh
/// calls, their budgets and the edits between them draw only on `schedule`. Neither
/// depends on parser outcomes or on the checks, so a seed gives every Tree-sitter version
/// the same edit trace.
const Workload = struct {
    engine: *BufferEngine,
    edits: std.Random,
    schedule: std.Random,
    budgeted: bool,
    stats: *Stats,
    mirror: *Mirror,
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
        defer result.deinit(allocator);
        const splices: []const litura.events.RealizedSplice = switch (result) {
            .committed => |block| switch (block) {
                .transition => |transition| if (transition.edit) |edit| edit.splices else &.{},
                .lifecycle => &.{},
            },
            .rejected => &.{},
        };
        const now = try self.engine.getText();
        self.stats.trace = std.hash.Wyhash.hash(self.stats.trace, now);
        try self.mirror.edit(splices, now);
        // An edit makes the views stale, and stale views are never served.
        if (self.engine.queryViewState("syntax").kind == .stale) {
            try std.testing.expectError(error.ViewStale, self.engine.queryTokenSpans(0, 0, null));
        }
    }

    /// A random range of up to `limit` graphemes inside the text.
    fn range(self: *Workload, limit: u32) struct { u32, u32 } {
        const count = self.engine.graphemeCount();
        const start = self.edits.uintAtMost(u32, count);
        return .{ start, start + self.edits.uintAtMost(u32, @min(limit, count - start)) };
    }

    /// Text to insert: a copy of part of the document, or a Unicode fragment.
    fn fragment(self: *Workload, storage: *std.ArrayListUnmanaged(u8)) ![]const u8 {
        if (self.edits.uintLessThan(u8, 3) == 0) {
            return unicode_fragments[self.edits.uintLessThan(usize, unicode_fragments.len)];
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
        const from = self.edits.uintLessThan(usize, text.len);
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
            ([_]u8{ 10, 10, 11, 11, 6, 7 })[self.edits.uintLessThan(usize, 6)]
        else
            self.edits.uintLessThan(u8, 13);
        switch (choice) {
            0, 1, 2 => {
                const start, const end = self.range(8);
                ops[0] = if (self.edits.boolean())
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
                const count = 2 + self.edits.uintLessThan(usize, 3);
                var limit = self.engine.graphemeCount();
                for (ops[0..count], storage[0..count]) |*op, *buffer| {
                    const at = self.edits.uintAtMost(u32, limit);
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
                const at = self.edits.uintAtMost(u32, self.engine.graphemeCount());
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
                const count: usize = if (self.edits.boolean()) 1 else 2 + self.edits.uintLessThan(
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

    /// Brings the views up to date. Under a budget: a scheduled number of refresh calls,
    /// each with a scheduled budget in progress checks, and scheduled edits between them,
    /// which arrive while a parse is halted whenever one is, as when typing. Then, as when
    /// typing pauses, an unlimited refresh finishes the work. After every call the
    /// provider and the mirror have both halted or both finished, at the same point.
    fn refresh(self: *Workload) !void {
        if (self.budgeted) {
            const calls = 1 + self.schedule.uintLessThan(u32, 8);
            for (0..calls) |_| {
                const steps = self.schedule.uintAtMost(u32, 6);
                const edit_after = self.interleave and self.schedule.uintLessThan(u8, 4) == 0;
                var budget = StepBudget{ .remaining = steps };
                const state = self.engine.refreshView("syntax", budget.budget());
                var mirror_budget = StepBudget{ .remaining = steps };
                try self.mirror.refresh(&mirror_budget);
                try std.testing.expectEqual(state.kind == .available, self.mirror.current);
                try std.testing.expectEqual(budget.remaining, mirror_budget.remaining);
                if (state.kind != .available) {
                    try std.testing.expectEqual(views.ViewStateKind.stale, state.kind);
                    const stale = self.engine.queryTokenSpans(0, 0, null);
                    try std.testing.expectError(error.ViewStale, stale);
                    self.stats.halts += 1;
                }
                if (edit_after) try self.step();
            }
        }
        const state = self.engine.refreshView("syntax", .unlimited);
        try std.testing.expectEqual(views.ViewStateKind.available, state.kind);
        try self.mirror.refresh(null);
        try std.testing.expect(self.mirror.current);
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
        // Three independent streams: edits, the refresh schedule, and the checks' queries.
        var edit_prng = std.Random.DefaultPrng.init(seed);
        var schedule_prng = std.Random.DefaultPrng.init(seed ^ 0x5c4e_d01e);
        var query_prng = std.Random.DefaultPrng.init(seed ^ 0x9e37_79b9);
        const queries = query_prng.random();
        var mirror = try Mirror.init(grammar, text);
        defer mirror.deinit();
        var workload = Workload{
            .engine = &engine,
            .edits = edit_prng.random(),
            .schedule = schedule_prng.random(),
            .budgeted = budgeted,
            .stats = stats,
            .mirror = &mirror,
        };
        stats.documents += 1;

        try workload.refresh();
        const original = try check(&engine, grammar, queries, &mirror, stats);
        const clean = original != .with_errors;
        stats.clean_originals += @intFromBool(clean);
        workload.interleave = true;
        for (0..steps) |_| {
            try workload.step();
            try workload.refresh();
            switch (try check(&engine, grammar, queries, &mirror, stats)) {
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
        const restored = try check(&engine, grammar, queries, &mirror, stats);
        try std.testing.expectEqual(clean, restored != .with_errors);

        // Edits that keep the program valid, so that the comparisons are exact: spaces
        // between tokens, alone and several per transaction, with undo, redo and halts.
        workload.neutral_only = true;
        workload.interleave = true;
        for (0..steps / 2) |_| {
            try workload.step();
            try workload.refresh();
            switch (try check(&engine, grammar, queries, &mirror, stats)) {
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
    // A failing grammar stops at its first failure, which is printed; the others still
    // run, so one failure does not hide the state of the rest.
    var total: Stats = .{};
    var failed: std.ArrayListUnmanaged([]const u8) = .empty;
    defer failed.deinit(allocator);
    grammars: for (&corpus.entries, 0..) |*entry, grammar_index| {
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
                std.debug.print("corpus {s} FAILED: {t}\n", .{ entry.name, err });
                try failed.append(allocator, entry.name);
                continue :grammars;
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
                std.debug.print("corpus {s} FAILED: {t}\n", .{ entry.name, err });
                try failed.append(allocator, entry.name);
                continue :grammars;
            };
        }
        std.debug.print("corpus {s:<11} {s:<17} examples {d:>4}  ", .{
            entry.name, entry.version, examples.items.len,
        });
        std.debug.print("documents {d:>4}  steps {d:>6}  exact {d:>6}  with errors {d:>5}  ", .{
            stats.documents, stats.steps, stats.exact, stats.with_errors,
        });
        std.debug.print("halts {d:>6}  clean originals {d:>4}  upstream divergences {d}  ", .{
            stats.halts, stats.clean_originals, stats.upstream_divergences,
        });
        std.debug.print("range queries {d:>5}  parent steps {d:>6}  same-range parents {d:>5}  ", .{
            stats.range_queries, stats.parent_steps, stats.same_range_parents,
        });
        std.debug.print("trace {x:0>16}\n", .{stats.trace});
        total.add(stats);
    }
    std.debug.print(
        "corpus total: {d} documents, {d} steps, {d} exact, {d} with errors, {d} halts, " ++
            "{d} upstream divergences, {d} range queries, {d} parent steps ({d} same-range)\n",
        .{
            total.documents,
            total.steps,
            total.exact,
            total.with_errors,
            total.halts,
            total.upstream_divergences,
            total.range_queries,
            total.parent_steps,
            total.same_range_parents,
        },
    );
    for (failed.items) |name| std.debug.print("corpus failure in {s}\n", .{name});
    try std.testing.expectEqual(@as(usize, 0), failed.items.len);
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
