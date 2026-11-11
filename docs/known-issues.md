# Known correctness and contract gaps

The v0.1 specification is authoritative but remains a draft. These implementation gaps are retained explicitly; structural cleanup must not silently turn them into different runtime behavior. A correction needs its own contract decision and regression tests. This is not a complete correctness audit.

## Allocation failure and transactions

`BufferEngine.initFromText` lacks cleanup after creating the engine if text initialization or path copying fails. `PieceTable.initFromText` destroys the old tree before allocating its replacement. Constructors and reinitialization need allocation-failure tests and defined cleanup/recovery before callers can rely on failure preserving a valid prior value.

Buffer operations are applied provisionally and committed only after the whole payload, and for composites its interaction positions, validate against the realized text. Rejections roll back through the recorded inverses and an anchor snapshot. Everything that can fail after the commit (the history slot, the provider notification set, anchors for marks) is reserved before it, and transient allocation failures anywhere in a composite are covered by an injection test. Allocation failure is still not fully transactional:

- `PieceTable.applySplice` prepares the add buffer and pieces before removing the old range, but inserting pieces into the tree allocates afterwards. A failure there loses the old range. Tree insertion needs to reserve node capacity, including splits, before it mutates; the skipped undo/redo injection test in `tests/transaction_test.zig` checks that fix.
- Rollback replays inverses through the piece table, which allocates. Under persistent exhaustion it logs and leaves the document inconsistent.

An intent without a document origin is treated as computed at head. Litura therefore checks position-bearing interaction requests against their document origin only when one is supplied.

Undo/redo error recovery discards allocation failures while restoring history entries. Provider destruction also allocates a temporary identity set and discards insertion failures, risking repeated destruction of shared provider state under memory pressure. Tree rebalancing has `catch unreachable` on list operations without a documented local capacity proof; that capacity invariant needs verification. These error paths require correctness work, not replacement with different unchecked failure handling during a style pass.

zg 0.16.2's `Graphemes.Iterator` sums cluster length in a `u8`, so a grapheme longer than 255 bytes panics in safe builds and is mismeasured otherwise. `text_segmentation.Iterator` drives zg's `graphemeBreak` with a full-width length instead; remove it once upstream is fixed.

## Interaction and provider revisions

`moveAnchor` checks only that an anchor exists. It accepts out-of-bounds positions and does not increment session interaction revisions, although moving a session cursor explicitly is an interaction mutation (SPEC §2.6). Higher-level interaction intents validate positions and advance revisions. The direct path remains observable and is characterized by a test; changing it requires deciding which pathway is authoritative.

`StaticTokenProvider.refresh` increments its local revision once, even if the document has advanced several revisions. It can report an available state at a different revision from the document. The provider borrows its input spans and never reparses or rebases them. A characterization test preserves visibility of the revision mismatch; it is not an endorsement of that contract.

## Borrowed results and evaluation

Provider callbacks use opaque engine/event pointers. Array ownership is defined for token, diagnostic and semantic-token queries, but nested strings and syntax/type/hover/symbol lifetimes depend on the provider. Tree-sitter syntax paths expire at refresh/destruction. Validation reports borrow their original intent; evaluation values do not own intent backing storage.

The native evaluation carrier meters view operations, not arbitrary callback execution. It is not a sandbox or a CPU-time bound. The evaluation search path also needs review: a match beyond the evaluation bounds returns null without freeing the owned match text.

## Persistence

Save copies the full document and writes synchronously. A supplied path replaces the stored path before the write succeeds; a failed save can therefore change the document path. Save is not an atomic filesystem replacement. Dirty state compares revision numbers rather than text identity, so undoing to identical text does not necessarily clear it.
