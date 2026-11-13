//! Measures what producing canonical blocks costs: submission time, allocations made
//! during a submission, and the bytes a block owns, for one caret and for a thousand.
//! Run with `zig build measure` (ReleaseFast by default).
const std = @import("std");
const litura = @import("litura");
const BufferEngine = litura.BufferEngine;
const types = litura.types;
const events = litura.events;
const AnchorId = litura.anchors.AnchorId;

/// Counts allocations passing through to `inner`.
const Counting = struct {
    inner: std.mem.Allocator,
    allocations: usize = 0,
    bytes: usize = 0,

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
        self.bytes += len;
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

/// Bytes the block owns: its slices and strings.
fn blockBytes(block: events.Block) usize {
    var total: usize = 0;
    switch (block) {
        .lifecycle => |lifecycle| switch (lifecycle.change) {
            .session_created => |created| total += created.selections.len * @sizeOf(
                events.SelectionValue,
            ),
            .session_dropped => {},
        },
        .transition => |transition| {
            if (transition.label) |label| total += label.len;
            if (transition.edit) |edit| {
                total += edit.splices.len * @sizeOf(events.RealizedSplice);
                total += edit.endpoint_effects.len * @sizeOf(events.EndpointEffect);
            }
            total += transition.interactions.len * @sizeOf(events.InteractionEvent);
            for (transition.interactions) |event| {
                if (event.selections) |change| {
                    total += (change.old.len + change.new.len) * @sizeOf(events.SelectionValue);
                }
                total += event.registers.len * @sizeOf(events.RegisterChange);
            }
        },
    }
    return total;
}

const Sample = struct {
    name: []const u8,
    iterations: usize,
    nanoseconds: i96 = 0,
    allocations: usize = 0,
    bytes_allocated: usize = 0,
    block_bytes: usize = 0,
    effects: usize = 0,
    splices: usize = 0,

    fn print(self: Sample) void {
        const n: i96 = @intCast(self.iterations);
        std.debug.print(
            "{s}: {d} us/submit, {d} allocations/submit ({d} bytes), block {d} bytes " ++
                "({d} splices, {d} endpoint effects)\n",
            .{
                self.name,
                @divTrunc(@divTrunc(self.nanoseconds, n), 1000),
                self.allocations / self.iterations,
                self.bytes_allocated / self.iterations,
                self.block_bytes / self.iterations,
                self.splices / self.iterations,
                self.effects / self.iterations,
            },
        );
    }
};

fn measure(
    sample: *Sample,
    io: std.Io,
    counting: *Counting,
    engine: *BufferEngine,
    intent: types.Intent,
) !void {
    const allocations = counting.allocations;
    const bytes = counting.bytes;
    const start = std.Io.Timestamp.now(io, .awake);
    var result = try engine.submit(intent);
    const elapsed = start.durationTo(std.Io.Timestamp.now(io, .awake));
    defer result.deinit(engine.allocator);
    if (result != .committed) return error.Rejected;
    sample.nanoseconds += elapsed.nanoseconds;
    sample.allocations += counting.allocations - allocations;
    sample.bytes_allocated += counting.bytes - bytes;
    sample.block_bytes += blockBytes(result.committed);
    if (result.committed.transition.edit) |edit| {
        sample.effects += edit.endpoint_effects.len;
        sample.splices += edit.splices.len;
    }
}

/// A session with one caret at the start of each of the first `count` lines.
fn carets(engine: *BufferEngine, count: usize) !struct { u32, []AnchorId } {
    const gpa = engine.allocator;
    const specs = try gpa.alloc(types.SelectionSpec, count);
    defer gpa.free(specs);
    for (specs, 0..) |*spec, line| {
        spec.* = .{ .start = .{ .new = .{ .position = try engine.lineStart(@intCast(line)) } } };
    }
    var block = try engine.createSession(
        .{ .id = .{ .value = 0 }, .origin = engine.revision, .selections = specs },
    );
    defer block.deinit(gpa);
    const created = block.lifecycle.change.session_created;
    const ids = try gpa.alloc(AnchorId, count);
    for (created.selections, ids) |selection, *out| out.* = selection.start.anchor;
    return .{ created.session, ids };
}

/// Types one character at every caret: one insertion per caret, applied from the last
/// caret backwards so earlier targets stay valid, with each caret moved after its text.
fn typeAtCarets(
    gpa: std.mem.Allocator,
    engine: *BufferEngine,
    session: u32,
    cursors: []const AnchorId,
    ops: []types.BufferOp,
    specs: []types.SelectionSpec,
) !types.Intent {
    for (cursors, 0..) |cursor, index| {
        const op_index = cursors.len - 1 - index;
        ops[op_index] = .{
            .insert = .{ .pos = (try engine.queryAnchor(cursor)).position.?, .text = "x" },
        };
        specs[index] = .{ .start = .{ .move = .{
            .anchor = cursor,
            .to = .{ .edit = .{ .op = @intCast(op_index) } },
        } } };
    }
    const parts = try gpa.alloc(types.IntentPayload, 2);
    parts[0] = .{ .buffer_mutation = .{ .ops = ops } };
    parts[1] = .{
        .interaction_mutation = .{
            .session_id = session,
            .origin = try engine.interactionRevision(session),
            .ops = try gpa.dupe(types.InteractionOp, &.{
                .{ .set_selections = .{ .selections = specs } },
            }),
        },
    };
    return .{
        .id = .{ .value = 1 },
        .origin = engine.revision,
        .payload = .{ .composite = .{ .parts = parts } },
    };
}

fn freeIntent(gpa: std.mem.Allocator, intent: types.Intent) void {
    const parts = intent.payload.composite.parts;
    gpa.free(parts[1].interaction_mutation.ops);
    gpa.free(parts);
}

pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var counting = Counting{ .inner = std.heap.smp_allocator };
    const gpa = counting.allocator();
    const line = "The quick brown fox jumps over the lazy dog.\n";
    const text = try std.mem.concat(std.heap.smp_allocator, u8, &(.{line} ** 1000));
    defer std.heap.smp_allocator.free(text);

    for ([_]usize{ 1, 1000 }) |count| {
        var engine = try BufferEngine.initFromText(gpa, text, null);
        defer engine.deinit();
        const session, const cursors = try carets(&engine, count);
        defer gpa.free(cursors);
        const ops = try gpa.alloc(types.BufferOp, count);
        defer gpa.free(ops);
        const specs = try gpa.alloc(types.SelectionSpec, count);
        defer gpa.free(specs);

        // Typing: an edit and the selection update in one composite.
        const iterations: usize = if (count == 1) 2000 else 20;
        var typing = Sample{
            .name = if (count == 1) "type, 1 caret" else "type, 1000 carets",
            .iterations = iterations,
        };
        for (0..iterations) |_| {
            const intent = try typeAtCarets(gpa, &engine, session, cursors, ops, specs);
            defer freeIntent(gpa, intent);
            try measure(&typing, io, &counting, &engine, intent);
        }
        typing.print();

        // Another client edits near the start: every caret after it only shifts.
        var passive = Sample{
            .name = if (count == 1) "remote edit, 1 caret" else "remote edit, 1000 carets",
            .iterations = iterations,
        };
        for (0..iterations) |_| {
            try measure(
                &passive,
                io,
                &counting,
                &engine,
                .{
                    .id = .{ .value = 2 },
                    .origin = engine.revision,
                    .payload = .{ .buffer_mutation = .{
                        .ops = &.{.{ .insert = .{ .pos = 3, .text = "y" } }},
                    } },
                },
            );
        }
        passive.print();

        // Moving every caret without editing.
        var moving = Sample{
            .name = if (count == 1) "move, 1 caret" else "move, 1000 carets",
            .iterations = iterations,
        };
        for (0..iterations) |_| {
            for (cursors, specs) |cursor, *spec| {
                const at = (try engine.queryAnchor(cursor)).position.?;
                spec.* = .{
                    .start = .{ .move = .{ .anchor = cursor, .to = .{ .position = at + 1 } } },
                };
            }
            try measure(
                &moving,
                io,
                &counting,
                &engine,
                .{
                    .id = .{ .value = 3 },
                    .origin = engine.revision,
                    .payload = .{ .interaction_mutation = .{
                        .session_id = session,
                        .origin = try engine.interactionRevision(session),
                        .ops = &.{.{ .set_selections = .{ .selections = specs } }},
                    } },
                },
            );
        }
        moving.print();
    }
}
