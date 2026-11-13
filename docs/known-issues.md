# Known correctness and contract gaps

The v0.1 specification is authoritative but remains a draft. These implementation gaps are retained explicitly; structural cleanup must not silently turn them into different runtime behavior. A correction needs its own contract decision and regression tests. This is not a complete correctness audit.

## Allocation failure and transactions

Buffer operations are applied provisionally and committed only after the whole payload, and for composites its interaction mutations, validate against the realized text. The piece table runs each payload as a transaction: committed tree nodes are copied on first write and never written, so rollback discards the candidate tree and restores the anchor snapshot without allocating, even under persistent allocator exhaustion. Interaction mutations and session creation are prepared in an overlay with provisional identities. Everything that can fail (the history slot, anchor and session capacity, undo's resurrection, the owned block) happens before publication, and publication, abandonment and provider notification do not allocate. Injection tests in `tests/allocation_failure_test.zig` and `tests/transaction_test.zig` cover transient and persistent failures, including node splits, merges, undo/redo, interaction-only and composite transitions with new endpoints, and session creation; the state comparator includes the identity boundaries and the sequence. `PieceTable.initFromText` builds a replacement tree before releasing the current one. The design is recorded in [the atomicity study](development/piece-tree-atomicity-study.md).

## Differences from the specification

Every intent and session creation states its document origin, and every interaction mutation its interaction origin; the types have no default, so no request obtains head-relative semantics by omission. Litura carries the interaction origin on each interaction mutation rather than once per intent, which allows a composite to change several sessions; for one session the two are equivalent.

The points where SPEC §4.2 and Litura once differed are settled in the specification: undo and redo carry no session in v0.1, `priority` applies only to engines that report `Queued` sequencing (Litura reports `Synchronous`), and intrinsic requests fail with typed errors (`BufferEngine.RequestError`), not validation reports (§2.6.3).

zg 0.16.2's `Graphemes.Iterator` sums cluster length in a `u8`, so a grapheme longer than 255 bytes panics in safe builds and is mismeasured otherwise. `text_segmentation.Iterator` drives zg's `graphemeBreak` with a full-width length instead; remove it once upstream is fixed.

## Costs

Each buffer operation rebases every anchor in the document, and each buffer transaction snapshots the anchor map for rollback, so a transition costs time proportional to its operations times the anchors held. Composites that use edit references add two transaction-scoped anchors per buffer operation. `set_selections` checks endpoint ownership with a linear scan per endpoint, which is quadratic in a session's selection count. `zig build measure` reports these costs; with a thousand carets, typing one character at each takes milliseconds per submission.

Public dead anchors whose resurrection path was discarded stay in storage until their owner disposes of them, by design (SPEC §2.5.6). A client or session that never releases them keeps them.

## Borrowed results and evaluation

Provider callbacks use opaque engine and block pointers. Array ownership is defined for token, diagnostic and semantic-token queries, but nested strings and syntax/type/hover/symbol lifetimes depend on the provider. Tree-sitter syntax paths expire at refresh/destruction. Evaluation values do not own intent backing storage. `queryRegister` returns a value borrowed until the session next changes.

The native evaluation carrier meters view operations, not arbitrary callback execution. It is not a sandbox or a CPU-time bound.

`queryCapabilities` returns its supported-view list in engine-owned scratch storage, so the result is valid only until the next call.

## Persistence

Save copies the full document and writes synchronously. Save is not an atomic filesystem replacement: a failed write can leave the target file partly written, although the stored path and saved revision change only after the write succeeds. Dirty state compares revision numbers rather than text identity, so undoing to identical text does not necessarily clear it.
