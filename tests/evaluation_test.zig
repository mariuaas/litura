//! Document behavior exercised through the public package.
const std = @import("std");
const litura = @import("litura");
const BufferEngine = litura.BufferEngine;
const anchors = litura.anchors;
const BufferOp = litura.types.BufferOp;
const Intent = litura.types.Intent;
const EvalValue = litura.types.EvalValue;
const castEvalView = litura.evaluation.castView;

fn testProviderDeinitNoop(_: *anyopaque, _: std.mem.Allocator) void {}

test "buffer eval returns bounded text result" {
    const Program = struct {
        fn run(_: ?*anyopaque, view_ptr: *anyopaque) anyerror!EvalValue {
            const view = castEvalView(view_ptr);
            return .{ .text = try view.getText(null, null) };
        }
    };

    var engine = try BufferEngine.initFromText(std.testing.allocator, "alpha beta gamma", null);
    defer engine.deinit();

    var outcome = try engine.bufferEval(.{
        .revision = 0,
        .start = 6,
        .end = 10,
        .fuel = 2,
        .program = .{ .run = Program.run },
    });
    defer outcome.deinit(std.testing.allocator);

    switch (outcome) {
        .result => |result| {
            try std.testing.expectEqual(@as(u32, 1), result.fuel_remaining);
            switch (result.value) {
                .text => |text| try std.testing.expectEqualStrings("beta", text),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "buffer eval rejects mismatched revision and interaction coherence" {
    const Program = struct {
        fn run(_: ?*anyopaque, view_ptr: *anyopaque) anyerror!EvalValue {
            const view = castEvalView(view_ptr);
            return .{ .text = try view.getText(null, null) };
        }
    };

    var engine = try BufferEngine.initFromText(std.testing.allocator, "alpha", null);
    defer engine.deinit();
    const session_id, _ = try @import("support.zig").caret(&engine, 0);

    var revision_outcome = try engine.bufferEval(
        .{ .revision = 1, .fuel = 1, .program = .{ .run = Program.run } },
    );
    defer revision_outcome.deinit(std.testing.allocator);
    switch (revision_outcome) {
        .err => |eval_error| try std.testing.expectEqualStrings(
            "revision 1 is unavailable; current revision is 0",
            eval_error.reason,
        ),
        else => return error.TestUnexpectedResult,
    }

    var coherence_outcome = try engine.bufferEval(.{
        .revision = 0,
        .fuel = 1,
        .interaction_revision = 0,
        .program = .{ .run = Program.run },
    });
    defer coherence_outcome.deinit(std.testing.allocator);
    switch (coherence_outcome) {
        .err => |eval_error| try std.testing.expectEqualStrings(
            "interaction_revision requires session_id",
            eval_error.reason,
        ),
        else => return error.TestUnexpectedResult,
    }

    var session_outcome = try engine.bufferEval(.{
        .revision = 0,
        .session_id = session_id,
        .interaction_revision = 1,
        .fuel = 1,
        .program = .{ .run = Program.run },
    });
    defer session_outcome.deinit(std.testing.allocator);
    switch (session_outcome) {
        .err => |eval_error| try std.testing.expectEqualStrings(
            "interaction revision 1 is unavailable; current revision is 0",
            eval_error.reason,
        ),
        else => return error.TestUnexpectedResult,
    }
}

test "buffer eval returns incomplete when fuel is exhausted" {
    const Program = struct {
        fn run(_: ?*anyopaque, view_ptr: *anyopaque) anyerror!EvalValue {
            const view = castEvalView(view_ptr);
            _ = try view.graphemeCount();
            return .{ .text = try view.getText(null, null) };
        }
    };

    var engine = try BufferEngine.initFromText(std.testing.allocator, "alpha beta", null);
    defer engine.deinit();

    var outcome = try engine.bufferEval(
        .{ .revision = 0, .fuel = 1, .program = .{ .run = Program.run } },
    );
    defer outcome.deinit(std.testing.allocator);
    switch (outcome) {
        .incomplete => |incomplete| {
            try std.testing.expect(incomplete.partial == null);
            try std.testing.expectEqual(@as(u32, 0), incomplete.fuel_remaining);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "buffer eval callable can return intent for later submission" {
    const Context = struct {
        ops: [1]BufferOp,
        intent: Intent,
    };
    const Program = struct {
        fn run(ptr: ?*anyopaque, view_ptr: *anyopaque) anyerror!EvalValue {
            const ctx: *Context = @ptrCast(@alignCast(ptr.?));
            const view = castEvalView(view_ptr);
            const pos = try view.graphemeCount();
            ctx.ops[0] = .{ .insert = .{ .pos = pos, .text = "!" } };
            ctx.intent = .{
                .id = .{ .value = 7 },
                .payload = .{ .buffer_mutation = .{ .ops = ctx.ops[0..] } },
                .origin = 0,
            };
            return .{ .intent = ctx.intent };
        }
    };

    var engine = try BufferEngine.initFromText(std.testing.allocator, "alpha", null);
    defer engine.deinit();
    var context = Context{ .ops = undefined, .intent = undefined };

    var outcome = try engine.bufferEval(.{
        .revision = 0,
        .fuel = 2,
        .program = .{ .ptr = &context, .run = Program.run },
    });
    defer outcome.deinit(std.testing.allocator);

    const returned_intent = switch (outcome) {
        .result => |result| blk: {
            switch (result.value) {
                .intent => |intent| break :blk intent,
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    };

    var submit_result = try engine.submit(returned_intent);
    defer submit_result.deinit(std.testing.allocator);
    const text = try engine.getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("alpha!", text);
}

test "buffer eval enforces engine limits" {
    const Program = struct {
        fn run(_: ?*anyopaque, view_ptr: *anyopaque) anyerror!EvalValue {
            const view = castEvalView(view_ptr);
            return .{ .text = try view.getText(null, null) };
        }
    };

    var engine = try BufferEngine.initFromText(std.testing.allocator, "alpha", null);
    defer engine.deinit();

    var lookahead_outcome = try engine.bufferEval(.{
        .revision = 0,
        .lookahead = 5000,
        .fuel = 1,
        .program = .{ .run = Program.run },
    });
    defer lookahead_outcome.deinit(std.testing.allocator);
    switch (lookahead_outcome) {
        .err => |eval_error| try std.testing.expectEqualStrings(
            "lookahead 5000 exceeds max_lookahead 4096",
            eval_error.reason,
        ),
        else => return error.TestUnexpectedResult,
    }

    var fuel_outcome = try engine.bufferEval(.{
        .revision = 0,
        .fuel = 20_000,
        .program = .{ .run = Program.run },
    });
    defer fuel_outcome.deinit(std.testing.allocator);
    switch (fuel_outcome) {
        .err => |eval_error| try std.testing.expectEqualStrings(
            "fuel 20000 exceeds max_fuel 10000",
            eval_error.reason,
        ),
        else => return error.TestUnexpectedResult,
    }
}

test "query capabilities reports current surface truthfully" {
    var engine = try BufferEngine.initFromText(std.testing.allocator, "alpha", null);
    defer engine.deinit();

    const capabilities = engine.queryCapabilities();
    try std.testing.expectEqualStrings("0.1-prototype", capabilities.protocol_version);
    try std.testing.expectEqual(@as(usize, 3), capabilities.supported_views.len);
    try std.testing.expectEqualStrings("text", capabilities.supported_views[0]);
    try std.testing.expectEqualStrings("anchors", capabilities.supported_views[1]);
    try std.testing.expectEqualStrings("summaries", capabilities.supported_views[2]);
    try std.testing.expect(capabilities.symbol_capabilities == null);
    try std.testing.expectEqual(@as(usize, 5), capabilities.summary_registry.len);
    try std.testing.expectEqualStrings("bracket-depth", capabilities.summary_registry[4]);
    try std.testing.expectEqual(@as(usize, 1), capabilities.apply_policies.len);
    try std.testing.expectEqualStrings("Strict", capabilities.apply_policies[0]);
    try std.testing.expectEqual(@as(usize, 1), capabilities.program_carriers.len);
    try std.testing.expectEqualStrings("zig-callback", capabilities.program_carriers[0].kind);
    try std.testing.expectEqualStrings(
        "PrototypeOperationCount",
        capabilities.program_carriers[0].fuel_model,
    );
    try std.testing.expectEqual(@as(u32, 4096), capabilities.limits.max_guard_extent);
    try std.testing.expectEqual(@as(u32, 4096), capabilities.limits.max_lookahead);
    try std.testing.expectEqual(@as(u32, 10_000), capabilities.limits.max_fuel);
}

test "buffer eval search beyond the evaluated range returns null without leaking" {
    const Program = struct {
        fn run(_: ?*anyopaque, view_ptr: *anyopaque) anyerror!EvalValue {
            const view = castEvalView(view_ptr);
            // "beta" exists in the document, but outside [0, 5).
            if (try view.findNext("beta", 0)) |match| return .{ .search_match = match };
            return .{ .none = {} };
        }
    };

    var engine = try BufferEngine.initFromText(std.testing.allocator, "alpha beta", null);
    defer engine.deinit();
    var outcome = try engine.bufferEval(.{
        .revision = 0,
        .start = 0,
        .end = 5,
        .fuel = 4,
        .program = .{ .run = Program.run },
    });
    defer outcome.deinit(std.testing.allocator);
    switch (outcome) {
        .result => |result| try std.testing.expect(result.value == .none),
        else => return error.TestUnexpectedResult,
    }
}
