//! Incrementally maintained syntax views agree with recomputation from scratch.
//!
//! Method: a seeded workload edits a document through ordinary submissions (local and
//! distant edits, multi-operation transactions, multi-cursor composites, undo and redo,
//! edits that resegment Unicode and that open or close block comments). After each
//! refresh completes, the provider's tree, its token spans over the whole document and
//! over random windows, and its enclosing nodes at random positions are compared with a
//! fresh engine that parses the same text from scratch.
//!
//! Where the text parses without errors the trees must match exactly, for uninterrupted
//! refreshes and for refreshes under budgets that halt parses partway, with edits
//! sometimes arriving while a parse is halted. That holds for these grammars and seeds;
//! in general Tree-sitter's incremental result can depend on its edit and resume history
//! (docs/known-issues.md). Inside syntax errors it often does, so there the views must
//! only be consistent with their own tree. A second workload makes only edits that keep
//! long documents valid, so that every comparison there is exact.
//!
//! These workloads are sized for the default test run. The grammar-diversity suite
//! (`-Dsyntax-corpus=true`) runs Lua and Zig in depth, with the mirror that checks the
//! provider against raw Tree-sitter.
const std = @import("std");
const litura = @import("litura");
const BufferEngine = litura.BufferEngine;
const TreeSitter = litura.tree_sitter.TreeSitterTokenProvider;
const views = litura.views;
const types = litura.types;
const allocator = std.testing.allocator;
const support = @import("support.zig");
const structure = @import("syntax_oracle.zig");

/// Halts a refresh after a fixed number of polls.
const StepBudget = struct {
    remaining: u32,
    polls: u32 = 0,

    fn budget(self: *StepBudget) views.RefreshBudget {
        return .{ .context = self, .exhausted = exhausted };
    }

    fn exhausted(context: ?*anyopaque) bool {
        const self: *StepBudget = @ptrCast(@alignCast(context.?));
        self.polls += 1;
        if (self.remaining == 0) return true;
        self.remaining -= 1;
        return false;
    }
};

fn provider(engine: *BufferEngine) *TreeSitter {
    return @ptrCast(@alignCast(engine.view_providers.get("syntax").?.ptr));
}

fn treeSexp(engine: *BufferEngine) ![]u8 {
    return provider(engine).tree.?.rootNode().toSexp(allocator);
}

fn expectSameSpans(expected: []const views.TokenSpan, actual: []const views.TokenSpan) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |left, right| {
        try std.testing.expectEqual(left.start, right.start);
        try std.testing.expectEqual(left.end, right.end);
        try std.testing.expectEqualStrings(left.kind, right.kind);
        try std.testing.expectEqualStrings(left.style, right.style);
    }
}

