//! Public behavioral suite plus module-local unit tests.
const litura = @import("litura");
comptime {
    _ = @import("document_test.zig");
    _ = @import("grapheme_boundary_test.zig");
    _ = @import("segmentation_locality_test.zig");
    _ = @import("transaction_test.zig");
    _ = @import("allocation_failure_test.zig");
    _ = @import("tree_transaction_test.zig");
    _ = @import("provider_notification_test.zig");
    _ = @import("evaluation_test.zig");
    _ = @import("providers_test.zig");
    _ = @import("piece_table_test.zig");
    _ = @import("selection_test.zig");
    _ = @import("spans_test.zig");
    _ = @import("contracts_test.zig");
    _ = litura.engine;
    _ = litura.anchors;
    _ = litura.queries;
    _ = litura.views;
    _ = litura.summaries;
    _ = litura.segmentation;
    _ = litura.engine_view;
    if (litura.tree_sitter_enabled) _ = @import("tree_sitter_test.zig");
}
