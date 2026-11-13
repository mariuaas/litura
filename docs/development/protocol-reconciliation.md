# Protocol reconciliation: anchors, interaction state and events

**Status:** reviewed and implemented, as revised. D1 and D2 (as narrowed in review)
and the defects in §4 are implemented as written; D3–D15 were revised in the
[interaction and event contract](interaction-contract.md), which supersedes their
recommendations here.
**Baseline:** commit `34e3d76`.

Litura's SPEC describes a causal editor state machine: every observable change
enters through an intent, commits atomically, and is explained by an event. The
recent transaction work made the buffer half of that machine sound. This report
examines the parts that still fall short: what happens to anchors over time,
how interaction state changes, and what a committed transition reports.

Each section gives the contract, what the code does, the gap, whether the right
behaviour is already determined, and a recommendation. Decisions that need
agreement are numbered **D1** to **D16** and collected at the end. Findings marked
*reproduced* were confirmed with a temporary probe test, since removed.

## Summary

| Area | Finding | Kind |
| --- | --- | --- |
| Anchors | Undo fails with `KeyError` after a dead anchor is dropped, and keeps failing (reproduced) | Defect; semantics undefined |
| Anchors | Discarded redo entries leave their hidden anchors live forever (reproduced) | Defect |
| Anchors | Engine-internal anchors share the public id space and can be dropped | Defect |
| Anchors | Dropping a session's anchor leaves the session referring to nothing | Undefined ownership |
| Interaction | `SetSelections` and registers are unimplemented | Missing core contract |
| Interaction | Six public session/anchor mutators bypass intents, CAS and events | Violates §0.1 |
| Interaction | Interaction-only submissions are not atomic | Defect |
| Interaction | `dropSession` mutates, then can fail | Defect |
| Interaction | Mutators other than `submit`/`applyOps` are callable from provider notification; registering a provider there mutates the map being iterated | Defect (memory safety) |
| Events | No intent identity; reports borrow the caller's intent | Missing contract; lifetime hazard |
| Events | Composite results drop the interaction part; no interaction deltas | Missing contract |
| Events | §7 mixes event production with delivery | SPEC correction |
| Remaining | Constructor leak, provider destruction under OOM, eval search leak, save path, static provider revision | Defects |
| Remaining | Eval sandboxing, non-atomic file replacement, revision-based dirty state | Documented limitations |

## 1. Anchor lifetime, deletion and undo

### Contract

§1.4 *Anchor Lifecycle* makes creation and destruction intrinsic operations
(`create_anchor`, `drop_anchor`) and forbids identifier reuse, even after GC.
§2.5.2 records anchors killed by a deletion in `DeletionMeta`, alongside one
*hidden* target anchor; §2.5.3 resurrects each record on undo and destroys the
target. §2.5.6 lets an engine reclaim metadata of unreachable entries, after
which "dead anchors … are truly terminal and may be dropped".

The SPEC does not say what happens when a client drops an anchor that a
reachable `DeletionMeta` still records, who may drop the hidden target, or what
`query_anchor` and `drop_anchor` return for an anchor the engine reclaimed.

### What the code does

`DeletionMeta` stores anchor ids. `dropAnchor` removes the id from the anchor
map. `resurrectDeletionMetas` looks each recorded id up and returns `KeyError`
if it is missing.

The reported sequence reproduces exactly. B selects `[2, 5)` (sticky cursor at 5,
weak mark at 2), A deletes `[1, 4)` and kills the mark, B moves its cursor, which
drops the dead mark, and A's undo fails with `KeyError`. Since the last change
the failure is atomic, but that makes it worse in practice: the entry stays on
top of the undo stack, so **every later undo fails** and the buffer's history is
permanently blocked.

Two further problems were reproduced:

- **Orphaned hidden anchors.** When a new edit discards the redo branch,
  `discardRedo` frees each entry's `DeletionMeta` but not the hidden target
  anchors it created. After 50 insert/undo/edit rounds, the engine held 50 live
  orphaned targets and 50 dead anchors nothing could ever resurrect. Every edit
  rebases the live ones, and every transaction clones all of them into its
  anchor snapshot, so per-edit cost grows with editing history.
