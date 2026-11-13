//! Stable document positions and their insertion/deletion liveness rules.

const std = @import("std");

pub const AnchorId = struct {
    value: u32,

    /// Whether the identifier belongs to the internal namespace (SPEC §1.4).
    pub fn isInternal(self: AnchorId) bool {
        return self.value & internal_bit != 0;
    }
};

/// Internal anchors are numbered from their own counter with this bit set, so an
/// internal identifier is never one a client could have been issued.
pub const internal_bit: u32 = 1 << 31;

pub const AnchorStickiness = enum {
    weak,
    sticky,
};

/// Whether a stored anchor has a position. Only stored anchors have a status;
/// a disposed handle has no storage (see HandleStatus).
pub const AnchorStatus = enum {
    live,
    dead,
};

/// What a client's handle refers to (SPEC §1.4). `dead` means only that the anchor
/// has no position; it does not promise that undo can still revive it. `disposed`
/// means its owner ended its lifetime, which is terminal. An identifier that was never
/// issued is not a handle state: queries reject it.
pub const HandleStatus = enum {
    live,
    dead,
    disposed,
};

pub const RangeStatus = enum {
    live,
    collapsed,
    dead,
};

/// Who owns an anchor. Client and endpoint anchors are public: queries, guards and
/// position references can name them. Internal anchors are invisible to clients, and
/// every public lookup treats their identifiers as unknown.
pub const AnchorKind = enum {
    /// Created by `createAnchor`; its creator disposes of it.
    client,
    /// A selection endpoint owned by a session; released by the session.
    endpoint,
    /// The internal target of a DeletionMeta; lives while undo history needs it.
    undo_target,
    /// Scoped to one transaction, such as an EditRef result; never recorded in history.
    transient,

    pub fn isPublic(self: AnchorKind) bool {
        return switch (self) {
            .client, .endpoint => true,
            .undo_target, .transient => false,
        };
    }
};

pub const Anchor = struct {
    id: AnchorId,
    position: u32,
    stickiness: AnchorStickiness,
    status: AnchorStatus = .live,
    kind: AnchorKind = .client,
    /// For undo targets only: one reference from the reachable undo entry that owns it,
    /// plus one per reachable deletion record naming it as dead. Released at zero.
    refs: u32 = 0,
    /// For endpoints only: set when the edit being prepared moved the anchor through a
    /// splice region or revived it, so the edit event must report it explicitly.
    touched: bool = false,
};

test "anchor defaults to a live client anchor" {
    const anchor = Anchor{
        .id = .{ .value = 1 },
        .position = 7,
        .stickiness = .sticky,
    };

    try std.testing.expectEqual(AnchorStatus.live, anchor.status);
    try std.testing.expect(anchor.kind.isPublic());
    try std.testing.expect(!anchor.id.isInternal());
}
