# Litura: Core Protocol Spec [v0.1]

Litura is a Causal Editor State Machine. It defines a causal, reflective editor
protocol with stable observable semantics across its declared capability
surface. Conforming implementations may differ internally so long as that
surface remains consistent.

## 0. Status

v0.1 is a draft, i.e., *not stable*. Derived from a pre-spec design document
and refined against the Python prototype.

### 0.1 Extension Reflection Principle (Normative)

The engine must not rely on privileged, host-only state transition pathways for
any built-in editor behavior that affects protocol-visible text, structure, or
interaction state.

Any such behavior must be representable, observable, and interceptable through
the same public evaluation, intent, and event machinery available to extensions.

**Declared requests (normative):** every state change enters through a declared
public request. Document and interaction changes are intents (§4.2). The
intrinsic requests are exactly `create_anchor`, `drop_anchor` (§1.4),
`create_session` and `drop_session` (§2.6.3). An engine offers no other way to
change protocol-visible state; in particular, no public function moves an
anchor or edits a session outside an intent.

**Interception is host-mediated (normative):** requests are inspectable data
values, so a host can route intents and intrinsic requests through a pipeline in
which extensions observe, transform, reorder or refuse them before they reach
the engine. The responsibilities divide: the engine makes every request an
inspectable value, provides no privileged bypass, gives each request a defined
effect on state and on the event stream (§7), and keeps notification read-only
(a component notified of a published block cannot change engine state). The
host provides the interception pipeline itself. The existence of request types
does not by itself give any extension an interception hook; an engine
conforms to this section when the host exposes that pipeline. Routing an
intrinsic request through it does not make the request an editing command:
session teardown, for instance, records no history.

Host-owned embedded UI surfaces that do not operate over shared protocol objects
are non-reflective interfaces. They are outside the protocol boundary and must
not participate in synchronous evaluation, guard validation, or atomic
application.

Editor-shell customization surfaces such as keybindings, minibuffer prompts,
status-line formatting, terminal colors, and local command registration are
also outside the core protocol. They may be provided by a host editor, but they
do not define engine conformance.

### 0.2 Protocol Scope (Normative)

v0.1 of this protocol defines single-client, multi-extension concurrency. The
engine acts as the authoritative sequencer for a single active editing session
and its connected reflective extensions.

Multi-client collaborative editing (e.g., networked OT or CRDT) is explicitly
out of scope for v0.1. Implementations requiring multi-user sync must build
conflict-resolution layers strictly above this engine.

Section §11 lists open items for v0.1. Remaining open items are

4. **Program representation**
5. **Summary algebra extensibility**
8. **Multi-buffer intents**
10. **Concurrency model**

---

## 1. Foundational Types

### 1.1 Buffer

```
Buffer = {
    id        : BufferId
    stores    : Store[]
    pieces    : Piece[]
    revision  : Revision
    anchors   : AnchorSet
    summaries : SummaryIndex
}

Store = {
    id   : StoreId
    data : byte[]          -- immutable, append-only
}

Piece = {
    store  : StoreId
    offset : nat
    length : nat
}
```

Logical text is the concatenation of `pieces` in order, resolved against
`stores`.

`Piece` is internal. No message in this protocol accepts or returns `Piece`
references.

### 1.2 Revision

```
Revision = nat

RevisionStamp = {
    buffer   : BufferId
    revision : Revision
}
```

Revisions are monotonically increasing per buffer. Every mutation produces
exactly one new revision. All queries, evaluations, and intents are scoped to a
specific revision.

### 1.3 Logical Position and Range

```
Position = nat                  -- logical grapheme offset into logical text
Range    = { 
    start: Position, 
    end: Position 
}                               -- half-open [start, end)
```

Positions and ranges are valid only within the revision they were computed from.

Protocol-visible positions are measured in logical grapheme clusters. This
keeps editor-visible movement, selection, and span reporting aligned with the
interaction model. Storage backends, program carriers, and derived-view
providers may maintain byte offsets internally, but byte offsets are not the
public coordinate type for `Position` or `Range`.

When a carrier or provider uses byte-oriented data internally, it must define a
deterministic conversion boundary to protocol positions. In particular,
tree-sitter-style syntax providers operate over UTF-8 bytes internally but must
return normalized protocol ranges at the engine boundary.

**Segmentation profile (normative).** Grapheme clusters are UAX #29 extended
grapheme clusters for one Unicode version. The profile is fixed for the lifetime
of a buffer. For the same text and profile, grapheme boundaries must be
identical regardless of storage layout or of the sequence of edits that
produced the text. Revisions, undo history, and anchor positions may depend on
editing history; the segmentation of a given text may not.

**Grapheme lengths belong to ranges, not to text.** A `Position` addresses a
boundary of one revision's text. Grapheme counts are not additive under
concatenation: `e` followed by U+0301 COMBINING ACUTE ACCENT is one grapheme,
not two. An edit can therefore remove or create boundaries outside the range it
targets (§1.4). Free-standing inserted text has no protocol grapheme length; a
grapheme length is only defined for a range of a specific revision.

### 1.4 Anchor

```
Anchor = {
    id         : AnchorId
    stickiness : Weak | Sticky
    status     : Live | Dead
}

-- derived editor/session-layer pairing over intrinsic anchors
AnchorRange = {
    start : AnchorId
    end   : AnchorId
}

RangeStatus =
    | Live       { start: Position, end: Position }  -- both alive, start < end
    | Collapsed  { position: Position }              -- both alive, start = end
    | Degenerate { surviving: AnchorId,
                   position: Position,
                   lost: Start | End }               -- one alive, one dead
    | Dead                                           -- both dead
```

Anchors are engine-managed durable references. They persist across revisions and
are rebased deterministically by the engine.

`AnchorRange` and `RangeStatus` are interpretations over anchor ids, not
intrinsic engine-managed objects. The engine owns anchor creation, rebasing,
lifecycle, and query. Interpreting a pair as `Live`, `Collapsed`, `Degenerate`,
or `Dead` orders its endpoints by position. For a session's selections, whose
endpoints the session owns (§2.6), `start` and `end` are slots rather than an
order: rebasing can move a selection's `start` past its `end`, and the derived
status still orders positions geometrically while the active edge keeps
identifying the point.

Anchor resurrection is not modeled on the anchor itself. It is driven
exclusively by the undo system (see §1.6).

#### Rebasing Algebra

Let an anchor be `A = (p, s)` where `p` is the logical position and
`s ∈ {0, 1}` encodes stickiness (`0` = Weak, `1` = Sticky).

Let `E` range over primitive buffer edit events in the rebasing algebra. In v0.1,
the primitive edit events are insertion and deletion:

```
E = E_ins(i, L) | E_del(d_s, d_e)
```

where `E_ins(i, L)` inserts text of `L` code points at offset `i`, and
`E_del(d_s, d_e)` deletes the half-open interval `[d_s, d_e)`.

**Algebra coordinates.** The transforms below are stated over code-point offsets
into the logical text, not over grapheme `Position`s. Code-point lengths are
additive under concatenation; grapheme lengths are not (§1.3). Code-point
offsets are internal to the algebra: an engine may use any additive encoding
coordinate (for example UTF-8 bytes) with the same result. Protocol-visible
anchor positions are obtained by projecting the result onto the new revision's
grapheme boundaries (see *Projection* below). Where no boundary appears or
disappears, the transforms read identically with grapheme positions and
grapheme lengths.

Let `T(A, E) → A'` be the rebasing function, where `A'` is either `(p', s)` or
`DEAD`.

**Insertion.** For `E_ins(i, L)` — insertion of `L` code points at offset `i`:

```
T_ins((p, s), E_ins(i, L)) =
    (p, s)           if p < i
    (p + L, s)       if p > i
    (p + L·s, s)     if p = i
```

When `p = i`: Weak anchors hold their logical position; Sticky anchors move
past the inserted text and therefore follow the inserted run.

**Deletion.** For `E_del(d_s, d_e)` deletion of half-open interval `[d_s, d_e)`:

```
T_del((p, s), E_del(d_s, d_e)) =
    (p, s)                      if p ≤ d_s
    (d_s, s)                    if d_s < p < d_e and s = 1
    DEAD                        if d_s < p < d_e and s = 0
    (p - (d_e - d_s), s)        if p ≥ d_e
```

Anchors exactly at deletion boundaries survive. Sticky anchors strictly
interior to the deleted region clamp to the deletion start. Weak anchors
strictly interior to the deleted region die.

**Design choice (normative):** This protocol adopts boundary-preserving
deletion semantics with sticky interior clamping. An anchor at position `d_s`
or `d_e` is not killed by `E_del(d_s, d_e)`. A Sticky anchor strictly interior
to the deleted interval clamps to `d_s`; a Weak anchor strictly interior to the
deleted interval dies. Other systems choose boundary-collapsing semantics where
endpoints are also killed, or they kill all interior anchors regardless of
insertion-edge behavior. This protocol explicitly rejects those choices.

The rationale is twofold: anchors can mark boundaries of a region and survive
deletion of that region, and cursor-like anchors can remain spatially
continuous through deletion while mark-like anchors can still die when their
interior text disappears.

Extensions that need "die if the region is touched at all" semantics should use
content guards (`SliceHash`, `SliceEquality`) rather than relying on anchor
death.

**Replacement.** `E_repl(d_s, d_e, L)` — replace `[d_s, d_e)` with text of `L`
code points — is the strict composition of deletion followed by insertion at
the deletion start:

```
T_repl(A, E_repl(d_s, d_e, L)) = T_ins(T_del(A, E_del(d_s, d_e)), E_ins(d_s, L))
```

This decomposition is normative and *internal* to one operation. `T_del` and
`T_ins` are composed over code-point offsets with no committed state, no
resegmentation and no projection between them; the result is projected once
(*Projection granularity*, below). It is not a statement about executing a
`Delete` operation and then an `Insert` operation. Engines must not implement
replacement as an "in-place swap" that preserves interior anchors.
Consequences, in code-point offsets:

- Anchor at `d_s` with Weak stickiness: survives deletion, stays at `d_s`
    (holds position through the subsequent insertion).
- Anchor at `d_s` with Sticky stickiness: survives deletion, moves to `d_s + L`
    (follows the replacement text).
- Anchor strictly inside `(d_s, d_e)` with Weak stickiness: killed by deletion.
    `T_ins` short-circuits on `DEAD`.
- Anchor strictly inside `(d_s, d_e)` with Sticky stickiness: clamps to `d_s`
    during deletion, then moves to `d_s + L` under the subsequent insertion.

#### Requested Edits and Realized Splices

Every `BufferOp` (§4.1) is a *requested edit*: replace the grapheme range
`[r_s, r_e)` of the current text state with UTF-8 text `T` (`Insert` has
`r_s = r_e`; `Delete` has empty `T`). The requested edit does not determine
how many graphemes the result contains, because `T` can merge with its
neighbours and change boundaries beyond `[r_s, r_e)`.

The *realized splice* of a requested edit is the minimal grapheme range of the
old revision whose rewrite accounts for every changed boundary:

```
Splice = {
    start   : Position   -- ≤ r_s; a boundary in both revisions
    old_end : Position   -- ≥ r_e; old-revision coordinate
    new_end : Position   -- new-revision coordinate
}
```

- `start = r_s` if `r_s` is still a boundary after the edit; otherwise
  `r_s - 1`.
- `old_end` is the least old boundary `q ≥ r_e` whose image after the edit is
  also a boundary of the new text.
- `new_end` is `start` plus the number of graphemes in the new text between
  `start` and the image of `old_end`.

Old graphemes `[start, old_end)` become new graphemes `[start, new_end)`.
Graphemes outside the splice are unchanged in content, and positions at or after
`old_end` shift by `(new_end - start) - (old_end - start)`. The splice is
*aligned* when `start = r_s` and `old_end = r_e`. Graphemes inside the splice
but outside `[r_s, r_e)` are *context*: they are rewritten, not deleted.

Example: in `e`, inserting U+0301 at `1` realizes the splice `[0, 1) → [0, 1)`.
The text changed; the grapheme count did not. In `e␤◌́` (three graphemes),
deleting `[1, 2)` realizes `[0, 3) → [0, 1)` with result `é`.

**Locality (normative, profile-qualified).** For the extended grapheme cluster
rules of the buffer's profile, an engine may rely on, and must verify for its
Unicode version, two properties:

1. A boundary depends only on the text before it and the single code point
   after it. An edit therefore cannot change boundaries before `r_s`, and a
   splice widens left by at most one grapheme.
2. Segmentation restarted at any boundary reproduces whole-text segmentation
   after that boundary. Regional-indicator pairing (GB12/GB13) is the only rule
   that looks back across a boundary, and a boundary between two indicators
   implies an even count of indicators before it. Once old and new
   segmentations share a boundary after the edit, they agree from there on.

Neither property bounds the right extent. One regional indicator inserted
before a run of `2k` indicators re-pairs the entire run, so `old_end - r_e` is
unbounded. Individual graphemes are also unbounded in length (combining-mark
runs, Hangul jamo runs, Indic conjuncts, emoji ZWJ sequences). Realizing a
splice costs time proportional to its extent; engines must not truncate a
splice to bound that cost. Both properties hold for every case of the Unicode
16.0.0 `GraphemeBreakTest.txt`; an engine adopting another Unicode version must
re-verify them against that version's data.

**Projection (normative).** An anchor `(p, s)` is rebased across a requested
edit by applying `T_repl` to its code-point offset with the requested deletion
`[r_s, r_e)` and the code-point length of `T`, then projecting the result `c'`
onto the new revision's boundaries:

```
project(c', Weak)   = greatest new boundary ≤ c'
project(c', Sticky) = least new boundary ≥ c'
```

When `c'` is a boundary, both cases return it. Otherwise the anchor's boundary
has disappeared, and each stickiness keeps its defining guarantee relative to
the inserted text: a Weak anchor stays before every inserted code point, and a
Sticky anchor stays after every inserted code point. The cost is that the anchor
also crosses the neighbouring text that the inserted text merged with.

- In `e`, insert U+0301 at `1`. Weak `1 → 0`; Sticky `1 → 1`.
- In `🇳🇴🇸🇪`, insert `🇦` at `0`. The result pairs as `(🇦🇳)(🇴🇸)(🇪)`.
  An anchor at old position `1` lands inside `(🇴🇸)`: Weak `1 → 1`,
  Sticky `1 → 2`.

Positions outside the splice need no projection. Inside an aligned splice the
rule reduces exactly to the grapheme formulas above, with `L = new_end - start`.

**Non-deletion rule (normative).** Resegmentation is not deletion. Only the
requested deletion `[r_s, r_e)` kills anchors, under `T_del`: Weak anchors
strictly inside `(r_s, r_e)` die. An anchor whose boundary disappears through
resegmentation, including any anchor inside the splice's context, is projected
and never killed, and creates no `DeletionMeta` record (§2.5.2).

