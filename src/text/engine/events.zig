//! Canonical blocks: the owned, ordered record of every transition a buffer instance
//! publishes (SPEC §7), and the snapshot an observer starts from.

const std = @import("std");
const anchors = @import("anchors.zig");

/// Opaque client-supplied identity of an intent or lifecycle request. The engine echoes
/// it in the block or report and never interprets, deduplicates or checks it, so
/// supplying one correlates a result; it does not promise exactly-once execution.
pub const IntentId = struct {
    value: u128,

    /// A random identity, for callers that need correlation but have no scheme of
    /// their own.
    pub fn random(io: std.Io) IntentId {
        var bytes: [16]u8 = undefined;
        io.random(&bytes);
        return .{ .value = std.mem.readInt(u128, &bytes, .little) };
    }
};

/// Who submitted a transition (SPEC §4.2, §7). Requests borrow the extension name;
/// blocks own a copy.
pub const Source = union(enum) {
    user_input,
    extension: []const u8,

    pub fn dupe(self: Source, allocator: std.mem.Allocator) !Source {
        return switch (self) {
            .user_input => .user_input,
            .extension => |name| .{ .extension = try allocator.dupe(u8, name) },
        };
    }

    pub fn free(self: Source, allocator: std.mem.Allocator) void {
        switch (self) {
            .user_input => {},
            .extension => |name| allocator.free(name),
        }
    }
};

/// A register value (SPEC §2.6). Requests borrow string contents; sessions, blocks and
/// snapshots own copies.
pub const InteractionValue = union(enum) {
    string: []const u8,
    int: i64,
    boolean: bool,

    pub fn dupe(self: InteractionValue, allocator: std.mem.Allocator) !InteractionValue {
        return switch (self) {
            .string => |text| .{ .string = try allocator.dupe(u8, text) },
            .int, .boolean => self,
        };
    }

    pub fn free(self: InteractionValue, allocator: std.mem.Allocator) void {
        switch (self) {
            .string => |text| allocator.free(text),
            .int, .boolean => {},
        }
    }

    pub fn eql(a: InteractionValue, b: InteractionValue) bool {
        return switch (a) {
            .string => |text| b == .string and std.mem.eql(u8, text, b.string),
            .int => |value| b == .int and value == b.int,
            .boolean => |value| b == .boolean and value == b.boolean,
        };
    }
};

/// Which edge of a selection, or of a buffer operation's inserted text.
pub const Edge = enum { start, end };

/// The kinds of buffer operation in one edit; `mixed` when they differ.
pub const EditClass = enum { insert, delete, replace, mixed };

/// One buffer operation's realized splice (SPEC §1.4). `start` and `old_end` are
/// positions in the text just before the operation; `new_end` is a position in the
/// text just after it. Positions before `start` are unchanged by the splice, positions
/// after `old_end` shift by `new_end - old_end`, and positions in `[start, old_end]`
/// are not described by the splice at all.
pub const RealizedSplice = struct {
    start: u32,
    old_end: u32,
    new_end: u32,
};

/// The explicit effect of an edit on one session endpoint. `old` is the endpoint at
/// the edit's old revision and `new` at its new revision; null means dead.
pub const EndpointEffect = struct {
    session: u32,
    anchor: anchors.AnchorId,
    old: ?u32,
    new: ?u32,
};

/// A document transition (SPEC §7). Owns its slices.
///
/// An observer that knows every session endpoint at `old_revision` reconstructs them
/// at `new_revision` without the text: each endpoint listed in `endpoint_effects`
/// takes its `new` value, and every other endpoint keeps its liveness and has its
/// position carried through the `splices` in order by their shift rule. An endpoint
/// is listed when it lay within the closed region `[start, old_end]` of some splice as
/// that splice was applied, or when the edit revived it. Endpoint effects are passive:
/// they advance no interaction revision.
pub const EditEvent = struct {
    old_revision: u32,
    new_revision: u32,
    edit_class: EditClass,
    splices: []const RealizedSplice,
    endpoint_effects: []const EndpointEffect,

    pub fn deinit(self: *EditEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.splices);
        allocator.free(self.endpoint_effects);
        self.* = undefined;
    }
};

/// A selection endpoint's identity and, when live, its position.
pub const EndpointValue = struct {
    anchor: anchors.AnchorId,
    position: ?u32,
};

/// A selection as a value: its endpoint slots and which one is active. A caret has the
/// same anchor in both slots. Slots are not ordered by position.
pub const SelectionValue = struct {
    start: EndpointValue,
    end: EndpointValue,
    active: Edge,

    pub fn isCaret(self: SelectionValue) bool {
        return self.start.anchor.value == self.end.anchor.value;
    }
};

