//! Compile-time contracts for caller-supplied read-only engine and cursor views.

fn valueType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| ptr.child,
        else => T,
    };
}

pub fn assertGraphemeCursorView(comptime T: type) void {
    const CursorT = valueType(T);
    comptime {
        if (!@hasField(CursorT, "valid")) @compileError("GraphemeCursorView requires field 'valid'");
        if (!@hasField(CursorT, "position")) @compileError("GraphemeCursorView requires field 'position'");
        if (!@hasDecl(CursorT, "current")) @compileError("GraphemeCursorView requires method 'current'");
        if (!@hasDecl(CursorT, "advance")) @compileError("GraphemeCursorView requires method 'advance'");
        if (!@hasDecl(CursorT, "retreat")) @compileError("GraphemeCursorView requires method 'retreat'");
    }
}

pub fn assertEngineView(comptime T: type) void {
    const EngineT = valueType(T);
    comptime {
        if (!@hasDecl(EngineT, "queryAnchor")) @compileError("EngineView requires method 'queryAnchor'");
        if (!@hasDecl(EngineT, "queryPosition")) @compileError("EngineView requires method 'queryPosition'");
        if (!@hasDecl(EngineT, "graphemeCount")) @compileError("EngineView requires method 'graphemeCount'");
        if (!@hasDecl(EngineT, "graphemeCursor")) @compileError("EngineView requires method 'graphemeCursor'");
        if (!@hasDecl(EngineT, "getTextRange")) @compileError("EngineView requires method 'getTextRange'");
        if (!@hasDecl(EngineT, "findNext")) @compileError("EngineView requires method 'findNext'");
    }
}

test "engine view shape assertions accept a matching type" {
    const Cursor = struct {
        valid: bool,
        position: u32,

        pub fn current(self: *const @This()) ![]const u8 {
            _ = self;
            return "x";
        }

        pub fn advance(self: *@This()) bool {
            _ = self;
            return false;
        }

        pub fn retreat(self: *@This()) bool {
            _ = self;
            return false;
        }
    };

    const Engine = struct {
        pub fn queryAnchor(self: *const @This(), anchor_id: u32) !void {
            _ = self;
            _ = anchor_id;
        }

        pub fn queryPosition(self: *const @This(), pos: u32) !void {
            _ = self;
            _ = pos;
        }

        pub fn graphemeCount(self: *const @This()) u32 {
            _ = self;
            return 0;
        }

        pub fn graphemeCursor(self: *const @This(), pos: u32) !Cursor {
            _ = self;
            _ = pos;
            return .{ .valid = false, .position = 0 };
        }

        pub fn getTextRange(self: *const @This(), start: u32, end: u32) ![]u8 {
            _ = self;
            _ = start;
            _ = end;
            return error.Unimplemented;
        }

        pub fn findNext(self: *const @This(), query: []const u8, start: u32) !?u32 {
            _ = self;
            _ = query;
            _ = start;
            return null;
        }
    };

    assertGraphemeCursorView(Cursor);
    assertEngineView(*const Engine);
}
