//! Tree-sitter runtime and grammar bindings used by the optional provider.

const std = @import("std");

const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

pub const Language = c.TSLanguage;

pub const Point = struct {
    row: u32,
    column: u32,

    fn fromRaw(raw: c.TSPoint) Point {
        return .{ .row = raw.row, .column = raw.column };
    }
};

pub const QueryPredicateStep = struct {
    type: enum {
        done,
        capture,
        string,
    },
    value_id: u32,
};

pub const Node = struct {
    raw: c.TSNode,

    pub fn isNull(self: Node) bool {
        return c.ts_node_is_null(self.raw);
    }

    pub fn startByte(self: Node) u32 {
        return c.ts_node_start_byte(self.raw);
    }

    pub fn endByte(self: Node) u32 {
        return c.ts_node_end_byte(self.raw);
    }

    pub fn startPoint(self: Node) Point {
        return Point.fromRaw(c.ts_node_start_point(self.raw));
    }

    pub fn endPoint(self: Node) Point {
        return Point.fromRaw(c.ts_node_end_point(self.raw));
    }

    pub fn @"type"(self: Node) []const u8 {
        return std.mem.span(c.ts_node_type(self.raw));
    }

    pub fn isNamed(self: Node) bool {
        return c.ts_node_is_named(self.raw);
    }

    pub fn text(self: Node, source: []const u8) []const u8 {
        const start = @min(self.startByte(), source.len);
        const end = @min(self.endByte(), source.len);
        return source[start..end];
    }

    pub fn parent(self: Node) Node {
        return .{ .raw = c.ts_node_parent(self.raw) };
    }

    pub fn child(self: Node, child_index: u32) Node {
        return .{ .raw = c.ts_node_child(self.raw, child_index) };
    }

    pub fn childCount(self: Node) u32 {
        return c.ts_node_child_count(self.raw);
    }

    pub fn namedChild(self: Node, child_index: u32) Node {
        return .{ .raw = c.ts_node_named_child(self.raw, child_index) };
    }

    pub fn namedChildCount(self: Node) u32 {
        return c.ts_node_named_child_count(self.raw);
    }

    pub fn descendantForByteRange(self: Node, start_byte: u32, end_byte: u32) Node {
        return .{ .raw = c.ts_node_descendant_for_byte_range(self.raw, start_byte, end_byte) };
    }

    pub fn namedDescendantForByteRange(self: Node, start_byte: u32, end_byte: u32) Node {
        return .{ .raw = c.ts_node_named_descendant_for_byte_range(self.raw, start_byte, end_byte) };
    }

    pub fn eql(self: Node, other: Node) bool {
        return c.ts_node_eq(self.raw, other.raw);
    }
};

pub const Tree = struct {
    raw: *c.TSTree,

    pub fn destroy(self: *Tree) void {
        c.ts_tree_delete(self.raw);
        self.* = undefined;
    }

    pub fn rootNode(self: Tree) Node {
        return .{ .raw = c.ts_tree_root_node(self.raw) };
    }
};

