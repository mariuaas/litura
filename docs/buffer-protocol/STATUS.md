# Litura implementation status

This describes the standalone Zig library against the [v0.1 draft specification](SPEC.md). It is descriptive, not normative, and does not claim complete protocol conformance. Package setup and public namespaces are covered in the [usage guide](../guide.md).

## Implemented

- Piece-table text storage, Unicode grapheme segmentation, line navigation, byte-exact search, summaries and bounded region reads.
- Sticky and weak anchors, revision tracking, sessions, cursors and selection marks.
- Native mutation intents, revision-origin checks, guards and validation reports.
- Composite buffer/interaction submission, document-wide undo/redo and edit events.
- Derived-view registration, capabilities and available/stale/partial/unavailable state reporting.
- Native callback evaluation with bounded document access and fuel charged for view operations.
- Optional Tree-sitter tokens and syntax for Lua, Zig and Fennel, including revision-scoped syntax references.

Diagnostics, semantic tokens, type information, hover and symbol queries have provider interfaces. The package does not supply a language server or built-in providers for those services. Capability reporting distinguishes registered providers from absent ones.

## Incomplete and outside scope

Allocation-failure cleanup and transactional rollback are incomplete, including confirmed constructor leaks. Direct anchor movement and the static token provider have revision-coherence gaps. These and other ownership/persistence concerns are listed in [known issues](../known-issues.md); the library is experimental, not hardened.

The evaluation carrier is a native Zig callback. Fuel does not bound arbitrary callback work, and there is no portable or sandboxed program representation. Grouped intent modes and multi-buffer intents are not implemented.

The library has no Lua adapter, graphical workbench, application loop or document-host service. Multi-client coordination and conflict resolution belong above the engine and remain outside the v0.1 protocol scope. Substrate is a separate private project; its editor commands and scripting APIs are not part of this package.