/// Compares every syntax view of `engine` with a fresh parse of the same text: exactly
/// when that text parses without errors, and otherwise only for the views' consistency
/// with their own tree. Returns whether the comparison was exact.
fn expectMatchesReference(engine: *BufferEngine, language: []const u8, random: std.Random) !bool {
    const text = try engine.getText();
    defer allocator.free(text);
    var reference = try BufferEngine.initFromText(allocator, text, null);
    defer reference.deinit();
    try std.testing.expect(try TreeSitter.attachBuiltin(&reference, language));
    try std.testing.expectEqual(
        views.ViewStateKind.available,
        reference.refreshView("tokens", .unlimited).kind,
    );

    const exact = !provider(&reference).tree.?.rootNode().hasError();
    const root = provider(engine).tree.?.rootNode();
    try std.testing.expectEqual(@as(u32, @intCast(text.len)), root.endByte());
    if (exact) {
        const incremental_tree = try treeSexp(engine);
        defer allocator.free(incremental_tree);
        const reference_tree = try treeSexp(&reference);
        defer allocator.free(reference_tree);
        try std.testing.expectEqualStrings(reference_tree, incremental_tree);
    }

    const count = engine.graphemeCount();
    const whole = try engine.queryTokenSpans(0, count, null);
    defer allocator.free(whole);
    const expected_whole = try reference.queryTokenSpans(0, count, null);
    defer allocator.free(expected_whole);
    if (exact) try expectSameSpans(expected_whole, whole);

    for (0..4) |_| {
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
        const node = try engine.queryEnclosingSyntaxNode(position, null);
        const expected_node = try reference.queryEnclosingSyntaxNode(position, null);
        try std.testing.expectEqual(expected_node == null, node == null);
        const found = node orelse continue;
        if (exact) {
            const expected = expected_node.?;
            try std.testing.expectEqualStrings(expected.kind, found.kind);
            try std.testing.expectEqual(expected.start, found.start);
            try std.testing.expectEqual(expected.end, found.end);
            try std.testing.expectEqual(expected.ref.id, found.ref.id);
        }
        const resolved = try engine.querySyntaxNodeInfo(found.ref);
        try std.testing.expectEqualStrings(found.kind, resolved.kind);
        try std.testing.expectEqual(found.start, resolved.start);
        try std.testing.expectEqual(found.end, resolved.end);
    }

    // The smallest node around a random range, and every ancestor of it, against an
    // independent walk of the provider's tree.
    var table = try structure.Table.init(allocator, root);
    defer table.deinit(allocator);
    if (count > 0) {
        const start = random.uintLessThan(u32, count);
        const end = start + 1 + random.uintAtMost(u32, count - start - 1);
        const node = try engine.queryEnclosingSyntaxNodeRange(start, end, null);
        const start_byte = try engine.table.byteOffset(start);
        const expected = table.enclosing(start_byte, try engine.table.byteOffset(end));
        try std.testing.expectEqual(expected, if (node) |found| found.ref.id else null);
        var current = node;
        while (current) |child| {
            const parent = try engine.querySyntaxNodeParent(child.ref);
            const parent_id: ?u32 = if (parent) |found| found.ref.id else null;
            try std.testing.expectEqual(table.parent[child.ref.id], parent_id);
            current = parent;
        }
    }
    return exact;
}