pub const Parser = struct {
    raw: *c.TSParser,

    pub fn create() !Parser {
        const raw = c.ts_parser_new() orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    pub fn destroy(self: *Parser) void {
        c.ts_parser_delete(self.raw);
        self.* = undefined;
    }

    pub fn setLanguage(self: *Parser, language: *const c.TSLanguage) !void {
        if (!c.ts_parser_set_language(self.raw, language)) {
            return error.IncompatibleLanguage;
        }
    }

    pub fn parseString(self: *Parser, source: []const u8, old_tree: ?Tree) !Tree {
        const old_raw = if (old_tree) |tree| tree.raw else null;
        const raw = c.ts_parser_parse_string(self.raw, old_raw, source.ptr, @intCast(source.len)) orelse {
            return error.ParseFailed;
        };
        return .{ .raw = raw };
    }
};

pub const Capture = struct {
    node: Node,
    index: u32,
};

pub const Match = struct {
    id: u32,
    pattern_index: u16,
    captures: []const Capture,
};

pub const Query = struct {
    raw: *c.TSQuery,

    pub fn create(language: *const c.TSLanguage, source: []const u8) !Query {
        var error_offset: u32 = 0;
        var error_kind: c.TSQueryError = c.TSQueryErrorNone;
        const raw = c.ts_query_new(language, source.ptr, @intCast(source.len), &error_offset, &error_kind) orelse {
            return switch (error_kind) {
                c.TSQueryErrorSyntax => error.InvalidSyntax,
                c.TSQueryErrorNodeType => error.InvalidNodeType,
                c.TSQueryErrorField => error.InvalidField,
                c.TSQueryErrorCapture => error.InvalidCapture,
                c.TSQueryErrorStructure => error.InvalidStructure,
                c.TSQueryErrorLanguage => error.InvalidLanguage,
                else => error.InvalidQuery,
            };
        };
        return .{ .raw = raw };
    }

    pub fn destroy(self: *Query) void {
        c.ts_query_delete(self.raw);
        self.* = undefined;
    }

    pub fn captureNameForId(self: Query, id: u32) ?[]const u8 {
        var length: u32 = 0;
        const name = c.ts_query_capture_name_for_id(self.raw, id, &length);
        if (name == null or length == 0) return null;
        return name[0..length];
    }

    pub fn stringValueForId(self: Query, id: u32) ?[]const u8 {
        var length: u32 = 0;
        const value = c.ts_query_string_value_for_id(self.raw, id, &length);
        if (value == null or length == 0) return null;
        return value[0..length];
    }

    pub fn predicatesForPattern(self: Query, pattern_index: u32) []const QueryPredicateStep {
        var count: u32 = 0;
        const raw_steps = c.ts_query_predicates_for_pattern(self.raw, pattern_index, &count);
        if (raw_steps == null or count == 0) return &.{};

        const Raw = c.TSQueryPredicateStep;
        const raw_slice: []const Raw = @as([*]const Raw, @ptrCast(raw_steps))[0..count];
        return @as([*]const QueryPredicateStep, @ptrCast(raw_slice.ptr))[0..count];
    }
};

pub const QueryCursor = struct {
    raw: *c.TSQueryCursor,

    pub fn create() !QueryCursor {
        const raw = c.ts_query_cursor_new() orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    pub fn destroy(self: *QueryCursor) void {
        c.ts_query_cursor_delete(self.raw);
        self.* = undefined;
    }

    pub fn exec(self: QueryCursor, query: Query, node: Node) void {
        c.ts_query_cursor_exec(self.raw, query.raw, node.raw);
    }

    pub fn setByteRange(self: QueryCursor, start_byte: u32, end_byte: u32) void {
        _ = c.ts_query_cursor_set_byte_range(self.raw, start_byte, end_byte);
    }

    pub fn nextMatch(self: QueryCursor) ?Match {
        var raw_match: c.TSQueryMatch = undefined;
        if (!c.ts_query_cursor_next_match(self.raw, &raw_match)) return null;
        const raw_captures: []const c.TSQueryCapture = @as([*]const c.TSQueryCapture, @ptrCast(raw_match.captures))[0..raw_match.capture_count];
        const captures: []const Capture = @as([*]const Capture, @ptrCast(raw_captures.ptr))[0..raw_captures.len];
        return .{
            .id = raw_match.id,
            .pattern_index = raw_match.pattern_index,
            .captures = captures,
        };
    }
};

pub fn luaLanguage() *const c.TSLanguage {
    return tree_sitter_lua();
}

pub fn zigLanguage() *const c.TSLanguage {
    return tree_sitter_zig();
}

pub fn fennelLanguage() *const c.TSLanguage {
    return tree_sitter_fennel();
}

extern fn tree_sitter_lua() callconv(.c) *const c.TSLanguage;
extern fn tree_sitter_zig() callconv(.c) *const c.TSLanguage;
extern fn tree_sitter_fennel() callconv(.c) *const c.TSLanguage;
