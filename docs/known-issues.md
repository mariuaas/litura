# Known correctness and contract gaps

The v0.1 specification is authoritative but remains a draft. These implementation gaps are retained explicitly; structural cleanup must not silently turn them into different runtime behavior. A correction needs its own contract decision and regression tests. This is not a complete correctness audit.

## Allocation failure and transactions

Buffer operations are applied provisionally and committed only after the whole payload, and for composites its interaction positions, validate against the realized text. The piece table runs each payload as a transaction: committed tree nodes are copied on first write and never written, so rollback discards the candidate tree and restores the anchor snapshot without allocating, even under persistent allocator exhaustion. Everything that can fail after the commit (the history slot, the provider notification set, anchors for marks, undo's anchor resurrection) happens before it. Injection tests in `tests/allocation_failure_test.zig` and `tests/transaction_test.zig` cover transient and persistent failures, including node splits, merges and undo/redo. `PieceTable.initFromText` builds a replacement tree before releasing the current one. The design is recorded in [the atomicity study](development/piece-tree-atomicity-study.md).

`BufferEngine.initFromText` still lacks cleanup after creating the engine if text initialization or path copying fails, so a failing constructor leaks the partly built engine.

An intent without a document origin is treated as computed at head. Litura therefore checks position-bearing interaction requests against their document origin only when one is supplied.

Provider destruction allocates a temporary identity set and discards insertion failures, risking repeated destruction of shared provider state under memory pressure. This error path needs correctness work, not replacement with different unchecked failure handling during a style pass.

zg 0.16.2's `Graphemes.Iterator` sums cluster length in a `u8`, so a grapheme longer than 255 bytes panics in safe builds and is mismeasured otherwise. `text_segmentation.Iterator` drives zg's `graphemeBreak` with a full-width length instead; remove it once upstream is fixed.

## Interaction and provider revisions

`moveAnchor` checks only that an anchor exists. It accepts out-of-bounds positions and does not increment session interaction revisions, although moving a session cursor explicitly is an interaction mutation (SPEC §2.6). Higher-level interaction intents validate positions and advance revisions. The direct path remains observable and is characterized by a test; changing it requires deciding which pathway is authoritative.

`StaticTokenProvider.refresh` increments its local revision once, even if the document has advanced several revisions. It can report an available state at a different revision from the document. The provider borrows its input spans and never reparses or rebases them. A characterization test preserves visibility of the revision mismatch; it is not an endorsement of that contract.

## Borrowed results and evaluation

Provider callbacks use opaque engine/event pointers. Array ownership is defined for token, diagnostic and semantic-token queries, but nested strings and syntax/type/hover/symbol lifetimes depend on the provider. Tree-sitter syntax paths expire at refresh/destruction. Validation reports borrow their original intent; evaluation values do not own intent backing storage.

The native evaluation carrier meters view operations, not arbitrary callback execution. It is not a sandbox or a CPU-time bound. The evaluation search path also needs review: a match beyond the evaluation bounds returns null without freeing the owned match text.

## Persistence

Save copies the full document and writes synchronously. A supplied path replaces the stored path before the write succeeds; a failed save can therefore change the document path. Save is not an atomic filesystem replacement. Dirty state compares revision numbers rather than text identity, so undoing to identical text does not necessarily clear it.