**Projection granularity (normative).** Projection is applied once per
`BufferOp`, onto the boundaries of the text state that operation produces.
Each operation in a payload produces such a state, even though the payload
commits a single revision (§4.1). Two levels of composition must therefore be
distinguished:

- *Internal decomposition.* Within one operation, `T_repl = T_ins ∘ T_del`
  holds exactly over code-point offsets, as stated under *Replacement*.
  Neither the text nor the coordinates are resegmented between the two steps.
- *Sequential operations.* Across operations, each operation is resegmented
  and projected before the next is resolved. The next operation's grapheme
  coordinates refer to that resegmented state.

A `Replace` operation is therefore not equivalent to a `Delete` operation
followed by an `Insert` operation, in text or in anchors, whether the two are
in one payload or in separate intents. In `e␤◌́`:

- `Replace([1, 2), "a")` yields `e` `á`: the inserted `a` takes the accent.
- `Delete(1, 2)` then `Insert(1, "a")` yields `é` `a`: after the deletion
  the text is the single grapheme `é`, so position `1` is after the accent.

**Composition.** Rebasing across sequential operations `e1, e2` equals rebasing
across `e1` then `e2`:

```
T(A, e1 · e2) = T(T(A, e1), e2)
```

where each `T` is the projected transform of one complete operation, applied
to the state that operation produced. This law composes operations; it does not
license an engine to split one operation into separately projected parts, or to
merge separate operations into one projection.

For live anchors, `T(DEAD, e) = DEAD` for all `e`. Dead anchors do not
participate in rebasing. Resurrection is handled exclusively by the undo system
(§2.5), not by the rebasing algebra.

**Tie-breaking.** Multiple insertions at the same logical position are ordered
by `(revision, operation_index)`. Anchors rebased across equal-position inserts
respect this total order.

#### Range Anchor Semantics

A `RangeStatus` is derived from the statuses of both endpoints. An `AnchorRange`
where one endpoint is `Dead` enters `Degenerate` state rather than dying
entirely. The surviving endpoint retains its position and can be queried.

- A `BracketEnclosure` guard on a `Collapsed` range: fails (no interior).
- A `BracketEnclosure` guard on a `Degenerate` range: fails, and the report
  includes which endpoint was lost.
- Extensions can use `Degenerate` state to trigger re-evaluation from the
  surviving position.

#### Anchor Lifecycle

Anchor creation and destruction are intrinsic engine operations, not buffer
mutations. They do not advance the revision.

```
create_anchor(buffer, origin_revision, position, stickiness) -> AnchorReceipt

AnchorReceipt = {
    id            : AnchorId
    status        : Live | Dead
    head_revision : Revision
}

drop_anchor(buffer, anchor_id) -> ()
```

**Handle states (normative):** a client's `AnchorId` refers to exactly one of:

| State | Meaning | `query_anchor` | `drop_anchor` |
|---|---|---|---|
| Live | Exists and has a position | `Live`, position | Disposes it |
| Dead | Exists, has no position | `Dead` | Disposes it |
| Disposed | Its owner ended its lifetime | `Disposed` | No-op, succeeds |
| Invalid | Never issued as a public anchor | error | error |

`Dead` describes the absence of a position. It does not promise that any
reachable undo entry can still resurrect the anchor, and engines do not expose
resurrection eligibility in v0.1. `Disposed` is terminal. `Invalid` covers
identifiers nobody was given, including every internal anchor's.

**Issuance (normative):** a public anchor identity is issued only when the
receipt or event block (§7) that creates it is published. Preparation may assign
provisional identities, but a preparation that is abandoned, whether rejected
or failed, leaves the issued-identity boundary unchanged and exposes none of
them. The boundary is the transaction, so two cases differ:

- An endpoint created and released while one transition is prepared, in a single
  interaction mutation or across the parts of a composite, exists only in
  provisional state. It never appears in a published block and is never issued.
- An endpoint published by one transition and released by a later one is
  issued, then terminal: the first block shows its creation, the later one its
  release, and queries afterwards report it `Disposed`.

Every issued identity therefore appears in some receipt or published block, and
an engine can tell a disposed identity from an invalid one without retaining a
record per disposal.

A session's selection endpoints are public anchors owned by the session (§2.6).
`drop_anchor` refuses them with an explicit error rather than leaving the
session referring to nothing; they are released by the session's own
interaction mutations or by `drop_session`. The creation, disposal and passive
movement of client-created anchors are outside the event stream (§7.3); their
creator holds the receipt and can query them.

If the requested position was deleted between `origin_revision` and
`head_revision`, the engine returns a valid `AnchorId` initialized with `status:
Dead`. The extension discovers this through the receipt and can decide whether
to re-evaluate. Rebasing the position from `origin_revision` follows the
engine's rebase policy (§6.2); a request the policy cannot interpret is
rejected without creating an anchor.

A `Dead` anchor may not be used as a mutation target. It may be queried (returns
`Dead` status).

**Identity rule (normative):** `AnchorId` is unique within the lifetime of its
buffer and must not be reused, even after the anchor is dropped or reclaimed by
GC. Engines that compact anchor storage must preserve identity, not recycle
identifiers.

**Disposal rule (normative):** `drop_anchor` is terminal. No later operation,
including an undo or redo whose `DeletionMeta` (§2.5.2) recorded the anchor,
may bring a dropped anchor back. Undo restores the text and resurrects the
other anchors of that deletion; the dropped anchor stays gone. This is a
separate guarantee from the identity rule: non-reuse says the identifier will
never name a different anchor, while disposal says it will never name this one
again.

**Internal anchors (normative):** an engine may create anchors for its own
bookkeeping, such as the `target_anchor` of a deletion (§2.5.2) or anchors that
carry a buffer operation's result through later operations in the same
payload. These are not part of the public anchor namespace. Anchor queries,
`drop_anchor`, guards, anchor position references and selection targets treat
an internal anchor's identifier as unknown, even if a caller guesses it, and an
internal identifier is never one a client could have been issued. Internal
anchors still rebase like any other anchor. An internal anchor lives exactly as
long as the engine needs it; how the engine tracks that is not specified.

### 1.5 Summary Algebra

```
Summary = {
    length        : nat
    newline_count : nat
    bracket_depth : BracketSummary  -- extensible per engine profile
}

BracketSummary = {
    net   : int                     -- net bracket depth change
    p_min : int                     -- minimum prefix depth relative to entry
}
```

Summaries compose associatively:

```
compose(a: Summary, b: Summary) -> Summary = {
    length        = a.length + b.length
    newline_count = a.newline_count + b.newline_count
    bracket_depth = compose_bracket(a.bracket_depth, b.bracket_depth)
}

compose_bracket(a: BracketSummary, b: BracketSummary) -> BracketSummary = {
    net   = a.net + b.net
    p_min = min(a.p_min, a.net + b.p_min)
}
```

The `SummaryIndex` supports prefix queries:

```
summary_to(position: Position) -> Summary
summary_range(range: Range) -> Summary
```

Implementation (Fenwick tree, balanced tree, etc.) is not normative. The algebra
and query interface are.

Composition is defined for adjacent ranges of one revision that meet at a
grapheme boundary. It is not a rule for concatenating independently summarized
text: `summary("e")` composed with `summary(U+0301)` is not
`summary("e" + U+0301)`. An engine that stores summaries per storage unit must
either keep every unit boundary at a grapheme boundary of the logical text, or
correct the junctions where it does not.

#### Summary Extensibility

Extensions do not define summary algebra. Engines expose a fixed, associative
family of aggregations.

**Core summaries** (`length`, `newline_count`, `bracket_depth`) are mandatory
and defined above. `BracketSummary` is a composite summary with a non-trivial
composition rule; composite summaries with custom composition are core-only and
cannot be expressed through the extensibility registry.

**Optional summaries** are profile-defined, declared at engine startup, and
discoverable via registry:

```
SummaryRegistry = SummaryFeature[]

SummaryFeature = {
    field    : string
    type     : Int32 | UInt32 | Bool | Option<Int32> | Option<UInt32>
    identity : Value
    operator : Operator
}

Operator =
    | SUM         -- identity: 0
    | MIN         -- identity: None (operates over Option<Value>)
    | MAX         -- identity: None (operates over Option<Value>)
    | FIRST       -- identity: None (left projection over Option<Value>)
    | LAST        -- identity: None (right projection over Option<Value>)
    | BIT_OR      -- identity: 0
```

All operators must be associative: `A ⊕ (B ⊕ C) = (A ⊕ B) ⊕ C`. This ensures
safe tree aggregation, compaction invariance, and deterministic summary queries.

`MIN`, `MAX`, `FIRST`, and `LAST` operate over `Option<Value>` with `None` as
identity. `FIRST(None, x) = x`, `FIRST(x, None) = x`, `FIRST(x, y) = x`. `LAST`
is symmetric. `MIN(None, x) = x`, `MIN(x, y) = min(x, y)`. This avoids sentinel
values and composes cleanly over empty spans.

**Program dependency declaration.** Programs that depend on optional summary
fields must declare them in the `EvalRequest`. If a required field is absent
from the engine's registry:

```
ViewUnavailable { missing_summary_field: string }
```

**Access semantics.** `query_summary` returns a key-value structure. Unknown
fields are ignored. Fields are opaque unless the program explicitly declared a
dependency on them.

This model intentionally restricts extensibility: it preserves O(log N) summary
performance, avoids extension-defined computation in the engine core, and keeps
the summary algebra closed and predictable. It is a controlled expansion
surface, not a general extensibility mechanism.

### 1.6 Message Taxonomy

The protocol defines a strict bipartite message boundary between the engine and
the client (which hosts the UI and extensions).

**Inbound messages (Client → Engine):**

| Message | Semantics |
|---|---|
| `EvalRequest` | Initiates synchronous, isolated, bounded execution |
| `SubmitIntent` | Submits a state transition request |
| `CreateAnchor` | Synchronous anchor creation (intrinsic request) |
| `DropAnchor` | Synchronous anchor disposal (intrinsic request) |
| `CreateSession` | Synchronous session creation (intrinsic request, §2.6.3) |
| `DropSession` | Synchronous session teardown (intrinsic request, §2.6.3) |

**Outbound messages (Engine → Client):**

| Message | Semantics |
|---|---|
| `EvalResponse` | Synchronous result of an `EvalRequest` |
| `AnchorReceipt` | Synchronous result of a `CreateAnchor` |
| `ValidationReport` | Rejection of a `SubmitIntent`; publishes nothing |
| `Block` | The canonical record of one committed intent or session request, returned at commit and delivered to other subscribers by the host (§7) |

**Tier 1 intrinsic queries** (`query_capabilities`, `query_position`,
`query_line`, `query_bracket_match`, `query_summary`, `query_anchor`) are
synchronous request/response pairs. They are not listed separately because they
do not alter engine state and their message shape is defined by their return
types in §5.1.

---

## 2. Views

A **view** is an engine-maintained derived index over buffer state. Views are
optional except where marked mandatory. Providers that build views (tree-sitter,
LSP, regex scanners, custom parsers, etc.) are implementation details; the
protocol boundary is the normalized view capability and query surface.

```
ViewClass =
    | Text              -- mandatory: raw logical text access
    | Anchors           -- mandatory: anchor resolution
    | Summaries         -- mandatory: prefix-searchable structural summaries
    | Tokens            -- optional: lexical token stream
    | Syntax            -- optional: syntax tree / node model
    | Diagnostics       -- optional: diagnostic message stream
    | SemanticTokens    -- optional: rich token classification
    | TypeInfo          -- optional: type/signature at position
    | Symbols           -- optional: definitions, references, rename
    | Hover             -- optional: documentation/info at position

ViewSet = set of ViewClass

ViewTransport =
    | PushBacked        -- host pushes revision-scoped data arrays
    | CallbackBacked    -- engine routes queries to registered provider

ViewState =
    | Available   { revision: Revision }
    | Absent
    | Stale       { available_revision: Revision | None }
    | Partial     { revision: Revision, reason: string | None }
    | Unavailable { reason: string }
```

**View transport (normative).** Every optional view class has a declared
transport that determines its adapter registration pattern and staleness
model:

| ViewClass | Transport | Adapter Pattern |
|---|---|---|
| Tokens | PushBacked | Host pushes `TokenSpan[]` with revision tag |
| Syntax | CallbackBacked | Engine routes node queries to registered provider |
| Diagnostics | PushBacked | Host pushes `Diagnostic[]` with revision tag |
| SemanticTokens | PushBacked | Host pushes `SemanticToken[]` with revision tag |
| TypeInfo | CallbackBacked | Engine routes point queries to provider |
| Symbols | CallbackBacked | Engine routes point queries to provider |
| Hover | CallbackBacked | Engine routes point queries to provider |

**Push-backed views** are revision-scoped: the host pushes a data array
tagged with the revision it covers. `ViewState.Available { revision }` means
data at that revision is stored and queryable. A committed buffer mutation
marks the view `Stale`. The host re-pushes data at the new revision to
restore `Available`.

**Callback-backed views** are also revision-scoped. The query carries a
revision parameter, and the provider must answer coherently for that
revision. The provider signals readiness at a revision without pushing data;
the engine updates `ViewState` accordingly. If the buffer advances past the
provider's declared revision, the view becomes `Stale`. The provider catches
up by signaling readiness at the new revision.

Transport differs; causal semantics do not. All view queries across both
transport classes are revision-parametric and subject to the same snapshot
consistency rule.

Every engine must provide `Text`, `Anchors`, and `Summaries`. Optional views are
declared by engine capability profile.

**Engine ownership:** Protocol-visible views are owned by the engine revision
cycle. A committed buffer mutation invalidates or advances derived views under
engine control. Clients and controllers may poll view state, but they do not
reconstruct canonical view freshness by replaying buffer edits outside the
engine.

**Snapshot consistency:** All views accessed during evaluation must be
consistent with the declared revision. If an optional view exists but has not
yet been updated to the requested revision, the engine must return
`ViewUnavailable { missing_view, state: Stale { available_revision } }`
rather than serve stale data.

**Provider opacity:** Provider-native identities and data structures are not
protocol values. An implementation may use tree-sitter nodes, LSP objects, or
any other internal representation, but it must expose only normalized protocol
objects.

### 2.0.1 Token View

The `Tokens` view exposes bounded lexical or highlight-oriented spans:

```
TokenSpan = {
    range : Range
    class : TokenClass
    style : TokenStyle | None
}

TokenClass = string
TokenStyle = string
```

`TokenClass` and `TokenStyle` are normalized labels, not provider-native node
types. Engines may derive them from tree-sitter highlight capture names (for
example `keyword`, `string`, `comment`, `number`, `operator`) or from another
provider. Capture query languages such as `.scm` files are provider
configuration, not protocol syntax.

Token spans are advisory derived data. They may inform rendering, evaluation,
or guards, but they do not mutate text or interaction state.

### 2.0.2 Syntax View

The `Syntax` view exposes revision-scoped syntax node references:

