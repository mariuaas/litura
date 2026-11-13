# Litura implementation status

This describes the standalone Zig library against the [v0.1 draft specification](SPEC.md). It is descriptive, not normative, and does not claim complete protocol conformance. Package setup and public namespaces are covered in the [usage guide](../guide.md).

## Implemented

- Piece-table text storage, Unicode 16.0 grapheme segmentation, line navigation, byte-exact search, summaries and bounded region reads. Edits are realized as grapheme-aligned splices, checked against Unicode's conformance data.
- Sticky and weak anchors with live, dead, disposed and never-issued handle states. Public identities are issued only when the transition that creates them is published; internal anchors are invisible and reclaimed when no history needs them. Disposal is terminal for undo.
- Sessions that own their selections: `set_selections` with kept, moved and new endpoints resolved simultaneously, role-based endpoint stickiness, registers, and session creation and teardown as intrinsic requests.
- Native mutation intents, revision-origin checks, guards and validation reports. Litura declares the `Reject` rebase policy: an intent with stale coordinates is rejected, never rebased. It declares `Synchronous` sequencing: each submission is applied when made, and intents carry no priority. Every intent carries the document revision, and every interaction mutation the interaction revision, it was computed against.
- Composite buffer/interaction submission and document-wide undo/redo. Payloads are validated exactly and roll back atomically on rejection or allocation failure, including under allocator exhaustion; composite interactions can refer to buffer-operation results (`EditRef`).
- Canonical blocks (SPEC §7): one owned block per committed intent or session request, with a gapless per-instance sequence, mandatory intent identities, typed sources and labels; edit events with realized splices and explicit session endpoint effects; interaction events with selection and register deltas; owned rejection reports; snapshots with `next_sequence`. Providers receive each complete block after publication and cannot change engine state from it. Delivery, retention and the envelope's buffer and instance identities are left to the host, as are replay-capable blocks.
- Derived-view registration, capabilities and available/stale/partial/unavailable state reporting.
- Native callback evaluation with bounded document access and fuel charged for view operations.
- Optional Tree-sitter tokens and syntax for Lua, Zig and Fennel, including revision-scoped syntax references.

Diagnostics, semantic tokens, type information, hover and symbol queries have provider interfaces. The package does not supply a language server or built-in providers for those services. Capability reporting distinguishes registered providers from absent ones.

## Incomplete and outside scope

Costs, ownership and persistence concerns are listed in [known issues](../known-issues.md); the library is experimental, not hardened.

The evaluation carrier is a native Zig callback. Fuel does not bound arbitrary callback work, and there is no portable or sandboxed program representation. Grouped intent modes and multi-buffer intents are not implemented.

The library has no Lua adapter, graphical workbench, application loop or document-host service. Multi-client coordination and conflict resolution belong above the engine and remain outside the v0.1 protocol scope. Substrate is a separate private project; its editor commands and scripting APIs are not part of this package.