const Workload = struct {
    engine: *BufferEngine,
    random: std.Random,
    fragments: []const []const u8,
    /// Whether refreshes run under budgets that halt parses.
    budgeted: bool,

    fn position(self: *Workload) u32 {
        return self.random.uintAtMost(u32, self.engine.graphemeCount());
    }

    fn fragment(self: *Workload) []const u8 {
        return self.fragments[self.random.uintLessThan(usize, self.fragments.len)];
    }

    fn submit(self: *Workload, payload: types.IntentPayload) !void {
        var result = try self.engine.submit(
            .{ .id = support.id, .origin = self.engine.revision, .payload = payload },
        );
        result.deinit(allocator);
    }

    /// One random change, through the same submissions an editor makes.
    fn step(self: *Workload) !void {
        var ops: [4]types.BufferOp = undefined;
        switch (self.random.uintLessThan(u8, 10)) {
            // Typing and deleting at one place.
            0, 1, 2 => {
                const at = self.position();
                const end = at + self.random.uintAtMost(
                    u32,
                    @min(2, self.engine.graphemeCount() - at),
                );
                ops[0] = if (self.random.boolean())
                    .{ .insert = .{ .pos = at, .text = self.fragment() } }
                else
                    .{ .replace = .{ .start = at, .end = end, .text = "" } };
                try self.submit(.{ .buffer_mutation = .{ .ops = ops[0..1] } });
            },
            // Several distant changes in one transaction, applied in sequence.
            3, 4 => {
                const count = 2 + self.random.uintLessThan(usize, 3);
                var length = self.engine.graphemeCount();
                for (ops[0..count]) |*op| {
                    // Descending positions keep earlier targets valid whatever each inserts.
                    const at = self.random.uintAtMost(u32, length);
                    op.* = .{ .insert = .{ .pos = at, .text = self.fragment() } };
                    length = at;
                }
                try self.submit(.{ .buffer_mutation = .{ .ops = ops[0..count] } });
            },
            // A multi-cursor edit with the carets placed after the inserted text.
            5 => {
                const session, const cursor = try support.caret(self.engine, self.position());
                defer support.dropSession(self.engine, session) catch {};
                const at = self.position();
                try self.submit(.{ .composite = .{ .parts = &.{
                    .{ .buffer_mutation = .{ .ops = &.{
                        .{ .insert = .{ .pos = at, .text = self.fragment() } },
                        .{ .insert = .{ .pos = 0, .text = self.fragment() } },
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
            6, 7 => try self.submit(.{ .undo = .{} }),
            8 => try self.submit(.{ .redo = .{} }),
            // Opening or closing a construct that changes how everything after it parses.
            else => {
                ops[0] = .{ .insert = .{ .pos = self.position(), .text = self.fragments[0] } };
                try self.submit(.{ .buffer_mutation = .{ .ops = ops[0..1] } });
            },
        }
    }

    /// Refreshes under a random budget until current. A halted parse is sometimes left
    /// behind by a new edit, which must abandon it.
    fn refresh(self: *Workload) !void {
        if (!self.budgeted) {
            const state = self.engine.refreshView("syntax", .unlimited);
            try std.testing.expectEqual(views.ViewStateKind.available, state.kind);
            return;
        }
        // A parse that keeps being halted still finishes: each call resumes it. Edits stop
        // after a while, as when typing pauses; while they keep arriving, parses complete
        // but the view only becomes current once one finishes before the next edit.
        for (0..10_000) |call| {
            var budget = StepBudget{ .remaining = self.random.uintAtMost(u32, 6) };
            const state = self.engine.refreshView("syntax", budget.budget());
            if (state.kind == .available) return;
            try std.testing.expectEqual(views.ViewStateKind.stale, state.kind);
            // Never served as current while halted.
            try std.testing.expectError(error.ViewStale, self.engine.queryTokenSpans(0, 0, null));
            try std.testing.expectError(
                error.ViewStale,
                self.engine.queryEnclosingSyntaxNode(0, null),
            );
            if (call < 20 and self.random.uintLessThan(u8, 4) == 0) try self.step();
        }
        return error.RefreshNeverCompleted;
    }
};

fn run(
    language: []const u8,
    seed_text: []const u8,
    fragments: []const []const u8,
    seed: u64,
    steps: usize,
) !void {
    for ([_]bool{ false, true }) |budgeted| {
        var engine = try BufferEngine.initFromText(allocator, seed_text, null);
        defer engine.deinit();
        try std.testing.expect(try TreeSitter.attachBuiltin(&engine, language));
        var prng = std.Random.DefaultPrng.init(seed);
        var workload = Workload{
            .engine = &engine,
            .random = prng.random(),
            .fragments = fragments,
            .budgeted = budgeted,
        };
        try workload.refresh();
        _ = try expectMatchesReference(&engine, language, workload.random);
        for (0..steps) |_| {
            try workload.step();
            try workload.refresh();
            _ = try expectMatchesReference(&engine, language, workload.random);
        }
    }
}

test "incremental Lua views match a full reparse through edits, undo, redo and halted parses" {
    const source =
        \\-- a module
        \\local M = {}
        \\function M.greet(name)
        \\  local s = "héllo, " .. name -- comment ✓
        \\  for i = 1, 10 do s = s .. i end
        \\  return s
        \\end
        \\return M
        \\
    ;
    const fragments = [_][]const u8{
        "--[[ ",
        "]]",
        "\"",
        "e\u{0301}",
        "\u{0301}",
        "\r\n",
        "\n",
        "end",
        "local x = 1\n",
        "(",
        ")",
        "\u{1f44d}\u{1f3fd}",
        "x",
    };
    try run("lua", source, &fragments, 0x1a7a, 60);
}

test "incremental Zig views match a full reparse through edits, undo, redo and halted parses" {
    const source =
        \\const std = @import("std");
        \\/// Doc comment ✓
        \\pub fn main() void {
        \\    const s = "héllo";
        \\    for (s) |c| {
        \\        if (c == 'x') return;
        \\    }
        \\}
        \\
    ;
    const fragments = [_][]const u8{
        "\\\\",
        "\"",
        "}",
        "{",
        "e\u{0301}",
        "\u{0301}",
        "\r\n",
        "\n",
        "fn f() void {}\n",
        "//",
        "\u{1f1f3}\u{1f1f4}",
        "x",
    };
    try run("zig", source, &fragments, 0x2196, 30);
}

/// `count` copies of `item`, each formatted with its index: a long top-level list, which
/// Tree-sitter stores as a balanced repetition that incremental parses reuse in parts.
fn longList(comptime item: []const u8, count: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (0..count) |index| try out.print(allocator, item, .{ index, index });
    return out.toOwnedSlice(allocator);
}

/// Edits that keep a long list of items free of syntax errors, as when working code is
/// changed: identifiers and comments edited, items duplicated and deleted, several
/// distant items changed in one transaction, undo and redo.
const ValidWorkload = struct {
    engine: *BufferEngine,
    random: std.Random,
    /// The text every item starts with, ending inside its comment.
    marker: []const u8,
    /// A complete item to insert.
    item: []const u8,
    budgeted: bool,

    const comment_fragments = [_][]const u8{ "e\u{0301}", "\u{1f44d}\u{1f3fd}", " \u{2713}", "x" };

    fn submit(self: *ValidWorkload, payload: types.IntentPayload) !void {
        var result = try self.engine.submit(
            .{ .id = support.id, .origin = self.engine.revision, .payload = payload },
        );
        result.deinit(allocator);
    }

    /// Grapheme positions just after each occurrence of `needle`, ascending.
    fn positionsAfter(self: *ValidWorkload, needle: []const u8) !std.ArrayListUnmanaged(u32) {
        const text = try self.engine.getText();
        defer allocator.free(text);
        var positions: std.ArrayListUnmanaged(u32) = .empty;
        errdefer positions.deinit(allocator);
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, text, from, needle)) |at| : (from = at + needle.len) {
            const byte: u32 = @intCast(at + needle.len);
            try positions.append(allocator, try self.engine.table.positionAtByte(byte, .down));
        }
        return positions;
    }

    fn pick(self: *ValidWorkload, positions: []const u32) u32 {
        return positions[self.random.uintLessThan(usize, positions.len)];
    }

    fn fragment(self: *ValidWorkload) []const u8 {
        return comment_fragments[self.random.uintLessThan(usize, comment_fragments.len)];
    }

    fn step(self: *ValidWorkload) !void {
        var comments = try self.positionsAfter(self.marker);
        defer comments.deinit(allocator);
        var names = try self.positionsAfter("f_");
        defer names.deinit(allocator);
        // An item starts at its marker.
        const marker_length: u32 = @intCast(self.marker.len);
        switch (self.random.uintLessThan(u8, 8)) {
            0, 1 => {
                const at = self.pick(names.items);
                try self.submit(
                    .{
                        .buffer_mutation = .{
                            .ops = &.{.{ .insert = .{ .pos = at, .text = "x" } }},
                        },
                    },
                );
            },
            2 => {
                const at = self.pick(comments.items);
                try self.submit(
                    .{
                        .buffer_mutation = .{
                            .ops = &.{.{ .insert = .{ .pos = at, .text = self.fragment() } }},
                        },
                    },
                );
            },
            3 => {
                const at = self.pick(comments.items) - marker_length;
                try self.submit(
                    .{
                        .buffer_mutation = .{
                            .ops = &.{.{ .insert = .{ .pos = at, .text = self.item } }},
                        },
                    },
                );
            },
            4 => {
                if (comments.items.len < 3) return;
                const index = self.random.uintLessThan(usize, comments.items.len - 1);
                const start = comments.items[index] - marker_length;
                const end = comments.items[index + 1] - marker_length;
                try self.submit(
                    .{
                        .buffer_mutation = .{
                            .ops = &.{.{ .delete = .{ .start = start, .end = end } }},
                        },
                    },
                );
            },
            5 => {
                // Distant items in one transaction, last first so each target stays valid.
                var ops: [4]types.BufferOp = undefined;
                const count = 2 + self.random.uintLessThan(usize, 3);
                var limit = comments.items.len;
                var used: usize = 0;
                while (used < count and limit > 0) : (used += 1) {
                    const index = self.random.uintLessThan(usize, limit);
                    ops[used] = .{
                        .insert = .{ .pos = comments.items[index], .text = self.fragment() },
                    };
                    limit = index;
                }
                try self.submit(.{ .buffer_mutation = .{ .ops = ops[0..used] } });
            },
            6 => try self.submit(.{ .undo = .{} }),
            else => try self.submit(.{ .redo = .{} }),
        }
    }

    fn refresh(self: *ValidWorkload) !void {
        if (!self.budgeted) {
            try std.testing.expectEqual(
                views.ViewStateKind.available,
                self.engine.refreshView("syntax", .unlimited).kind,
            );
            return;
        }
        for (0..10_000) |call| {
            var budget = StepBudget{ .remaining = self.random.uintAtMost(u32, 6) };
            if (self.engine.refreshView("syntax", budget.budget()).kind == .available) return;
            if (call < 20 and self.random.uintLessThan(u8, 4) == 0) try self.step();
        }
        return error.RefreshNeverCompleted;
    }
};

fn runValid(
    language: []const u8,
    source: []const u8,
    marker: []const u8,
    item: []const u8,
    seed: u64,
) !void {
    for ([_]bool{ false, true }) |budgeted| {
        var engine = try BufferEngine.initFromText(allocator, source, null);
        defer engine.deinit();
        try std.testing.expect(try TreeSitter.attachBuiltin(&engine, language));
        var prng = std.Random.DefaultPrng.init(seed);
        var workload = ValidWorkload{
            .engine = &engine,
            .random = prng.random(),
            .marker = marker,
            .item = item,
            .budgeted = budgeted,
        };
        try workload.refresh();
        try std.testing.expect(try expectMatchesReference(&engine, language, workload.random));
        for (0..30) |_| {
            try workload.step();
            try workload.refresh();
            try std.testing.expect(try expectMatchesReference(&engine, language, workload.random));
        }
    }
}

test "incremental views over long valid documents match a full reparse exactly" {
    const lua = try longList(
        \\-- helper ✓ {d}
        \\local function f_{d}(a) return a * 2 end
        \\
    , 40);
    defer allocator.free(lua);
    try runValid(
        "lua",
        lua,
        "-- helper",
        "-- helper new\nlocal function f_new(a) return a + 1 end\n",
        0x5a11d,
    );

    const zig = try longList(
        \\/// doc ✓ {d}
        \\fn f_{d}(a: u32) u32 {{ return a * 2; }}
        \\
    , 40);
    defer allocator.free(zig);
    try runValid(
        "zig",
        zig,
        "/// doc",
        "/// doc new\nfn f_new(a: u32) u32 { return a + 1; }\n",
        0x2a11d,
    );
}

test "incremental views over long top-level lists match a full reparse" {
    const lua = try longList(
        \\-- helper {d}
        \\local function f_{d}(a) return a * 2 end
        \\
    , 40);
    defer allocator.free(lua);
    const lua_fragments = [_][]const u8{
        "--[[ ",
        "]]",
        "end",
        "local x = 1\n",
        "\n",
        "x",
        "(",
        "e\u{0301}",
    };
    try run("lua", lua, &lua_fragments, 0x7e9e, 20);

    const zig = try longList(
        \\/// doc {d}
        \\fn f_{d}(a: u32) u32 {{ return a * 2; }}
        \\
    , 40);
    defer allocator.free(zig);
    const zig_fragments = [_][]const u8{
        "}",
        "{",
        "fn g() void {}\n",
        "\n",
        "x",
        "//",
        "\"",
        "e\u{0301}",
    };
    try run("zig", zig, &zig_fragments, 0x2e9e, 20);
}

test "queries never parse, and stale views are reported as stale" {
    var engine = try BufferEngine.initFromText(allocator, "local x = 1\n", null);
    defer engine.deinit();
    try std.testing.expect(try TreeSitter.attachBuiltin(&engine, "lua"));
    _ = engine.refreshView("tokens", .unlimited);
    const tree_before = provider(&engine).tree.?.raw;

    try support.edit(&engine, &.{.{ .insert = .{ .pos = 0, .text = "local y = 2\n" } }});
    try std.testing.expectError(error.ViewStale, engine.queryTokenSpans(0, 1, null));
    try std.testing.expectError(error.ViewStale, engine.queryEnclosingSyntaxNode(0, null));
    const state = engine.queryViewState("syntax");
    try std.testing.expectEqual(views.ViewStateKind.stale, state.kind);
    try std.testing.expectEqual(@as(?u32, 0), state.revision);
    // No query parsed: the tree is still the one from revision 0, edited in place.
    try std.testing.expectEqual(tree_before, provider(&engine).tree.?.raw);
}

test "a halted parse resumes, and survives edits made while it is halted" {
    const line = "local function f(a) return a * 2 end\n";
    var engine = try BufferEngine.initFromText(allocator, line ** 400, null);
    defer engine.deinit();
    try std.testing.expect(try TreeSitter.attachBuiltin(&engine, "lua"));

    var first = StepBudget{ .remaining = 2 };
    try std.testing.expectEqual(
        views.ViewStateKind.stale,
        engine.refreshView("tokens", first.budget()).kind,
    );
    try std.testing.expect(provider(&engine).halted);
    try std.testing.expectEqual(@as(?u32, null), engine.queryViewState("tokens").revision);

    // Resuming completes the same parse.
    var resumed = StepBudget{ .remaining = std.math.maxInt(u32) };
    try std.testing.expectEqual(
        views.ViewStateKind.available,
        engine.refreshView("tokens", resumed.budget()).kind,
    );

    // A parse overtaken by an edit keeps going on the text it started with; the edit is
    // queued for its tree, then parsed incrementally once it completes.
    try support.edit(&engine, &.{.{ .insert = .{ .pos = 0, .text = "--[[" } }});
    var halted = StepBudget{ .remaining = 1 };
    _ = engine.refreshView("tokens", halted.budget());
    try std.testing.expect(provider(&engine).halted);
    try support.edit(&engine, &.{.{ .insert = .{ .pos = 4, .text = "]]" } }});
    try std.testing.expect(provider(&engine).halted);
    try std.testing.expectEqual(@as(usize, 1), provider(&engine).pending.items.len);
    try std.testing.expectError(error.ViewStale, engine.queryTokenSpans(0, 1, null));
    try std.testing.expectEqual(
        views.ViewStateKind.available,
        engine.refreshView("tokens", .unlimited).kind,
    );
    var prng = std.Random.DefaultPrng.init(7);
    try std.testing.expect(try expectMatchesReference(&engine, "lua", prng.random()));
}

test "edits arriving faster than a parse can finish do not keep it from finishing" {
    // Every refresh gets two progress checks and is followed by an edit. Abandoning the
    // halted parse on each edit would restart it every time, and it would never finish.
    const line = "local function f(a) return a * 2 end\n";
    var engine = try BufferEngine.initFromText(allocator, line ** 2000, null);
    defer engine.deinit();
    try std.testing.expect(try TreeSitter.attachBuiltin(&engine, "lua"));

    var completed: std.ArrayListUnmanaged(u32) = .empty;
    defer completed.deinit(allocator);
    var calls: usize = 0;
    while (completed.items.len < 3) : (calls += 1) {
        if (calls == 100_000) return error.ParseNeverCompleted;
        var budget = StepBudget{ .remaining = 2 };
        const state = engine.refreshView("tokens", budget.budget());
        if (state.revision) |revision| {
            // Each completed parse describes a newer revision than the last.
            if (completed.items.len == 0 or completed.items[completed.items.len - 1] < revision) {
                try completed.append(allocator, revision);
            }
        }
        try support.edit(
            &engine,
            &.{.{ .insert = .{ .pos = engine.graphemeCount(), .text = "x = 1\n" } }},
        );
    }
    try std.testing.expectEqual(
        views.ViewStateKind.available,
        engine.refreshView("tokens", .unlimited).kind,
    );
    var prng = std.Random.DefaultPrng.init(11);
    try std.testing.expect(try expectMatchesReference(&engine, "lua", prng.random()));
}

test "exhaustion while a parse is halted abandons it, and the views still converge" {
    // Method: fail each allocation in turn, from the halt on: copying the text, queuing
    // splices, and the edits themselves. Then refresh with allocation restored and
    // compare with a fresh parse.
    const line = "local function f(a) return a * 2 end\n";
    var fail_after: usize = 0;
    while (true) : (fail_after += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        var engine = try BufferEngine.initFromText(failing.allocator(), line ** 200, null);
        defer engine.deinit();
        try std.testing.expect(try TreeSitter.attachBuiltin(&engine, "lua"));

        failing.fail_index = failing.alloc_index + fail_after;
        var budget = StepBudget{ .remaining = 1 };
        _ = engine.refreshView("tokens", budget.budget());
        for (0..2) |_| {
            support.edit(
                &engine,
                &.{.{ .insert = .{ .pos = 0, .text = "local z = 1\n" } }},
            ) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
            };
            var more = StepBudget{ .remaining = 1 };
            _ = engine.refreshView("tokens", more.budget());
        }
        const induced = failing.has_induced_failure;
        failing.fail_index = std.math.maxInt(usize);

        try std.testing.expectEqual(
            views.ViewStateKind.available,
            engine.refreshView("tokens", .unlimited).kind,
        );
        var prng = std.Random.DefaultPrng.init(13);
        try std.testing.expect(try expectMatchesReference(&engine, "lua", prng.random()));
        if (!induced) break;
    }
}

test "node references are plain values: queries keep no storage and allocate nothing" {
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var engine = try BufferEngine.initFromText(
        failing.allocator(),
        "function f()\n  return { 1, { 2 } }\nend\n",
        null,
    );
    defer engine.deinit();
    try std.testing.expect(try TreeSitter.attachBuiltin(&engine, "lua"));
    _ = engine.refreshView("syntax", .unlimited);

    failing.fail_index = failing.alloc_index;
    for (0..1000) |round| {
        const node = (try engine.queryEnclosingSyntaxNode(
            @intCast(round % engine.graphemeCount()),
            null,
        )).?;
        const again = try engine.querySyntaxNodeInfo(node.ref);
        try std.testing.expectEqualStrings(node.kind, again.kind);
        // Structural queries allocate nothing either.
        _ = try engine.querySyntaxNodeParent(node.ref);
        _ = try engine.queryEnclosingSyntaxNodeRange(0, engine.graphemeCount(), null);
    }
    try std.testing.expect(!failing.has_induced_failure);
    failing.fail_index = std.math.maxInt(usize);

    // An identifier the tree does not have is an error, not a missing node.
    const bad: views.SyntaxNodeRef = .{
        .provider = "tree-sitter-lua",
        .revision = engine.revision,
        .id = 1 << 30,
    };
    try std.testing.expectError(error.KeyError, engine.querySyntaxNodeInfo(bad));
}

test "exhaustion during a token query leaves the view intact" {
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var engine = try BufferEngine.initFromText(
        failing.allocator(),
        "local s = \"x\" -- c\nprint(s)\n",
        null,
    );
    defer engine.deinit();
    try std.testing.expect(try TreeSitter.attachBuiltin(&engine, "lua"));
    _ = engine.refreshView("tokens", .unlimited);
    const expected = try engine.queryTokenSpans(0, engine.graphemeCount(), null);
    defer engine.allocator.free(expected);
    var fail_after: usize = 0;
    while (true) : (fail_after += 1) {
        failing.has_induced_failure = false;
        failing.fail_index = failing.alloc_index + fail_after;
        const spans = engine.queryTokenSpans(0, engine.graphemeCount(), null);
        const failed = failing.has_induced_failure;
        failing.fail_index = std.math.maxInt(usize);
        if (spans) |result| {
            defer engine.allocator.free(result);
            if (!failed) {
                try expectSameSpans(expected, result);
                break;
            }
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqual(
            views.ViewStateKind.available,
            engine.queryViewState("tokens").kind,
        );
    }
}
