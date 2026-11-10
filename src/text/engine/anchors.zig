//! Stable document positions and their insertion/deletion liveness rules.

const std = @import("std");

pub const AnchorId = struct {
    value: u32,
};

pub const AnchorStickiness = enum {
    weak,
    sticky,
};

pub const AnchorStatus = enum {
    live,
    dead,
};

pub const RangeStatus = enum {
    live,
    collapsed,
    dead,
};

pub const Anchor = struct {
    id: AnchorId,
    position: u32,
    stickiness: AnchorStickiness,
    status: AnchorStatus = .live,
};

test "anchor defaults to live" {
    const anchor = Anchor{
        .id = .{ .value = 1 },
        .position = 7,
        .stickiness = .sticky,
    };

    try std.testing.expectEqual(AnchorStatus.live, anchor.status);
}
