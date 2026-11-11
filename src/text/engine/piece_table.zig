//! Owning piece-table storage, tree traversal and grapheme-based text queries.

const std = @import("std");

const segmentation = @import("text_segmentation.zig");
const summaries = @import("summaries.zig");

const Segmenter = segmentation.Segmenter;
const Summary = summaries.Summary;
const BracketDepth = summaries.BracketDepth;

pub const nodes = @import("pt_nodes.zig");
const search = @import("pt_search.zig");

pub const Error = nodes.Error;
pub const PieceTableError = nodes.PieceTableError;
pub const max_cursor_path = 64;

pub const PathEntry = struct {
    node: *nodes.Internal,
    child_index: usize,
};

/// Borrows a piece table without allocating. Positions are grapheme offsets.
/// The table must outlive the cursor; edits invalidate its cached tree path.
pub const GraphemeCursor = struct {
    table: *const PieceTable,
    position: u32,
    leaf: ?*nodes.Leaf = null,
    path: [max_cursor_path]PathEntry = undefined,
    path_len: usize = 0,
    piece_index: usize = 0,
    cluster_byte: usize = 0,
    valid: bool = false,

    pub fn current(self: *const GraphemeCursor) Error![]const u8 {
        if (!self.valid) return error.OutOfRange;
        const leaf = self.leaf orelse return error.OutOfRange;
        if (self.piece_index >= leaf.pieces.items.len) return error.OutOfRange;
        const piece = leaf.pieces.items[self.piece_index];
        const text = self.table.pieceText(piece);
        if (self.cluster_byte >= text.len) return error.OutOfRange;
        var iter = self.table.seg.iterator(text[self.cluster_byte..]);
        return iter.next() orelse error.OutOfRange;
    }

    pub fn advance(self: *GraphemeCursor) bool {
        if (!self.valid) return false;

        const cluster = self.current() catch return false;
        const leaf = self.leaf orelse return false;
        const piece = leaf.pieces.items[self.piece_index];
        self.cluster_byte += cluster.len;
        self.position += 1;

        if (self.cluster_byte < piece.len) {
            return true;
        }

        if (self.piece_index + 1 < leaf.pieces.items.len) {
            self.piece_index += 1;
            self.cluster_byte = 0;
            return true;
        }

        if (self.table.cursorNextLeaf(self.path[0..self.path_len])) |target| {
            self.leaf = target.leaf;
            self.path = target.path;
            self.path_len = target.path_len;
            self.piece_index = 0;
            self.cluster_byte = 0;
            self.valid = true;
            return true;
        }

        self.valid = false;
        self.leaf = null;
        self.path_len = 0;
        self.piece_index = 0;
        self.cluster_byte = 0;
        self.position = self.table.graphemeCount();
        return false;
    }

    pub fn retreat(self: *GraphemeCursor) bool {
        if (!self.valid) {
            if (self.position == self.table.graphemeCount() and self.position > 0) {
                const target = self.table.cursorRightmostLeaf() catch return false;
                const leaf = target.leaf orelse return false;
                self.leaf = leaf;
                self.path = target.path;
                self.path_len = target.path_len;
                self.piece_index = leaf.pieces.items.len - 1;
                self.cluster_byte = self.lastGraphemeByteInPiece(leaf.pieces.items[self.piece_index]) catch return false;
                self.valid = true;
                self.position -= 1;
                return true;
            }
            return false;
        }

        const leaf = self.leaf orelse return false;

        if (self.cluster_byte > 0) {
            self.cluster_byte = self.previousBoundaryInPiece(leaf.pieces.items[self.piece_index], self.cluster_byte) catch return false;
            self.position -= 1;
            return true;
        }

        if (self.piece_index > 0) {
            self.piece_index -= 1;
            self.cluster_byte = self.lastGraphemeByteInPiece(leaf.pieces.items[self.piece_index]) catch return false;
            self.position -= 1;
            return true;
        }

        if (self.table.cursorPreviousLeaf(self.path[0..self.path_len])) |target| {
            const prev_leaf = target.leaf orelse return false;
            self.leaf = prev_leaf;
            self.path = target.path;
            self.path_len = target.path_len;
            self.piece_index = prev_leaf.pieces.items.len - 1;
            self.cluster_byte = self.lastGraphemeByteInPiece(prev_leaf.pieces.items[self.piece_index]) catch return false;
            self.valid = true;
            self.position -= 1;
            return true;
        }

        self.valid = false;
        self.leaf = null;
        self.path_len = 0;
        self.piece_index = 0;
        self.cluster_byte = 0;
        self.position = 0;
        return false;
    }

    fn previousBoundaryInPiece(
        self: *const GraphemeCursor,
        piece: nodes.Piece,
        end_byte: usize,
    ) Error!usize {
        const text = self.table.pieceText(piece);
        if (end_byte > text.len) return error.OutOfRange;

        var iter = self.table.seg.iterator(text);
        var previous: ?usize = null;
        while (iter.inner.next()) |gc| {
            if (gc.offset >= end_byte) break;
            previous = gc.offset;
        }
        return previous orelse error.OutOfRange;
    }

    fn lastGraphemeByteInPiece(self: *const GraphemeCursor, piece: nodes.Piece) Error!usize {
        return self.previousBoundaryInPiece(piece, piece.len);
    }
};

pub const LineCol = struct {
    line: u32,
    col: u32,
};

