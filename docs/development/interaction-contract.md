# Interaction and event contract: a proposal

**Status:** approved and implemented. The normative text now lives in the
[specification](../buffer-protocol/SPEC.md) (§0.1, §1.4, §2.5.6, §2.6, §4.2, §4.3,
§7); this note keeps the reasoning behind it. Implementation refined one point: identities
are issued at the transaction boundary, so an endpoint created and released within one
intent, including across the parts of a composite, is never issued, and blocks report
one net interaction event per changed session rather than one per mutation.
**Follows:** [protocol reconciliation](protocol-reconciliation.md), D3–D15 as revised in review.

**Changes since the first revision.** Public identifiers are issued at
publication, not at creation (§1). One `SetSelections` resolves all its targets
against a single state (§2). Edit events report their passive effects on session
endpoints (§3), because a realized splice does not determine them. Interception
covers the declared intrinsic requests and separates the engine's obligations
from the host's. Role-based stickiness is recorded as a v0.1 decision. The
no-op rule states its consequences for history. Snapshots carry a sequence
watermark.

The review of the reconciliation report left three connected questions open:

1. What becomes terminal when history disappears?
2. What survives when a selection changes?
3. Which transitions does the canonical stream promise to explain?

They have to be settled together, because they meet in the same places. A selection can hold a dead mark whose only way back is an undo entry that a new edit is about to discard. An event that reports a selection change has to say which endpoints persisted and at which document revision their positions mean anything. And whatever reclamation does to that selection must either be visible in the stream or provably change nothing a client can see.

The principle from the review governs every choice below: *resource reclamation must not become an undocumented editing operation, and easier ownership must not erase identities that the causal model relies upon.* We get there by making reclamation unobservable by construction (§1), keeping endpoint identity explicit in every selection change (§2), and stating both the stream's scope and the payload that makes that scope achievable (§3).

## 1. Handles and reclamation

### Four handle states

A client holding an `AnchorId` can be in one of four situations, and the extension waiting on it needs to tell them apart.

| State | Meaning | `query_anchor` | `drop_anchor` |
| --- | --- | --- | --- |
| Live | Exists and has a position | `Live`, position | Disposes it |
| Dead | Exists, has no position | `Dead` | Disposes it |
| Disposed | Its owner ended its lifetime; terminal (SPEC §1.4) | `Disposed` | No-op, succeeds |
| Invalid | Never issued as a public anchor | error | error |

`Dead` describes the absence of a position. It does not promise that any reachable undo entry can still resurrect the anchor, and an extension can't infer the contents of undo history from it. What `Dead` and `Disposed` do separate is geometric death from the end of a lifetime: a disposed anchor will never return, while a dead one may or may not. `Invalid` covers identifiers nobody was given, including internal anchors, which must stay indistinguishable from never-allocated ones (D2).

I would not expose resurrection eligibility in v0.1. It changes when a new edit discards the redo branch, so exposing it would make every such discard an observable transition of the anchors involved. If an extension needs it later, it can be added together with an event that reports the change.

### Issuance happens at publication

Telling `Disposed` from `Invalid` without storing a tombstone per disposal requires one invariant. Marks churn on every selection change, so tombstones would grow with typing.

> A public anchor identity is issued only when the transition or receipt that creates it is published. Preparation may assign provisional identities, but an aborted preparation leaves the issued-identity boundary unchanged and exposes none of them.

Given that, a public identifier below the boundary and absent from storage was issued and then disposed. The engine never reclaims a public anchor (next section), so absence has no other cause.

The invariant has to hold for every path that creates public anchors, and composites are the demanding one. A composite's `SetSelections` can create several `New` endpoints from `EditRef` targets, and its preparation can still fail afterwards: a later interaction operation might be invalid, or an allocation might fail. The engine prepares those endpoints and the owned result block, which already names them, then either publishes both or discards both. Discarding resets the provisional counter to the committed boundary. Since the engine runs one transaction at a time, nothing else can take identities in between.

