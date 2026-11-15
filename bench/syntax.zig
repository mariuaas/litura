//! Measures what syntax views cost per edit and per query across document sizes, for
//! ordinary typing and for the worst cases: the first parse, an edit that changes how
//! everything after it parses, and many edits in one transaction.
//! Run with `zig build measure-syntax -Dtree-sitter=true` (ReleaseFast by default).
const std = @import("std");
const litura = @import("litura");
const BufferEngine = litura.BufferEngine;
const TreeSitter = litura.tree_sitter.TreeSitterTokenProvider;
const types = litura.types;
const views = litura.views;

const io = std.Io.Threaded.global_single_threaded.io();

fn now() std.Io.Timestamp {
    return std.Io.Timestamp.now(io, .awake);
}

fn microseconds(start: std.Io.Timestamp) u64 {
    return @intCast(@divTrunc(start.durationTo(now()).nanoseconds, 1000));
}

/// A host's refresh budget: a deadline on its own clock.
const Deadline = struct {
    end: std.Io.Timestamp,

    fn within(microseconds_from_now: u64) Deadline {
        return .{
            .end = now().addDuration(.{ .nanoseconds = @intCast(microseconds_from_now * 1000) }),
        };
    }

    fn budget(self: *Deadline) views.RefreshBudget {
        return .{ .context = self, .exhausted = exhausted };
    }

    fn exhausted(context: ?*anyopaque) bool {
        const self: *Deadline = @ptrCast(@alignCast(context.?));
        return now().nanoseconds >= self.end.nanoseconds;
    }
};

/// Counts allocations through the engine allocator. Tree-sitter allocates with its own.
const Counting = struct {
    inner: std.mem.Allocator,
    allocations: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(context));
        self.allocations += 1;
        return self.inner.rawAlloc(len, alignment, ret);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        len: usize,
        ret: usize,
    ) bool {
        const self: *Counting = @ptrCast(@alignCast(context));
        return self.inner.rawResize(memory, alignment, len, ret);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        len: usize,
        ret: usize,
    ) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(context));
        self.allocations += 1;
        return self.inner.rawRemap(memory, alignment, len, ret);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Counting = @ptrCast(@alignCast(context));
        self.inner.rawFree(memory, alignment, ret);
    }
};

/// Lua source of roughly `size` bytes: many small functions with strings, numbers,
/// comments and nested blocks.
fn luaSource(gpa: std.mem.Allocator, size: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var index: usize = 0;
    while (out.items.len < size) : (index += 1) {
        try out.print(gpa,
            \\-- helper {d}: sums a table
            \\local function sum_{d}(items, scale)
            \\  local total = 0
            \\  for i, value in ipairs(items) do
            \\    if value > {d} then total = total + value * scale else total = total - 1 end
            \\  end
            \\  return total, "sum_{d}"
            \\end
            \\
        , .{ index, index, index % 97, index });
    }
    return out.toOwnedSlice(gpa);
}

fn submit(engine: *BufferEngine, ops: []const types.BufferOp) !void {
    var result = try engine.submit(
        .{ .id = .{ .value = 0 }, .origin = engine.revision, .payload = .{
            .buffer_mutation = .{ .ops = ops },
        } },
    );
    result.deinit(engine.allocator);
}

/// Syntax work a host schedules: refresh calls with a 4 ms deadline each, as an idle
/// loop would make them, until the views are current.
const Work = struct {
    /// All refresh calls together: how long highlighting lags, not input.
    total: u64 = 0,
    /// The longest single call: how long one refresh can block the host's loop.
    longest: u64 = 0,
    calls: usize = 0,
};

fn refreshScheduled(engine: *BufferEngine) Work {
    var work: Work = .{};
    while (true) {
        var deadline = Deadline.within(4000);
        const started = now();
        const state = engine.refreshView("tokens", deadline.budget());
        const spent = microseconds(started);
        work.total += spent;
        work.longest = @max(work.longest, spent);
        work.calls += 1;
        if (state.kind == .available) return work;
    }
}

/// Queries a 60-line window around `position`, as a host drawing the screen would.
fn queryWindow(engine: *BufferEngine, position: u32) !void {
    const line = (try engine.positionToLineCol(position)).line;
    const first = line -| 30;
    const last = @min(first + 60, engine.lineCount());
    const spans = try engine.queryTokenSpans(
        try engine.lineStart(first),
        try engine.lineStart(last),
        null,
    );
    engine.allocator.free(spans);
}

const Stats = struct {
    samples: std.ArrayListUnmanaged(u64) = .empty,

    fn add(self: *Stats, gpa: std.mem.Allocator, value: u64) !void {
        try self.samples.append(gpa, value);
    }

    fn median(self: *Stats) u64 {
        std.mem.sort(u64, self.samples.items, {}, std.sort.asc(u64));
        return self.samples.items[self.samples.items.len / 2];
    }

    fn max(self: *const Stats) u64 {
        return std.mem.max(u64, self.samples.items);
    }
};

