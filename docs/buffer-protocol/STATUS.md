# Litura implementation status

Descriptive, not normative. The [v0.1 draft specification](SPEC.md) is the protocol; this is what the Zig library implements. Costs and remaining defects are in [known issues](../known-issues.md).

## Implemented

- Text, anchors and summaries (§1): piece-table storage, Unicode 16.0 graphemes, line navigation, byte-exact search, bounded reads. Edits are grapheme-aligned splices.
- Sessions and interaction (§2.6): session-owned selections, `set_selections`, registers, `create_session` / `drop_session`. Public identities are issued only when the creating transition is published. Disposal is terminal for undo.
- Intents (§4, §6): mandatory `IntentId` and origins, guards, validation reports. Rebase policy `Reject`; sequencing `Synchronous`. Composite buffer/interaction payloads, `EditRef`, document-wide undo/redo. Payloads roll back atomically, including under allocator exhaustion.
- Blocks (§7): one owned block per committed request, gapless `sequence`, typed source and label, edit events with grapheme and byte/point splices and endpoint effects, interaction deltas, snapshots with `next_sequence`. Providers receive the block after publication and cannot change the engine. Delivery, retention and envelope identities are the host's.
- Views (§2): registration and available/stale/partial/unavailable state. Callback-backed views catch up only on `refreshView` with a host budget; queries never refresh (`error.ViewStale` / `error.ViewUnavailable`). Optional Tree-sitter `tokens` and `syntax` for Lua and Zig, or any `tree_sitter.Grammar`. Syntax queries give the smallest node enclosing a range and any node's immediate parent. Diagnostics, semantic tokens, type, hover and symbol have provider interfaces and no built-in providers.
- Evaluation (§5): native Zig callback, fuel charged for view operations.

## Incomplete

- Grouped intent modes and multi-buffer intents.
- Portable or sandboxed evaluation; fuel does not bound arbitrary callback work.
- Replay-capable blocks.

## Out of scope

v0.1 is single-client. Multi-client coordination belongs above the engine. The package is not a language server, Lua adapter, workbench or document host. Substrate is a separate private project.