One case within a *successful* transaction needs a ruling. A composite with two `SetSelections` for the same session can create an endpoint in the first and omit it from the second. The client couldn't have kept it, because it learns the identifier only from the result. The endpoint is issued: the block's first interaction event creates it and its second releases it, so the identity appears in published history, and querying it afterwards returns `Disposed`. Every identity below the boundary therefore appears in some published block or receipt, and there are no unexplained holes.

Internal anchors need their own namespace so they never count as issued. A tagged second counter is one way to do it. The SPEC should state the observable guarantees (the four states and the issuance invariant) and leave the representation to the engine.

Tests: a composite that prepares several `New` endpoints and then fails leaves the public anchor set *and* the issuance boundary unchanged, including under the exhaustion sweep. An endpoint created and omitted within one successful composite queries as `Disposed`. After every operation in the sweeps, every public identifier below the boundary is either present or was named in a published block or receipt.

### Reclamation never touches public anchors

Discarding an unreachable undo or redo entry frees the entry's text and records, and its internal targets once nothing needs them, but nothing a client can see:

- **Public anchors lose eligibility, nothing else.** A public anchor named in a discarded record stays `Dead` until its owner disposes of it. Its map entry (about twenty bytes) is the small dead-anchor record the review asked for: it outlives the history that could revive it. For a client anchor, the client is the owner. For a session endpoint, the session is (§2), so a degenerate selection keeps its dead mark until that session changes the selection.
- **Internal targets live exactly as long as they are needed.** That is the normative part. It is not trivial, because an internal target can outlive its owning entry. The edit that discards a redo branch can kill one of that branch's targets and record it for its own undo, and freeing the target on discard would make that later undo fail with `CorruptHistory`. The implementation I'd use is a reference count on the internal anchor: one for the reachable owning entry, plus one per reachable record naming it. The transaction snapshot restores the count on rollback for free. The anchor is released when the count reaches zero, either on discard or right after an undo resurrects a target whose owner is already gone. The count is an implementation choice, not a SPEC requirement, and it is unrelated to how the piece tree shares nodes.

Since internal anchors are invisible and public anchors don't change, reclamation changes no observable state and needs no event. That answers the first question: when history disappears, *resurrection eligibility* becomes terminal. Nothing else does.

SPEC §2.5.6 currently says dead anchors whose metadata is reclaimed "are truly terminal and may be dropped". It would instead say that they lose eligibility and remain `Dead` until disposed, and that GC may reclaim internal anchors only.

## 2. Selections

### Ownership

A session owns the anchors that form its selections. Any client can query them, but only the session's own interaction intents can change them, and dropping the session releases them all. `drop_anchor` on a session endpoint fails with an explicit error (`AnchorOwned`) rather than leaving the session referring to nothing. Client-created anchors stay with their creator.

Nothing transfers between the two. A client anchor can supply a *position* for a selection (below), but it never becomes an endpoint. The review mentioned an alternative: a session borrows client anchors, and `drop_anchor` is refused while they are borrowed. That keeps the SPEC's literal pairing of arbitrary anchors. It costs a borrow count per anchor, though, and a drop would then fail for reasons the dropping client may not know about, because another client's session happens to use the anchor. I recommend against it for v0.1, but it is compatible with everything else here if we want it later.

### Identity: what survives a change

`SetSelections` replaces the selection list. Each endpoint in the new list says explicitly how it relates to the old state:

```
SetSelections { selections: SelectionSpec[] }

SelectionSpec = {
    start  : Endpoint
    end    : Endpoint | SameAsStart     -- SameAsStart: a caret
    active : Start | End
}

Endpoint =
    | Keep(AnchorId)                     -- an endpoint this session owns; unchanged
    | Move(AnchorId, Target)             -- same endpoint, new position; must be live
    | New(Target)                        -- a fresh endpoint anchor

Target =
    | Position(Position)                 -- coordinate-bearing: origin-checked
    | Edit(EditRef)                      -- composites only (§2.6.1)
    | AnchorPosition(AnchorId)           -- sample a live public anchor; anchor-scoped
```

Three rules give these their meaning.