- **Hidden anchors are public.** Target anchors and `EditRef` result anchors
  live in the same id space as client anchors. A client can query them, and
  dropping a target makes that undo fail permanently, by the same route as above.

Session ownership is also undefined. `createSession` takes anchors the caller
created (and does not require them to be sticky, so a cursor can die), while
`dropSession` drops them and the engine creates and drops mark anchors on its own.
A client can drop a cursor anchor still in use, after which session operations
fail with `KeyError`.

### Is the behaviour determined?

Partly. §2.5.4 and the identity rule determine that a dropped anchor must never
reappear, and that undo of an otherwise valid entry must not fail because of it.
The rest needs decisions.

### Recommendation

- **D1. Explicit drop is terminal.** A dropped anchor never reappears.
  Resurrection skips records whose anchor no longer exists. Identifiers are
  never reused, so absence is unambiguous: the anchor was dropped or reclaimed.
  The alternative, removing the anchor from every `DeletionMeta` when it is
  dropped, costs a scan of the whole history per drop and gains nothing.
- **D2. Engine-internal anchors are not addressable.** Deletion targets and
  `EditRef` anchors move to engine-internal storage (or carry an internal flag),
  so `query_anchor` and `drop_anchor` cannot reach them. This is what §2.5.2
  already means by "hidden".
- **D3. Reclaim on unreachability.** When an undo or redo entry becomes
  unreachable, the engine drops its hidden targets and the dead anchors its
  metadata records, as §2.5.6 permits. A dead anchor is recorded by at most one
  reachable `DeletionMeta`, since it cannot die again before it is resurrected,
  so reclamation never removes an anchor another entry still needs. A reclaimed
  anchor can still be a session's dead mark; with D5 that anchor belongs to the
  session, so reclamation also clears it from the selection, which then
  collapses to its point. Dropping only frees, so this cannot fail after
  publication.
- **D4. Absent identifiers have a defined answer.** Because identifiers are
  monotonic and never reused, any id below the next unallocated one that is
  absent from storage was dropped or reclaimed. `query_anchor` reports it as
  terminal (a `Dropped` status, or `Dead` if we prefer not to add a state), and
  `drop_anchor` on it succeeds as a no-op. Anything above the allocated range
  stays `KeyError`. Reclamation then needs no tombstones.

Session-owned anchors depend on §2 (D5).

### Tests

The reported two-client sequence, plus variants that clear the mark with
`SetSelections`, drop the cursor, or tear the session down before undo. Undo and
redo across those, checking that dropped anchors stay dropped and live ones
resurrect. Redo-branch discard followed by an anchor-count check (no live
orphans, reclaimed dead anchors report terminal). Attempts to query or drop a
hidden anchor. The persistent-exhaustion sweep extended to undo with skipped
records, and to an edit that discards a redo branch.

## 2. Interaction state and mutation pathways

### Contract

§2.6 defines a session's state as `selections: Selection[]` and `registers`, where
a `Selection` is an `AnchorRange` plus an active edge. §2.6.1 defines exactly
three interaction operations: `SetSelections`, `WriteRegister` and
`ClearRegister`. §0.1 requires every protocol-visible change to interaction state
to be representable, observable and interceptable through intents and events.
§2.6.1 requires composite application to be atomic. The SPEC defines no session
creation or teardown at all: §1.6 lists anchor creation and dropping as the only
intrinsic messages.

### What the code does

A session is a list of cursors, each a cursor anchor plus an optional mark.
Interaction intents support `move_cursor_anchor`, `set_cursor_selection` and
`place_cursor`, each addressing one existing cursor. There is no way to replace
the selection list, and registers do not exist.

Alongside the intents, six public functions change interaction state directly:
`moveAnchor`, `addSessionCursor`, `dropSessionCursor`, `setSessionMarkPosition`,
`setSessionMarkAnchor` and `dropSession`.
- None of them takes an origin, checks the interaction CAS, evaluates guards or
  produces an event.
- The four session mutators advance the interaction revision anyway.
- `moveAnchor` accepts out-of-range positions and does not advance it.

Some paths are also not atomic:
- A pure `InteractionMutation` is applied in place. If a later operation fails,
  for instance when allocating a new mark anchor, earlier operations remain
  applied and the revision does not advance. Only composites reserve capacity
  first.