```
SyntaxNodeRef = {
    provider : string
    revision : Revision
    id       : opaque
}

SyntaxNodeInfo = {
    ref      : SyntaxNodeRef
    kind     : SyntaxNodeKind
    range    : Range
    is_named : bool
}

SyntaxNodeKind = string
```

`SyntaxNodeRef` is ephemeral and revision-scoped. It is valid only for the
revision that produced it and must not be treated like a durable anchor. If a
client presents a `SyntaxNodeRef` at a later buffer revision, the engine must
reject it as stale. Durable identity across edits remains anchor- and
guard-based.

Syntax node kinds are normalized strings. Engines may choose the granularity
supported by their provider, but must not expose provider-native node handles as
public protocol objects.

### 2.0.3 Diagnostic View

The `Diagnostics` view exposes a revision-scoped, stably ordered diagnostic
stream aggregated from all registered sources:

```
Diagnostic = {
    range    : Range
    severity : DiagnosticSeverity
    code     : string | None
    source   : string              -- provider identity ("mypy", "eslint", etc.)
    message  : string
}

DiagnosticSeverity = Error | Warning | Info | Hint
```

`DiagnosticSeverity` is a closed enum with a total order:
`Error > Warning > Info > Hint`. Engines must not accept free-form severity
strings.

**Ordering (normative).** `query_diagnostic_list` results are stably ordered
by `(range.start asc, severity desc, source asc, code asc)`. Two conforming
engines with identical buffer state and identical pushed diagnostic arrays must
return them in the same order.

**Aggregation.** The engine aggregates diagnostics from all registered sources.
The `source` field provides attribution. Per-source filtering is a client-side
concern; the protocol does not expose per-source query variants at Tier 1.

**Staleness.** Diagnostics follow the standard push-backed staleness model: a
committed buffer mutation marks the view `Stale`. The host re-pushes
diagnostics at the new revision to restore `Available`. There is no
"diagnostics persist across mutations" special case — it would break the
revision-scoped read contract. Clients that wish to display stale diagnostics
with a visual indicator may do so, but the engine must not serve stale data
through `query_diagnostic_list` when the view state is `Stale`.

### 2.0.4 Semantic Token View

The `SemanticTokens` view exposes rich token classification derived from a
language-aware provider (typically LSP `textDocument/semanticTokens`):

```
SemanticToken = {
    range     : Range
    type      : string              -- "variable", "function", "class", etc.
    modifiers : string[]            -- "readonly", "deprecated", "static", etc.
}
```

`SemanticTokens` and `Tokens` are independent views with independent
staleness. A span may have both a `TokenSpan` and a `SemanticToken`. The
engine does not merge them. The merging policy (e.g., semantic tokens override
syntactic tokens for overlapping spans) is a client/renderer decision, not a
protocol concern.

Semantic token types and modifiers are normalized strings. Engines may derive
them from LSP semantic token types or from another provider, but must not
expose provider-native token identifiers as protocol values.

### 2.0.5 Type Info View

The `TypeInfo` view exposes type and signature information at a position,
routed to a registered callback-backed provider:

```
TypeResult = {
    range      : Range              -- extent of the typed expression
    type_text  : string             -- rendered type signature
    source     : string             -- provider identity
}
```

The query is revision-parametric. The provider must answer coherently for the
requested revision. If the provider has not caught up to the requested
revision, the engine returns `ViewUnavailable` with `Stale` state, consistent
with the unified staleness model.

### 2.0.6 Symbol View

The `Symbols` view exposes definition, reference, and rename queries, routed
to a registered callback-backed provider:

```
Location = {
    buffer   : BufferId | ExternalPath
    range    : Range
}

RenameInfo = {
    range       : Range             -- extent of the symbol to rename
    placeholder : string            -- current name
}
```

`ExternalPath` is an opaque string referencing a file outside the engine's
buffer set. The engine does not open or manage external files; it passes the
provider's answer through. Resolution of external paths is a client concern.

The `Symbols` view class covers a family of query kinds rather than a single
data model. Not all providers support all query kinds. Provider sub-capability
is declared through `SymbolCapabilities` in `EngineCapabilities` (§2.1).
Individual queries may return `NotSupported` if the registered provider does
not implement that query kind. `NotSupported` is distinct from `None` (the
provider looked and found nothing at this position).

```
NotSupported = {}       -- sentinel: provider does not implement this query kind
```

`NotSupported` is a protocol-level result variant, not an error. It indicates
a permanent capability gap in the registered provider, not a transient
failure. Clients should check `SymbolCapabilities` in `EngineCapabilities`
(§2.1) to avoid issuing queries that will return `NotSupported`.

### 2.0.7 Hover View

The `Hover` view exposes documentation and contextual information at a
position, routed to a registered callback-backed provider:

```
HoverResult = {
    range    : Range                -- extent of the hovered element
    content  : string               -- markdown-formatted content
    source   : string               -- provider identity
}
```

Content is markdown-formatted, consistent with LSP's `MarkupContent`. The
engine does not interpret or render the content.

`Hover` and `TypeInfo` are separate view classes despite similar transport
and query shape because their failure modes and semantics differ. Type
information is structural (a type signature is either available or not);
hover documentation is contextual and may vary in completeness without
constituting a failure. Independent `ViewState` allows the engine to
accurately report availability of each capability.

### 2.1 Capability Discovery

Before issuing evaluations or submitting intents that depend on optional
protocol features, a client must be able to discover the engine's supported
capability surface.

```
query_capabilities() -> EngineCapabilities

EngineCapabilities = {
    protocol_version      : string
    supported_views       : ViewSet
    symbol_capabilities   : SymbolCapabilities | None
    summary_registry      : SummaryRegistry
    supported_group_modes : GroupModeSet
    apply_policies        : ApplyPolicySet
    program_carriers      : ProgramCarrierProfile[]
    rebase_policy         : RebasePolicy      -- §6.2
    sequencing            : Sequencing        -- §6.1
    limits                : EngineLimits
}

Sequencing =
    | Queued         -- pending intents ordered by priority, then registration
    | Synchronous    -- each submission applied when made; no priority accepted

SymbolCapabilities = {
    definition : bool
    references : bool
    rename     : bool
}

GroupModeSet = set of Atomic | Ordered | Independent

ApplyPolicySet = set of Strict | DegradedPermit | Custom

ProgramCarrierProfile = {
    kind             : string
    version          : string
    deterministic    : bool
    fuel_model       : string
    max_program_size : nat | None
    notes            : string | None
}

EngineLimits = {
    max_fuel                 : nat
    max_lookahead            : nat
    lookahead_penalty_lambda : nat
    max_guard_extent         : nat
    max_intent_group_size    : nat | None
}
```

`program_carriers` declares which `Program` representations the engine accepts.
The core protocol remains carrier-agnostic; carrier support is profile-defined
and must be discoverable through `EngineCapabilities`.

**Normative constraint:** For any conforming carrier profile in v0.1, `fuel_model`
must be `"CanonicalAWU"`, indicating compatibility with the abstract cost model
defined in §5.3.

**Normative constraint:** `supported_views`, `summary_registry`,
`supported_group_modes`, `apply_policies`, `program_carriers`, `rebase_policy`,
and `sequencing` together define the complete protocol-visible optional feature
surface of the engine. A
client must not be required to infer support for any optional feature through
failed speculative requests alone.

**Normative constraint:** If `Symbols ∈ supported_views`, then
`symbol_capabilities` must not be `None`. If `Symbols ∉ supported_views`,
then `symbol_capabilities` must be `None`. This ensures clients can always
discover which Symbols sub-capabilities are available without issuing
speculative queries.

**Normative constraint:** `limits` must be sufficient for a client to bound
every protocol-defined resource-sensitive request before submission. At minimum,
the engine must advertise the maximum accepted fuel budget, maximum permitted
lookahead, lookahead penalty multiplier, maximum content-guard extent, and
maximum supported `IntentGroup` size when grouped composition is available.

**Stability rule:** `EngineCapabilities` must remain stable for the lifetime of
a connected session unless the engine explicitly renegotiates capabilities
through a profile/version transition outside the scope of this protocol draft.

---

## 2.5 Undo Model

### Design Principle

> Anchors model spatial continuity. Undo models historical restoration.

The anchor rebasing algebra must not encode resurrection. Resurrection is driven
exclusively by undo lineage — the causal link between a deletion and its inverse
— not by geometric coincidence (position and length matching).

### 2.5.1 UndoEntry

```
UndoEntry = {
    id            : UndoEntryId
    buffer        : BufferId
    forward_revs  : Revision[]
    inverse_ops   : BufferOp[]
    deletion_meta : DeletionMeta | None
}
```

Undo operates on `UndoEntry` objects, not on revisions directly. Revisions
remain linear and monotonically increasing. An `UndoEntry` groups one or more
forward revisions with a pre-computed inverse operation sequence.

**Normative constraint:** Inverse operations must be captured eagerly at commit
time. The engine must not attempt to reconstruct inverse operations from
revision history. Deleted text is retained via the existing immutable
piece-table stores.

**Normative constraint (splice inverse):** The inverse of a `BufferOp` is
derived from its realized splice (§1.4), not from the requested text:

```
inverse(op) = Replace { target: [start, new_end), text: old_text[start, old_end) }
```

where `old_text` includes the splice's context. Engines may write it as
`Insert` when `new_end = start`, or `Delete` when the old text is empty. A grapheme
length computed from the requested text must not be used. Example: inserting
U+0301 after `e` realizes `[0, 1) → [0, 1)`. Its inverse is `Replace([0, 1), "e")`,
which restores `e`; "delete one grapheme at 1" is out of range, and "delete
`[0, 1)`" removes too much. Applied to the revision its operation produced, an
inverse realizes an aligned splice, so undo and redo restore text exactly.

**Normative constraint (undo boundary):** Undo operations strictly capture and
restore buffer state. Interaction state (selections, registers) is not recorded
in the undo lineage. Pure interaction mutations do not generate an `UndoEntry`.
When undoing a `Composite` intent, only the `BufferOp`s are reverted. The
interaction state itself is not rolled back, nor does the `InteractionRevision`
advance (§2.6: no buffer edit advances it). Instead, the `AnchorId`s within selections passively undergo standard
geometric rebasing against the reverted buffer state (which may cause selections
to shrink, collapse, or become degenerate), while non-spatial interaction state
(active edge designations, register contents) persists unchanged.

### 2.5.2 DeletionMeta

When a mutation deletes text, the engine records metadata sufficient to
resurrect any anchors killed by that deletion:

```
DeletionMeta = {
    deletion_id   : DeletionId
    target_anchor : AnchorId
    inverse_text  : byte[]
    dead_anchors  : DeadAnchorRecord[]
}

DeadAnchorRecord = {
    anchor     : AnchorId
    offset     : nat              -- relative offset within deleted region
    stickiness : Weak | Sticky    -- original stickiness at time of death
}
```

A record may name a public anchor or the `target_anchor` of an earlier
deletion, which must survive for that deletion's own undo. Anchors scoped to a
single transaction are never recorded: they no longer exist when any undo could
run.

**Constraints:**

- Exactly one internal live anchor (`target_anchor`, §1.4) per deletion unit, placed at
    the realized splice's `start` with `Weak` stickiness. This anchor
    participates in normal rebasing and tracks coordinate drift from
    intervening edits. The splice start is used rather than the requested
    deletion start because the requested start can stop being a boundary: in
    `e␤X␤◌́`, deleting `[1, 4)` leaves `é`, and position `1` no longer exists.
- Dead anchors are stored as offsets relative to the splice start, not as
  absolute positions. This makes the metadata immune to coordinate drift.
  Undo restores the splice's old text at the target anchor, so `target + offset`
  is the anchor's original position.
- The `inverse_text` field references the splice's old text, including context
  (may be a reference into an immutable store rather than a copy).

### 2.5.3 Undo Application

When an `UndoEntry` is applied, its `inverse_ops` run in reverse order of the
original operations, as one buffer mutation that advances the revision once.
For each inverse operation that restores a deletion:

1. Apply the inverse operation, restoring the deleted text at the position of
   that deletion's `target_anchor`, `pos`.
2. For each `DeadAnchorRecord` in its `dead_anchors`: resurrect the anchor at
    `pos + offset` with its original `stickiness`, transitioning it from `Dead`
    to `Live`. A record naming a public anchor that was dropped is skipped
    (§1.4).
3. Destroy `target_anchor` (the internal tracking anchor is no longer needed).

Only then does the next inverse operation run. The offsets describe the text
immediately after this inverse operation, and a later inverse operation can
both move the resurrected anchors and need one of them: when the second of two
deletions in one entry covers the first deletion's `target_anchor`, undoing the
second must resurrect that target before the first can be undone.

A missing or dead `target_anchor`, or a missing internal anchor named by a
record, means the engine's history is inconsistent. The undo then fails as a
whole and has no effect; it is not treated as a disposal to skip.

Resurrection is atomic with the undo mutation. Extensions observe the anchor
transition from `Dead` to `Live` in the same revision step as the text
restoration.

**Intent routing:** Undo application is triggered by an `Undo` intent payload
(§4.2), not by an engine-internal bypass. The resulting block (§7) echoes the
undo intent's `IntentId` and has `source: UserInput` (if user-initiated) or
`source: Extension { id }` (if extension-initiated), and its edit event lists
every session endpoint the undo revived (§7.1). This ensures undo is
speculative-queue-compatible and observable by all subscribers.

### 2.5.4 Resurrection Rule (Strict)

> Anchors resurrect only when an UndoEntry restores its own deletion.

Resurrection is forbidden in all other cases:

- An unrelated insertion at the same position and length must not trigger
  resurrection.
- Manual re-insertion of identical text must not trigger resurrection.
- Only the `UndoEntry` that owns the `DeletionMeta` containing the dead anchor's
  record may resurrect it.

This is what distinguishes lineage-based resurrection from geometric matching.
The identity of the deletion — not its shape — is what authorizes restoration.

Anchors moved by projection (§1.4) are not dead, so undo does not restore their
earlier positions. They undergo ordinary rebasing across the inverse
operation. In `e`, a Weak anchor at `1` projects to `0` when U+0301 is
inserted; undoing the insertion leaves it at `0`. This follows the design
principle above: anchors model spatial continuity, and resegmentation does not
create undo lineage.

### 2.5.5 Redo

Redo is the inverse of undo: a forward re-application of the original mutation.
The engine re-captures a new `UndoEntry` for the redo operation, with the redo's
inverse being the original undo's inverse payload. Dead anchors killed by redo
follow the same `DeletionMeta` capture path.

### 2.5.6 GC Policy

Deletion metadata lifetime is tied to undo/redo reachability:

- When an `UndoEntry` becomes unreachable (e.g., new edits after an undo discard
  the redo branch), its `DeletionMeta` may be reclaimed.
- A public anchor named by reclaimed metadata loses only its resurrection path.
  It stays `Dead` until its owner disposes of it: its client, or the session
  whose selection holds it. Reclamation never disposes of a public anchor and
  never changes a session's selections.