1. **A kept endpoint is the same object.** `Keep` preserves the endpoint's identity and geometric state: position and status, including `Dead`. That is how a degenerate selection survives an unrelated change with its lineage intact. Stickiness is not geometric state. It follows the endpoint's role, so it changes only when an explicit selection update changes that role (see *Edges and stickiness*). A dead endpoint can't change role, since a dead fixed endpoint has no position from which to serve as a live Sticky cursor.
2. **A moved endpoint keeps its identity.** `Move` is what lets "this cursor" persist across movement. An extension tracking a session's point by `AnchorId` doesn't see it disposed and replaced on every keystroke. `Move` requires a live anchor, and deletion records only ever name dead ones (an anchor's record is consumed when it is resurrected). A moved anchor can therefore never be pulled back by an older deletion record.
3. **Whatever the new list does not mention is released.** Unmentioned endpoints are disposed, which is terminal. Each owned anchor may appear at most once in the new list, except that a caret uses one anchor for both ends.

Take the review's example. A session has two selections. Selection 1 is `[p1, m1]`, and its mark `m1` died when another client deleted the text around it. Selection 2 is the caret `c2`. The user moves only the caret:

```
SetSelections [
    { start: Keep(m1), end: Keep(p1), active: End },            -- untouched, mark still dead
    { start: Move(c2, Position(17)), end: SameAsStart, active: End },
]
```

`m1` remains dead and recorded, so undoing the other client's deletion still brings it back. `p1` and `c2` keep their identifiers, and nothing is disposed. If the user then cleared selection 1 into a caret at its point, the spec would be `{ start: Keep(p1), end: SameAsStart }`. `m1` would be released, and the later undo would skip it under the disposal rule already implemented. That is the two-client case from the original bug report, expressed in the canonical operation.

There are no selection identifiers beyond the endpoints themselves. A selection is identified by its anchors, which already carry identity in the SPEC. A `SelectionId` would give multi-cursor hosts a key that survives the point being recreated, but with `Move` the point is not recreated, so for the operations proposed here it buys nothing.

### Resolution is simultaneous within one `SetSelections`

The endpoints of one `SetSelections` describe a replacement state, not a sequence of steps. Consider two carets, `a` at 3 and `b` at 9:

```
{ start: Move(a, AnchorPosition(b)), end: SameAsStart, active: End },
{ start: Move(b, AnchorPosition(a)), end: SameAsStart, active: End },
```

The result should be `a = 9`, `b = 3`. If the first move took effect before the second target was read, both would end at 9, and the meaning would depend on the order in which the engine traverses the list.

> Every endpoint reference and target in one `SetSelections` is resolved against the same pre-operation state: the state left by the preceding buffer operations and preceding interaction operations of the same intent. Only after the whole replacement resolves and validates is it installed.

This also settles sampling an endpoint the new list omits: its position is still available during resolution, and it is released only afterwards.

Separate interaction operations stay sequential. In a composite, the engine conceptually:

1. applies the buffer operations to the candidate state;
2. resolves the first interaction operation against that candidate state and prepares its complete replacement;
3. resolves each later interaction operation against the state the previous one prepared;
4. publishes only when the whole transaction is ready, with the issuance rule of §1.

### Target interpretation

The three target forms correspond to the three meanings the review separated:

- **Sample:** `Position`, `Edit` and `AnchorPosition` all mean "place an endpoint here". `AnchorPosition` reads a live public anchor's position under the resolution rule above and creates no relationship with it. Sampling another session's endpoint is allowed, and it is still only a position.
- **Retain:** `Keep` and `Move` refer to endpoints the session already owns.
- **Transfer:** deliberately absent.

A `Position` is coordinate-bearing and validated against the intent's document origin. `AnchorPosition` is anchor-scoped and follows liveness and guards, as SPEC §2.6 already distinguishes.

### Edges and stickiness

The proposal keeps the SPEC's shape: a selection is an `AnchorRange` plus an active edge. Two decisions need stating.

**Stickiness follows role: a normative v0.1 policy.** The active endpoint is Sticky, the fixed endpoint is Weak, and a caret's single anchor is Sticky. The SPEC's rationale in §1.4 ("cursor-like anchors can remain spatially continuous through deletion while mark-like anchors can still die") motivates this. It does not require it: other selection models are coherent. We adopt it as a deliberate session-selection policy that gives ordinary selections predictable behaviour. Anchors created independently of sessions keep whatever stickiness their creator chose. The engine assigns stickiness when it installs a selection, so exchanging point and mark swaps the stickiness of the two live anchors, and that swap is part of the interaction event.

**`start` and `end` are slots, not an order.** With a Sticky point and a Weak mark at the same position, an insertion there moves the point past the mark. A backward selection can therefore end up with its `start` slot after its `end` slot, purely by rebasing. The derived `RangeStatus` orders positions geometrically, while the slots and the active edge still say which identity is the point, so nothing is lost. SPEC §1.4's `Live` status ("start < end") needs that clarification.

### Expressing the current operations

`SetSelections` has to be semantically complete before the old operations can go (D7). The mapping, for a session's cursor `c` with optional mark `m`:

| Current | As `SetSelections` (other selections `Keep`) |
| --- | --- |
| `move_cursor_anchor(c, p)` | `c` → `Move(c, Position(p))`, `m` → `Keep(m)` |
| `set_cursor_selection(c, mark: q)` | `m` → `New(Position(q))` (old `m` released); `null` → `SameAsStart` |
| `place_cursor(c, at, mark)` | `Move(c, at)`; mark as above; `EditRef` targets in composites |
| `addSessionCursor` | append `{ start: New(...), end: SameAsStart }` |
| `dropSessionCursor` | omit that selection |
| `setSessionMarkAnchor(c, a)` | `m` → `New(AnchorPosition(a))` (sampled; `a` is not adopted) |

The last row is a deliberate change. Today the session adopts the client's anchor. Under this proposal it samples the anchor's position, because adopting it would be a transfer.

### Registers and session lifecycle

`WriteRegister` and `ClearRegister` (D9) join the same prepared transition: the new register map is built beside the current one and installed at publication. Keys and values are owned by the session.

`create_session(initial: SelectionSpec[])` accepts only `New` endpoints. It returns the session and its endpoint identifiers, which are issued when its lifecycle block is published. junc's pattern of creating an anchor and handing it to `createSession` becomes `create_session([{ start: New(Position(p)), end: SameAsStart }])`. `drop_session` releases every endpoint and register atomically. Both are intrinsic: they advance no document or interaction revision. They are still observable (§3) and interceptable (§4).

## 3. The stream

### Scope

The stream promises to explain, for one buffer instance:

- every document revision, including undo and redo;
- every session's existence and its complete interaction state: selections with endpoint identities, positions, liveness and roles, plus registers and the interaction revision.

It does not cover client-created anchors (their creation, disposal, or the effect of edits on them), internal anchors, history reclamation (unobservable by §1), view-provider registration, persistence state, or evaluation. These exclusions go into the SPEC as a list, so that "the stream explains interaction state" can't be read more broadly than intended. Client anchors are handles held by their creator, who gets a receipt and can query them. Broadcasting their lifecycle would add data for every handle in the buffer, when most observers hold none of them.

Session existence is in scope because an observer holding a snapshot with session S otherwise can't learn that S is gone.

### What an edit event must carry

The first revision claimed that a deletion's effect on anchors "follows from the edit and the rebasing algebra". It doesn't, if the edit event carries only realized splice ranges. Take three graphemes, `e`, a newline and a combining acute accent, with a Weak anchor at boundary 1, just after `e`:

| Requested operation | Resulting text | Weak anchor at 1 |
| --- | --- | --- |
| Delete the newline, `[1, 2)` | `e` + accent | Survives at the deletion boundary, then projects to 0 |
| Replace `[0, 3)` with `e` + accent | the same | Dies: it was strictly inside the requested deletion |

Both realize the splice `[0, 3) → [0, 1)`. The rewritten region doesn't say which original text was semantically deleted, which is exactly why we kept requested operations and realized splices apart. An observer could only reproduce the outcome from the requested operations, the old text and Litura's Unicode projection.

So the edit event reports the passive effects on session endpoints directly. These are not interaction events: they advance no interaction revision and don't claim that the session did anything. They are consequences of the document mutation:

```
EditEvent = {
    ...
    splices          : RealizedSplice[]       -- in application order, old coordinates
    endpoint_effects : EndpointEffect[]
}

RealizedSplice = { start, old_end, new_end }

EndpointEffect = {
    session : SessionId
    anchor  : AnchorId
    old     : Position | Dead                 -- at old_revision
    new     : Position | Dead                 -- at new_revision
}
```

The payload can stay small, because rebasing is plain arithmetic outside each splice's closed region. An anchor before `start` doesn't move. An anchor after `old_end` shifts by `new_end - old_end`. Only anchors within `[start, old_end]` depend on stickiness, the requested operation and projection; the engine already branches on exactly that condition while rebasing. The rule, then:

> `endpoint_effects` lists every session endpoint that lay within the closed region of at least one splice when that splice was applied, and every endpoint resurrected by the transition. Every other session endpoint moved by composing the splices' shifts.

An observer maintains session state by shifting the unlisted endpoints and overwriting the listed ones. The cost scales with the number of endpoints near the edit rather than with the total. The worst case is many cursors editing at once, where every cursor sits at its own splice and is listed. We should measure that case, for instance a thousand carets inserting one character each.

The alternative is to report every endpoint whose position changed. That is simpler to state, but a single insertion near the start of a document would then list every endpoint after it. Either way, document replay (deriving effects from requested operations and text) stays a separate capability, not something the causal stream relies on.

Resurrection is now a case of this rule rather than a separate list. Undo's revived session endpoints appear as `Dead → Position`, and deaths appear as `Position → Dead`.

### Blocks

```
Block =
    | Transition {                       -- one committed intent
        sequence     : nat
        intent       : IntentId
        source       : EventSource
        label        : string | None     -- D13
        edit         : EditEvent | None
        interactions : InteractionEvent[]   -- in application order
      }
    | Lifecycle {                        -- one intrinsic session request
        sequence : nat
        request  : IntentId
        change   : SessionCreated { session, selections, document_revision }
                 | SessionDropped { session, interaction_revision }
      }
```

- **Sequence:** gapless per buffer instance, starting at zero. Every committed intent and every session lifecycle request takes exactly one number. Rejections take none.
- **Instance:** one engine, from construction to destruction. A reopened or restarted buffer is a new instance, and its sequence restarts. The protocol envelope carries `(buffer, instance, sequence)`, and the host stamps the first two (D15). A sequence number is meaningful only together with its instance, so a restart can't be mistaken for a continuation.
- **Watermark:** a snapshot records the instance and `next_sequence`, the number of the first block it does *not* reflect. A snapshot of a fresh instance has `next_sequence = 0`, and an observer consumes blocks whose sequence is at least the watermark. That avoids a "before the first block" sentinel, which "last block seen" would need.

### Interaction values and revisions

Each `InteractionEvent` names one `document_revision`, the revision after the block's edit if there is one, and its endpoint values are positions at that revision. Its `old` value is the selection state *after* the edit's passive effects. The difference between `old` and `new` is then exactly the explicit change, and the edit event accounts for everything before it. Endpoint values are `{ anchor, role, position | Dead }`, so a delta shows which identities were kept, moved, created or released, and when a role swap changed stickiness.

### Accepted no-ops

Every accepted intent commits: it advances the revisions its payload addresses and produces a block, even when the result is indistinguishable from the old state. For buffer operations, that has consequences beyond a redundant revision, and the contract should state them:

- the document revision advances, so the buffer becomes dirty under revision-based dirty state;
- an undo entry is recorded, and undoing it is itself a committed transition;
- the redo branch is discarded, as for any edit.

Identical resulting bytes would be the wrong test for a no-op anyway. The table above shows a replacement that leaves the text unchanged while killing an anchor. The alternative, a `NoOp` verdict without a block, would need a semantic comparison the client can't predict either. Tests: a buffer mutation whose result equals the old text advances the revision, marks the buffer dirty, records an undo entry, discards redo and produces a block; an identical `SetSelections` advances the interaction revision and produces a block with an empty delta.

### Intent identity

Every intent carries a mandatory, opaque 128-bit `IntentId` (D11). The engine echoes it in the block or report and never interprets, deduplicates or validates it for uniqueness. Supplying an identifier correlates; it doesn't promise exactly-once execution. A convenience function in the Zig API can generate one for callers that don't care. Session lifecycle requests take the same kind of identifier, so every block is attributable. Client anchor requests don't, since they produce no blocks.

## 4. Interception

Every mutation enters through a declared public request. Document and interaction changes use intents. The listed lifecycle operations (`create_anchor`, `drop_anchor`, `create_session`, `drop_session`) use intrinsic requests. Nothing else changes state, and notification callbacks remain read-only, with re-entrant mutation refused as it is now.

This is a *host-mediated* interception contract, and the responsibilities divide:

- **Litura** makes every request an inspectable data value, provides no privileged bypass (D8), and gives each request a defined effect on state and on the stream.
- **The host** routes both kinds of request through a pipeline that extensions can observe, transform, reorder or refuse before they reach the engine.

A function that accepts a data structure isn't, by itself, an interception hook for anybody else. §0.1's reflection principle is met only when a host provides that pipeline, and the SPEC should say so instead of implying the request types are enough. Intrinsic requests going through the pipeline doesn't make them editing commands: session teardown still records no history.

A later engine-level `prepare`/`commit` split could let an interceptor see the exact block a request would produce before committing it. That is an optimisation for hosts that want precise previews, not a requirement for §0.1, and I'd leave it out of v0.1.

## 5. Order and impact

The halves share one piece of machinery: prepared transitions with provisional identities. I would build them in this order, each step with SPEC changes, exhaustion sweeps and comparator coverage:

1. Handle states, the issuance boundary and reclamation (§1). This is independent of the rest and closes the last known anchor leak.
2. `SetSelections` with simultaneous resolution, registers and session lifecycle on prepared transitions (§2), with the old operations and direct mutators removed (D7, D8).
3. Blocks with endpoint effects, identity, provenance and owned reports (§3, D10–D14), with providers receiving the block. This step includes measuring the many-cursor case.

junc changes in three places: session creation, its one `place_cursor` call (now `SetSelections` with `Move` for the point), and the result type. Its current convention matches the role-based stickiness, so its behaviour doesn't change.

## Decisions for review

| | Question | Proposal |
| --- | --- | --- |
| H1 | Handle states | Live, Dead (no position, no eligibility promise), Disposed, Invalid; idempotent drop of Disposed |
| H2 | Distinguishing Disposed from Invalid | Identities issued at publication; aborts leave the boundary unchanged; endpoints created and released within one transaction are issued; internal anchors in their own namespace |
| H3 | Resurrection eligibility | Not exposed in v0.1 |
| H4 | Reclamation | Public anchors never reclaimed; internal targets live while needed (reference count as the implementation) |
| S1 | Endpoint ownership | Session-owned; `drop_anchor` refuses them; no transfer or borrowing |
| S2 | Identity across `SetSelections` | `Keep` / `Move` / `New`; unmentioned endpoints released; `Keep` preserves identity and geometry; dead endpoints can't change role |
| S3 | Target interpretation | Sample (`Position`, `Edit`, `AnchorPosition`) vs retain (`Keep`, `Move`) |
| S4 | Resolution order | Simultaneous within one `SetSelections`; sequential across operations |
| S5 | Stickiness | By role, as a normative v0.1 session policy |
| S6 | Slot order | `start`/`end` are slots; derived status orders by position |
| E1 | Stream scope | Document revisions, session existence and full interaction state; exclusions listed |
| E2 | Edit event payload | Ordered realized splices plus endpoint effects for session endpoints in a splice's closed region or resurrected; others follow by shift |
| E3 | Lifecycle blocks | Session create/drop take a sequence number, no revision; client anchors excluded |
| E4 | Sequence | Gapless per instance from zero; envelope `(buffer, instance, sequence)`, host-stamped; snapshots carry `next_sequence` |
| E5 | Interaction positions | One `document_revision` per event; `old` is after the edit's passive effects |
| E6 | No-ops | Every accepted intent commits; buffer no-ops still dirty, record undo and discard redo |
| I1 | Interception | Host-mediated: intents and declared intrinsic requests through the host pipeline; notifications read-only |