/// Owns tree nodes and original/add text buffers through allocator.
/// Do not shallow-copy. Keep its address stable while a GraphemeCursor borrows it.
pub const PieceTable = struct {
    allocator: std.mem.Allocator,
    seg: Segmenter,
    original_buf: std.ArrayListUnmanaged(u8) = .empty,
    add_buf: std.ArrayListUnmanaged(u8) = .empty,
    root: nodes.NodeRef,
    /// The active mutation transaction, if any (see `begin`).
    transaction: ?Transaction = null,

    const Location = struct {
        leaf: *nodes.Leaf,
        path: [max_cursor_path]PathEntry,
        path_len: usize,
        piece_index: usize,
        cluster_byte: usize,
    };

    const LeafTarget = struct {
        leaf: ?*nodes.Leaf,
        path: [max_cursor_path]PathEntry,
        path_len: usize,
    };

    const NodeOverflow = struct {
        left: nodes.NodeRef,
        right: nodes.NodeRef,
    };

    pub const BracketKind = enum { paren, square, curly };

    pub const BracketMatch = struct {
        start: u32,
        end: u32,
    };

    const SplitPiece = struct {
        left: ?nodes.Piece,
        right: ?nodes.Piece,
    };

    /// A requested replacement widened to grapheme boundaries that exist both before and
    /// after the edit. Old graphemes [start, old_end) become new graphemes [start, new_end).
    /// Context graphemes are unrequested neighbours rewritten because their boundaries changed.
    pub const Splice = struct {
        start: u32,
        old_end: u32,
        new_end: u32,
        left_context: u32 = 0,
        right_context: u32 = 0,
        left_context_bytes: u32 = 0,
        right_context_bytes: u32 = 0,

        pub fn isAligned(self: Splice) bool {
            return self.left_context == 0 and self.right_context == 0;
        }

        pub fn requestedStart(self: Splice) u32 {
            return self.start + self.left_context;
        }

        pub fn requestedEnd(self: Splice) u32 {
            return self.old_end - self.right_context;
        }
    };

    /// A mutation in progress. Edits build a candidate tree beside the committed one: a
    /// committed node is copied on its first write, never written, so the committed tree
    /// stays intact until `commit` publishes the candidate or `abort` discards it.
    pub const Transaction = struct {
        committed_root: nodes.NodeRef,
        add_buf_len: usize,
        /// Nodes this transaction created, threaded through `Ownership.next`.
        created: ?nodes.NodeRef = null,
        /// Committed nodes this transaction copied, threaded the same way.
        replaced: ?nodes.NodeRef = null,
        /// Committed nodes copied so far; a diagnostic for path-copy cost.
        copied: u32 = 0,
    };

    pub fn init(allocator: std.mem.Allocator) !PieceTable {
        const empty_leaf = try allocator.create(nodes.Leaf);
        empty_leaf.* = .{};
        return .{
            .allocator = allocator,
            .seg = try Segmenter.init(allocator),
            .root = .{ .leaf = empty_leaf },
        };
    }

    pub fn deinit(self: *PieceTable) void {
        std.debug.assert(self.transaction == null);
        freeNode(self.allocator, self.root);
        self.add_buf.deinit(self.allocator);
        self.original_buf.deinit(self.allocator);
        self.seg.deinit(self.allocator);
        self.* = undefined;
    }

    /// Replaces the whole document. The new tree is built beside the current one and
    /// swapped in only once complete, so on error the current document is unchanged.
    pub fn initFromText(self: *PieceTable, text: []const u8) !void {
        std.debug.assert(self.transaction == null);
        // Holds the new buffer until the swap, then the old one; freed either way.
        var original: std.ArrayListUnmanaged(u8) = .empty;
        defer original.deinit(self.allocator);
        try original.appendSlice(self.allocator, text);
        // Pieces are built against `original_buf`; nothing reads the old tree meanwhile.
        std.mem.swap(std.ArrayListUnmanaged(u8), &self.original_buf, &original);
        const root = self.buildRoot(text.len) catch |err| {
            std.mem.swap(std.ArrayListUnmanaged(u8), &self.original_buf, &original);
            return err;
        };
        freeNode(self.allocator, self.root);
        self.root = root;
        self.add_buf.clearRetainingCapacity();
    }

    fn buildRoot(self: *const PieceTable, len: usize) !nodes.NodeRef {
        if (len == 0) {
            const empty_leaf = try self.allocator.create(nodes.Leaf);
            empty_leaf.* = .{};
            return .{ .leaf = empty_leaf };
        }
        const chunked = try self.makePiecesChunked(.original, 0, len);
        defer self.allocator.free(chunked);
        return buildTree(self.allocator, chunked);
    }

    pub fn graphemeCount(self: *const PieceTable) u32 {
        return self.root.summary().graphemes;
    }

    pub fn byteCount(self: *const PieceTable) u32 {
        return self.root.summary().bytes;
    }

    pub fn lineCount(self: *const PieceTable) u32 {
        return self.root.summary().newlines + 1;
    }

    pub fn wordCount(self: *const PieceTable) u32 {
        return self.root.summary().words.runs;
    }

    pub fn lineStart(self: *const PieceTable, line: u32) Error!u32 {
        if (line > self.lineCount()) return error.OutOfRange;
        if (line == 0) return 0;
        if (line == self.lineCount()) return self.graphemeCount();
        return self.positionAfterNewline(line);
    }

    pub fn lineEnd(self: *const PieceTable, line: u32, include_newline: bool) Error!u32 {
        if (line >= self.lineCount()) return error.OutOfRange;

        const start = try self.lineStart(line);
        const next_start = try self.lineStart(line + 1);
        if (include_newline or next_start == start) return next_start;
        if (next_start > 0) {
            const previous = try self.graphemeAt(next_start - 1);
            if (std.mem.eql(u8, previous, "\n")) return next_start - 1;
        }
        return next_start;
    }

    pub fn lineColToPosition(self: *const PieceTable, line: u32, col: u32) Error!u32 {
        if (line >= self.lineCount()) return error.OutOfRange;

        const start = try self.lineStart(line);
        const end = try self.lineEnd(line, false);
        return start + @min(col, end - start);
    }

    pub fn positionToLineCol(self: *const PieceTable, pos: u32) Error!LineCol {
        try self.validatePosition(pos);
        const line = try self.newlineCountBefore(pos);
        return .{
            .line = line,
            .col = pos - try self.lineStart(line),
        };
    }

    pub fn newlineCountBefore(self: *const PieceTable, pos: u32) Error!u32 {
        try self.validatePosition(pos);
        if (pos == 0) return 0;
        return self.newlineCountBeforeNode(self.root, pos);
    }

    pub fn getText(self: *const PieceTable) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.ensureTotalCapacity(self.allocator, self.root.summary().bytes);
        try self.collectText(self.root, &out);
        return out.toOwnedSlice(self.allocator);
    }

    pub fn getTextRange(self: *const PieceTable, start: u32, end: u32) ![]u8 {
        try self.validateRange(start, end);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);

        try self.collectTextRange(self.root, start, end, &out);

        return out.toOwnedSlice(self.allocator);
    }

    pub fn graphemeAt(self: *const PieceTable, pos: u32) Error![]const u8 {
        if (pos >= self.root.summary().graphemes) return error.OutOfRange;

        const location = try self.locateGrapheme(pos);
        const piece = location.leaf.pieces.items[location.piece_index];
        const text = self.pieceText(piece);
        if (location.cluster_byte >= text.len) return error.OutOfRange;
        var iter = self.seg.iterator(text[location.cluster_byte..]);
        return iter.next() orelse error.OutOfRange;
    }

    fn insertInto(
        self: *PieceTable,
        node: nodes.NodeRef,
        pos: u32,
        piece: nodes.Piece,
    ) !?NodeOverflow {
        switch (node) {
            .internal => |n| {
                var remaining = pos;
                for (n.children.items, 0..) |child, i| {
                    const g = child.summary().graphemes;
                    if (remaining < g or i == n.children.items.len - 1) {
                        const target = try self.writable(&n.children.items[i]);
                        if (try self.insertInto(target, remaining, piece)) |overflow| {
                            n.children.items[i] = overflow.left;
                            try n.children.insert(self.allocator, i + 1, overflow.right);
                        }
                        break;
                    }
                    remaining -= g;
                }
                nodes.recomputeNode(node);
                if (n.children.items.len > nodes.max_internal_fanout) {
                    const split = try self.splitInternal(n);
                    return .{ .left = split.left, .right = split.right };
                }
                return null;
            },
            .leaf => |n| {
                var remaining = pos;
                var insert_at: usize = n.pieces.items.len;
                var split_offset: u32 = 0;
                for (n.pieces.items, 0..) |p, i| {
                    if (remaining < p.summary.graphemes) {
                        insert_at = i;
                        split_offset = remaining;
                        break;
                    }
                    remaining -= p.summary.graphemes;
                }

                if (insert_at < n.pieces.items.len and split_offset > 0 and split_offset < n.pieces.items[insert_at].summary.graphemes) {
                    const old = n.pieces.items[insert_at];
                    const split = try self.splitPiece(old, split_offset);
                    n.pieces.items[insert_at] = split.left.?;
                    try n.pieces.insert(self.allocator, insert_at + 1, split.right.?);
                    insert_at += 1;
                }

                try n.pieces.insert(self.allocator, insert_at, piece);
                nodes.recomputeNode(node);
                if (n.pieces.items.len > nodes.max_leaf_pieces) {
                    const split = try self.splitLeaf(n);
                    return .{ .left = split.left, .right = split.right };
                }
                return null;
            },
        }
    }

    fn locateGrapheme(self: *const PieceTable, pos: u32) Error!Location {
        var node = self.root;
        var remaining = pos;
        var path: [max_cursor_path]PathEntry = undefined;
        var path_len: usize = 0;
        while (true) {
            switch (node) {
                .internal => |n| {
                    var found = false;
                    for (n.children.items, 0..) |child, index| {
                        const g = child.summary().graphemes;
                        if (remaining < g) {
                            std.debug.assert(path_len < max_cursor_path);
                            path[path_len] = .{ .node = n, .child_index = index };
                            path_len += 1;
                            node = child;
                            found = true;
                            break;
                        }
                        remaining -= g;
                    }
                    if (!found) return error.OutOfRange;
                },
                .leaf => |n| {
                    for (n.pieces.items, 0..) |piece, i| {
                        if (remaining < piece.summary.graphemes) {
                            const text = self.pieceText(piece);
                            const split = self.seg.splitAtGrapheme(text, remaining) catch return error.OutOfRange;
                            return .{ .leaf = n, .path = path, .path_len = path_len, .piece_index = i, .cluster_byte = split.left.len };
                        }
                        remaining -= piece.summary.graphemes;
                    }
                    return error.OutOfRange;
                },
            }
        }
    }

    pub fn cursorNextLeaf(self: *const PieceTable, path: []const PathEntry) ?LeafTarget {
        return self.cursorAdjacentLeaf(path, true);
    }

    pub fn cursorPreviousLeaf(self: *const PieceTable, path: []const PathEntry) ?LeafTarget {
        return self.cursorAdjacentLeaf(path, false);
    }

    pub fn cursorAdjacentLeaf(
        self: *const PieceTable,
        path: []const PathEntry,
        forward: bool,
    ) ?LeafTarget {
        _ = self;
        if (path.len == 0) return null;

        var new_path: [max_cursor_path]PathEntry = undefined;
        @memcpy(new_path[0..path.len], path);
        var path_len = path.len;

        var depth = path_len;
        while (depth > 0) {
            depth -= 1;
            const entry = &new_path[depth];
            const children = entry.node.children.items;

            const next_index = if (forward)
                if (entry.child_index + 1 < children.len) entry.child_index + 1 else continue
            else if (entry.child_index > 0) entry.child_index - 1 else continue;

            entry.child_index = next_index;
            path_len = depth + 1;

            var node = children[next_index];
            while (true) {
                switch (node) {
                    .leaf => |leaf| {
                        return .{ .leaf = leaf, .path = new_path, .path_len = path_len };
                    },
                    .internal => |internal| {
                        const child_index: usize = if (forward) 0 else internal.children.items.len - 1;
                        std.debug.assert(path_len < max_cursor_path);
                        new_path[path_len] = .{ .node = internal, .child_index = child_index };
                        path_len += 1;
                        node = internal.children.items[child_index];
                    },
                }
            }
        }

        return null;
    }

    pub fn cursorRightmostLeaf(self: *const PieceTable) Error!LeafTarget {
        var node = self.root;
        var path: [max_cursor_path]PathEntry = undefined;
        var path_len: usize = 0;
        while (true) {
            switch (node) {
                .leaf => |leaf| {
                    return .{ .leaf = leaf, .path = path, .path_len = path_len };
                },
                .internal => |internal| {
                    const child_index = internal.children.items.len - 1;
                    std.debug.assert(path_len < max_cursor_path);
                    path[path_len] = .{ .node = internal, .child_index = child_index };
                    path_len += 1;
                    node = internal.children.items[child_index];
                },
            }
        }
    }

    pub fn graphemeCursor(self: *const PieceTable, pos: u32) Error!GraphemeCursor {
        try self.validatePosition(pos);
        if (pos == self.root.summary().graphemes) {
            return .{
                .table = self,
                .position = pos,
                .leaf = null,
                .path_len = 0,
                .piece_index = 0,
                .cluster_byte = 0,
                .valid = false,
            };
        }

        const location = try self.locateGrapheme(pos);
        return .{
            .table = self,
            .position = pos,
            .leaf = location.leaf,
            .path = location.path,
            .path_len = location.path_len,
            .piece_index = location.piece_index,
            .cluster_byte = location.cluster_byte,
            .valid = true,
        };
    }

    pub fn findNext(self: *const PieceTable, pattern_text: []const u8, start: u32) !?u32 {
        return search.findNext(self, pattern_text, start);
    }

    pub fn findPrevious(self: *const PieceTable, pattern_text: []const u8, start: ?u32) !?u32 {
        return search.findPrevious(self, pattern_text, start);
    }

    fn bracketDepth(summary: Summary, kind: BracketKind) BracketDepth {
        return switch (kind) {
            .paren => summary.brackets.paren,
            .square => summary.brackets.square,
            .curly => summary.brackets.curly,
        };
    }

    fn bracketKindForCluster(cluster: []const u8) ?BracketKind {
        if (cluster.len != 1) return null;
        return switch (cluster[0]) {
            '(', ')' => .paren,
            '[', ']' => .square,
            '{', '}' => .curly,
            else => null,
        };
    }

    fn isOpenCluster(cluster: []const u8) bool {
        return cluster.len == 1 and (cluster[0] == '(' or cluster[0] == '[' or cluster[0] == '{');
    }

    fn isCloseCluster(cluster: []const u8) bool {
        return cluster.len == 1 and (cluster[0] == ')' or cluster[0] == ']' or cluster[0] == '}');
    }

    fn summarizePieceGraphemeRange(
        self: *const PieceTable,
        piece: nodes.Piece,
        start_offset: u32,
        end_offset: u32,
    ) Error!Summary {
        if (start_offset > end_offset or end_offset > piece.summary.graphemes) return error.InvalidRange;
        if (start_offset == 0 and end_offset == piece.summary.graphemes) return piece.summary;
        if (start_offset == end_offset) return Summary.empty;

        const text = self.pieceText(piece);
        var grapheme: u32 = 0;
        var start_byte: usize = text.len;
        var end_byte: usize = text.len;
        var iter = self.seg.iterator(text);
        while (iter.inner.next()) |gc| {
            if (grapheme == start_offset) start_byte = gc.offset;
            if (grapheme == end_offset) {
                end_byte = gc.offset;
                break;
            }
            grapheme += 1;
        }
        if (end_offset == piece.summary.graphemes) end_byte = text.len;
        if (start_byte > end_byte or end_byte > text.len) return error.OutOfRange;
        return Summary.fromText(&self.seg, text[start_byte..end_byte]);
    }

    fn nodeSummaryRange(
        self: *const PieceTable,
        node: nodes.NodeRef,
        node_start: u32,
        start: u32,
        end: u32,
    ) Error!Summary {
        const node_end = node_start + node.summary().graphemes;
        if (end <= node_start or start >= node_end) return Summary.empty;
        if (start <= node_start and node_end <= end) return node.summary();

        var acc = Summary.empty;
        switch (node) {
            .leaf => |leaf| {
                var cursor = node_start;
                for (leaf.pieces.items) |piece| {
                    const piece_start = cursor;
                    const piece_end = cursor + piece.summary.graphemes;
                    if (end > piece_start and start < piece_end) {
                        const local_start: u32 = if (start > piece_start) start - piece_start else 0;
                        const local_end: u32 = if (end < piece_end) end - piece_start else piece.summary.graphemes;
                        acc = Summary.merge(acc, try self.summarizePieceGraphemeRange(piece, local_start, local_end));
                    }
                    cursor = piece_end;
                    if (cursor >= end) break;
                }
            },
            .internal => |internal| {
                var cursor = node_start;
                for (internal.children.items) |child| {
                    const child_start = cursor;
                    const child_end = cursor + child.summary().graphemes;
                    if (end > child_start and start < child_end) {
                        acc = Summary.merge(acc, try self.nodeSummaryRange(child, child_start, start, end));
                    }
                    cursor = child_end;
                    if (cursor >= end) break;
                }
            },
        }
        return acc;
    }

    pub fn summaryRange(self: *const PieceTable, start: u32, end: u32) Error!Summary {
        try self.validateRange(start, end);
        if (start == end) return Summary.empty;
        return try self.nodeSummaryRange(self.root, 0, start, end);
    }

    fn forwardHasMatch(
        self: *const PieceTable,
        start: u32,
        end: u32,
        kind: BracketKind,
    ) Error!bool {
        const depth = bracketDepth(try self.summaryRange(start, end), kind);
        return depth.p_min <= -1;
    }

    fn backwardHasMatch(
        self: *const PieceTable,
        start: u32,
        end: u32,
        kind: BracketKind,
    ) Error!bool {
        const depth = bracketDepth(try self.summaryRange(start, end), kind);
        // Reverse traversal minimum prefix: min_suffix(-range) = p_min - net.
        return depth.p_min - depth.net <= -1;
    }

    fn matchForward(self: *const PieceTable, pos: u32, kind: BracketKind) Error!?u32 {
        const start = pos + 1;
        const end_limit = self.graphemeCount();
        if (start >= end_limit or !(try self.forwardHasMatch(start, end_limit, kind))) return null;
        var lo = start + 1;
        var hi = end_limit;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (try self.forwardHasMatch(start, mid, kind)) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        return lo - 1;
    }

    fn matchBackward(self: *const PieceTable, pos: u32, kind: BracketKind) Error!?u32 {
        if (pos == 0 or !(try self.backwardHasMatch(0, pos, kind))) return null;
        var lo: u32 = 0;
        var hi: u32 = pos;
        while (lo < hi) {
            const mid = lo + (hi - lo + 1) / 2;
            if (try self.backwardHasMatch(mid, pos, kind)) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return lo;
    }

    pub fn matchBracketAt(self: *const PieceTable, pos: u32) Error!?BracketMatch {
        if (pos >= self.graphemeCount()) return null;
        var cursor = try self.graphemeCursor(pos);
        const cluster = try cursor.current();
        const kind = bracketKindForCluster(cluster) orelse return null;
        if (isOpenCluster(cluster)) {
            const mate = (try self.matchForward(pos, kind)) orelse return null;
            var mate_cursor = try self.graphemeCursor(mate);
            if (!isCloseCluster(try mate_cursor.current())) return null;
            return .{ .start = pos, .end = mate };
        }
        if (isCloseCluster(cluster)) {
            const mate = (try self.matchBackward(pos, kind)) orelse return null;
            var mate_cursor = try self.graphemeCursor(mate);
            if (!isOpenCluster(try mate_cursor.current())) return null;
            return .{ .start = mate, .end = pos };
        }
        return null;
    }

    pub fn insert(self: *PieceTable, pos: u32, text: []const u8) !void {
        try self.replace(pos, pos, text);
    }

    pub fn delete(self: *PieceTable, start: u32, end: u32) !void {
        try self.replace(start, end, "");
    }

    /// Replaces graphemes [start, end) with UTF-8 text and resegments any neighbours whose
    /// boundaries change; the caller keeps ownership of text, which is copied.
    /// Range errors change nothing. For allocation failure, see applySplice.
    pub fn replace(self: *PieceTable, start: u32, end: u32, text: []const u8) !void {
        const splice = try self.planReplace(start, end, text);
        self.begin();
        self.applySplice(splice, text) catch |err| {
            self.abort();
            return err;
        };
        self.commit();
    }

    /// Starts a transaction. Until `commit` or `abort`, edits apply to a candidate tree and
    /// never write a node committed before `begin`. A failed edit may leave the candidate
    /// inconsistent; then only `abort` is allowed. Does not allocate.
    pub fn begin(self: *PieceTable) void {
        std.debug.assert(self.transaction == null);
        self.transaction = .{ .committed_root = self.root, .add_buf_len = self.add_buf.items.len };
    }

    /// Publishes the candidate tree, then frees the committed nodes it no longer uses.
    /// Requires every edit since `begin` to have succeeded. Does not allocate or fail.
    pub fn commit(self: *PieceTable) void {
        const transaction = self.transaction.?;
        self.transaction = null;
        markReachable(self.root);

        // Created nodes left unreachable were split, merged or deleted away.
        var created = transaction.created;
        while (created) |node| {
            created = node.ownership().next;
            if (!node.ownership().reachable) node.destroyShallow(self.allocator);
        }
        // A replaced node's children are shared with its copy unless they were removed.
        // Parents are replaced before children, so free removed children first, while
        // every replaced node can still be inspected.
        var replaced = transaction.replaced;
        while (replaced) |node| : (replaced = node.ownership().next) {
            if (node == .internal) {
                for (node.internal.children.items) |child| self.freeRemoved(child);
            }
        }
        replaced = transaction.replaced;
        while (replaced) |node| {
            replaced = node.ownership().next;
            node.destroyShallow(self.allocator);
        }
        settle(self.root);
    }

    /// Discards the candidate tree and restores the committed one. Never reads the
    /// candidate, so it is safe after any failed edit. Does not allocate or fail.
    pub fn abort(self: *PieceTable) void {
        const transaction = self.transaction.?;
        self.transaction = null;
        var created = transaction.created;
        while (created) |node| {
            created = node.ownership().next;
            node.destroyShallow(self.allocator);
        }
        var replaced = transaction.replaced;
        while (replaced) |node| {
            const ownership = node.ownership();
            replaced = ownership.next;
            ownership.* = .{};
        }
        self.root = transaction.committed_root;
        self.add_buf.shrinkRetainingCapacity(transaction.add_buf_len);
    }

    /// Returns the node in `slot` in a form the transaction may write: the node itself if
    /// the transaction created it, otherwise a copy that replaces it in `slot`. `slot` must
    /// be the root or belong to a node the transaction may write.
    fn writable(self: *PieceTable, slot: *nodes.NodeRef) !nodes.NodeRef {
        if (slot.ownership().owned) return slot.*;
        const copy = try self.copyNode(slot.*);
        const transaction = &self.transaction.?;
        const original = slot.ownership();
        original.replaced = true;
        original.next = transaction.replaced;
        transaction.replaced = slot.*;
        transaction.copied += 1;
        slot.* = copy;
        return copy;
    }

    fn copyNode(self: *PieceTable, node: nodes.NodeRef) !nodes.NodeRef {
        switch (node) {
            .leaf => |leaf| {
                const copy = try self.createLeaf();
                try copy.pieces.appendSlice(self.allocator, leaf.pieces.items);
                copy.summary = leaf.summary;
                return .{ .leaf = copy };
            },
            .internal => |internal| {
                const copy = try self.createInternal();
                try copy.children.appendSlice(self.allocator, internal.children.items);
                copy.summary = internal.summary;
                return .{ .internal = copy };
            },
        }
    }

    /// Creates an empty leaf owned by the transaction. It is recorded before it is linked
    /// anywhere, so `abort` frees it whatever happens next.
    fn createLeaf(self: *PieceTable) !*nodes.Leaf {
        const leaf = try self.allocator.create(nodes.Leaf);
        leaf.* = .{};
        self.register(.{ .leaf = leaf });
        return leaf;
    }

    fn createInternal(self: *PieceTable) !*nodes.Internal {
        const internal = try self.allocator.create(nodes.Internal);
        internal.* = .{};
        self.register(.{ .internal = internal });
        return internal;
    }

    fn register(self: *PieceTable, node: nodes.NodeRef) void {
        const transaction = &self.transaction.?;
        const ownership = node.ownership();
        ownership.owned = true;
        ownership.next = transaction.created;
        transaction.created = node;
    }

    /// Frees a committed subtree that the candidate no longer references, stopping at
    /// nodes it still reaches and at replaced nodes, which are freed separately.
    fn freeRemoved(self: *PieceTable, node: nodes.NodeRef) void {
        const ownership = node.ownership();
        if (ownership.reachable or ownership.replaced) return;
        if (node == .internal) {
            for (node.internal.children.items) |child| self.freeRemoved(child);
        }
        node.destroyShallow(self.allocator);
    }

    /// Plans replacing [start, end) with text without mutating the table.
    /// Boundaries before the edit cannot change, and UAX #29 segmentation restarted at a
    /// boundary reproduces the whole-text result. The plan therefore starts at the last
    /// surviving boundary and extends right until old and new segmentations share one.
    /// Scratch text is allocated and freed here. Rejects a range past the end with
    /// error.OutOfRange and start > end with error.InvalidRange.
    pub fn planReplace(self: *const PieceTable, start: u32, end: u32, text: []const u8) !Splice {
        try self.validateRange(start, end);

        var scratch: std.ArrayListUnmanaged(u8) = .empty;
        defer scratch.deinit(self.allocator);
        if (start > 0) try scratch.appendSlice(self.allocator, try self.graphemeAt(start - 1));
        const left_bytes = scratch.items.len;
        try scratch.appendSlice(self.allocator, text);

        var right = try self.graphemeCursor(end);
        var right_context: u32 = 0;
        var right_bytes: usize = 0;
        var left_aligned = true;
        var from: usize = 0;
        while (true) {
            const target = scratch.items.len;
            const lookahead: []const u8 = if (right.valid) try right.current() else "";
            try scratch.appendSlice(self.allocator, lookahead);
            if (right_context == 0 and left_bytes > 0) {
                const left = boundaryFrom(scratch.items, 0, left_bytes);
                left_aligned = left.found;
                from = left.last;
            }
            const probe = boundaryFrom(scratch.items, from, target);
            from = probe.last;
            if (probe.found) {
                scratch.shrinkRetainingCapacity(target);
                break;
            }
            right_context += 1;
            right_bytes += lookahead.len;
            _ = right.advance();
        }

        const left_context: u32 = if (left_aligned) 0 else 1;
        const region = scratch.items[if (left_aligned) left_bytes else 0..];
        const region_start = start - left_context;
        return .{
            .start = region_start,
            .old_end = end + right_context,
            .new_end = region_start + @as(u32, @intCast(segmentation.graphemeCount(region))),
            .left_context = left_context,
            .right_context = right_context,
            .left_context_bytes = if (left_aligned) 0 else @intCast(left_bytes),
            .right_context_bytes = @intCast(right_bytes),
        };
    }

    /// Applies a plan from planReplace to the candidate tree it was planned against, inside
    /// an active transaction. Rewritten context is copied with the text so every piece
    /// boundary stays a grapheme boundary. On error the candidate may be inconsistent; the
    /// caller must `abort`, which restores the committed tree and the add buffer.
    pub fn applySplice(self: *PieceTable, splice: Splice, text: []const u8) !void {
        std.debug.assert(self.transaction != null);
        const add_offset = self.add_buf.items.len;
        if (splice.isAligned()) {
            try self.add_buf.appendSlice(self.allocator, text);
        } else {
            const left = try self.getTextRange(splice.start, splice.requestedStart());
            defer self.allocator.free(left);
            const right = try self.getTextRange(splice.requestedEnd(), splice.old_end);
            defer self.allocator.free(right);
            try self.add_buf.appendSlice(self.allocator, left);
            try self.add_buf.appendSlice(self.allocator, text);
            try self.add_buf.appendSlice(self.allocator, right);
        }
        const pieces = try self.makePiecesChunked(
            .add,
            add_offset,
            self.add_buf.items.len - add_offset,
        );
        defer self.allocator.free(pieces);

        if (splice.start != splice.old_end) try self.deleteAligned(splice.start, splice.old_end);
        try self.insertPieces(splice.start, pieces);
    }

    fn insertPieces(self: *PieceTable, pos: u32, pieces: []const nodes.Piece) !void {
        var current_pos = pos;
        for (pieces) |piece| {
            const root = try self.writable(&self.root);
            if (try self.insertInto(root, current_pos, piece)) |overflow| {
                const new_root = try self.createInternal();
                try new_root.children.ensureTotalCapacity(self.allocator, 2);
                new_root.children.appendAssumeCapacity(overflow.left);
                new_root.children.appendAssumeCapacity(overflow.right);
                nodes.recomputeNode(.{ .internal = new_root });
                self.root = .{ .internal = new_root };
            }
            current_pos += piece.summary.graphemes;
        }
    }

    fn deleteAligned(self: *PieceTable, start: u32, end: u32) !void {
        const root = try self.writable(&self.root);
        _ = try self.deleteFrom(root, start, end);
        try self.normalizeRoot();
    }

    const SplitNode = struct {
        left: nodes.NodeRef,
        right: nodes.NodeRef,
    };

    fn deleteFrom(
        self: *PieceTable,
        node: nodes.NodeRef,
        start: u32,
        end: u32,
    ) PieceTableError!bool {
        return switch (node) {
            .leaf => |leaf| try self.deleteFromLeaf(leaf, start, end),
            .internal => |internal| try self.deleteFromInternal(internal, start, end),
        };
    }

    fn deleteFromLeaf(
        self: *PieceTable,
        node: *nodes.Leaf,
        start: u32,
        end: u32,
    ) PieceTableError!bool {
        var new_pieces: std.ArrayListUnmanaged(nodes.Piece) = .empty;
        errdefer new_pieces.deinit(self.allocator);

        var cursor: u32 = 0;
        for (node.pieces.items) |piece| {
            const piece_start = cursor;
            const piece_end = cursor + piece.summary.graphemes;
            cursor = piece_end;

            if (piece_end <= start or piece_start >= end) {
                try new_pieces.append(self.allocator, piece);
                continue;
            }

            const delete_start = @max(start, piece_start) - piece_start;
            const delete_end = @min(end, piece_end) - piece_start;

            const left_remainder = try self.splitPiece(piece, delete_start);
            if (left_remainder.left) |left| {
                try new_pieces.append(self.allocator, left);
            }
            if (left_remainder.right) |remainder| {
                const right_split = try self.splitPiece(remainder, delete_end - delete_start);
                if (right_split.right) |right| {
                    try new_pieces.append(self.allocator, right);
                }
            }
        }

        node.pieces.deinit(self.allocator);
        node.pieces = new_pieces;
        nodes.recomputeNode(.{ .leaf = node });
        return node.pieces.items.len == 0;
    }

    fn deleteFromInternal(
        self: *PieceTable,
        node: *nodes.Internal,
        start: u32,
        end: u32,
    ) PieceTableError!bool {
        var new_children: std.ArrayListUnmanaged(nodes.NodeRef) = .empty;
        errdefer new_children.deinit(self.allocator);

        // Removed children are not freed here: commit frees them, abort keeps them.
        var cursor: u32 = 0;
        for (node.children.items, 0..) |child, index| {
            const child_start = cursor;
            const child_end = cursor + child.summary().graphemes;
            cursor = child_end;

            if (child_end <= start or child_start >= end) {
                try new_children.append(self.allocator, child);
                continue;
            }
            if (start <= child_start and child_end <= end) continue;

            const target = try self.writable(&node.children.items[index]);
            const local_start = @max(start, child_start) - child_start;
            const local_end = @min(end, child_end) - child_start;
            if (try self.deleteFrom(target, local_start, local_end)) continue;
            try new_children.append(self.allocator, target);
        }

        node.children.deinit(self.allocator);
        node.children = new_children;
        // The node owns the list now; the errdefer above must not free it.
        new_children = .empty;
        try self.repairUnderfullChildren(node);
        nodes.recomputeNode(.{ .internal = node });
        return node.children.items.len == 0;
    }

    fn nodeLen(node: nodes.NodeRef) usize {
        return switch (node) {
            .leaf => |leaf| leaf.pieces.items.len,
            .internal => |internal| internal.children.items.len,
        };
    }

    fn nodeMinLen(node: nodes.NodeRef) usize {
        return switch (node) {
            .leaf => nodes.min_leaf_pieces,
            .internal => nodes.min_internal_fanout,
        };
    }

    fn nodeIsUnderfull(node: nodes.NodeRef) bool {
        return nodeLen(node) < nodeMinLen(node);
    }

    fn nodeCanLend(node: nodes.NodeRef) bool {
        return nodeLen(node) > nodeMinLen(node);
    }

    fn repairUnderfullChildren(self: *PieceTable, parent: *nodes.Internal) PieceTableError!void {
        var index: usize = 0;
        while (index < parent.children.items.len) {
            const child = parent.children.items[index];
            if (!nodeIsUnderfull(child)) {
                index += 1;
                continue;
            }

            if (index > 0 and nodeCanLend(parent.children.items[index - 1])) {
                try self.borrowFromLeftSibling(parent, index);
                index += 1;
                continue;
            }

            if (index + 1 < parent.children.items.len and nodeCanLend(parent.children.items[index + 1])) {
                try self.borrowFromRightSibling(parent, index);
                index += 1;
                continue;
            }

            if (index > 0) {
                try self.mergeWithLeftSibling(parent, index);
                continue;
            }

            if (index + 1 < parent.children.items.len) {
                try self.mergeWithRightSibling(parent, index);
                index += 1;
                continue;
            }

            index += 1;
        }
    }

    /// Moves the left sibling's last entry to the front of the child at `index`.
    /// Both siblings change, so both are made writable first.
    fn borrowFromLeftSibling(self: *PieceTable, parent: *nodes.Internal, index: usize) !void {
        const left = try self.writable(&parent.children.items[index - 1]);
        const right = try self.writable(&parent.children.items[index]);
        switch (left) {
            .leaf => |left_leaf| {
                try right.leaf.pieces.insert(self.allocator, 0, left_leaf.pieces.pop().?);
            },
            .internal => |left_internal| {
                try right.internal.children.insert(self.allocator, 0, left_internal.children.pop().?);
            },
        }
        nodes.recomputeNode(left);
        nodes.recomputeNode(right);
    }

    /// Moves the right sibling's first entry to the end of the child at `index`.
    fn borrowFromRightSibling(self: *PieceTable, parent: *nodes.Internal, index: usize) !void {
        const left = try self.writable(&parent.children.items[index]);
        const right = try self.writable(&parent.children.items[index + 1]);
        switch (right) {
            .leaf => |right_leaf| {
                const moved = right_leaf.pieces.orderedRemove(0);
                try left.leaf.pieces.append(self.allocator, moved);
            },
            .internal => |right_internal| {
                const moved = right_internal.children.orderedRemove(0);
                try left.internal.children.append(self.allocator, moved);
            },
        }
        nodes.recomputeNode(left);
        nodes.recomputeNode(right);
    }

    fn mergeWithLeftSibling(
        self: *PieceTable,
        parent: *nodes.Internal,
        index: usize,
    ) PieceTableError!void {
        const left = try self.writable(&parent.children.items[index - 1]);
        try self.mergeNodes(left, parent.children.items[index]);
        _ = parent.children.orderedRemove(index);
        nodes.recomputeNode(left);
    }

    fn mergeWithRightSibling(
        self: *PieceTable,
        parent: *nodes.Internal,
        index: usize,
    ) PieceTableError!void {
        const left = try self.writable(&parent.children.items[index]);
        try self.mergeNodes(left, parent.children.items[index + 1]);
        _ = parent.children.orderedRemove(index + 1);
        nodes.recomputeNode(left);
    }

    /// Appends `right`'s entries to the writable `left`. `right` is only read; once its
    /// parent drops it, commit frees it (or, if committed, frees what it no longer shares).
    fn mergeNodes(
        self: *PieceTable,
        left: nodes.NodeRef,
        right: nodes.NodeRef,
    ) PieceTableError!void {
        switch (left) {
            .leaf => |left_leaf| {
                try left_leaf.pieces.appendSlice(self.allocator, right.leaf.pieces.items);
            },
            .internal => |left_internal| {
                try left_internal.children.appendSlice(self.allocator, right.internal.children.items);
            },
        }
    }

    /// Collapses single-child roots. Dropped roots stay recorded for commit or abort.
    fn normalizeRoot(self: *PieceTable) PieceTableError!void {
        while (true) {
            switch (self.root) {
                .leaf => return,
                .internal => |internal| {
                    if (internal.children.items.len == 0) {
                        self.root = .{ .leaf = try self.createLeaf() };
                        return;
                    }
                    if (internal.children.items.len == 1) {
                        self.root = internal.children.items[0];
                        continue;
                    }
                    // A committed root is unchanged, so its summary is already correct.
                    if (internal.ownership.owned) nodes.recomputeNode(self.root);
                    return;
                },
            }
        }
    }

    pub fn validatePosition(self: *const PieceTable, pos: u32) Error!void {
        if (pos > self.root.summary().graphemes) return error.OutOfRange;
    }

    fn validateRange(self: *const PieceTable, start: u32, end: u32) Error!void {
        if (start > end) return error.InvalidRange;
        if (end > self.root.summary().graphemes) return error.OutOfRange;
    }

    fn makePiece(
        self: *const PieceTable,
        source: nodes.Source,
        offset: usize,
        len: usize,
    ) nodes.Piece {
        const text = self.bufferText(source)[offset .. offset + len];
        return .{
            .source = source,
            .offset = offset,
            .len = len,
            .summary = Summary.fromText(&self.seg, text),
        };
    }

    fn splitPiece(self: *const PieceTable, piece: nodes.Piece, grapheme_offset: u32) !SplitPiece {
        if (grapheme_offset == 0) return .{ .left = null, .right = piece };
        if (grapheme_offset >= piece.summary.graphemes) return .{ .left = piece, .right = null };

        const text = self.pieceText(piece);
        const split = try self.seg.splitAtGrapheme(text, grapheme_offset);
        return .{
            .left = self.makePiece(piece.source, piece.offset, split.left.len),
            .right = self.makePiece(piece.source, piece.offset + split.left.len, split.right.len),
        };
    }

    /// Splits a writable, overfull leaf in half. The leaf keeps the left half.
    fn splitLeaf(self: *PieceTable, node: *nodes.Leaf) !SplitNode {
        const mid = node.pieces.items.len / 2;
        const right = try self.createLeaf();
        try right.pieces.appendSlice(self.allocator, node.pieces.items[mid..]);
        node.pieces.shrinkRetainingCapacity(mid);
        nodes.recomputeNode(.{ .leaf = node });
        nodes.recomputeNode(.{ .leaf = right });
        return .{ .left = .{ .leaf = node }, .right = .{ .leaf = right } };
    }

    /// Splits a writable, overfull internal node in half. The node keeps the left half.
    fn splitInternal(self: *PieceTable, node: *nodes.Internal) !SplitNode {
        const mid = node.children.items.len / 2;
        const right = try self.createInternal();
        try right.children.appendSlice(self.allocator, node.children.items[mid..]);
        node.children.shrinkRetainingCapacity(mid);
        nodes.recomputeNode(.{ .internal = node });
        nodes.recomputeNode(.{ .internal = right });
        return .{ .left = .{ .internal = node }, .right = .{ .internal = right } };
    }

    fn positionAfterNewline(self: *const PieceTable, newline_number: u32) Error!u32 {
        if (newline_number == 0 or newline_number > self.root.summary().newlines) return error.OutOfRange;

        var node = self.root;
        var remaining = newline_number;
        var position: u32 = 0;

        while (true) {
            switch (node) {
                .internal => |internal| {
                    for (internal.children.items) |child| {
                        const child_newlines = child.summary().newlines;
                        if (remaining <= child_newlines) {
                            node = child;
                            break;
                        }
                        remaining -= child_newlines;
                        position += child.summary().graphemes;
                    }
                },
                .leaf => |leaf| {
                    for (leaf.pieces.items) |piece| {
                        if (remaining > piece.summary.newlines) {
                            remaining -= piece.summary.newlines;
                            position += piece.summary.graphemes;
                            continue;
                        }

                        var iter = self.seg.iterator(self.pieceText(piece));
                        while (iter.next()) |cluster| {
                            position += 1;
                            if (std.mem.eql(u8, cluster, "\n")) {
                                remaining -= 1;
                                if (remaining == 0) return position;
                            }
                        }
                    }
                    return self.graphemeCount();
                },
            }
        }
    }

    fn countNewlinesInPiecePrefix(
        self: *const PieceTable,
        piece: nodes.Piece,
        grapheme_count: u32,
    ) u32 {
        var count: u32 = 0;
        var seen: u32 = 0;
        var iter = self.seg.iterator(self.pieceText(piece));
        while (seen < grapheme_count) : (seen += 1) {
            const cluster = iter.next() orelse break;
            if (std.mem.eql(u8, cluster, "\n")) count += 1;
        }
        return count;
    }

    fn newlineCountBeforeNode(self: *const PieceTable, node: nodes.NodeRef, pos: u32) u32 {
        if (pos == 0) return 0;
        if (pos >= node.summary().graphemes) return node.summary().newlines;

        return switch (node) {
            .leaf => |leaf| blk: {
                var count: u32 = 0;
                var remaining = pos;
                for (leaf.pieces.items) |piece| {
                    if (remaining >= piece.summary.graphemes) {
                        count += piece.summary.newlines;
                        remaining -= piece.summary.graphemes;
                        continue;
                    }
                    break :blk count + self.countNewlinesInPiecePrefix(piece, remaining);
                }
                break :blk count;
            },
            .internal => |internal| blk: {
                var count: u32 = 0;
                var remaining = pos;
                for (internal.children.items) |child| {
                    const child_graphemes = child.summary().graphemes;
                    if (remaining >= child_graphemes) {
                        count += child.summary().newlines;
                        remaining -= child_graphemes;
                        continue;
                    }
                    break :blk count + self.newlineCountBeforeNode(child, remaining);
                }
                break :blk count;
            },
        };
    }

    pub fn patternClusters(self: *const PieceTable, pattern_text: []const u8) ![]const []const u8 {
        var clusters: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer clusters.deinit(self.allocator);

        var iter = self.seg.iterator(pattern_text);
        while (iter.next()) |cluster| {
            try clusters.append(self.allocator, cluster);
        }
        return clusters.toOwnedSlice(self.allocator);
    }

    fn collectText(self: *const PieceTable, node: nodes.NodeRef, out: *std.ArrayListUnmanaged(u8)) !void {
        switch (node) {
            .leaf => |leaf| {
                for (leaf.pieces.items) |piece| {
                    try out.appendSlice(self.allocator, self.pieceText(piece));
                }
            },
            .internal => |internal| {
                for (internal.children.items) |child| {
                    try self.collectText(child, out);
                }
            },
        }
    }

    fn collectTextRange(self: *const PieceTable, node: nodes.NodeRef, start: u32, end: u32, out: *std.ArrayListUnmanaged(u8)) !void {
        if (start == end) return;

        switch (node) {
            .leaf => |leaf| {
                var cursor: u32 = 0;
                for (leaf.pieces.items) |piece| {
                    const piece_start = cursor;
                    const piece_end = cursor + piece.summary.graphemes;
                    cursor = piece_end;

                    if (piece_end <= start) continue;
                    if (piece_start >= end) break;

                    const local_start = @max(start, piece_start) - piece_start;
                    const local_end = @min(end, piece_end) - piece_start;
                    const text = self.pieceText(piece);
                    const left_split = try self.seg.splitAtGrapheme(text, local_start);
                    const right_split = try self.seg.splitAtGrapheme(left_split.right, local_end - local_start);
                    try out.appendSlice(self.allocator, right_split.left);
                }
            },
            .internal => |internal| {
                var cursor: u32 = 0;
                for (internal.children.items) |child| {
                    const child_start = cursor;
                    const child_end = cursor + child.summary().graphemes;
                    cursor = child_end;

                    if (child_end <= start) continue;
                    if (child_start >= end) break;

                    try self.collectTextRange(child, @max(start, child_start) - child_start, @min(end, child_end) - child_start, out);
                }
            },
        }
    }

    pub fn pieceText(self: *const PieceTable, piece: nodes.Piece) []const u8 {
        return self.bufferText(piece.source)[piece.offset .. piece.offset + piece.len];
    }

    fn bufferText(self: *const PieceTable, source: nodes.Source) []const u8 {
        return switch (source) {
            .original => self.original_buf.items,
            .add => self.add_buf.items,
        };
    }

    fn makePiecesChunked(
        self: *const PieceTable,
        source: nodes.Source,
        buf_offset: usize,
        len: usize,
    ) ![]nodes.Piece {
        var result: std.ArrayListUnmanaged(nodes.Piece) = .empty;
        errdefer result.deinit(self.allocator);
        if (len == 0) return result.toOwnedSlice(self.allocator);

        const text = self.bufferText(source)[buf_offset .. buf_offset + len];
        var chunk_byte_start: usize = 0;
        var chunk_graphemes: u32 = 0;
        var byte_pos: usize = 0;

        var iter = self.seg.iterator(text);
        while (iter.next()) |cluster| {
            byte_pos += cluster.len;
            chunk_graphemes += 1;
            if (chunk_graphemes == nodes.piece_grapheme_chunk) {
                try result.append(self.allocator, self.makePiece(source, buf_offset + chunk_byte_start, byte_pos - chunk_byte_start));
                chunk_byte_start = byte_pos;
                chunk_graphemes = 0;
            }
        }
        if (chunk_graphemes > 0) {
            try result.append(self.allocator, self.makePiece(source, buf_offset + chunk_byte_start, len - chunk_byte_start));
        }
        return result.toOwnedSlice(self.allocator);
    }
};