pub const SelectionChange = struct {
    old: []const SelectionValue,
    new: []const SelectionValue,
};

/// One register's change; null means absent. Owns key and string values.
pub const RegisterChange = struct {
    key: []const u8,
    old: ?InteractionValue,
    new: ?InteractionValue,

    fn deinit(self: *RegisterChange, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        if (self.old) |value| value.free(allocator);
        if (self.new) |value| value.free(allocator);
        self.* = undefined;
    }
};

/// The net explicit change a transition made to one session (SPEC §2.6.2), over all
/// of its interaction mutations: `old` is the state after the edit's passive effects,
/// `new` the final state. Each mutation advances the interaction revision once, so the
/// revisions can differ by more than one. Positions are at `document_revision`.
/// `selections` is null and `registers` empty when the session ends as it started.
/// Owns its data.
pub const InteractionEvent = struct {
    session: u32,
    document_revision: u32,
    old_revision: u32,
    new_revision: u32,
    selections: ?SelectionChange,
    registers: []RegisterChange,

    pub fn deinit(self: *InteractionEvent, allocator: std.mem.Allocator) void {
        if (self.selections) |change| {
            allocator.free(change.old);
            allocator.free(change.new);
        }
        for (self.registers) |*change| change.deinit(allocator);
        allocator.free(self.registers);
        self.* = undefined;
    }
};

/// One committed intent: its edit, if it changed the document, then one interaction
/// event per session it changed, in order of first change.
pub const Transition = struct {
    sequence: u64,
    intent: IntentId,
    source: Source,
    label: ?[]const u8,
    edit: ?EditEvent,
    interactions: []InteractionEvent,

    pub fn deinit(self: *Transition, allocator: std.mem.Allocator) void {
        self.source.free(allocator);
        if (self.label) |label| allocator.free(label);
        if (self.edit) |*edit| edit.deinit(allocator);
        for (self.interactions) |*event| event.deinit(allocator);
        allocator.free(self.interactions);
        self.* = undefined;
    }
};

pub const SessionCreated = struct {
    session: u32,
    document_revision: u32,
    selections: []const SelectionValue,
};

/// The session's endpoints and registers were released with it.
pub const SessionDropped = struct {
    session: u32,
    interaction_revision: u32,
};

pub const LifecycleChange = union(enum) {
    session_created: SessionCreated,
    session_dropped: SessionDropped,
};

/// One intrinsic session request. It takes a sequence number but advances no document
/// or interaction revision.
pub const Lifecycle = struct {
    sequence: u64,
    request: IntentId,
    change: LifecycleChange,

    pub fn deinit(self: *Lifecycle, allocator: std.mem.Allocator) void {
        switch (self.change) {
            .session_created => |created| allocator.free(created.selections),
            .session_dropped => {},
        }
        self.* = undefined;
    }
};

/// One published transition of a buffer instance. Sequence numbers are gapless per
/// instance, starting at zero; rejections consume none. A delivery envelope adds the
/// buffer and instance identities, which the host stamps (SPEC §7). Owned through the
/// engine allocator; providers receive it borrowed. A shallow copy shares ownership:
/// call deinit on exactly one copy.
pub const Block = union(enum) {
    transition: Transition,
    lifecycle: Lifecycle,

    pub fn sequence(self: Block) u64 {
        return switch (self) {
            .transition => |transition| transition.sequence,
            .lifecycle => |lifecycle| lifecycle.sequence,
        };
    }

    pub fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .transition => |*transition| transition.deinit(allocator),
            .lifecycle => |*lifecycle| lifecycle.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const RegisterEntry = struct {
    key: []const u8,
    value: InteractionValue,
};

pub const SessionSnapshot = struct {
    id: u32,
    interaction_revision: u32,
    selections: []const SelectionValue,
    registers: []const RegisterEntry,
};

/// The state the stream explains, at one point in it. `next_sequence` is the first
/// block the snapshot does not reflect: an observer resumes with that block. Sessions
/// are ordered by identifier and positions are at `document_revision`. Owns its data
/// through the allocator passed to `BufferEngine.snapshot`; free it with the same one.
pub const Snapshot = struct {
    next_sequence: u64,
    document_revision: u32,
    sessions: []SessionSnapshot,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        for (self.sessions) |session| {
            allocator.free(session.selections);
            for (session.registers) |entry| {
                allocator.free(entry.key);
                entry.value.free(allocator);
            }
            allocator.free(session.registers);
        }
        allocator.free(self.sessions);
        self.* = undefined;
    }
};
