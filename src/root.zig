//! Causal document editing, storage, evaluation and optional syntax providers.
const options = @import("build_options");

pub const engine = @import("text/engine/buffer_engine.zig");
pub const BufferEngine = engine.BufferEngine;
pub const types = @import("text/engine/buffer_types.zig");
pub const events = @import("text/engine/events.zig");
pub const anchors = @import("text/engine/anchors.zig");
pub const queries = @import("text/engine/queries.zig");
pub const views = @import("text/engine/views.zig");
pub const piece_table = @import("text/engine/piece_table.zig");
pub const selection = @import("text/engine/selection.zig");
pub const spans = @import("text/engine/spans.zig");
pub const evaluation = @import("text/engine/buffer_eval.zig");
pub const tree_sitter_enabled = options.tree_sitter;
pub const tree_sitter = if (tree_sitter_enabled)
    @import("text/engine/providers/tree_sitter_tokens.zig")
else
    void;
pub const summaries = @import("text/engine/summaries.zig");
pub const segmentation = @import("text/engine/text_segmentation.zig");
pub const engine_view = @import("text/engine/engine_view.zig");