const Boundary = struct {
    found: bool,
    last: usize,
};

/// Segments bytes from a known boundary and reports whether target is a boundary.
/// `last` is the greatest boundary at or before target, a valid restart point.
fn boundaryFrom(bytes: []const u8, from: usize, target: usize) Boundary {
    if (target == from or target == bytes.len) return .{ .found = true, .last = target };
    var iter = segmentation.graphemeIterator(bytes[from..]);
    var last = from;
    while (iter.inner.next()) |gc| {
        const offset = from + gc.offset;
        if (offset == target) return .{ .found = true, .last = offset };
        if (offset > target) break;
        last = offset;
    }
    return .{ .found = false, .last = last };
}

/// Marks every node the candidate reaches. Committed nodes are marked but not entered:
/// none of their descendants was written, so the whole subtree is shared.
fn markReachable(node: nodes.NodeRef) void {
    const ownership = node.ownership();
    ownership.reachable = true;
    if (!ownership.owned) return;
    if (node == .internal) {
        for (node.internal.children.items) |child| markReachable(child);
    }
}

/// Clears transaction bookkeeping from the published tree; it is all committed now.
fn settle(node: nodes.NodeRef) void {
    const ownership = node.ownership();
    const owned = ownership.owned;
    ownership.* = .{};
    if (!owned) return;
    if (node == .internal) {
        for (node.internal.children.items) |child| settle(child);
    }
}