- Internal anchors (§1.4), such as deletion targets, may be reclaimed once no
  reachable entry needs them. A target can be needed by an entry other than
  the one that created it: the edit that discards a redo branch can kill one
  of that branch's targets and record it for its own undo.
- Engines may coalesce adjacent deletions, compress interval metadata, and drop
  unreachable entries aggressively, provided undo correctness and anchor
  resurrection semantics are preserved.

Reclamation therefore changes nothing a client can observe and produces no
event. It does not permit `AnchorId` reuse.

---

## 2.6 Session and Interaction State

A buffer is shared, persistent text. A session is a situated, ephemeral act of
editing by a specific client or agent.

```
Session = {
    id          : SessionId
    buffer      : BufferId
    revision    : InteractionRevision
    interaction : InteractionState
}

InteractionRevision = nat

Selection = {
    range  : AnchorRange      -- endpoint slots; equal ids form a caret
    active : Start | End      -- dynamic edge (point) vs fixed edge (mark)
}

InteractionState = {
    selections : Selection[]  -- never empty
    registers  : map<string, InteractionValue>
}

InteractionValue =
    | String(string)
    | Int(int)
    | Bool(bool)
```

**Design note:** `Session` binds to a single `BufferId` in v0.1. Multi-buffer
sessions (split views, indirect buffers, transient contexts) are a future
extension. The coupling is intentionally minimal.

**Ownership (normative):** a session owns the anchors that form its selections,
its endpoints. Any client can query them, but only the session's own
interaction mutations change which anchors form its selections, where they are
placed explicitly, and their active edges; `drop_session` releases all of them.
Released endpoints are disposed (§1.4), so undo never revives them. Ownership
never transfers: a client-created anchor can supply a position for a selection
(§2.6.1) but never becomes an endpoint, and an endpoint never becomes a client
anchor.

**Selection identity (normative):** a selection is identified by its endpoint
anchors. A caret is a selection whose two slots name the same anchor. A
selection whose fixed endpoint is `Dead` is degenerate (§1.4); it keeps that
endpoint, and so remains eligible for its resurrection, until the session
itself changes the selection. A host may display a degenerate selection as a
caret; the engine does not rewrite it.

