# Piece-tree transaction atomicity: design study

**Status:** option B implemented; see [Outcome](#outcome). Sections 1 to 7 are the
original investigation, kept as written apart from the fuller treatment of option A.
**Baseline:** commit `4864521` plus uncommitted rebase-policy work, which does not
touch the piece table.

## The problem

A Litura payload is applied provisionally and committed only after it validates
(SPEC §4.1). If anything fails before commit, `BufferEngine.rollbackPending`
restores the previous state. It restores anchors by swapping back a snapshot of
the anchor map, which cannot fail. It restores text by *replaying inverse
operations through the piece table*, which can.

That asymmetry is the whole problem. Rollback is supposed to be the safe path,
but its text half is just another sequence of edits, and edits allocate. Under
allocator exhaustion, the operation that is meant to undo a failure can itself
fail, and `rollbackPending` can only log it. The skipped undo/redo injection test
in `tests/transaction_test.zig` is the visible symptom; the question below is
what makes the commit genuinely infallible once preparation has succeeded.

The guiding question was: *what is the smallest maintainable change that makes
Litura's mutation commit genuinely infallible after preparation, including
under allocator exhaustion?* The short answer is transaction-scoped
copy-on-write in the piece tree: never mutate a committed node during a
transaction, publish by swapping the root, and abort by discarding what the
transaction created. The rest of this note explains why pre-reservation cannot
get there, and what the copy-on-write change actually involves.

## 1. Audit of the current mutation path (established facts)

### Ownership

The piece table owns a single tree of `Leaf` and `Internal` nodes
(`pt_nodes.zig`). Each node owns one `ArrayListUnmanaged`: pieces for a leaf,
child `NodeRef`s for an internal node, plus a cached `Summary`. Nodes are
individually heap-allocated with `allocator.create`. Every node has exactly one
parent; there is no sharing, no reference counting and no parent pointer.
`GraphemeCursor` records a transient root-to-leaf path and is invalidated by any
edit. Nothing outside `piece_table.zig` holds a node pointer across an edit, and
`buffer_eval` keeps a cursor only during a pure evaluation. Node identity is
therefore not part of any contract.

Text lives in two append-only byte stores, `original_buf` and `add_buf`. Pieces
refer to them by offset and length, never by pointer, so growing `add_buf`
(which may reallocate) never invalidates a piece.

### Every edit is one `replace`

Insert, delete, replace, contextual splices, undo and redo all reach the tree
the same way. `applyPendingOp` calls `planReplace` then `applySplice`; undo and
redo submit their recorded inverse operations through the same path.
`planReplace` only reads the tree. `applySplice` then:

1. appends the new region text (context included) to `add_buf`;
2. builds pieces for it (`makePiecesChunked`, one allocation);
3. deletes the old range (`deleteAligned`);
4. inserts the pieces (`insertPieces`).

Steps 1 and 2 allocate before anything changes. Steps 3 and 4 mutate committed
nodes *and* allocate:

| Routine | Mutates existing state | Allocates |
| --- | --- | --- |
| `insertInto`, leaf | overwrites a piece with its left half in place | `pieces.insert` for the right half and for the new piece |
| `insertInto`, internal | replaces a child with a split's left half | `children.insert` for the right half |
| `splitLeaf`, `splitInternal` | destroys the original node | two `create`s, two list allocations |
| `insertPieces` | sets a new root | `create` and two `append`s |
| `deleteFromLeaf` | replaces the piece list | a fresh piece list per touched leaf |
| `deleteFromInternal` | **frees fully covered child subtrees immediately** | a fresh child list per touched node |
| `mergeNodes` | moves children, destroys the right sibling | `appendSlice` into the left sibling |
| `borrowFrom*Sibling` | moves one child or piece | `insert`/`append`, currently `catch unreachable` |
| `normalizeRoot` | destroys the root | `create` for an empty leaf |

Summaries are recomputed in place by `nodes.recomputeNode`, which never
allocates. There are no rotations; balance comes from splits on insertion and
borrow/merge on deletion.

### Where rollback stops being free

The earliest unrecoverable point is the **first mutation of a committed node**
in a transaction. For a pure insertion that is the in-place piece split in
`insertInto`, which writes the left half before allocating room for the right
half; if that allocation fails, the right half of the piece is simply lost. For
anything with a deletion it is `deleteFromLeaf`, or `deleteFromInternal` freeing
a covered subtree, which is irreversible without reallocating its contents.

From that point on, the only way back is inverse replay, which allocates. That
holds within a single operation, and also between operations: once operation 0
of a payload has committed its tree changes, every later failure in the payload
(a rejected operation, an invalid interaction position, a dead `EditRef`, or an
allocation failure) relies on replaying operation 0's inverse.

Note that rollback is not only an out-of-memory path. A composite whose
interaction part is invalid, or whose `EditRef` was deleted by a later
operation, is rejected after its buffer operations have been applied. Rollback
runs on ordinary validation failures, so it must be reliable under the same
conditions as everything else.

### Tree atomicity versus the engine transaction

The tree is one participant. Around it, the engine transaction already handles
the rest before publication:

| State | Current protection | Fallible after publication? |
| --- | --- | --- |
| Anchors, including killed and hidden undo anchors | snapshot cloned before the first operation, swapped back on rollback | no |
| Undo/redo stacks | slot reserved before commit | no |
| View-provider notification set | reserved before commit | no |
| Mark anchors created by interaction operations | capacity reserved before commit | no |
| Revision and `EditEvent` | built before the revision advances | no |
| Text in the piece tree | inverse replay | **yes, allocates** |
| Deletion-meta resurrection on undo | runs after commit; can return `KeyError` (not an allocation failure) | yes, logic error only |

So the tree is the one remaining participant whose rollback allocates. Fixing it
makes the whole engine rollback allocation-free, apart from the resurrection
check, which is a separate ordering issue (see §5).

## 2. Measurements

**Conditions.** Apple M2 Max, macOS, Zig 0.16.0, `ReleaseFast`,
`std.heap.smp_allocator` wrapped in a counting allocator. A temporary,
uncommitted probe test (since removed). Documents are repeated ASCII lines,
loaded with `initFromText` ("fresh"), then optionally fragmented by 20,000
single-character insertions at random positions directly in the table. 50 weak
anchors. Allocation counts were identical across two runs; times varied by
roughly ±15% and are rounded.

Tree shape:

| Document | Pieces | Leaves | Internal nodes | Depth |
| --- | ---: | ---: | ---: | ---: |
| 64 KiB, fresh | 128 | 22 | 9 | 4 |
| 1 MiB, fresh | 2,048 | 342 | 117 | 6 |
| 8 MiB, fresh | 16,384 | 2,731 | 912 | 7 |
| 64 KiB, after 20k edits | 35,379 | 8,057 | 4,136 | 10 |
| 1 MiB, after 20k edits | 41,630 | 8,983 | 4,612 | 10 |
| 8 MiB, after 20k edits | 56,295 | 12,080 | 6,195 | 10 |

Each insertion inside a piece splits it into three, so piece count grows with
editing, not with document size. Depth reaches 10 in every heavily edited case.

Per operation (one sample each, plus a 200-keystroke average):

| Operation (8 MiB, after 20k edits) | Allocations | Bytes |
| --- | ---: | ---: |
| Insert one character | 21 | 5,127 |
| Delete one grapheme | 22 | 3,633 |
| Replace three graphemes | 24 | 3,902 |
| Merging accent (unaligned splice) | 26 | 4,027 |
| Undo of that accent | 25 | 4,046 |
| Rejected two-operation payload, including rollback | 23 | 4,997 |
| **Rollback step alone: inverse delete in the table** | **12** | **2,041** |
| Keystroke, average of 200 | 13.8 | 3,139 |

The rollback row is the problem in numbers: undoing one inserted character
performs 12 allocations (6 to 12 across all documents). Most of a deletion's
allocations are the fresh piece and child lists that `deleteFromLeaf` and
`deleteFromInternal` build along the path.

Path copying was estimated by copying the real root-to-leaf path (node struct
plus an exact-capacity list per node) and freeing the copies, averaged over
1,000 random positions on the same trees:

| Document | Nodes copied | Extra allocations | Extra bytes | Copy time | Keystroke time |
| --- | ---: | ---: | ---: | ---: | ---: |
| 64 KiB, fresh | 4 | 8 | 1,265 | 0.16 µs | 8.3 µs |
| 1 MiB, fresh | 6 | 12 | 1,628 | 0.21 µs | 8.3 µs |
| 8 MiB, fresh | 7 | 14 | 1,839 | 0.29 µs | 10.0 µs |
| 64 KiB, after 20k edits | 10 | 20 | 2,100 | 0.46 µs | 1.9 µs |
| 8 MiB, after 20k edits | 10 | 20 | 2,143 | 0.50 µs | 6.6 µs |

This measures the copying alone, not a working implementation. It is a fair
first-order estimate of what copy-on-write adds per first touch of a path.

## 3. Option A: pre-reservation

The idea is to compute, before mutating, everything an operation will need and
allocate it up front, so the mutation itself cannot fail.

**A bound exists.** An operation inserts `c` chunks (usually one). Each chunk can
cascade splits from leaf to root, so it needs at most `d + 1` new nodes and
their lists at depth `d`, plus a possible new root. A deletion touches at most
two root-to-leaf paths and merges at most once per level. Repeated operations
in a payload can be bounded by re-deriving `d` after each one, since depth
grows by at most one per cascade. Undo and redo are ordinary operations.

**But the bound cannot be spent by the current code.** Every routine in the
table above allocates internally with its own pattern: fresh lists in
deletion, `appendSlice` in merges, `create` in splits. Making them consume
reserved resources means rewriting each of them to draw from a node pool and
pre-sized lists, and replacing the `catch unreachable` borrows with proven
capacity. That is not a preparation phase bolted on; it touches every
mutating routine.

**And even then it fixes the wrong half.** Reservation makes each *operation*
atomic. It does not make the *transaction* reversible. Once operation 0 has
completed, a later rejection still needs operation 0 undone, which means
inverse replay. Reserving for that replay in advance runs into intermediate
state: the inverse of operation `i` is applied to the tree after operations
`i+1..n` have been undone, whose shape is not known when operation `i` runs.
Capacity reserved on particular nodes can be lost when later operations split
or merge them. A global pool sized for the worst case of every inverse is
possible in principle, but it amounts to a second bound proof for a second
code path that only runs on failure, which is exactly the path tests exercise
least.

The other way to undo completed operations without allocation is to save the
old contents of every node before changing it. That is copy-on-write under
another name.

It is worth following the strongest version of A to its end, because it shows
where the two options meet. Mutation routines can be made allocation-free by
giving nodes fixed-capacity entry arrays and drawing new nodes from a pool. A
conservative pool size can be bounded, since the numbers are small. That leaves
the inverse path: rolling back a deletion currently appends the deleted text to
the add buffer again and resegments it, which allocates. Making it
allocation-free means reinserting the original pieces the deletion removed, and
that requires keeping the removed tree structure until the transaction ends.
Keeping it is precisely what option B does. A fully worked option A is
therefore option B plus a node pool and a bound proof.

**Judgment.** Pre-reservation gives per-operation atomicity at the cost of
rewriting every mutation routine, and still leaves transaction rollback
fallible. It does not answer the guiding question.

## 4. Option B: copy-on-write within a transaction

A fully persistent tree, with structural sharing across revisions and reference
counting, is more than Litura needs: it keeps no historical trees. The useful
part is narrower. During a transaction, the committed tree must stay intact
and readable, and the candidate tree must be disposable.

**The rule.** A node is either *committed* (reachable from the published root
when the transaction began) or *transaction-owned* (created during it). The
transaction never mutates a committed node. The first time a mutation needs
one, it copies it, records the original as replaced, and edits the copy.
Transaction-owned nodes are edited in place, exactly as today. One invariant
keeps this sound: **a committed node never references a transaction-owned
node**, because committed nodes are never written.

**Publishing and aborting.**

- *Begin* records the root and the length of `add_buf`. Nothing allocates.
- *Commit* sets the root to the candidate and frees what the old tree no longer
  needs: replaced nodes are freed shallowly (their children live on in the
  copies), and subtrees removed whole are freed recursively. A committed
  subtree contains only committed nodes, so the recursion never meets a
  transaction-owned node. Freeing cannot fail.
- *Abort* sets the root back, frees every transaction-owned node shallowly, and
  truncates `add_buf` to its recorded length. Freeing and truncating cannot
  fail, and abort never reads the candidate tree.

That last point is the main simplification. Because abort only frees what the
transaction created, a failure *anywhere* during preparation may leave the
candidate tree half-built and inconsistent without consequence. The current
`errdefer` choreography inside split routines and the `catch unreachable`
borrows become unnecessary: a tree routine can simply return the error.

**Bookkeeping without allocation.** The created and replaced sets must be
recorded without allocating, or recording them could fail too. An intrusive
link in each node (one pointer) threads the created nodes into a list. A node
that leaves the candidate during the transaction (split away, merged, emptied,
or replaced as root) is marked as dropped, rather than freed, so it is never
freed twice. Removing a whole subtree walks only its transaction-owned nodes:
they are marked dropped, and each committed child met on the way is recorded as
removed, to be freed recursively at commit. Commit frees dropped
transaction-owned nodes; abort frees all transaction-owned nodes and forgets the
replaced and removed records without touching those committed nodes. The
records are threaded through the committed nodes' own link field, which the
committed tree does not otherwise use. That is roughly two words per node (the
link, plus a few flag bits): about 16 bytes on a 96-byte node.

**What changes in the code.** Every mutation routine gains one step: obtain a
writable version of the node before writing to it. Splits, merges and borrows
operate on writable nodes, so a sibling must be made writable before moving
pieces into or out of it. Places that free or destroy a node during mutation
call a `drop` that defers the decision to commit or abort. The algorithms
themselves (split, borrow, merge, normalisation) are unchanged.

**Cost (estimates from §2).** Up to `d` node copies per operation on its first
touch of a path, about 10 for a heavily edited document, then nothing more for
later edits along that path in the same payload. For insertions this is +8 to
+20 allocations and about 1.3 to 2.1 KiB per keystroke, which doubles to
roughly 2.5 times the allocation count, and 0.16 to 0.5 µs, which is 2% to 25%
of a measured keystroke. Deletion already allocates a fresh list for every node on its path,
so for deletions copying largely replaces existing allocations rather than
adding to them (estimate, not measured). Worst cases are unchanged in order:
a large paste or deletion copies at most the two boundary paths and otherwise
behaves as today. Transient peak memory is one extra copy of each touched path
until commit.

**Beyond atomicity.** Two near-term benefits follow without extra design:
`initFromText` can build a new tree and swap it in, closing its documented
"destroys the old tree first" issue; and the readable committed tree remains a
consistent snapshot while a transaction is in progress. Retaining old trees for
revision history or snapshots would need real sharing and reclamation across
transactions. That is not proposed here.

## 5. The full transaction

Copy-on-write fixes the tree. The engine transaction then becomes:

- **Preparation:** clone the anchor snapshot, begin the tree transaction, apply
  each operation to the candidate, rebase anchors, record inverses and deletion
  metadata, reserve history, provider and anchor capacity, and build the event.
  Every allocation happens here.
- **Abort:** tree abort, anchor-map swap, free pending records. No allocation,
  and no inverse replay.
- **Publish:** tree commit, advance the revision, store the undo entry,
  notify providers. No allocation.

What this resolves: rollback under persistent exhaustion, for rejections and
allocation failures alike; the skipped undo/redo test; the in-place piece split
that can lose text; the `catch unreachable` borrows; and the constructor
replacing its tree before allocating the new one.

What it leaves independent:

- **Undo resurrection** (`resurrectDeletionMetas`) runs after commit and can
  return `KeyError` if a deletion's hidden target anchor has died. That is an
  invariant violation rather than an allocation failure, but it should be
  checked during preparation so that nothing after publication can fail.
- **View providers** receive a notification they cannot fail; anything a
  provider does internally is its own responsibility.
- **The anchor snapshot** clones the whole map per transaction. It is correct
  and already allocation-safe, but costs O(anchors) per edit. That is a
  separate performance question and is not measured here.
- **Future event blocks** (SPEC §11 item 12) slot into preparation like the
  existing event: built before publication, handed over after. The tree change
  neither helps nor hinders them.

Inverse operations are still needed for undo history. They just stop being the
rollback mechanism.

## 6. Verification

The guarantee to establish is: no mutation is published until its fallible
preparation has succeeded, and any failure before that leaves observable state
exactly as it was.

1. **Enable the skipped undo/redo injection test** unchanged.
2. **Persistent exhaustion sweeps.** The existing transient sweep fails one
   allocation and then succeeds, so rollback itself never sees exhaustion. Add
   sweeps where every allocation fails from index `n` onward, for: a
   multi-operation composite with edit references; undo and redo of a joining
   deletion; an unaligned splice; a paste larger than one 512-grapheme chunk
   (forcing leaf and internal splits); a deletion spanning many leaves (forcing
   borrows and merges); and a deletion that empties the document (forcing
   `normalizeRoot`).
3. **Full state comparison, not just bytes.** Before and after each injected
   failure, compare text, buffer revision, every session's interaction
   revision and cursors, every anchor (id, position, stickiness, status), undo
   and redo stack contents, `add_buf` length, and the number of provider
   notifications (which must be zero for a failed operation).
4. **Structural tree check after every operation in the sweeps:** recompute
   each summary from its pieces and compare; check fan-out and fill bounds; and
   check that every piece boundary is a grapheme boundary of the whole text
   (the existing whole-text segmentation oracle).
5. **Ownership invariant check** in tests: after commit and abort, no node is
   transaction-owned, and during a transaction no committed node references a
   transaction-owned one.
6. **Leak detection** through `std.testing.allocator`, so aborted transactions
   free everything they created and commits free everything they replaced.
7. **Unchanged behaviour:** the existing Unicode conformance, locality,
   transaction and anchor suites pass without modification.
8. **Allocation budget:** keep the probe's per-operation allocation counts as a
   benchmark outside the default test step, so the copy cost is visible in
   review.

## 7. Recommendation

**Option B, scoped as transaction-local copy-on-write, not a persistent tree.**

1. **Why.** It is the only option that makes rollback allocation-free. Abort
   becomes pointer restoration plus frees, which hold under total exhaustion.
   Pre-reservation needs a rewrite of every mutation routine and still leaves
   transaction rollback fallible.
2. **Concrete changes.**
   - `pt_nodes.zig`: an intrusive link and a dropped flag per node.
   - `piece_table.zig`: begin, commit and abort; a "make writable" step before
     every node mutation; `drop` in place of immediate frees; removal of the
     `catch unreachable` borrows.
   - `buffer_engine.zig`: preparation begins a tree transaction; rollback
     calls tree abort instead of replaying inverses; commit calls tree commit
     after all reservations.
   - Resurrection checks move into preparation.
   - `initFromText` builds the new tree before releasing the old one.
3. **Invariants.** Simpler: tree routines no longer need error cleanup; a
   failure anywhere before commit is handled in one place; rollback stops
   depending on the inverse machinery being correct. Harder: every write must
   go through the writable step, and a missed one would mutate the committed
   tree. The ownership-invariant check (§6.5) exists to catch exactly that.
4. **Remaining failure cases.** Provider-internal failures; anything that
   still runs after publication by mistake; and constructor cleanup outside
   `initFromText`, which is already listed in `known-issues.md`.
5. **Performance.** Estimated from the measurements: about 10 extra
   allocations and 2 KiB per edit on a heavily edited document, and well under
   a microsecond, against keystrokes of 2 to 10 µs. No persistent memory
   overhead beyond about 16 bytes per node.
6. **Reviewable steps.**
   1. Test infrastructure: the state comparator, the structural tree check and
      the persistent-exhaustion sweeps, with the sweeps skipped pending the
      fix. No production change.
   2. Tree transactions inside `piece_table.zig`. Each public table mutation
      (`insert`, `delete`, `replace`) runs as its own begin–commit, so table
      users and tests see no behaviour change.
   3. Engine integration: preparation uses one tree transaction for the whole
      payload; rollback becomes abort; inverse replay is removed from the
      rollback path. The skipped sweeps are enabled.
   4. Remaining ordering: resurrection checks before publication;
      `initFromText` build-then-swap; `known-issues.md` updated.

Neither option needs a redesign of Litura beyond the piece table. Option B
touches more lines than its idea suggests, but they are mechanical and local:
the algorithms stay, and the commit point becomes a root assignment.

## Outcome

Option B is implemented as described in §4 and §7, in transaction scope only.
This section records the rules as built, with particular care for the three
places where an error would be easy to make, and replaces the §4 estimates with
measurements.

### Which nodes are copied, shared and freed

During a transaction every tree node is in exactly one of five classes:

| Class | How it arises | Commit | Abort |
| --- | --- | --- | --- |
| Committed, shared | Reachable from the committed root and not copied | kept | kept |
| Committed, replaced | Copied on its first write (`writable`) | freed shallowly | kept, mark cleared |
| Committed, removed | No longer referenced by the candidate | freed, subtree included | kept |
| Owned, live | Created by the transaction, reachable from the candidate | becomes committed | freed |
| Owned, dropped | Created, then split, merged or deleted away | freed | freed |

Two invariants make this sound. A committed node is never written, apart from
its bookkeeping record, so a committed node never references an owned one.
And copying is top-down: a node is made writable only through a writable parent,
so if any node in a committed subtree was copied, so was its root. A committed
subtree that the candidate still references therefore contains no replaced
nodes, and can be shared whole.

The bookkeeping stays valid independently of the candidate tree:

- Every owned node is recorded on the transaction's created list *before* it
  is linked anywhere, and every replaced node on its replaced list, through an
  intrusive link in the node. Recording never allocates.
- **Abort never reads the candidate.** It frees exactly the created list
  (shallowly: each node's own entry list and struct), clears the marks on the
  replaced list, restores the root and truncates the add buffer. A candidate left
  inconsistent by a failure halfway through a split is never traversed.
- **Commit runs only on a complete candidate,** after every edit succeeded. It
  marks what the new root reaches, without entering committed subtrees, then
  frees unreachable created nodes. Removed committed subtrees are found as the
  unreached children of replaced nodes; the search stops at reached nodes and
  at replaced nodes. Since parents are copied before children, replaced nodes
  are freed only after that search, so it never reads a freed node.
- Mutation routines no longer free anything themselves. A split keeps the
  original node as its left half; merged-away siblings, collapsed roots and
  covered children are simply left out of the candidate.

### The publication boundary

`BufferEngine` brackets each payload with one tree transaction. Everything that
can fail happens before publication: anchor snapshot, all edits, anchor
rebasing, inverse operations and deletion metadata, undo's anchor resurrection
(moved there in this change), and the reservations for the history slot,
provider notification set and mark anchors. Rollback is tree abort plus the
anchor-map swap, and allocates nothing. Publication is tree commit, the revision
increment and storing the undo entry, none of which can fail. Future event
blocks belong on the preparation side.

View providers are notified last, after every part of the submission is
published, including a composite's interaction part. The engine's notification
loop cannot fail, since its provider set is reserved during preparation, and the
callback returns nothing, so a provider cannot make a commit fail. Two hazards
remained and are closed:
- Notification used to precede a composite's interaction part, so a provider could
  observe the edit without the cursor placement.
- A provider could re-enter `submit` from its callback and commit a nested edit in
  the middle of publication. It now receives `error.ReentrantMutation`, as does
  `applyOps`.

Both shipped providers, the static token provider and the Tree-sitter provider,
only mark themselves stale when notified and reparse on `refresh`. A test
delivers a notification with every allocation failing and checks that neither
allocates. What a user-supplied provider does inside its callback remains its own
responsibility; the documented contract asks it to defer fallible work to
`refresh`.

### Repeated edits in one transaction

`writable` returns an owned node unchanged, so a payload copies each committed
node at most once, however many of its operations pass through it. Splits create
owned nodes but copy nothing. The table counts copies per transaction
(`Transaction.copied`), and a test applies 200 insertions at one position
after the first and checks that the count does not move.

### Verification

- `tests/allocation_failure_test.zig` sweeps persistent exhaustion (every
  allocation from the nth onward fails) for nine scenarios: a composite with edit
  references, undo with resurrection, redo, an unaligned splice, a multi-chunk
  paste that splits nodes, a deletion across many leaves, a deletion that
  empties the document, and two rejected payloads whose rollback runs while the
  allocator is exhausted. Each failure must leave the full observable state
  unchanged, the tree must pass the structural check, and the same submission
  must then succeed. Against the previous implementation, seven of the nine
  failed.
- `tests/engine_state.zig` captures that state without allocating through the
  engine: text, revision, add-buffer length, every anchor, every session and
  cursor, undo and redo history with their inverses and deletion metadata, and
  whether a view provider was notified.
- `tests/tree_check.zig` recomputes every summary from its pieces, checks
  fan-out and uniform leaf depth, checks that every piece boundary is a grapheme
  boundary of the whole text, and checks that no bookkeeping survives a
  transaction.
- `tests/tree_transaction_test.zig` checks that a transaction leaves every
  committed node's identity and content unchanged until abort, that the
  candidate shares everything except the copied path, that one transaction
  produces the same tree as separate ones, that repeated edits copy nothing
  further, and that a failing `initFromText` keeps the current document.
- The previously skipped undo/redo transient-failure test is enabled unchanged.

The sweeps found three pre-existing cleanup bugs, fixed here: `deleteFromInternal`
freed a list it had already handed to its node when a later step failed, and
`buildTree` leaked a leaf's piece list and could free shared children twice
when it failed partway.

### Measured cost

Same probe and conditions as §2, now against the implementation. Allocation
counts were identical across runs. Times varied by up to 65% between runs on the
smallest fragmented document, and by around 10% elsewhere, so only larger
differences are meaningful.

| 200-keystroke average | Allocations | Bytes | Time |
| --- | ---: | ---: | ---: |
| 64 KiB, after 20k edits, before | 13.5 | 2,823 | 1.7 to 1.9 µs |
| 64 KiB, after 20k edits, after | 32.2 | 6,012 | 2.7 to 4.4 µs |
| 8 MiB, after 20k edits, before | 13.8 | 3,139 | 6.6 µs |
| 8 MiB, after 20k edits, after | 32.2 | 6,128 | 7.5 to 7.7 µs |
| 8 MiB, fresh, before | 23.0 | 4,490 | 8.7 to 10.0 µs |
| 8 MiB, fresh, after | 33.5 | 6,739 | 9.7 to 10.2 µs |

Insertions cost what §4 estimated: one copied node and list per level. Deletions
cost more than estimated. §4 expected copying to replace the fresh lists that
deletion already builds, but deletion still builds them, now for nodes it has
just copied; a single-grapheme deletion went from 22 to 42 allocations. Since
owned nodes may now be edited in place, deletion could filter their lists in
place instead. That is a self-contained follow-up, not needed for correctness.
Rejected payloads allocate slightly more in total (17 to 25 allocations before,
18 to 32 after), because applying their first operation now copies its path. The
rollback itself allocates nothing, where it previously replayed inverses, and
their measured time fell in five of the six documents (single samples).

### Remaining failure cases

- `BufferEngine.initFromText` still leaks a partly built engine when its own
  construction fails, and provider destruction discards allocation failures.
  Both are listed in `known-issues.md`.
- View providers are notified after publication and cannot fail it; anything a
  provider does internally is its own responsibility.
- The anchor snapshot still clones the whole anchor map per payload. It is
  allocation-safe but costs time proportional to the number of anchors, which
  this study did not measure.
