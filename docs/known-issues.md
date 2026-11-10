# Known correctness and contract gaps

The v0.1 specification is authoritative but remains a draft. These implementation gaps are retained explicitly; structural cleanup must not silently turn them into different runtime behavior. A correction needs its own contract decision and regression tests. This is not a complete correctness audit.

## Allocation failure and transactions

`BufferEngine.initFromText` lacks cleanup after creating the engine if text initialization or path copying fails. `PieceTable.initFromText` destroys the old tree before allocating its replacement. Constructors and reinitialization need allocation-failure tests and defined cleanup/recovery before callers can rely on failure preserving a valid prior value.

`submit` validates before mutation but does not provide rollback for all allocation failures. Operations can edit text and rebase anchors before later allocations for events, history or interaction state fail. In particular, replacement deletes before insertion. This falls short of the draft atomicity contract; successful preflight alone does not establish transactional failure safety.

Undo/redo error recovery discards allocation failures while restoring history entries. Provider destruction also allocates a temporary identity set and discards insertion failures, risking repeated destruction of shared provider state under memory pressure. Tree rebalancing has `catch unreachable` on list operations without a documented local capacity proof; that capacity invariant needs verification. These error paths require correctness work, not replacement with different unchecked failure handling during a style pass.

## Interaction and provider revisions

`moveAnchor` checks only that an anchor exists. It accepts out-of-bounds positions and does not increment session interaction revisions. Higher-level interaction intents validate positions and advance revisions. The direct path remains observable and is characterized by a test; changing it requires deciding which pathway is authoritative.

`StaticTokenProvider.refresh` increments its local revision once, even if the document has advanced several revisions. It can report an available state at a different revision from the document. The provider borrows its input spans and never reparses or rebases them. A characterization test preserves visibility of the revision mismatch; it is not an endorsement of that contract.

## Borrowed results and evaluation

Provider callbacks use opaque engine/event pointers. Array ownership is defined for token, diagnostic and semantic-token queries, but nested strings and syntax/type/hover/symbol lifetimes depend on the provider. Tree-sitter syntax paths expire at refresh/destruction. Validation reports borrow their original intent; evaluation values do not own intent backing storage.

The native evaluation carrier meters view operations, not arbitrary callback execution. It is not a sandbox or a CPU-time bound. The evaluation search path also needs review: a match beyond the evaluation bounds returns null without freeing the owned match text.

## Persistence

Save copies the full document and writes synchronously. A supplied path replaces the stored path before the write succeeds; a failed save can therefore change the document path. Save is not an atomic filesystem replacement. Dirty state compares revision numbers rather than text identity, so undoing to identical text does not necessarily clear it.
