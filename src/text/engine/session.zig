//! A session's owned interaction state: selections over its endpoint anchors, and
//! registers (SPEC §2.6).

const std = @import("std");
const anchors = @import("anchors.zig");
const events = @import("events.zig");

/// A selection over two endpoint slots, or a caret when both name one anchor. The
/// session owns both anchors. The active endpoint is Sticky and the fixed endpoint
/// Weak; a caret's anchor is Sticky (SPEC §2.6).
pub const Selection = struct {
    start: anchors.AnchorId,
    end: anchors.AnchorId,
    active: events.Edge,

    pub fn isCaret(self: Selection) bool {
        return self.start.value == self.end.value;
    }

    pub fn activeAnchor(self: Selection) anchors.AnchorId {
        return if (self.active == .start) self.start else self.end;
    }

    /// The anchor of the fixed endpoint, or null for a caret.
    pub fn fixedAnchor(self: Selection) ?anchors.AnchorId {
        if (self.isCaret()) return null;
        return if (self.active == .start) self.end else self.start;
    }
};

/// Owns its keys and string values.
pub const Registers = std.StringArrayHashMapUnmanaged(events.InteractionValue);

pub fn freeRegisters(allocator: std.mem.Allocator, registers: *Registers) void {
    var iter = registers.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.free(allocator);
    }
    registers.deinit(allocator);
    registers.* = undefined;
}

/// A deep copy; on error nothing is left allocated.
pub fn cloneRegisters(allocator: std.mem.Allocator, registers: Registers) !Registers {
    var copy: Registers = .empty;
    errdefer freeRegisters(allocator, &copy);
    try copy.ensureTotalCapacity(allocator, registers.count());
    var iter = registers.iterator();
    while (iter.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        const value = entry.value_ptr.dupe(allocator) catch |err| {
            allocator.free(key);
            return err;
        };
        copy.putAssumeCapacityNoClobber(key, value);
    }
    return copy;
}

/// Owned by the engine. `selections` is never empty.
pub const Session = struct {
    id: u32,
    revision: u32 = 0,
    selections: []Selection,
    registers: Registers = .empty,

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        allocator.free(self.selections);
        freeRegisters(allocator, &self.registers);
        self.* = undefined;
    }
};
