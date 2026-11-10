//! Module-local tests of pure functions and private implementation helpers.
const options = @import("build_options");
comptime {
    _ = @import("text/engine/anchors.zig");
    _ = @import("text/engine/queries.zig");
    _ = @import("text/engine/views.zig");
    _ = @import("text/engine/engine_view.zig");
    _ = @import("text/engine/summaries.zig");
    _ = @import("text/engine/text_segmentation.zig");
    _ = @import("text/engine/buffer_engine.zig");
    _ = @import("text/engine/buffer_validation.zig");
    if (options.tree_sitter) _ = @import("text/engine/providers/tree_sitter_tokens.zig");
}