**Stickiness of endpoints (normative v0.1 policy):** the active endpoint of a
selection is `Sticky`, its fixed endpoint `Weak`, and a caret's anchor
`Sticky`. The engine assigns stickiness when a selection is installed, so an
interaction mutation that exchanges point and mark exchanges the stickiness of
the two live anchors. The rationale in §1.4 motivates this choice ("cursor-like
anchors can remain spatially continuous through deletion while mark-like
anchors can still die") without requiring it of every selection model; v0.1
adopts it so that ordinary selections behave predictably. Because a `Sticky`
anchor never dies, only fixed endpoints can be `Dead`, and a dead endpoint
cannot change role. Anchors created independently of sessions keep the
stickiness their creator chose.

**Normative constraint (interaction revision):** `InteractionRevision` versions
interaction state: which anchors form selections, their explicit placement,
their active edges, and register contents. It advances only when interaction state is explicitly
mutated (an applied `InteractionMutation`, or the interaction part of a
`Composite`). Passive anchor rebasing caused by buffer edits, including undo,
redo and lineage resurrection, never advances it. An anchor's position is a
fact of the buffer revision; the `EditEvent` of that revision is the causal
notification for passive anchor changes. Observable cursor and selection
positions are therefore a function of both the buffer revision and the
interaction revision.

**Normative constraint (coordinates in interaction requests):** An interaction
operation that carries a `Position` is coordinate-bearing. It is valid only at
the buffer revision it was computed against: the engine validates the intent's
`origin.buffer_revision` and, according to its rebase policy (§6.2), either
rebases the position or rejects the intent as `Stale`. An interaction CAS match
alone does not make a position current, because buffer edits do not advance the
interaction revision. Operations that refer only to `AnchorId`s are
anchor-scoped and follow anchor liveness and guard semantics instead.

**Register constraints (normative):**

- Registers are session-local and non-authoritative. They must not be required
  to interpret core protocol invariants (buffer state, anchor semantics, guard
  evaluation, intent validation).
- Registers provide a safe, protocol-visible namespace for extensions to store
  mode-like flags, macro state, or transient metadata without canonicalizing a
  monolithic mode concept into the core engine.
- Extensions must not use registers to smuggle ambient editor state. An engine
  that depends on register contents for any core operation is non-conforming.

### 2.6.1 Interaction Operations

```
BufferOp =
    | Insert  { target: Position | AnchorId, text: byte[] }
    | Delete  { target: Range | AnchorRange }
    | Replace { target: Range | AnchorRange, text: byte[] }

InteractionOp =
    | SetSelections { selections: SelectionSpec[] }
    | WriteRegister { key: string, value: InteractionValue }
    | ClearRegister { key: string }

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
    | Position(Position)                 -- coordinate-bearing
    | Edit(EditRef)                      -- composites only (below)
    | AnchorPosition(AnchorId)           -- a live public anchor's position; anchor-scoped
```

`SetSelections` replaces the session's selection list. Each endpoint states how
it relates to the current state:

- **Keep** preserves an owned endpoint's identity and geometric state: its
  position and status, including `Dead`. Its stickiness follows its role in the
  new selection (§2.6). A dead endpoint may be kept only as the fixed endpoint
  of a non-caret selection.
- **Move** preserves an owned endpoint's identity at a new position. The
  endpoint must be live. A moved endpoint can never be pulled back by an older
  deletion record, since deletion records name only dead anchors.
- **New** creates a fresh endpoint. It receives a public identity when its
  transition is published, and only if it is still part of a selection then; an
  endpoint released again within the same transition is never issued (§1.4).
  A later operation in the same intent therefore cannot name it.

Every target samples a position: none creates a relationship with what it
names. `Position` is coordinate-bearing; `AnchorPosition` is anchor-scoped and
follows liveness and guard semantics, and may name any live public anchor,
including another session's endpoint.

**Normative constraint (replacement):** each owned anchor appears at most once
in the new list, except that a caret's single anchor fills both slots;
`Keep` and `Move` name only the session's current endpoints; the list is not
empty. Every current endpoint the list does not mention is released, which is
terminal (§1.4).

**Normative constraint (simultaneous resolution):** every endpoint reference
and target in one `SetSelections` is resolved against the same pre-operation
state: the state left by the preceding buffer operations and preceding
interaction operations of the same intent. Only after the whole replacement
resolves and validates is it installed. In particular, an endpoint the new list
omits can still be sampled, and it is released afterwards; and with carets `a`
at 3 and `b` at 9, `[Move(a, AnchorPosition(b)), Move(b, AnchorPosition(a))]`
leaves `a` at 9 and `b` at 3, independent of list order. Separate interaction
operations remain sequential: each sees the state the previous one prepared.

`WriteRegister` and `ClearRegister` change the session's registers. Keys and
values are copied into the session.

The full `IntentPayload` type (including `BufferMutation`,
`InteractionMutation`, `Composite`, `Undo`, and `Redo` variants) is defined in
§4.2.

**Normative constraint (Composite application order):** In a `Composite`
payload, validation occurs against a single pre-application snapshot (both
buffer and interaction state at the moment of validation). Execution applies
`buffer_ops` first, advancing the buffer revision and rebasing all anchors.
`interaction_ops` are then applied in the context of the newly rebased anchors.
The entire composite application is atomic — if either phase fails, neither
takes effect.

Origins, guards and the interaction CAS are checked against the pre-application
snapshot. `interaction_ops` are then prepared in order, each against the state
the previous one prepared; publication happens only when all of them, and the
whole event block (§7), are ready. Positions carried by `interaction_ops`
address the text produced by `buffer_ops`. Because that text's grapheme count cannot be predicted from the
requested operations (§1.4), those positions are validated against the
produced state, with the atomicity of §4.1.

**Symbolic edit references (normative).** Within a `Composite`, a selection
target may designate a position by reference to the realized result of one of
its buffer operations, instead of computing that position itself:

```

EditRef = {
    op   : nat          -- index into the Composite's buffer_ops, in order
    edge : Start | End
}
```

The engine resolves an `EditRef` during application:

- `End` behaves as a Sticky anchor created when operation `op` completes, at
  the Sticky projection (§1.4) of the end of its inserted text. `Start` behaves
  as a Weak anchor at the Weak projection of the start of its inserted text.
- The anchor is rebased through the later buffer operations by the ordinary
  algebra and resolved after the last of them. A later insertion at an `End`
  reference moves it, as it would any Sticky anchor.
- If the anchor is dead when resolved, or `op` does not name a buffer operation
  of the same `Composite`, the intent is `Invalid` with no effect (§4.1).
- The anchors are internal: they are not observable, and their identifiers are
  not reused.

Examples: in `e`, `Insert(1, U+0301)` resolves `End` to `1` (after `é`) and
`Start` to `0`. On `ab`, `[Insert(2, "X"), Insert(0, "YY")]` resolves `End` of
operation `0` to `5`.

An `EditRef` carries no client-computed coordinate, so it is not
coordinate-bearing. It addresses positioning within one transaction only.
Interpreting a request computed at an earlier revision is a separate problem
(§11, item 11).

**Normative constraint (buffer operation ordering):** `BufferOp` arrays within
`BufferMutation` and `Composite` follow the same transaction-log semantics as
defined in §4.1: strictly ordered, sequentially applied, with the descending
non-overlapping optimization available.

### 2.6.2 Interaction Events

```
InteractionEvent = {
    session           : SessionId
    document_revision : Revision
    old_revision      : InteractionRevision
    new_revision      : InteractionRevision
    selections        : SelectionsChanged | None
    registers         : RegisterChanged[]
}

SelectionsChanged = { old: SelectionValue[], new: SelectionValue[] }

SelectionValue = {
    start  : EndpointValue
    end    : EndpointValue
    active : Start | End
}

EndpointValue = { anchor: AnchorId, position: Position | Dead }

RegisterChanged = {
    key : string,
    old : InteractionValue | None,
    new : InteractionValue | None
}
```

A committed intent's block contains one `InteractionEvent` per session its
interaction mutations changed, in order of first change (§7). The event states
the session's net change over the whole transition: `old` is the session's
state after the edit's passive effects and before any explicit change, and `new`
its final state. States between the mutations of one intent are never
published; the intent is atomic, so no observer could have seen them. Each
interaction mutation still advances the interaction revision once, so
`old_revision` and `new_revision` can differ by more than one. Positions are at
`document_revision`, the revision after the block's edit if there is one. The
difference between `old` and `new` is exactly the explicit change: passive
rebasing never appears as an interaction event, and an edit event explains it
(§7.1). Because endpoint values carry identities, a
delta shows which endpoints were kept, moved, created or released, and which
role each has. `selections` is `None` and `registers` empty when the session
ends the transition as it started.

### 2.6.3 Session Lifecycle

```
create_session(selections: SelectionSpec[], origin: Revision) -> Block
drop_session(session: SessionId) -> Block
```

Session creation and teardown are intrinsic requests (§0.1). They advance no
document or interaction revision and record no history, but each publishes a
lifecycle block (§7). `create_session` accepts only `New` endpoints with
`Position` or `AnchorPosition` targets; the new session starts at interaction
revision 0, and its block carries its identity and initial selections.
`drop_session` releases every endpoint and register of the session atomically.

**Intrinsic request failures (normative):** `create_anchor`, `drop_anchor`,
`create_session` and `drop_session` fail synchronously with a typed error to the
requester, not with a `ValidationReport`. A report is the rejection of an
intent: it carries the guard evaluations and verdict that a speculative intent
queue reconciles against (§7.6), and intrinsic requests have neither guards nor
a place in that queue. The error kinds are: a malformed request (an empty
selection list, an endpoint other than `New`, an edit reference, or an anchor
target that is not live), a position out of range, a stale origin, an unknown
session or never-issued anchor identifier, an attempt to drop a session's
endpoint, and resource exhaustion. A failed request publishes nothing, consumes
no sequence number and issues no identity.

---

## 3. Guard Model

### 3.1 Guard Taxonomy

Guards are conditions attached to mutation intents. They are classified by the
view they require.

#### Core Structural Guards (require: Text + Anchors + Summaries)

```
CoreStructuralGuard =
    | RangeOrdering     { 
        a: Position | AnchorId, 
        b: Position | AnchorId 
    }
    | RangeContainment  { 
        inner: Range | AnchorRange, 
        outer: Range | AnchorRange 
    }
    | LineContainment   { 
        target: Position | AnchorId, 
        line: nat 
    }
    | BracketEnclosure  { 
        inner: Position | AnchorId,
        open: Position | AnchorId,
        close: Position | AnchorId,
        depth: nat 
    }
    | AnchorLiveness    { 
        anchor: AnchorId 
    }
    | AnchorSeparation  { 
        a: AnchorId, 
        b: AnchorId, 
        min_distance: nat 
    }
```

#### Core Content Guards (require: Text)

```
CoreContentGuard =
    | SliceHash     { 
        range: Range | AnchorRange,
        digest: byte[8],
        max_extent: nat 
    }
    | SliceEquality { 
        range: Range | AnchorRange,
        expected: byte[],
        max_extent: nat 
    }
```

**`SliceHash` specification (normative):**

- **Algorithm:** XXH64 (xxHash 64-bit), initialized with seed `0`.
- **Input:** The logical byte sequence of the guarded range. If the buffer
  contains valid UTF-8, the input is the UTF-8 byte sequence. If the buffer is
  not valid UTF-8, `SliceHash` operates over raw bytes without normalization.
- **Output:** The 64-bit result serialized as an 8-byte little-endian array.
  Equality is byte-for-byte comparison of the 8-byte digest; no integer
  conversion or endianness reinterpretation is permitted.
- **Representation invariance:** The digest must be a pure function of the
  logical text. Two buffers with identical logical bytes in the guarded range
  must produce identical digests, regardless of piece fragmentation, compaction
  state, or store layout.
- **Streaming execution:** Engines must compute the hash incrementally,
  iterating the underlying piece-table spans and feeding each chunk into the
  hash state. Engines must not require intermediate contiguous memory allocation
  to evaluate the hash.
- **Evaluation order:** The hash is always computed against the current logical
  text at head, never against stale coordinates. When the intent's origin is
  behind head, the guarded range is first rebased according to the engine's
  rebase policy (§6.2); under `Reject`, the intent is rejected as `Stale`
  before any guard is evaluated.
- **Posture:** `SliceHash` is a bounded, probabilistic guard for detecting
  accidental coordinate skew or concurrent mutation. It is strictly
  non-cryptographic.

**Content guard constraints (both `SliceHash` and `SliceEquality`):**

- Region must be bounded by `max_extent` (engine policy caps this). Engines must
  reject content guards whose resolved range exceeds `max_extent` before
  performing any computation (hashing or comparison). The rejection is a `Fail`
  with reason indicating extent violation, not an engine error.
- Region must be unambiguously rebasable to head revision.
- Intended as fallback hardening, not primary validation.

#### Lexical Guards (require: Tokens)

```
LexicalGuard =
    | TokenClassAt      { 
        position: Position | AnchorId, 
        class: TokenClass 
    }
    | TokenSpanContains { 
        span: Range | AnchorRange, 
        position: Position | AnchorId 
    }
    | InLexicalScope    { 
        position: Position | AnchorId, 
        scope: LexicalScopeClass 
    }
```

#### Syntactic Guards (require: Syntax)

```
SyntacticGuard =
    | NodeKindAt        { 
        position: Position | AnchorId, 
        kind: SyntaxNodeKind 
    }
    | NodeContainment   { 
        position: Position | AnchorId, 
        node: SyntaxNodeRef 
    }
    | NodeLineage       { 
        descendant: SyntaxNodeRef, 
        ancestor_kind: SyntaxNodeKind 
    }
```

#### Diagnostic Guards (require: Diagnostics)

```
DiagnosticGuard =
    | DiagnosticAt      {
        position: Position | AnchorId,
        severity: DiagnosticSeverity | None    -- None matches any severity
    }
    | NoDiagnosticAt    {
        position: Position | AnchorId,
        severity: DiagnosticSeverity | None
    }
```

`DiagnosticAt` passes if a diagnostic overlapping the position exists (with
matching severity if specified). `NoDiagnosticAt` passes if no such diagnostic
exists. These guards enable intents that are conditional on error state — for
example, an auto-fix extension that should only apply when a specific
diagnostic is present.

#### Semantic Token Guards (require: SemanticTokens)

```
SemanticTokenGuard =
    | SemanticTokenTypeAt {
        position: Position | AnchorId,
        type: string
    }
```

`SemanticTokenTypeAt` passes if the semantic token at the given position has
the specified type. This enables guards that depend on rich language-aware
classification rather than lexical token class alone.

### 3.2 Guard Instance

```
Guard = {
    condition     : CoreStructuralGuard | CoreContentGuard | 
                    LexicalGuard | SyntacticGuard |
                    DiagnosticGuard | SemanticTokenGuard
    required      : bool           -- mandatory for application, or advisory
    required_view : ViewClass      -- derived from condition variant
}
```

### 3.3 Guard Result

```
GuardResult =
    | Pass
    | Fail { reason: string }
    | Unavailable { 
        missing_view: ViewClass, 
        state: ViewState
    }
```

`Unavailable` is distinct from `Fail`. A missing or stale capability is not a
false condition.

---

## 4. Mutation Intent

### 4.1 Buffer Operations

```
BufferOp =
    | Insert  { target: Position | AnchorId, text: byte[] }
    | Delete  { target: Range | AnchorRange }
    | Replace { target: Range | AnchorRange, text: byte[] }
```

**Normative constraint:** `BufferOp` arrays (within `BufferMutation` and
`Composite` payloads) are strictly ordered, not sets. Operations are applied
sequentially: the target coordinates for operation N are evaluated against the
logical text state produced by operations 0 through N-1. This makes the array an
atomic transaction log. Engines must resolve all intra-payload coordinate shifts
identically by applying this sequential model.

For intra-payload insertions at the same position, later operations have
implicit `Sticky` stickiness relative to earlier operations, ensuring
deterministic ordering of the inserted text.

**Descending non-overlapping optimization.** If all operations in a payload
target non-overlapping ranges and are sorted in strictly descending position
order, the intra-payload rebasing function for any operation against a preceding
operation is the identity. Formally, for payload `P = [Op_0, ..., Op_{N-1}]`
where `∀ j > i: target(Op_i) > target(Op_j)` and all targets are disjoint,
applying operations front-to-back with sequential rebasing is isomorphic to
applying them back-to-front without rebasing. Engines may detect this property
and bypass the O(N²) rebasing matrix, applying the payload in O(N). This is a
provable equivalence, not an approximation.

Positions before a realized splice's `start` are unchanged (§1.4), so the
identity holds for positions. Content does not: a splice extends left into
the preceding grapheme when its own start boundary disappears. An operation
whose target ends exactly where an earlier-applied operation begins may
therefore address a grapheme that operation rewrote. On `ae`,
`[Insert(2, U+0301), Delete(1, 2)]` deletes `é`, not `e`. Clients that compute
a payload from one snapshot must not assume adjacent targets are independent.

Because grapheme deltas depend on realized splices, validating operation N
against the sequential model requires the realized effect of operations
0..N-1, not lengths computed from their requested text.

**Normative constraint (payload atomicity):** If any operation in a payload is
invalid against the state produced by its predecessors, the whole payload is
rejected with no observable effect. Text, anchors (including anchors killed by
earlier operations), revision, undo and redo history, interaction state and
events are as before submission. The same holds when a `Composite`'s
interaction operations are invalid against the text its buffer operations
produce. An engine may validate by applying operations provisionally and
rolling back with their realized inverses (§2.5.1). Identifiers consumed
internally during a rolled-back application are not reused.

### 4.2 Intent

```
Intent = {
    id         : IntentId
    origin     : IntentOrigin
    payload    : IntentPayload
    guards     : Guard[]
    source     : IntentSource
    label      : string | None
    priority   : int
}

IntentId = u128
```

`IntentId` is mandatory and opaque: a 128-bit value the submitting client
supplies (a random UUID is one choice). The engine echoes it in the resulting
block or report and never interprets, deduplicates or checks it for
uniqueness. Supplying an identity correlates a result; it does not promise
exactly-once execution. A convenience layer may generate identities for callers
that need none of their own, but the canonical request always has one. Session
lifecycle requests (§2.6.3) carry the same kind of identity.

`label` is a descriptive name for the transition, echoed in its block. It is not
part of the causal contract: `id` identifies the intent and `source` its
provenance.

```
IntentOrigin = {
    buffer_revision      : RevisionStamp
    interaction_revision : InteractionRevisionStamp | None
}

InteractionRevisionStamp = {
    session  : SessionId
    revision : InteractionRevision
}

IntentPayload =
    | BufferMutation      { ops: BufferOp[] }
    | InteractionMutation { session: SessionId, ops: InteractionOp[] }
    | Composite           { buffer_ops: BufferOp[],
                            interaction_ops: InteractionOp[],
                            session: SessionId }
    | Undo                {}
    | Redo                {}

IntentSource =
    | Extension { id: ExtensionId }
    | UserInput

IntentClass =
    | Positional          -- simple coordinate rebasing
    | AnchorScoped        -- validity from anchor liveness
    | StructureGuarded    -- core structural guard validation
    | ContentGuarded      -- core content guard validation
    | ViewGuarded         -- requires optional view for validation
```

**Undo/Redo as intents (normative):** Undo and Redo are routed through the
intent system, not as engine-internal bypasses. This satisfies the Extension
Reflection Principle (§0.1), provides an `IntentId` for client-side speculative
queue reconciliation (§7.6), and allows extensions to observe undo/redo
transitions through the standard event stream. In v0.1 history is per buffer:
`Undo` targets the buffer's most recent `UndoEntry` and `Redo` its most recent
redo entry, whichever session or extension made them. The payloads therefore
carry no session: a session could not change which entry is applied, and the
intent's `id` and `source` already attribute the operation. Per-session history
and explicit `UndoEntryId` targeting are future extension points (§11 item 9);
they would add the fields they need.

**Undo/Redo sequencing (normative):** Undo and Redo are ordinary intents for
scheduling purposes. They enter the same sequencing pipeline as other intents,
are ordered by the same sequencing rules (§6.1), validated at application time,
and may be interleaved with any other intents targeting the same buffer.

**Priority:** `priority` is an input to a `Queued` engine's sequencing (§6.1). A
`Synchronous` engine applies each intent when it is submitted, so there is no
pending set for priority to order; such an engine does not accept the field, and
reports `sequencing: Synchronous` so a client never assumes priority was
honoured. A host that queues intents before submitting them to a synchronous
engine applies its own ordering, and that ordering is the sequence its blocks
record.

**Coherence rule:** If `payload` is `InteractionMutation` or `Composite`,
`origin.interaction_revision` must be present. If `payload` is `BufferMutation`,
`Undo`, or `Redo`, `origin.interaction_revision` may be `None`.

**Interaction validation (strict CAS algebra):** Interaction state does not
possess a geometric rebasing algebra like text. Selections and registers cannot
be meaningfully "rebased" across concurrent changes. Therefore, interaction
transitions rely on strict Compare-And-Swap (CAS) causality.

If an intent's payload is `InteractionMutation` or `Composite`, the engine
compares `origin.interaction_revision` against the head `InteractionRevision` of
the target session:

1. If `origin.interaction_revision == head`: validation proceeds normally.
2. If `origin.interaction_revision < head`: the user or another extension has
   mutated interaction state (e.g., moved the cursor) while the intent was in
   flight. The engine must reject the intent with `Stale { reason:
   InteractionAdvanced { origin, head } }` verdict.
3. Because `Composite` intents are strictly atomic, an interaction CAS failure
   completely aborts the accompanying `buffer_ops`. This prevents an extension
   from successfully inserting text but failing to update the selection, which
   would leave the cursor desynced from the buffer.

`IntentClass` is engine-derived metadata, not client-authoritative input. The
engine computes it from the submitted intent during validation. Advisory guards
do not elevate the class. The derived class is the maximum required validation
tier implied by the intent, and determines the minimum engine capability needed
for full validation as well as the default apply policy expectations:

- `Positional`: safe to rebase without guard evaluation.
- `AnchorScoped`: valid if referenced anchors are live.
- `StructureGuarded`: must validate core structural guards.
- `ContentGuarded`: must validate core content guards.
- `ViewGuarded`: at least one guard references an optional view (Tokens,
  Syntax, Diagnostics, SemanticTokens, TypeInfo, Symbols, or Hover). The
  engine derives this class from the presence of any guard whose
  `required_view` is optional. The specific view class needed is determined
  per-guard, not per-intent.

### 4.3 Validation Report

```
ValidationReport = {
    intent               : IntentId
    intent_class         : IntentClass
    head_revision        : Revision
    interaction_revision : InteractionRevision | None
    per_guard            : GuardEval[]
    verdict              : Verdict
}

GuardEval = {
    guard  : Guard
    result : GuardResult
}

Verdict =
    | Valid                           -- all guards passed
    | Invalid       { failed: GuardEval[] }
    | Degraded      { passed: GuardEval[],
                      unavailable: GuardEval[] }
    | Stale         { reason: StaleReason }
    | AnchorDead    { anchors: AnchorId[] }

StaleReason =
    | BufferAdvanced      { origin: Revision, head: Revision }
    | OriginUnavailable   { origin: Revision, oldest: Revision, head: Revision }
    | InteractionAdvanced { 
        origin: InteractionRevision, 
        head: InteractionRevision 
    }
```

`OriginUnavailable` is specific to engines with a `Rebase` policy (§6.2): the
origin is older than the history the engine retains, so its coordinates cannot
be interpreted at all.

**Normative constraint (ownership):** a report identifies its intent; it does
not contain or refer to the submitted intent, whose memory belongs to the
submitter. Everything a report holds, including each evaluated guard and its
result messages, is owned by the report and stays valid after the submitter's
request memory is released.

**Normative constraint:** `Verdict` is a projection over `per_guard`, not an
independent computation. An engine must not produce a verdict that contradicts
the individual guard evaluations.

**Normative constraint (report currency):** The `head_revision` and
`interaction_revision` fields in the `ValidationReport` must reflect the
engine's canonical head state at the exact moment of validation. They must not
simply echo the `origin` values provided in the intent. Clients require the
current head state to correctly rebase their speculative queues on rejection.

**Apply policy** (engine-configurable):

- `Strict`: apply only on `Valid`.
- `DegradedPermit`: apply on `Valid` or `Degraded` if all `required` guards passed.
- Custom policies may inspect the full report.

---

## 5. Evaluation Model (`buffer_eval`)

### 5.1 Tiers

**Tier 1: Intrinsic queries.** Not `buffer_eval`. Direct engine operations:

```
query_capabilities() -> EngineCapabilities
query_position(buffer, revision, position) -> PositionInfo
query_line(buffer, revision, line_number) -> Range
query_grapheme(buffer, revision, position) -> Grapheme
query_bracket_match(buffer, revision, position) -> Position | None
query_summary(buffer, revision, range) -> Summary
query_anchor(buffer, anchor_id) -> AnchorInfo
query_view_state(buffer, view) -> ViewState
query_token_spans(buffer, revision, range) -> TokenSpan[]
query_enclosing_syntax_node(buffer, revision, position) -> SyntaxNodeInfo | None
query_syntax_node_info(buffer, ref) -> SyntaxNodeInfo
query_diagnostic_list(buffer, revision, range: Range | None) -> Diagnostic[]
query_semantic_tokens(buffer, revision, range) -> SemanticToken[]
query_type_at(buffer, revision, position) -> TypeResult | None
query_definition(buffer, revision, position) -> Location[] | None | NotSupported
query_references(buffer, revision, position) -> Location[] | NotSupported
query_rename_prepare(buffer, revision, position) -> RenameInfo | None | NotSupported
query_hover(buffer, revision, position) -> HoverResult | None
```

`query_diagnostic_list` accepts an optional range parameter. `None` returns
all diagnostics for the buffer. A range returns diagnostics overlapping that
range. Results are stably ordered per §2.0.3.

`query_definition`, `query_references`, and `query_rename_prepare` may return
`NotSupported` if the registered Symbols provider does not implement the query
kind. `NotSupported` is distinct from `None` (provider looked and found
nothing) and from `ViewUnavailable` (no provider registered or provider not at
requested revision).

All queries are revision-parametric regardless of view transport class.

In addition to point queries such as `query_grapheme`, the engine must provide a
revision-scoped grapheme traversal capability equivalent to seeking a grapheme
cursor at an arbitrary logical position and stepping it forward or backward
without requiring whole-buffer materialization. The protocol does not require a
specific transport shape for that cursor, but conforming engines must expose an
equivalent capability to editor-layer span resolvers and extensions.

**Tier 2: Bounded evaluation.** The core of `buffer_eval`:

```
EvalRequest = {
    buffer               : BufferId
    revision             : Revision
    session              : SessionId | None
    interaction_revision : InteractionRevision | None
    range                : Range | AnchorRange
    lookahead            : nat
    required_views       : ViewSet
    program              : Program
    fuel                 : nat
}

EvalResponse =
    | Result     { value: Value, fuel_remaining: nat, anchors: AnchorReceipt[] }
    | Incomplete { partial: Value, fuel_remaining: 0 }
    | ViewUnavailable { missing: ViewClass, state: ViewState }
    | Error      { reason: string }
```

`Incomplete` is a typed result, not an exception. Callers must handle it.

**Coherence rule:** If `interaction_revision` is present, `session` must also be
present. An `EvalRequest` with `interaction_revision` but no `session` is
malformed and must be rejected. When `session` is `None`, the program has no
access to interaction state (selections, registers).

#### Anchor Requests in Evaluation

During evaluation, a program may compute positions where anchors are needed.
These are expressed as `AnchorRequest` objects returned alongside the result.
The engine fulfills them synchronously before delivering the response.

```
AnchorRequest = {
    position   : Position       -- in evaluation revision coordinates
    stickiness : Weak | Sticky
    tag        : string         -- caller-defined correlation key
}

AnchorReceipt = {
    tag    : string
    anchor : AnchorId
    status : Live | Dead
}
```

Evaluation is pure — no side effects occur during program execution. Anchor
requests are collected as part of the result and fulfilled by the engine at
delivery time. The extension receives only `AnchorReceipt` objects; unresolved
requests are never exposed externally.

**Fulfillment semantics:** Anchor positions are computed against the
evaluation's declared revision. Fulfillment occurs at delivery time against
current head. If the buffer has advanced between evaluation and delivery, the
engine rebases the requested position from the evaluation revision to head,
within its rebase policy (§6.2). This rebasing must strictly apply the
geometric rebasing algebra (`T_ins`, `T_del`) and projection defined in §1.4 —
it is a rigid mathematical transform, not a best-effort approximation. If the
position was deleted, the receipt is returned with `status: Dead`, consistent
with `create_anchor` born-dead semantics. If the policy cannot interpret the
evaluation revision, the request is not fulfilled and the response reports the
revision as unavailable. An engine with a `Reject` policy can avoid this case
entirely by fulfilling anchor requests before head advances.

**Tier 3: Intent synthesis.** An `EvalResponse` of tier `Result` may contain an
`Intent` as its value. The engine applies it through the standard
validation/application path. There is no privileged mutation channel from within
evaluation.

### 5.2 Program Model (Constraints, Not Syntax)

A `Program` is:

> A bounded, deterministic, side-effect-free procedure over the canonical
> abstract operations (§5.4), with finite control flow and isolated local state.

The protocol defines execution semantics, not interchange format. Representation
(AST, bytecode, WASM, etc.) is profile-defined and out of scope for v0.1.
Supported carriers must be advertised through `query_capabilities()` (§2.1).

A conforming `Program` satisfies:

1. **Revision-scoped.** Executes against a single declared revision.
2. **Pure.** No mutation of buffer state during execution.
3. **View-bounded.** Accesses only declared views.
4. **Range-bounded.** Reads only within the declared evaluation window. The
   evaluation window is the declared `range` plus declared `lookahead`. If
   `lookahead = 0`, no reads beyond `range` are permitted. A program that
   depends on lookahead must declare it explicitly in the `EvalRequest`; engines
   must not grant undeclared opportunistic lookahead. Two engines with
   different lookahead limits must produce identical results for programs whose
   declared lookahead fits within both engines' advertised bounds.
5. **Fuel-bounded.** Halts when fuel is exhausted, producing `Incomplete`.
6. **Compaction-invariant.** Behavior is identical under any
   representation-preserving compaction of the underlying piece table.
7. **Prefix-safe under truncation.** Evaluation is ordered and deterministic
   such that `Incomplete` results correspond to a well-defined prefix of the
   full computation. Different engines must produce identical partial results
   for the same fuel budget.

Additional semantic constraints:

- **Trace semantics.** All observable behavior must correspond to a
  deterministic sequence of canonical abstract operations. Implementations must
  preserve this trace — no reordering, elision, or hidden operations.
- **Deterministic control flow.** Branching and iteration depend only on:
  outputs of canonical operations, program-local state, and static `EvalRequest`
  inputs.
- **Host isolation.** No access to time, randomness, memory addresses, or
  external state.
- **State discipline.** Local state is ephemeral and per-evaluation. State at
  step k is a pure function of the executed operation prefix. On preemption,
  only the serialized partial result persists.

The protocol does not mandate program syntax or representation. It mandates
these properties. A conforming engine may accept programs as bytecode, a DSL, a
combinator tree, or any other form, provided the properties hold.

### 5.3 Fuel Model

Fuel is measured in Abstract Work Units (AWU). The protocol defines a canonical
set of abstract operations with fixed costs. Fuel is metered exclusively over
these operations, never over host-level instructions, CPU cycles, or JIT
artifacts.

#### Cost Table

| Operation | AWU | Notes |
|---|---|---|
| `read_text(1)` | 1 | per byte/character of logical text read |
| `query_summary` | 1 | one prefix or range summary lookup |
| `query_anchor` | 1 | resolve anchor position or status |
| `iterator_next` | 1 | advance any declared iterator by one element |
| `query_token` | 2 | access token class, span, or value at a position |
| `query_syntax_node` | 2 | access syntax node kind, span, or lineage |
| `emit_result` | 1 | emit a value into the result accumulator |
| `emit_intent` | 1 | emit a mutation intent as return value |
| `emit_anchor_request` | 1 | request anchor creation in the result |
| control flow | 0 | branching, comparison, local state updates |

**Rationale:** Data access against engine views is where computational cost
concentrates. Control flow is free because metering it would force fuel-checking
instructions between basic blocks, destroying compilation performance without
meaningfully bounding work. Optional view queries (`query_token`,
`query_syntax_node`) cost more than core queries because they access structures
with higher internal resolution cost.

#### Accounting Rules

**Fixed costs.** The cost `W(O)` of each abstract operation is fixed and
independent of buffer size, piece table fragmentation, or internal engine
topology. A `query_summary` costs 1 AWU whether the underlying index is a
Fenwick tree or a balanced rope.

**Bulk decomposition.** A bulk read of `n` elements (e.g., `read_text(n)`) costs
`n` AWU. The engine need not literally execute `n` single-step operations — it
may read a contiguous slice in O(1) and charge `n` AWU. What matters is that
fuel accounting and the observable partial-result prefix behave identically to
unit-stepped execution.

**Atomic queries.** Structural queries (`query_summary`, `query_anchor`,
`query_token`, `query_syntax_node`) are indivisible. They execute fully or not
at all. If insufficient fuel remains for an atomic query, the engine preempts
before the query executes.

**Monotonicity.** Fuel consumption is monotone with respect to execution.
Extending a program's evaluation path must not reduce the cumulative cost of
previously executed operations.

#### Preemption

If the next operation would exceed the fuel budget, the engine preempts
execution before that operation alters any local program state. The `Incomplete`
result corresponds exactly to the state after the last fully executed operation.

The `fuel_remaining` field in `EvalResponse` must equal `F_max - Σ W(O_k)` for
the executed prefix. This makes fuel accounting auditable by the caller.

#### Lookahead Cost

Reads within the declared lookahead window but outside the declared `range`
incur a penalty multiplier `λ` applied to each AWU of out-of-range access:

```
W_total = W_in_range + λ · W_out_of_range
```

`λ` is engine-declared and must satisfy `λ ≥ 2`. `λ` affects cost only, not
permission: semantic permission to read beyond `range` is determined
exclusively by the declared `lookahead` and the engine's advertised
`max_lookahead`.

#### Minimum Fuel Guarantee

Engines must accept any `EvalRequest` with `fuel ≥ 1`. An engine must not reject
requests solely on the basis of a low fuel budget. Extensions may intentionally
probe with small budgets to estimate cost or perform lightweight checks.

#### Additional Constraints

**Canonical operation set.** The operations listed in the cost table form a
complete and closed set. Engines must not introduce additional observable
operations or alter their decomposition.

**Deterministic execution.** Given identical inputs, revision, and fuel, all
conforming engines must execute the same sequence of abstract operations.

**State purity.** Program state after each operation must be a pure function of
the executed prefix. Engines must not defer, reorder, or batch state transitions
in a way that alters observable results.

**Bounded lookahead.** Declared `lookahead` must not exceed the engine's
advertised `max_lookahead`. Engines may reject evaluations whose declared
lookahead exceeds this bound. The engine-advertised bound is a capability
limit; it does not authorize undeclared reads beyond `range`.

**Progress requirement.** Engines may reject programs that perform unbounded
zero-cost control flow without consuming fuel. A conforming program must
eventually perform a fuel-consuming operation or terminate.

**Iterator semantics.** Advancing an iterator is equivalent in cost and
semantics to consuming one element from the corresponding logical sequence.

### 5.4 Available Operations Within Evaluation

A conforming program may:

- iterate text within declared range
- query summary index (prefix, range)
- resolve anchor positions and liveness
- query token view (if declared and available)
- query syntax view (if declared and available)
- maintain finite local state
- emit structured result values
- emit mutation intents as return values

A conforming program may not:

- mutate buffer state
- access text outside declared range (summary queries over the full buffer are
  permitted, as summaries are pre-computed indexes, not text reads)
- observe piece structure
- perform I/O
- allocate unboundedly
- call back into extension code

---

## 6. Intent Application

### 6.1 Sequencing

An engine declares its sequencing in `EngineCapabilities` (§2.1). For a `Queued`
engine, when multiple intents target the same buffer in the same evaluation
cycle:

1. Intents are ordered by `(priority desc, registration_order asc)`.
2. Each intent is validated against the current head revision at time of
   application.
3. Application produces a new revision; subsequent intents validate against it.
4. An intent that fails validation is rejected with a `ValidationReport`. It is
   not retried.

A `Synchronous` engine applies each intent when it is submitted, in call order;
steps 2–4 apply to it unchanged.

**Guard evaluation cost.** Guard validation occurs during the engine's
transactional application phase, not during extension evaluation. Guard
evaluation does not consume `buffer_eval` fuel (AWU). The engine bounds the
computational cost of content guards (`SliceHash`, `SliceEquality`) strictly via
its configured `max_extent` policy, rejecting intents that request content
validation over regions exceeding this limit. Structural and capability-gated
guards are bounded by the engine's index lookup cost, which is O(log N) or
better.

### 6.2 Coordinate Rebasing for Application

An intent's coordinates describe the document at its origin revision. When the
origin is behind head, the revisions in between may have moved, merged or
deleted the text those coordinates address. Interpreting them anyway requires
the realized splices of every intervening revision (§1.4), and how much of that
history an engine keeps is an engineering choice. The protocol therefore does
not promise rebasing. Each engine declares one policy through capability
discovery (§2.1):

```
RebasePolicy =
    | Reject                    -- stale coordinates are never interpreted
    | Rebase { window: nat }    -- interpreted across at most `window` revisions
```

The policy governs coordinate-bearing intents: `Positional` intents, guarded
intents whose targets or guards carry positions, and interaction operations
that carry positions (§2.6). `AnchorScoped` intents need no rebasing, since
anchor positions are maintained at head. `EditRef` targets (§2.6.1) name a
result of the transaction itself and are unaffected.

Under `Reject`, a coordinate-bearing intent whose origin is behind head is
rejected with `Stale { reason: BufferAdvanced { origin, head } }`. Nothing is
rebased, retried or interpreted at head. The client observes the new head and
decides again.

Under `Rebase { window }`, the engine rebases the intent's coordinates through
the realized splices of revisions `origin+1..head` with the algebra and
projection of §1.4, then evaluates guards at head:

- Insertion points and range starts rebase as Sticky anchors; range ends rebase
  as Weak anchors. An empty range rebases as one insertion point, so its ends
  cannot cross. A rebased range never absorbs text that another revision
  inserted exactly at its boundaries, and a rebased insertion lands after text
  committed earlier at the same position, consistent with §1.4 tie-breaking.
- If a coordinate lies strictly inside text deleted by an intervening revision,
  the intent is rejected with `Stale { reason: BufferAdvanced }`. The position
  the client observed no longer exists. Deletions strictly inside a target
  range shrink it without rejection; an intent that must fail whenever its
  target changed should carry a content guard (§3.1), which is evaluated at
  head.
- If `head - origin > window`, or the engine no longer retains the realized
  splices of some revision in `origin+1..head`, the intent is rejected with
  `Stale { reason: OriginUnavailable { origin, oldest, head } }`. `oldest` is
  the oldest origin the engine can still rebase from. The engine must not
  rebase partially, substitute a different origin, or interpret the coordinates
  at head.

Anchor creation from an earlier revision (§1.4 *Anchor Lifecycle*, §5.1 anchor
requests) depends on the same history and follows the same policy. A position
the policy cannot interpret is rejected rather than reported as a `Dead`
anchor; `Dead` remains reserved for positions that were deleted.

Rebasing is deterministic: the same intent, origin and history produce the same
coordinates. Under either policy, a client can rely on stale coordinates never
being applied to text it did not observe. Under `Rebase`, it can additionally
rely on interpretation within the advertised window.

### 6.3 Non-Requirement

The engine is not required to maintain editable historical snapshots. It must
only be able to validate intents against their origin revision's semantics by
evaluating guards at head after rebasing. The origin revision is metadata for
validation, not a requirement for time-travel.

### 6.4 Extension Compositionality

The core protocol defines `Independent` sequencing only: extensions submit
intents individually, ordered by `(priority desc, registration_order asc)`, each
validated and applied against the evolving head.

Grouped composition is a reserved extension point. When supported, the engine
accepts:

```
IntentGroup = {
    id      : IntentGroupId
    intents : Intent[]
    mode    : Atomic | Ordered | Independent
}
```

**Normative constraint:** All intents within an `IntentGroup` must target the
same `BufferId`. Cross-buffer atomic transactions require revision vectors and
multi-buffer locking, which are outside the scope of this protocol. Multi-buffer
coordination, if needed, is an extension-level concern built on top of
per-buffer intent groups.

**Mode semantics:**

- **Independent**: no special treatment. Intents are extracted from the group
  and sequenced normally alongside other intents. Group identity is discarded.

- **Atomic**: all intents in the group are validated against the same head
  revision (the head at the moment the group enters the application queue). If
  any intent's validation fails, the entire group is rejected — no partial
  application. If all pass, all are applied as a single transaction producing
  one new revision. Guards across intents within an atomic group see the same
  pre-application state, not the effects of sibling intents.

- **Ordered**: intents are validated and applied sequentially within the group.
  Each intent sees the state produced by the preceding intents in the group. The
  group is applied as a contiguous block in the sequencing order (no
  interleaving with other intents or groups). Group identity is preserved in the
  `EditEvent` for reporting and undo history. If an intent within an ordered
  group fails validation, the engine rejects the remaining intents in the group
  but retains the effects of already-applied intents (partial completion). The
  group's `ValidationReport` includes per-intent results.

The distinction: `Atomic` is all-or-nothing against a single snapshot. `Ordered`
is sequential with visible intermediate state but guaranteed contiguity.
`Independent` is the current default behavior.

Engines that do not support grouped composition must reject `IntentGroup`
messages with mode `Atomic` or `Ordered` and return an `Unsupported` error.
Extensions that require grouped composition must discover engine support via
`query_capabilities()` (§2.1).

---

## 7. Event Model

The engine *produces* one canonical record of every committed transition; how
those records reach subscribers is *delivery*, which belongs to the host. The
engine knows exactly what committed and in what order. How long anyone keeps
the record, and who receives it, depends on the consumer, so the engine keeps
no delivery state.

### 7.0 Blocks (normative)

```
Block =
    | Transition {
        sequence     : nat
        intent       : IntentId
        source       : EventSource
        label        : string | None
        edit         : EditEvent | None
        interactions : InteractionEvent[]   -- one per changed session (§2.6.2)
      }
    | Lifecycle {
        sequence : nat
        request  : IntentId
        change   : SessionCreated { session, selections: SelectionValue[],
                                    document_revision }
                 | SessionDropped { session, interaction_revision }
      }
```

- Every committed intent, including undo and redo, yields exactly one
  `Transition`; every session lifecycle request yields one `Lifecycle` block.
  A rejected intent or request yields a `ValidationReport` or error and no
  block.
- The block is built completely before anything is published: if any part of
  it cannot be built, the transition has no effect (§4.1). Publication and
  abandonment do not allocate.
- The block is returned to the caller that committed it, who owns it. View
  providers receive it borrowed, once the whole transition is published; they
  may read the engine but not change it (§0.1).
- `sequence` numbers blocks gaplessly per buffer instance, starting at zero.
  Rejections consume no number. A buffer instance is one engine from creation
  to destruction; a reopened or restarted buffer is a new instance whose
  sequence restarts.

### 7.1 The Edit Event

```
EditEvent = {
    old_revision     : Revision
    new_revision     : Revision
    edit_class       : EditClass
    splices          : RealizedSplice[]    -- one per buffer operation, in order
    endpoint_effects : EndpointEffect[]
}

RealizedSplice = { start: Position, old_end: Position, new_end: Position }

EndpointEffect = {
    session : SessionId
    anchor  : AnchorId
    old     : Position | Dead    -- at old_revision
    new     : Position | Dead    -- at new_revision
}

EditClass =
    | Insert
    | Delete
    | Replace
    | Mixed             -- buffer operations of different kinds
    | Compaction        -- representation-only, no logical change
```

**Splice coordinates (normative):** the `i`th splice is operation `i`'s
realized splice (§1.4). Its `start` and `old_end` are positions in the text just
before operation `i`, which is the text after operations `0..i-1` of the same
transition (for undo and redo, after the preceding inverse operations and their
resurrections, §2.5.3); its `new_end` is a position in the text just after
operation `i`. The splice rewrites `[start, old_end)` as `[start, new_end)`,
which can extend beyond the requested target and can be non-empty with an
unchanged grapheme count. A splice is a coordinate map only outside its closed
region: a position `p < start` is unchanged, a position `p > old_end` becomes
`p - old_end + new_end`, and a position in `[start, old_end]` is not described
by the splice at all.

**Endpoint effects (normative):** what happened to a session endpoint inside a
splice's closed region depends on the requested operation, the endpoint's
stickiness and grapheme projection (§1.4), not on the splice: in `e␤◌́`,
deleting `[1, 2)` and replacing `[0, 3)` with `é` realize the same splice, but
a `Weak` anchor at 1 survives the first and dies in the second. The edit event
therefore lists explicitly:

- every session endpoint that lay within the closed region `[start, old_end]`
  of at least one splice as that splice was applied, including endpoints at a
  splice boundary; and
- every session endpoint the transition revived by resurrection (§2.5.3).

Each listed endpoint appears once, with its value at `old_revision` and at
`new_revision`. Every other session endpoint keeps its liveness, and a live one
is carried through the splices in order by the shift rule above. An observer
never infers an endpoint's death from a splice's extent. Effects are passive:
they advance no interaction revision, and they are not interaction events.

An observer that knows every session at `old_revision` therefore reconstructs
them at `new_revision` without the text: listed endpoints take their `new`
value, the rest shift. A block's interaction events then apply in order, each
stating its `old` value after these passive effects (§2.6.2).

`Compaction` events have no splices. They signal that internal layout changed
but logical text did not.

Two subscriber classes exist with respect to compaction:

- **Logical subscribers** (syntax trees, analysis, overlays): depend only on
  logical text. Safe to ignore compaction events.
- **Structural-cache subscribers** (summary mirrors, custom positional indexes,
  layout caches): depend on representation-derived state. Must invalidate on
  compaction.

### 7.2 Provenance

```
TransactionCause =
    | Intent  { id: IntentId }
    | Group   { id: IntentGroupId }
    | BuiltIn                          -- engine-internal (compaction)

EventSource =
    | Extension { id: ExtensionId }
    | UserInput
    | Engine
```

A transition block's `intent` is its cause; grouped and built-in causes are
reserved for group modes and compaction, which the reference implementation
does not produce.

**Source semantics:**

- `Extension`: transitions originating from an intent submitted by a
  protocol-connected extension.
- `UserInput`: transitions originating from direct human interaction through the
  host UI (e.g., typing, UI-driven commands). Per the Extension Reflection
  Principle (§0.1), these must still transit the standard intent machinery.
- `Engine`: intrinsic internal transitions (e.g., compaction) that do not
  originate from a specific user action or extension intent. Undo and redo are
  intent-routed (§4.2), not engine-internal.

**Source provenance (normative):**

- `Extension`: if an applied intent has `source: Extension { id: E }`, its block
  has `source: Extension { id: E }`.
- `UserInput`: reserved exclusively for host-routed input that transits the
  intent machinery per §0.1. If an extension synthesizes an intent in response
  to a user keystroke, the source is `Extension { id: ... }`, not `UserInput`.
- `Engine`: intrinsic transitions only (compaction).

### 7.3 Stream Scope (normative)

The blocks of one buffer instance explain, in order:

- every document revision, including undo and redo;
- every session's existence, and its complete interaction state: selections
  with endpoint identities, positions, liveness and roles; registers; and
  interaction revision.

They do not cover, and an observer must not assume they cover: client-created
anchors (their creation, disposal, passive movement or resurrection; their
creator holds the receipt and can query them); internal anchors; history
reclamation, which changes nothing observable (§2.5.6); view-provider
registration; persistence state; and evaluation. Document replay (deriving the
new text from blocks), historical rebasing (§6.2, §11 item 11), event retention
and delivery are separate capabilities or hosting responsibilities.

**Snapshots (normative):** a snapshot of the stream's state carries
`next_sequence`, the sequence number of the first block it does not reflect. An
observer resumes with block `next_sequence`, not `next_sequence + 1`; a snapshot
of a fresh instance has `next_sequence = 0`. A host that pairs a snapshot with
later blocks captures both in one serialized step.

**Accepted no-ops (normative):** every accepted intent commits. It advances the
revisions its payload addresses and produces a block, even when the result is
indistinguishable from the previous state. For a buffer mutation this means the
document revision advances, so revision-based dirty state reports a change, an
undo entry is recorded, and the redo branch is discarded. Identical bytes are
not a test for a no-op: a replacement that leaves the text unchanged can still
kill anchors. An interaction mutation that leaves the session unchanged
advances the interaction revision and produces an interaction event with no
changes.

### 7.4 Delivery (hosting profile)

Delivery is the host's: retention, fan-out, coalescing and lagging subscribers
are hosting decisions. A delivery envelope identifies the buffer, the buffer
instance and the block's sequence, `(buffer, instance, sequence)`. The host
stamps the buffer and instance identities, so an engine needs no
application-wide identifiers; a sequence number is meaningful only within its
instance, so a restarted buffer is never mistaken for a continuation. Since
sequences are gapless, a subscriber can detect a missing block without the
engine retaining any.

A host that broadcasts blocks delivers each one whole before any later one.
Because a composite's edit and interaction events are parts of one block, they
are never separated by another transition.

### 7.5 Acknowledgment Semantics

Blocks are strictly 1:1 with committed intents and lifecycle requests. The
engine must not coalesce several intents into one block. If an extension
submits three intents, the engine validates and applies them sequentially,
producing three blocks or rejection reports, each echoing the corresponding
`IntentId`.

**Atomic group exception:** An `IntentGroup` applied with `Atomic` mode produces
exactly one unified block with `cause: Group { id }`. The individual
`IntentId`s within the atomic block are consumed by the group and must not
generate individual acknowledgments or rejections. Engines must not emit both
group-level and member-level records for the same atomic application.

**Built-in events:** Engine-internal transitions (compaction) produce blocks
with `cause: BuiltIn`. These have no associated `IntentId` and are not subject
to the 1:1 acknowledgment rule. Undo and redo are intent-routed (§4.2) and echo
their intent's identity.

Rejected intents produce a `ValidationReport` with a rejection verdict
(`Invalid`, `Stale`, or `AnchorDead`) echoing the `IntentId`. Rejection reports
are not blocks and consume no sequence number; they are routed to the submitting
client.

### 7.6 Client Reconciliation

When a client maintains speculative local state (e.g., for responsive UI), the
following reconciliation algorithm applies:

**On receiving a block:**

1. Apply the block to the client's canonical state (§7.1).
2. Inspect the block's cause. If it is `Intent { id }` or `Group { id }` and
   matches an entry in the client's local in-flight queue, pop that entry from
   the queue (it has been confirmed). If the cause is `BuiltIn`, no queue entry
   is affected.
3. Rebase the remaining in-flight queue against the new canonical state.
4. Recompute speculative state from the rebased queue.

Rebasing the in-flight queue does not rewrite intent provenance.
`origin.buffer_revision` and `origin.interaction_revision` remain the
historical origin stamps captured when the intent was created or submitted;
only the client's speculative target coordinates and derived local application
state are rebased.

**On receiving a rejection report** for `IntentId = X`:

1. Locate `X` in the in-flight queue.
2. Remove `X` from the queue.
3. Preserve all later intents in the queue.
4. Rebase the surviving suffix over the current canonical state (which does not
   include the effects of `X`).
5. Recompute speculative state from the rebased queue.

This model is sufficient for single-user editing with concurrent extensions.
Multi-user collaboration (multiple clients editing the same buffer) would
require a conflict resolution layer beyond this reconciliation algorithm, which
is deferred.

---

## 8. Worked Example: Auto-Close Bracket

### Scenario

User types `(` at the cursor. The auto-close extension should:

1. Determine whether the cursor is in a context where auto-closing is
   appropriate.
2. If so, insert `)` after the cursor.
3. Position the cursor between the pair.

### Step-by-step against the protocol

**Setup:**
- Buffer is at revision `r = 42`.
- Cursor is represented by anchor `cursor` with `Sticky` stickiness.
- Engine has mandatory views: `Text`, `Anchors`, `Summaries`.
- Engine optionally has `Tokens` view.

**Phase 1: User edit**

The user's keystroke is routed through the intent system per §0.1:

```
Intent {
    id: <user_keystroke_id>
    origin: IntentOrigin { 
        buffer_revision: RevisionStamp { buffer: b, revision: 42 }, 
        interaction_revision: None 
    }
    payload: BufferMutation { ops: [ Insert { target: cursor, text: "(" } ] }
    guards: []
    source: UserInput
    priority: 0
}
```

Buffer advances to `r = 43`. Anchor `cursor` is now after the inserted `(`.

Engine emits:

```
Transition {
    sequence: <n>
    intent: <user_keystroke_id>
    source: UserInput
    edit: EditEvent {
        old_revision: 42
        new_revision: 43
        edit_class: Insert
        splices: [RealizedSplice { start: <pos of "(">, old_end: <pos of "(">,
                                   new_end: <pos after "("> }]
        endpoint_effects: [EndpointEffect { session: session_1, anchor: cursor,
                                            old: <pos of "(">, new: <pos after "("> }]
    }
    interactions: []
}
```

**Phase 2: Extension evaluation**

The auto-close extension subscribes to `Insert` events. On receiving the event,
it issues:

```
EvalRequest {
    buffer: b
    revision: 43
    session: session_1
    interaction_revision: 7
    range: Range { start: cursor_pos - 1, end: cursor_pos + 64 }
    lookahead: 0
    required_views: { Text, Summaries }
    program: <auto_close_bracket_program>
    fuel: 256
}
```

The program executes:

1. Read character at `cursor_pos - 1`. Confirm it is `(`.
2. Query `BracketSummary` for the range ahead of cursor. Check net depth.
3. Optionally (if `Tokens` available): check token class at cursor. If inside a
   string literal or comment, do not auto-close.
4. Decision: insert `)` and reposition the cursor between the pair.

The program returns a `Composite` intent that atomically inserts the closing
bracket and updates the selection:

```
Result {
    value: Intent {
        id: <auto_close_intent_id>
        origin: IntentOrigin {
            buffer_revision: RevisionStamp { buffer: b, revision: 43 }
            interaction_revision: InteractionRevisionStamp {
                session: session_1, revision: 7
            }
        }
        payload: Composite {
            buffer_ops: [
                Insert { target: cursor, text: ")" }
            ]
            interaction_ops: [
                SetSelections { selections: [
                    SelectionSpec { start: Keep(cursor), end: SameAsStart }
                ]}
            ]
            session: session_1
        }
        guards: [
            Guard {
                condition: AnchorLiveness { anchor: cursor }
                required: true
                required_view: Anchors
            },
            Guard {
                condition: SliceEquality {
                    range: Range { start: cursor_pos - 1, end: cursor_pos }
                    expected: "("
                    max_extent: 1
                }
                required: true
                required_view: Text
            },
            Guard {
                condition: InLexicalScope {
                    position: cursor,
                    scope: NotStringOrComment
                }
                required: false
                required_view: Tokens
            }
        ]
        source: Extension { id: "auto_close_ext" }
        priority: 100
    }
    fuel_remaining: 201
}
```

**Phase 3: Validation**

Engine validates intent at current head (still `r = 43` if no intervening
edits):

| Guard | Result |
|---|---|
| `AnchorLiveness(cursor)` | **Pass** |
| `SliceEquality("(")` | **Pass** |
| `InLexicalScope(NotStringOrComment)` | **Unavailable** (no Tokens view) or **Pass** |

Validation report:

```
ValidationReport {
    intent: <above>
    intent_class: ContentGuarded
    head_revision: 43
    interaction_revision: 7
    per_guard: [
        GuardEval { guard: <guard 0>, result: Pass },
        GuardEval { guard: <guard 1>, result: Pass },
        GuardEval { 
            guard: <guard 2>, 
            result: Unavailable { 
                missing_view: Tokens, 
                state: Absent
            } 
        }
    ]
    verdict: Degraded {
        passed: [guard 0, guard 1]
        unavailable: [guard 2]
    }
}
```

Under `DegradedPermit` policy: all `required` guards passed. Advisory guard
unavailable. **Intent is applied.**

**Phase 4: Composite Application**

The engine applies the `Composite` payload atomically:

1. **Buffer phase:** `Insert { target: cursor, text: ")" }`. Buffer advances to
    `r = 44`. Anchor `cursor` (`Sticky`) is rebased past the inserted `)`.

2. **Interaction phase:** `SetSelections` is resolved against the rebased
   anchors. `Keep(cursor)` keeps the session's caret where it is. Because
   `cursor` is the session's `Sticky` caret and was rebased past `)`, the caret
   is now *after* the closing paren, not between the parens.

**Corrected approach:** The extension places the caret at the start of the
inserted text with an edit reference, keeping the caret's identity:

```
SetSelections { selections: [
    SelectionSpec {
        start: Move(cursor, Edit(EditRef { op: 0, edge: Start }))
        end: SameAsStart
    }
]}
```

This places the caret between `(` and `)` as intended, with no client-computed
coordinate. (Sampling a `Weak` anchor that the program requested during
evaluation, with `Move(cursor, AnchorPosition(between_anchor))`, works too, but
only the session's own endpoint becomes the caret.)

**Phase 5: Events**

The engine publishes one block for the composite (§7), which the host delivers
whole:

```
Transition {
    sequence: <n + 1>
    intent: <auto_close_intent_id>
    source: Extension { id: "auto_close_ext" }
    edit: EditEvent {
        old_revision: 43
        new_revision: 44
        edit_class: Insert
        splices: [RealizedSplice { start: <pos of ")">, old_end: <pos of ")">,
                                   new_end: <pos after ")"> }]
        endpoint_effects: [EndpointEffect { session: session_1, anchor: cursor,
                                            old: <pos of ")">, new: <pos after ")"> }]
    }
    interactions: [InteractionEvent {
        session: session_1
        document_revision: 44
        old_revision: 7
        new_revision: 8
        selections: SelectionsChanged {
            old: [<caret after ")">],
            new: [<the same caret, between the parens>]
        }
        registers: []
    }]
}
```

Other subscribers (syntax highlighter, bracket matcher, structural editing
extensions) update incrementally. A structural editing extension that wants to
snap the caret to an AST node boundary submits its own intent; with a
host-mediated pipeline (§0.1) it could instead intercept the auto-close intent
before it reaches the engine.

---

## 9. Worked Example: Expand Selection to Enclosing Delimiters

### Scenario

Cursor is inside a nested expression. The user invokes "expand selection to
enclosing delimiters." The extension should find the innermost balanced
delimiter pair enclosing the cursor and set the selection to span it.

### Step-by-step

**Setup:**
- Buffer content: `foo(bar[baz + 1] + 2)` at revision `r = 10`.
- Cursor anchor `cursor` is at the position of `+` between `1]` and `+ 2`, i.e.
  inside `(...)` but outside `[...]`.
- No selection currently active.
- Engine has mandatory views only (no `Tokens`).

**Phase 1: Evaluation**

The extension issues:

```
EvalRequest {
    buffer: b
    revision: 10
    range: Range { start: 0, end: buffer_length }
    lookahead: 0
    required_views: { Text, Summaries, Anchors }
    program: <expand_selection_program>
    fuel: 512
}
```

The program executes:

1. Resolve `cursor` position in logical text. Let `cursor_pos = 18` (the `+`).
2. Search backward for an unmatched open delimiter. Use bracket summary: query
   prefix summary up to `cursor_pos`, observe `p_min` to locate the nearest
   position where bracket depth decreases below entry depth. This finds `(` at
   position 3.
3. From the open delimiter, search forward for its match. Query bracket summary
   from position 3 forward, seeking the first position where net depth returns
   to zero. This finds `)` at position 21.
4. The enclosing pair is `[3, 22)` (inclusive of delimiters).
5. Create two anchors to mark the selection. The program requests anchor
   creation as part of its result.

The program returns:

```
Result {
    value: {
        selection: {
            open_pos: 3,
            close_pos: 22,
            open_char: "(",
            close_char: ")"
        },
        intent: None,
        selection_hint: Range { start: 3, end: 22 }
    }
    fuel_remaining: 340
    anchors: [
        AnchorReceipt { tag: "sel_start", anchor: <id>, status: Live },
        AnchorReceipt { tag: "sel_end", anchor: <id>, status: Live }
    ]
}
```

The program internally computed `AnchorRequest` objects for positions 3
(`Sticky` stickiness) and 22 (`Weak` stickiness). The engine fulfilled them
synchronously before
delivering the response. The extension receives receipts with live anchor IDs,
ready for use as durable selection endpoints.

**Phase 2: No mutation needed**

This operation is read-only. No intent, no guards, no validation. The result is
a selection hint that the frontend interprets. The anchor receipts give the
extension durable references for the selection boundaries without a separate
round-trip.

**What this stresses:**

- The summary algebra does real work: bracket matching via `(net, p_min)` prefix
  queries without scanning every character.
- No optional views needed. This is fully portable.
- The distinction between "eval that returns a value" and "eval that returns an
  intent" is exercised: not every evaluation mutates.
- Anchor creation via eval-embedded requests: the extension gets durable
  references without a separate `create_anchor` round-trip, while evaluation
  remains pure (requests are collected, not executed, during program execution).

---

## 10. Worked Example: Function Range Detection (Token-Dependent)

### Scenario

User invokes "select function" while the cursor is inside a function body. The
extension should identify the enclosing function and select its full range. This
requires the optional `Tokens` view.

### Step-by-step

**Setup:**
- Buffer contains Python code at revision `r = 20`:

```
x = 1

def process(data):
    result = []
    for item in data:
        result.append(item * 2)
    return result

y = 2
```

- Cursor anchor `cursor` is inside `result.append(item * 2)`, let's say at
  position of `item`.
- Engine has `Tokens` view available.

**Phase 1: Evaluation with token view**

```
EvalRequest {
    buffer: b
    revision: 20
    range: Range { start: 0, end: buffer_length }
    lookahead: 0
    required_views: { Text, Summaries, Tokens }
    program: <function_range_program>
    fuel: 1024
}
```

The program executes:

1. Resolve `cursor` position.
2. Using `Tokens` view: scan backward from cursor through token stream, looking
   for a token of class `Keyword` with value `def`.
3. Found `def` at position 6. Record as function start.
4. From the `def` token, scan forward through the token stream. In Python, the
   function body is indentation-delimited. Using the `Summaries` view (newline
   count) and `Text` view (inspect leading whitespace), walk lines forward until
   indentation returns to the level of the `def` line or a new top-level
   statement begins.
5. Determine function end: position of `\n` after `return result`, before `y =
   2`. Let's say position 112.
6. Function range: `[6, 112)`.

The program returns:

```
Result {
    value: {
        function_range: Range { start: 6, end: 112 },
        function_name: "process",
        selection_hint: Range { start: 6, end: 112 }
    }
    fuel_remaining: 710
}
```

**Phase 2: Again, no mutation**

This is a read-only query. The selection hint goes to the frontend.

### Degraded mode: Tokens view unavailable

Now consider the same request on an engine without `Tokens`:

```
EvalRequest {
    buffer: b
    revision: 20
    range: Range { start: 0, end: buffer_length }
    lookahead: 0
    required_views: { Text, Summaries, Tokens }
    program: <function_range_program>
    fuel: 1024
}
```

Engine response:

```
ViewUnavailable { missing: Tokens }
```

The extension has two options:

**(a)** Fail gracefully. Report to the user that function detection requires
token support.

**(b)** Fall back to a weaker program that uses only `Text` and `Summaries`:

```
EvalRequest {
    buffer: b
    revision: 20
    range: Range { start: 0, end: buffer_length }
    lookahead: 0
    required_views: { Text, Summaries }
    program: <function_range_heuristic_program>
    fuel: 1024
}
```

The heuristic program does a text-only regex-like scan for `def ` at line start,
then uses indentation analysis via `Text` to estimate function extent. Less
reliable, but portable.

**What this stresses:**

- **Capability gating works as designed.** The extension discovers view absence
  *before* evaluation, not during. The `ViewUnavailable` response is clean and
  typed.
- **Degradation is an extension-level decision.** The protocol doesn't silently
  degrade. The extension chooses whether to fall back or fail.
- **The token view is genuinely useful here** — without it, you're doing
  heuristic text matching that will break on edge cases (e.g., `def` inside a
  string). The capability hierarchy isn't ceremony; it reflects real analytical
  power differences.

### Mutation variant: rename function

If the user instead invoked "rename function," the extension would use the same
evaluation to locate the function, then return an intent:

```
Result {
    value: Intent {
        id: "550e8400-e29b-41d4-a716-446655440000"
        origin: IntentOrigin {
            buffer_revision: RevisionStamp { buffer: b, revision: 20 }
            interaction_revision: None
        }
        payload: BufferMutation {
            ops: [
                Replace {
                    target: Range { start: 10, end: 17 },
                    text: "transform"
                }
            ]
        }
        guards: [
            Guard {
                condition: SliceEquality {
                    range: Range { start: 10, end: 17 },
                    expected: "process",
                    max_extent: 7
                }
                required: true
                required_view: Text
            },
            Guard {
                condition: TokenClassAt {
                    position: 10,
                    class: Identifier
                }
                required: false
                required_view: Tokens
            }
        ]
        source: Extension { id: "rename_ext" }
        priority: 100
    }
    fuel_remaining: 680
}
```

Validation on an engine with `Tokens`:

| Guard | Result |
|---|---|
| `SliceEquality("process")` | **Pass** |
| `TokenClassAt(Identifier)` | **Pass** |

Verdict: `Valid`. Intent applied.

Validation on an engine without `Tokens`:

| Guard | Result |
|---|---|
| `SliceEquality("process")` | **Pass** |
| `TokenClassAt(Identifier)` | **Unavailable** |

Verdict: `Degraded`. Under `DegradedPermit`: applied, since the advisory lexical guard is not required.

This demonstrates the full portability story: the same intent, the same guards,
two different engine capabilities, both handled correctly with explicit
reporting.

---

## 11. Open Items

Items deferred from this draft, required before stabilization:

1. ~~**Anchor rebasing algebra**~~: resolved. Formal transforms for insertion,
   deletion, and replacement defined in §1.4 with compositional semantics,
   tie-breaking, and range anchor state model.
2. ~~**Anchor lifecycle management**~~: resolved. `create_anchor` and
   `drop_anchor` defined as intrinsic operations in §1.4 with born-dead
   semantics for deleted positions.
3. ~~**Fuel model**~~: resolved. Abstract Work Units (AWU) with fixed cost table
   defined in §5.3. Fuel metered over canonical abstract operations, not
   host-level instructions. Control flow costs 0 AWU. Preemption before
   over-budget operations. Auditable `fuel_remaining`. Lookahead penalty
   multiplier `λ ≥ 2`. Minimum fuel guarantee of 1 AWU.
4. **Program representation**: partially resolved. Semantic envelope defined in
   §5.2 (trace semantics, deterministic control flow, host isolation, state
   discipline). Carrier format (bytecode, AST, WASM) deferred to engine profiles
   and surfaced through capability discovery (§2.1). A normative interchange
   format may be specified in a future version.
5. **Summary algebra extensibility**: partially resolved. Registry model with
   closed operator set (`SUM`, `MIN`, `MAX`, `FIRST`, `LAST`, `BIT_OR`) defined
   in §1.5 and surfaced through capability discovery (§2.1). Option-typed
   identity semantics for `MIN`/`MAX`/`FIRST`/`LAST`. Composite summaries with
   custom composition rules remain core-only. Operator set may evolve; registry
   contents may be refined.
6. ~~**Cursor/selection model**~~: resolved. Selections are protocol-visible via
   `Session` and `InteractionState` (§2.6): endpoint slots with an `active`
   edge, over anchors the session owns. `SetSelections` states for each
   endpoint whether it is kept, moved or new (§2.6.1), so a replacement
   preserves the identities the causal model relies on, including dead marks.
   Interaction mutations are part of the `IntentPayload` (including `Composite`
   for atomic buffer+interaction changes), and sessions are created and dropped
   by intrinsic requests (§2.6.3). Registers provide session-local ephemeral
   storage for extension state. The engine remains GUI-agnostic.
7. ~~**Content guard hash specification**~~: resolved. `SliceHash` uses XXH64
   with seed 0, 8-byte little-endian digest. Streaming execution required (no
   intermediate allocation). Representation-invariant. Guard evaluation cost
   bounded by `max_extent` policy, outside AWU fuel model.
8. **Multi-buffer intents**: partially resolved / out of scope for v0.1.
   `IntentGroup` is constrained to a single `BufferId` (§6.4). Cross-buffer
   atomic transactions would require revision vectors and multi-buffer locking.
   Multi-buffer coordination is an extension-level concern.
9. ~~**Undo integration**~~: resolved. Undo is lineage-aware inverse mutation at
   head via `UndoEntry` (§2.5). Anchor resurrection is driven by undo lineage,
   not geometric matching. `DeletionMeta` tracks dead anchors as relative
   offsets against a single hidden rebasing anchor per deletion unit. GC tied to
   undo/redo reachability. Undo-tree (branching undo history) remains
   unspecified — the current model supports linear undo; branching would require
   additional revision graph semantics.
10. **Concurrency model**: partially resolved in single-authority environments.
    The protocol defines a complete single-authority concurrency model with
    deterministic client-side speculation, `TransactionCause`-based
    acknowledgment, and queue reconciliation (§7.5, §7.6). Distributed merge
    semantics (e.g., peer-to-peer CRDTs or multi-user operational
    transformation) remain deferred as an external coordination layer.
11. **Coordinate rebasing across revisions**: partially resolved. This is
    distinct from positioning within one transaction, which `EditRef` resolves
    (§2.6.1). §6.2 now fixes the observable contract: an engine declares
    `Reject` or `Rebase { window }`, and a bounded engine rejects an origin
    outside its retained history with `OriginUnavailable` rather than
    interpreting it partially or at head. The reference implementation
    declares `Reject`.

    What remains open is the machinery behind `Rebase`. Grapheme coordinates
    are not additive (§1.3), so an engine rebasing a position needs the
    realized splice of every retained revision and enough text to project
    positions that fall inside rewritten context (§1.4). A client that rebases
    its own speculative queue (§7.6) needs the same information, and must also
    segment with the engine's profile. Realized splices (§7.1) describe each
    revision's rewritten regions but not positions inside them, so they support
    neither on their own.
    Candidate mechanisms are retained splice history with an origin-to-head
    projection query, the realized splices that blocks now carry (§7.1), and a
    segmentation-profile capability (for example `"UAX29-extended/16.0.0"`).
    Changing the profile of an existing buffer is a coordinate migration, not
    an edit, and is unspecified.
12. **Canonical event production**: resolved in §7. The engine produces one
    owned block per committed intent or session lifecycle request, built before
    publication and returned at commit, with a gapless per-instance sequence;
    delivery, retention and the envelope's buffer and instance identities
    belong to the host (§7.4). Blocks carry realized splices and explicit
    session endpoint effects, which make session state reconstructible without
    text or segmentation (§7.1), and identify intents by a mandatory opaque
    `IntentId` (§4.2). Interception is host-mediated (§0.1).

    Still open: replay-capable blocks, which carry enough content to
    reconstruct the next document state, and whether that content is copied
    or referenced in the engine's append-only stores. Causal blocks do not grow
    with inserted text; a replay block would.