pub fn main() !void {
    const gpa = std.heap.smp_allocator;
    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (rows.items) |row| gpa.free(row);
        rows.deinit(gpa);
    }
    std.debug.print("Typing 200 characters mid-document, per keystroke (microseconds):\n", .{});
    std.debug.print(
        "{s:>8} | {s:>7} {s:>7} | {s:>9} {s:>9} {s:>8} | {s:>7} {s:>7} | {s:>6}\n",
        .{ "bytes", "submit", "max", "work p50", "work max", "longest", "query", "max", "allocs" },
    );
    for ([_]usize{ 16 << 10, 128 << 10, 1 << 20, 8 << 20 }) |size| {
        const text = try luaSource(gpa, size);
        defer gpa.free(text);
        var counting = Counting{ .inner = gpa };
        var engine = try BufferEngine.initFromText(counting.allocator(), text, null);
        defer engine.deinit();
        std.debug.assert(try TreeSitter.attachBuiltin(&engine, "lua"));

        const first = refreshScheduled(&engine);

        // Typing mid-document. Submission is what the editor waits for; the refresh work
        // is scheduled in 4 ms calls; the query draws the visible window.
        var submits: Stats = .{};
        defer submits.samples.deinit(gpa);
        var works: Stats = .{};
        defer works.samples.deinit(gpa);
        var queries: Stats = .{};
        defer queries.samples.deinit(gpa);
        var longest: u64 = 0;
        var position = engine.graphemeCount() / 2;
        const allocations_before = counting.allocations;
        for (0..200) |index| {
            var started = now();
            const character: []const u8 = if (index % 7 == 6) "\n" else "a";
            try submit(&engine, &.{.{ .insert = .{ .pos = position, .text = character } }});
            try submits.add(gpa, microseconds(started));
            position += 1;
            const work = refreshScheduled(&engine);
            try works.add(gpa, work.total);
            longest = @max(longest, work.longest);
            started = now();
            try queryWindow(&engine, position);
            try queries.add(gpa, microseconds(started));
        }
        const allocations_per_key = (counting.allocations - allocations_before) / 200;
        std.debug.print(
            "{d:>8} | {d:>7} {d:>7} | {d:>9} {d:>9} {d:>8} | {d:>7} {d:>7} | {d:>6}\n",
            .{
                text.len,            submits.median(), submits.max(),    works.median(),
                works.max(),         longest,          queries.median(), queries.max(),
                allocations_per_key,
            },
        );

        // Worst cases, each as scheduled work and its longest single call.
        const count = engine.graphemeCount();
        try submit(&engine, &.{
            .{ .insert = .{ .pos = count - 10, .text = "x" } },
            .{ .insert = .{ .pos = count / 2 + 5, .text = "y" } },
            .{ .insert = .{ .pos = count / 4, .text = "z" } },
            .{ .insert = .{ .pos = 10, .text = "w" } },
        });
        const distant = refreshScheduled(&engine);

        var undo = try engine.submit(
            .{ .id = .{ .value = 0 }, .origin = engine.revision, .payload = .{ .undo = .{} } },
        );
        undo.deinit(engine.allocator);
        const undo_work = refreshScheduled(&engine);

        // Opening a block comment near the top changes how everything after it parses.
        try submit(&engine, &.{.{ .insert = .{ .pos = 0, .text = "--[[" } }});
        const comment = refreshScheduled(&engine);
        try submit(&engine, &.{.{ .delete = .{ .start = 0, .end = 4 } }});
        _ = refreshScheduled(&engine);

        // A thousand carets typing one character each, one transaction.
        var ops: std.ArrayListUnmanaged(types.BufferOp) = .empty;
        defer ops.deinit(gpa);
        const lines = @min(engine.lineCount() - 1, 1000);
        var line = lines;
        while (line > 0) {
            line -= 1;
            const at = try engine.lineStart(line * (engine.lineCount() - 1) / lines);
            try ops.append(gpa, .{ .insert = .{ .pos = at, .text = "c" } });
        }
        var started = now();
        try submit(&engine, ops.items);
        const carets_submit = microseconds(started);
        const carets = refreshScheduled(&engine);

        started = now();
        const node = (try engine.queryEnclosingSyntaxNode(count / 2, null)).?;
        const node_us = microseconds(started);
        started = now();
        _ = try engine.querySyntaxNodeInfo(node.ref);
        const info_us = microseconds(started);

        try rows.append(gpa, try std.fmt.allocPrint(
            gpa,
            "{d:>8} | {d:>9} {d:>6} | {d:>8} {d:>6} | {d:>8} {d:>6} | {d:>9} {d:>6} | " ++
                "{d:>7} {d:>8} {d:>6} | {d:>4} {d:>4}\n",
            .{
                text.len,        first.total,     first.longest,     distant.total,
                distant.longest, undo_work.total, undo_work.longest, comment.total,
                comment.longest, carets_submit,   carets.total,      carets.longest,
                node_us,         info_us,
            },
        ));
    }
    std.debug.print("\nWorst cases: scheduled work and longest call (microseconds):\n", .{});
    std.debug.print(
        "{s:>8} | {s:>9} {s:>6} | {s:>8} {s:>6} | {s:>8} {s:>6} | {s:>9} {s:>6} | " ++
            "{s:>7} {s:>8} {s:>6} | {s:>4} {s:>4}\n",
        .{
            "bytes", "first", "call", "distant", "call", "undo",
            "call",  "--[[",  "call", "carets",  "work", "call",
            "node",  "info",
        },
    );
    for (rows.items) |row| std.debug.print("{s}", .{row});
    std.debug.print(
        "(first = first parse; carets = 1000-caret submit, then its refresh work; " ++
            "allocs = engine allocator only)\n",
        .{},
    );
}