fn freeNode(allocator: std.mem.Allocator, node: nodes.NodeRef) void {
    switch (node) {
        .leaf => |n| {
            n.pieces.deinit(allocator);
            allocator.destroy(n);
        },
        .internal => |n| {
            for (n.children.items) |child| freeNode(allocator, child);
            n.children.deinit(allocator);
            allocator.destroy(n);
        },
    }
}

fn buildTree(allocator: std.mem.Allocator, pieces: []const nodes.Piece) !nodes.NodeRef {
    if (pieces.len == 0) {
        const leaf = try allocator.create(nodes.Leaf);
        leaf.* = .{};
        return .{ .leaf = leaf };
    }

    var level: std.ArrayListUnmanaged(nodes.NodeRef) = .empty;
    errdefer {
        for (level.items) |n| freeNode(allocator, n);
        level.deinit(allocator);
    }

    var i: usize = 0;
    while (i < pieces.len) {
        const end = @min(i + nodes.max_leaf_pieces, pieces.len);
        const leaf = try allocator.create(nodes.Leaf);
        leaf.* = .{};
        errdefer freeNode(allocator, .{ .leaf = leaf });
        try leaf.pieces.appendSlice(allocator, pieces[i..end]);
        nodes.recomputeNode(.{ .leaf = leaf });
        try level.append(allocator, .{ .leaf = leaf });
        i = end;
    }

    while (level.items.len > 1) {
        var next_level: std.ArrayListUnmanaged(nodes.NodeRef) = .empty;
        // Until the swap below, `level` owns the children: free these nodes shallowly.
        errdefer {
            for (next_level.items) |n| n.destroyShallow(allocator);
            next_level.deinit(allocator);
        }
        var j: usize = 0;
        while (j < level.items.len) {
            const end = @min(j + nodes.max_internal_fanout, level.items.len);
            const node = try allocator.create(nodes.Internal);
            node.* = .{};
            errdefer (nodes.NodeRef{ .internal = node }).destroyShallow(allocator);
            try node.children.appendSlice(allocator, level.items[j..end]);
            nodes.recomputeNode(.{ .internal = node });
            try next_level.append(allocator, .{ .internal = node });
            j = end;
        }
        level.deinit(allocator);
        level = next_level;
    }

    const root = level.items[0];
    level.deinit(allocator);
    return root;
}