- `dropSession` drops a cursor, then fails with `InvalidArgument` if other cursors
  remain.

The notification guard covers `submit` and `applyOps` only. Every other mutator
is callable from a provider's callback. For `registerViewProvider` that is a
memory-safety problem, since the engine is iterating the provider map at the time.

junc uses only `createAnchor` + `createSession`, `dropSession`, `querySessionMark`
and submissions with `place_cursor`. Its pattern (create an anchor, hand it to the
session, expect `dropSession` to release it) already assumes sessions own their
anchors.

### Is the behaviour determined?

§0.1 and §2.6.1 determine that interaction state changes only through intents,
atomically. How selections own their anchors, how sessions are created, and what
happens to the existing operations need decisions.

### Recommendation

- **D5. Sessions own their selection anchors.** `SetSelections` takes, for each
  selection, a point target and an optional mark target, where a target is a
  `Position` (coordinate-bearing, origin-checked), an `EditRef` (composites only),
  or an `AnchorId` (resolved to that anchor's current position, anchor-scoped).
  The engine creates the session's own anchors for the new selections and drops
  the ones they replace. Clients never manage selection anchors, so they cannot
  leak, die unexpectedly, or be dropped from under a session; the external
  `drop_anchor` refuses a session-owned anchor with an explicit error.

  *Alternative:* the SPEC-literal model, in which selections reference
  client-created `AnchorId`s and clients drop them. It keeps §2.6 unchanged but
  leaves every lifetime question to the client, including how the engine must
  treat a selection whose anchor was dropped or died. I recommend D5 and a SPEC
  amendment that states it.
- **D6. Session lifecycle is intrinsic.** Creating and dropping a session are
  intrinsic operations like anchor creation: they do not advance any revision or
  produce events. `create_session` takes an initial target (defaulting to
  position 0) and returns the session; `drop_session` releases every anchor the
  session owns, atomically. The SPEC gains both in §1.6 and §2.6.
- **D7. One canonical operation.** `SetSelections` replaces `move_cursor_anchor`,
  `set_cursor_selection` and `place_cursor`. Multicursor editing is then a
  selection list, not a special path. I would remove the three old operations
  rather than keep aliases; junc's single `place_cursor` call site becomes a
  one-selection `SetSelections`.
- **D8. Remove the privileged mutators.** `moveAnchor`, `addSessionCursor`,
  `dropSessionCursor`, `setSessionMarkPosition` and `setSessionMarkAnchor` leave
  the public API. Anchors move only by rebasing; session state changes only
  through intents.
- **D9. Implement registers.** `WriteRegister` and `ClearRegister` are core
  operations in §2.6.1, not optional features, and use the same machinery as
  selections: owned values, deltas, revision. The cost is small once D10 exists.
- **Determined: prepared interaction transitions.** Every interaction mutation,
  pure or composite, builds the session's new selection list and register map
  beside the current ones, then publishes by swapping them in and advancing the
  revision. Failure discards the prepared state. This also produces the
  old/new values that interaction events need (§3).
- **Determined: re-entrancy.** Every state-changing entry point, intrinsic ones
  included, returns `error.ReentrantMutation` during notification. Reads remain
  allowed.

### Tests

`SetSelections` with several selections, active edges, `AnchorId` targets and
`EditRef` targets in composites. CAS and origin rejection. Replacing selections
drops the old anchors, and a later undo does not revive them. Two sessions
editing concurrently, with passive rebasing and no revision change for the
bystander. Register writes and clears. Interaction-only and composite submissions
under the persistent-exhaustion sweep, with session state in the state
comparator. Session teardown releasing all anchors. Re-entrancy refusal for each
mutator, including provider registration.

## 3. Canonical causal events

### Contract

§7 defines `EditEvent` with typed `cause` (`Intent { id }`, `Group { id }`,
`BuiltIn`), typed `source`, an `EditClass`, and a buffer id. §2.6.2 defines
`InteractionEvent` with `InteractionDelta`s carrying old and new selections or
register values. §7.1 requires events to correspond 1:1 with applied intents,
echo the `IntentId`, and route rejections as `ValidationReport`s that also echo
it. §4.3 puts the whole `Intent` in the report. §7 also requires a composite's
edit and interaction events to be contiguous, and says subscribers receive one
synchronous, ordered stream.

SPEC §11 item 12 records the decision to separate *production* (the engine
returns complete, owned, ordered blocks at commit) from *delivery* (hosts own
retention and fan-out).

### What the code does

- `Intent` has no identity; `source` and `cause` are free strings.
- `SubmitResult` is one of an edit event, an interaction result or a report. A
  composite with both parts returns only the edit event. With several
  interaction parts, only the last result survives.
- `InteractionResult` carries only old and new revision numbers: no deltas and no
  cause.
- `EditEvent.edit_class` is a string, including `"mixed"`, which `EditClass` does
  not have.
- `ValidationReport` stores the submitted `Intent` by value, so its payload
  slices, guards and strings borrow caller memory. A stored or forwarded report
  can dangle.
- Event construction already happens before publication, and providers are
  notified after the whole submission, with re-entrancy refused.

### Is the behaviour determined?

The data each transition must report is determined by §2.6.2 and §7. Five things
need decisions: the delivery wording in §7, the identity representation, what a
report carries, typed provenance, and the multi-operation edit class.

### Recommendation

The shape I would build:

```
SubmitResult = Committed(EventBlock) | Rejected(ValidationReport)

EventBlock = {            -- owned by the caller; allocated before publication
    sequence     : nat    -- gapless per buffer; rejections consume none
    cause        : TransactionCause
    source       : EventSource
    edit         : EditEvent | None
    interactions : InteractionEvent[]   -- in application order
}
```

Every committed intent yields exactly one block, including interaction-only
intents and undo/redo, whose cause is the undo intent's id (§2.5.3). The block is
built during preparation, so publication cannot fail. Providers receive it
borrowed, after the whole submission.

- **D10. Restructure §7 into production and delivery.** Production becomes
  normative for engines: block contents, sequence, 1:1 with intents, composite
  contiguity (now structural, since both events sit in one block). Delivery
  becomes a hosting profile: the synchronous broadcast wording, subscriber
  classes and fan-out. §1.6's "asynchronous broadcast" entries become "returned
  at commit, broadcast by the host". This is the item 12 direction made
  normative, and it removes nothing a host needs.
- **D11. `IntentId` representation.** I recommend an optional 128-bit value
  supplied by the client (UUID-sized), echoed in blocks and reports. `None`
  means the submission needs no correlation, which suits direct library use; a
  host such as junc can require it on its wire protocol.
- **D12. Reports carry identity, not the intent.** `ValidationReport` keeps
  `intent_id`, `intent_class`, revisions, guard results and verdict, all owned. The
  submitter already holds the intent; copying payload text into every rejection
  would be wasteful, and borrowing it is unsafe. This changes §4.3.
- **D13. Typed provenance.** `source` becomes `Extension { id } | UserInput`
  (§4.2), with `Engine` reserved for built-in transitions. Litura's free-form
  `cause` string, which junc uses as a label, becomes an optional owned `label`
  on the intent, echoed in the block, not part of the causal contract.
- **D14. Edit class for mixed payloads.** A payload may insert in one place and
  delete in another. I recommend adding `Mixed` to `EditClass`, since the
  per-operation realized splices already describe the detail.
- **D15. Buffer identity is host-stamped.** A `BufferEngine` is one buffer with
  no identity of its own. Blocks omit the buffer id; the host adds it when
  delivering. §7 should say so.

### Tests

One block per committed intent with a gapless sequence across buffer, composite,
interaction-only, undo and redo submissions, and no sequence consumed by
rejections. Composite blocks contain the edit and every interaction event in
order. Interaction deltas match before/after state, including registers. Reports
echo the id and stay valid after the intent's memory is freed. Block
construction under the persistent-exhaustion sweep: a failure leaves no block,
no sequence consumed and no state change. Providers receive the complete block.

## 4. Remaining correctness and contract gaps

| Item | Classification | Recommendation |
| --- | --- | --- |
| `BufferEngine.initFromText` leaks the engine if text or path copying fails | Defect | `errdefer engine.deinit()`; exhaustion sweep over construction and `fromFile` |
| Provider destruction allocates a dedupe set and ignores insertion failure, so a shared provider can be destroyed twice under memory pressure | Defect | Deduplicate without allocation (scan the registered list), or keep distinct providers in a list maintained at registration; notification can use the same list instead of reserving a set |
| `StaticTokenProvider.refresh` advances its own counter instead of adopting the engine revision, so it can report `available` at the wrong revision | Defect in a shipped provider | Adopt the engine revision; replace the characterization test with a coherence test |
| Evaluation `findNext` returns `null` for an out-of-bounds match without freeing the match text | Defect (leak) | Free before returning; test with `std.testing.allocator` |
| `save` replaces the stored path before the write succeeds | Defect | Replace only on success; failure test with an unwritable path |
| `save` is not an atomic file replacement | Limitation | Keep documented; temporary-file-and-rename is a reasonable later improvement, outside the SPEC |
| Dirty state compares revisions, so undoing to identical text stays dirty | Design limitation | Keep documented |
| Evaluation is not a sandbox; the carrier advertises `PrototypeOperationCount`, not `CanonicalAWU` | Correctly advertised limitation | Keep; the capability already says it is non-conforming |
| Provider callback results and Tree-sitter syntax paths are borrowed with documented lifetimes | Documented contract | Keep; review once providers receive event blocks |
| Validation reports borrow their intent | Lifetime defect | Resolved by D12 |
| Grouped intents unsupported | Limitation, advertised as no group modes | Keep |
| `Undo`/`Redo` intents carry no session (§4.2 has one) | Representation difference | Add the field when D11–D13 land; history stays document-wide in v0.1 |

STATUS currently says Litura implements "edit events". After §3 it should say
which event contract it implements; until then it overstates.

## Dependencies and order

1. **Small defect fixes** (§4): independent, each with its own test. They clear
   noise from the known-issues list first.
2. **Anchor lifetime** (D1–D4): internal anchor storage, terminal drop,
   reclamation, absent-id semantics. This fixes the blocked undo. It does not
   depend on the session model, except that refusing to drop a session-owned
   anchor waits for D5.
3. **Interaction model** (D5–D9): session-owned anchors, `SetSelections`,
   registers, intrinsic session lifecycle, removal of privileged mutators,
   prepared interaction transitions, complete re-entrancy guard. Depends on 2.
4. **Event blocks** (D10–D15): identity, typed provenance, owned reports,
   blocks with sequence and interaction deltas, providers receiving blocks.
   Depends on 3 for deltas and prepared interaction state.

Each step updates the SPEC where its contract changes, removes the matching
known-issue entries, and extends the exhaustion sweeps and state comparator to
cover the new state. Steps 3 and 4 change the public API; junc's adaptation is
small (session creation, one `SetSelections` call, the result type) and can follow
each step.

## Decisions for review

| | Decision | Recommendation |
| --- | --- | --- |
| D1 | Effect of explicit drop on undo lineage | Terminal; resurrection skips absent anchors |
| D2 | Visibility of engine-internal anchors | Not queryable or droppable |
| D3 | Reclaiming unreachable history | Drop hidden targets and recorded dead anchors when an entry becomes unreachable |
| D4 | Query/drop of dropped or reclaimed ids | Terminal status; idempotent drop; `KeyError` only for never-allocated ids |
| D5 | Selection anchor ownership | Session-owned; targets as `Position`, `EditRef` or `AnchorId` |
| D6 | Session lifecycle | Intrinsic create/drop; drop releases owned anchors |
| D7 | Existing cursor operations | Replace with `SetSelections` |
| D8 | Direct mutators | Remove from the public API |
| D9 | Registers | Implement |
| D10 | §7 structure | Production normative, delivery a hosting profile |
| D11 | `IntentId` | Optional 128-bit, client-supplied |
| D12 | Report contents | Owned id and results, not the intent |
| D13 | Provenance | Typed source; free-form cause becomes a label |
| D14 | Multi-operation edit class | Add `Mixed` |
| D15 | Buffer id in events | Host-stamped |
| D16 | Order | Defects, anchors, interaction, events |
