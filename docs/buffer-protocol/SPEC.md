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

`AnchorRange` and `RangeStatus` are derived interaction/editor-layer
interpretations over anchor ids, not intrinsic engine-managed objects. The
engine owns anchor creation, rebasing, lifecycle, and query. Pairing anchors
into selections or regions and interpreting the result as `Live`, `Collapsed`,
`Degenerate`, or `Dead` occurs above the intrinsic engine boundary.

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

where `E_ins(i, L)` inserts `L` bytes at position `i`, and `E_del(d_s, d_e)`
deletes the half-open interval `[d_s, d_e)`.

Let `T(A, E) → A'` be the rebasing function, where `A'` is either `(p', s)` or
`DEAD`.

**Insertion.** For `E_ins(i, L)` — insertion of `L` bytes at position `i`:

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

**Replacement.** `E_repl(d_s, d_e, L)` — replace `[d_s, d_e)` with `L` bytes
— is the strict composition of deletion followed by insertion at the deletion
start:

```
T_repl(A, E_repl(d_s, d_e, L)) = T_ins(T_del(A, E_del(d_s, d_e)), E_ins(d_s, L))
```

This decomposition is normative. Engines must not implement replacement as an
"in-place swap" that preserves interior anchors. Consequences:

- Anchor at `d_s` with Weak stickiness: survives deletion, stays at `d_s`
    (holds position through the subsequent insertion).
- Anchor at `d_s` with Sticky stickiness: survives deletion, moves to `d_s + L`
    (follows the replacement text).
- Anchor strictly inside `(d_s, d_e)` with Weak stickiness: killed by deletion.
    `T_ins` short-circuits on `DEAD`.
- Anchor strictly inside `(d_s, d_e)` with Sticky stickiness: clamps to `d_s`
    during deletion, then moves to `d_s + L` under the subsequent insertion.

**Composition.** Rebasing across edits `e1, e2` equals rebasing across `e1` then
`e2`:

```
T(A, e1 · e2) = T(T(A, e1), e2)
```

For live anchors, `T(DEAD, e) = DEAD` for all `e`. Dead anchors do not
participate in rebasing. Resurrection is handled exclusively by the undo system
(§1.6), not by the rebasing algebra.

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

If the requested position was deleted between `origin_revision` and
`head_revision`, the engine returns a valid `AnchorId` initialized with `status:
Dead`. The extension discovers this through the receipt and can decide whether
to re-evaluate.

A `Dead` anchor may not be used as a mutation target. It may be queried (returns
`Dead` status).

**Identity rule (normative):** `AnchorId` is unique within the lifetime of its
buffer and must not be reused, even after the anchor is dropped or reclaimed by
GC. Engines that compact anchor storage must preserve identity, not recycle
identifiers.

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
| `SubmitIntent` | Submits an asynchronous state transition request |
| `CreateAnchor` | Synchronous anchor creation (intrinsic operation) |
| `DropAnchor` | Synchronous anchor destruction (intrinsic operation) |

**Outbound messages (Engine → Client):**

| Message | Semantics |
|---|---|
| `EvalResponse` | Synchronous result of an `EvalRequest` |
| `AnchorReceipt` | Synchronous result of a `CreateAnchor` |
| `ValidationReport` | Asynchronous rejection of a `SubmitIntent` |
| `EditEvent` | Asynchronous broadcast of a canonical buffer transition |
| `InteractionEvent` | Asynchronous broadcast of a canonical session transition |

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
    limits                : EngineLimits
}

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
`supported_group_modes`, `apply_policies`, and `program_carriers` together
define the complete protocol-visible optional feature surface of the engine. A
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

**Normative constraint (undo boundary):** Undo operations strictly capture and
restore buffer state. Interaction state (selections, registers) is not recorded
in the undo lineage. Pure interaction mutations do not generate an `UndoEntry`.
When undoing a `Composite` intent, only the `BufferOp`s are reverted. The
interaction state itself is not rolled back, nor does the `InteractionRevision`
advance. Instead, the `AnchorId`s within selections passively undergo standard
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

**Constraints:**

- Exactly one hidden live anchor (`target_anchor`) per deletion unit, placed at
    the deletion boundary with `Weak` stickiness. This anchor participates in
    normal rebasing and tracks coordinate drift from intervening edits.
- Dead anchors are stored as relative offsets within the deleted region, not as
  absolute positions. This makes the metadata immune to coordinate drift.
- The `inverse_text` field references the deleted content (may be a reference
  into an immutable store rather than a copy).

### 2.5.3 Undo Application

When an `UndoEntry` is applied:

1. Resolve `target_anchor` position: `pos ← query_position(target_anchor)`.
2. Apply `inverse_ops` sequentially at `pos`. This is a standard buffer mutation
   that advances the revision.
3. For each `DeadAnchorRecord` in `deletion_meta.dead_anchors`: resurrect the
    anchor at `pos + offset` with its original `stickiness`, transitioning it
    from `Dead` to `Live`.
4. Destroy `target_anchor` (the hidden tracking anchor is no longer needed).

Resurrection is atomic with the undo mutation. Extensions observe the anchor
transition from `Dead` to `Live` in the same revision step as the text
restoration.

**Intent routing:** Undo application is triggered by an `Undo` intent payload
(§4.2), not by an engine-internal bypass. The resulting `EditEvent` carries
`cause: Intent { id }` (the `IntentId` of the undo intent) and `source:
UserInput` (if user-initiated) or `source: Extension { id }` (if
extension-initiated). This ensures undo is speculative-queue-compatible and
observable by all subscribers.

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

### 2.5.5 Redo

Redo is the inverse of undo: a forward re-application of the original mutation.
The engine re-captures a new `UndoEntry` for the redo operation, with the redo's
inverse being the original undo's inverse payload. Dead anchors killed by redo
follow the same `DeletionMeta` capture path.

### 2.5.6 GC Policy

Deletion metadata lifetime is tied to undo/redo reachability:

- When an `UndoEntry` becomes unreachable (e.g., new edits after an undo discard
  the redo branch), its `DeletionMeta` may be reclaimed.
- Dead anchors whose `DeletionMeta` has been reclaimed are truly terminal and
  may be dropped.
- Engines may coalesce adjacent deletions, compress interval metadata, and drop
  unreachable entries aggressively, provided undo correctness and anchor
  resurrection semantics are preserved.

GC may reclaim anchor storage and metadata, but it does not permit `AnchorId`
reuse.

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
    range  : AnchorRange
    active : Start | End      -- dynamic edge (point) vs fixed edge (mark)
}

InteractionState = {
    selections : Selection[]
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

`Selection` is interaction/session state, not intrinsic engine state. The
engine owns anchor rebasing and anchor query. The session/editor layer owns the
pairing of anchors into selections, the active-edge interpretation, and the
derived range status over paired anchors.

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
    | SetSelections { selections: Selection[] }
    | WriteRegister { key: string, value: InteractionValue }
    | ClearRegister { key: string }
```

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

**Normative constraint (buffer operation ordering):** `BufferOp` arrays within
`BufferMutation` and `Composite` follow the same transaction-log semantics as
defined in §4.1: strictly ordered, sequentially applied, with the descending
non-overlapping optimization available.

### 2.6.2 Interaction Events

```
InteractionEvent = {
    session       : SessionId
    buffer        : BufferId
    cause         : TransactionCause
    old_revision  : InteractionRevision
    new_revision  : InteractionRevision
    changed       : InteractionDelta[]
    source        : EventSource
}

InteractionDelta =
    | SelectionsChanged { old: Selection[], new: Selection[] }
    | RegisterChanged   { 
        key: string, 
        old: InteractionValue | None,
        new: InteractionValue | None 
    }
```

Interaction events are delivered in `InteractionRevision` order. They are
sequenced alongside `EditEvent`s in a unified event stream, maintaining causal
ordering between buffer mutations and interaction state changes.

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
- **Evaluation order:** The guarded range must be rebased to head revision
  before hashing. The hash is always computed against the current logical text
  at head, not against stale coordinates.
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

### 4.2 Intent

```
Intent = {
    id         : IntentId
    origin     : IntentOrigin
    payload    : IntentPayload
    guards     : Guard[]
    source     : IntentSource
    priority   : int
}
```

`IntentId` must be a globally unique identifier (e.g., UUIDv4) generated by the
submitting client. The engine treats `IntentId` as an opaque correlation token
for acknowledgment and rejection routing.

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
    | Undo                { session: SessionId }
    | Redo                { session: SessionId }

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
queue reconciliation (§7.2), and allows extensions to observe undo/redo
transitions through the standard event stream. The `session` field identifies
the interaction context that initiated the operation. In v0.1, `Undo` targets the
most recent `UndoEntry` for the session's buffer; `Redo` targets the most recent
redo entry. Explicit `UndoEntryId` targeting is a future extension point.

**Undo/Redo sequencing (normative):** Undo and Redo are ordinary intents for
scheduling purposes. They enter the same sequencing pipeline as other intents,
are ordered by the same sequencing rules (including priority and registration
order), validated at application time, and may be interleaved with any other
intents targeting the same buffer.

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
    intent               : Intent
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
    | InteractionAdvanced { 
        origin: InteractionRevision, 
        head: InteractionRevision 
    }
```

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
engine rebases the requested position from the evaluation revision to head. This
rebasing must strictly apply the geometric rebasing algebra (`T_ins`, `T_del`)
defined in §1.4 — it is a rigid mathematical transform, not a best-effort
approximation. If rebasing fails (the position was deleted), the receipt is
returned with `status: Dead`, consistent with `create_anchor` born-dead
semantics.

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

When multiple intents target the same buffer in the same evaluation cycle:

1. Intents are ordered by `(priority desc, registration_order asc)`.
2. Each intent is validated against the current head revision at time of
   application.
3. Application produces a new revision; subsequent intents validate against it.
4. An intent that fails validation is rejected with a `ValidationReport`. It is
   not retried.

**Guard evaluation cost.** Guard validation occurs during the engine's
transactional application phase, not during extension evaluation. Guard
evaluation does not consume `buffer_eval` fuel (AWU). The engine bounds the
computational cost of content guards (`SliceHash`, `SliceEquality`) strictly via
its configured `max_extent` policy, rejecting intents that request content
validation over regions exceeding this limit. Structural and capability-gated
guards are bounded by the engine's index lookup cost, which is O(log N) or
better.

### 6.2 Coordinate Rebasing for Application

When an intent's `origin` revision is behind head:

- `Positional` intents: coordinates are rebased using the edit history
  `origin..head`.
- `AnchorScoped` intents: anchor positions are already maintained at head. No
  rebasing needed.
- `StructureGuarded` / `ContentGuarded` / `ViewGuarded` intents: coordinates
  are rebased, then guards are evaluated at head.

Rebasing failure (ambiguous offset mapping) produces `Stale { reason:
BufferAdvanced { origin, head } }` verdict.

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

Edits emit structured events:

```
EditEvent = {
    buffer          : BufferId
    cause           : TransactionCause
    old_revision    : Revision
    new_revision    : Revision
    affected_ranges : Range[]         -- in new-revision coordinates
    edit_class      : EditClass
    source          : EventSource
}

TransactionCause =
    | Intent  { id: IntentId }
    | Group   { id: IntentGroupId }
    | BuiltIn                          -- engine-internal (compaction)

EditClass =
    | Insert
    | Delete
    | Replace
    | Compaction        -- representation-only, no logical change

EventSource =
    | Extension { id: ExtensionId }
    | UserInput
    | Engine
```

**Source semantics:**

- `Extension`: edits originating from an evaluated intent submitted by a
  protocol-connected extension.
- `UserInput`: edits originating from direct human interaction through the host
  UI (e.g., typing, UI-driven commands). Per the Extension Reflection Principle
  (§0.1), these edits must still transit the standard intent/event machinery.
- `Engine`: intrinsic internal state transitions (e.g., compaction) that do not
  originate from a specific user action or extension intent. Undo and redo are
  intent-routed (§4.2), not engine-internal.

`Compaction` events have empty `affected_ranges`. They signal that internal
layout changed but logical text did not.

Two subscriber classes exist with respect to compaction:

- **Logical subscribers** (syntax trees, analysis, overlays): depend only on
  logical text. Safe to ignore compaction events.
- **Structural-cache subscribers** (summary mirrors, custom positional indexes,
  layout caches): depend on representation-derived state. Must invalidate on
  compaction.

Engines should allow subscribers to declare which class they belong to, so
compaction events are not delivered unnecessarily.

Subscribers receive events in revision order through one unified stream shared
by `EditEvent` and `InteractionEvent`. Delivery is synchronous within a
revision step: once the engine begins broadcasting the events caused by a
committed step, it must deliver that step's full contiguous event block before
broadcasting events from any later step.

**Normative constraint (composite event ordering):** When applying a `Composite`
intent, the engine must emit the resulting `EditEvent` followed immediately by
the corresponding `InteractionEvent`. No intervening events from other intents,
extensions, or intrinsic engine operations may separate them in the broadcast
stream. This prevents speculative state tearing on the client.

**Source provenance (normative):**

- `Extension`: if an applied intent has `source: Extension { id: E }`, the
  resulting event must have `source: Extension { id: E }`.
- `UserInput`: reserved exclusively for host-routed input that transits the
  intent machinery per §0.1. If an extension synthesizes an intent in response
  to a user keystroke, the resulting event source is `Extension { id: ... }`,
  not `UserInput`.
- `Engine`: intrinsic transitions only (compaction).

### 7.1 Acknowledgment Semantics

Protocol events are strictly 1:1 with applied intents. The engine must not
coalesce multiple intents into a single `EditEvent` or `InteractionEvent`. If an
extension submits three intents, the engine validates and applies them
sequentially, emitting three distinct events (or rejection reports), each with a
`cause` that echoes the corresponding `IntentId`.

**Atomic group exception:** An `IntentGroup` applied with `Atomic` mode produces
exactly one unified event with `cause: Group { id }`. The individual `IntentId`s
within the atomic block are consumed by the group and must not generate
individual acknowledgment or rejection events. Engines must not emit both
group-level and member-level events for the same atomic application.

**Built-in events:** Engine-internal transitions (compaction) produce events
with `cause: BuiltIn`. These events have no associated `IntentId` and are not
subject to the 1:1 acknowledgment rule. Undo and redo are intent-routed (§4.2)
and produce events with `cause: Intent { id }`, not `BuiltIn`.

Rejected intents produce a `ValidationReport` with a rejection verdict
(`Invalid`, `Stale`, or `AnchorDead`) echoing the `IntentId`. Rejection reports
are not `EditEvent`s — they are a distinct message type routed to the submitting
client.

### 7.2 Client Reconciliation

When a client maintains speculative local state (e.g., for responsive UI), the
following reconciliation algorithm applies:

**On receiving a canonical event** (`EditEvent` or `InteractionEvent`):

1. Apply the canonical event to the client's canonical state.
2. Inspect the event's `cause`. If it is `Intent { id }` or `Group { id }` and
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
EditEvent {
    buffer: b
    cause: Intent { id: <user_keystroke_id> }
    old_revision: 42
    new_revision: 43
    affected_ranges: [Range { start: <pos of "(">, end: <pos after "("> }]
    edit_class: Insert
    source: UserInput
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
                    Selection {
                        range: AnchorRange { start: cursor, end: cursor }
                        active: End
                    }
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

2. **Interaction phase:** `SetSelections` is applied in the context of the
   rebased anchors. The selection uses `cursor` for both start and end, forming
   a zero-width selection (cursor position) between the parentheses. Because
    `cursor` has `Sticky` stickiness and was rebased past `)`, the extension anticipated
   this: the `cursor` anchor is already at the correct position *after* the
   closing paren. To place the cursor *between* the parens, the extension should
    have created an anchor with `Weak` stickiness at the insert point, or
    requested an anchor via `AnchorRequest` during evaluation.

**Corrected approach:** The program requests a `between` anchor during
evaluation:

```
anchors: [
    AnchorReceipt { tag: "between", anchor: between_anchor, status: Live }
]
```

The `Composite` interaction ops then use `between_anchor` for the selection:

```
SetSelections { selections: [
    Selection {
        range: AnchorRange { start: between_anchor, end: between_anchor }
        active: End
    }
]}
```

This places the cursor between `(` and `)` as intended. The `between_anchor`
(with `Weak` stickiness) stays before the inserted `)`.

**Phase 5: Events**

Engine emits both events atomically (per §7 composite event ordering):

```
EditEvent {
    buffer: b
    cause: Intent { id: <auto_close_intent_id> }
    old_revision: 43
    new_revision: 44
    affected_ranges: [Range { start: <pos of ")">, end: <pos after ")"> }]
    edit_class: Insert
    source: Extension { id: "auto_close_ext" }
}

InteractionEvent {
    session: session_1
    buffer: b
    cause: Intent { id: <auto_close_intent_id> }
    old_revision: 7
    new_revision: 8
    changed: [SelectionsChanged { 
        old: <previous>, 
        new: <cursor between parens> 
    }]
    source: Extension { id: "auto_close_ext" }
}
```

Other subscribers (syntax highlighter, bracket matcher, structural editing
extensions) update incrementally. A structural editing extension could intercept
the `InteractionEvent` and snap the cursor to an AST node boundary if desired.

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
   `Session` and `InteractionState` (§2.6). Selections are `AnchorRange` with an
   `active` edge. Interaction mutations are part of the `IntentPayload`
   (including `Composite` for atomic buffer+interaction changes). Interaction
   events are sequenced alongside edit events. Registers provide session-local
   ephemeral storage for extension state. The engine remains GUI-agnostic.
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
    acknowledgment, and queue reconciliation (§7.1, §7.2). Distributed merge
    semantics (e.g., peer-to-peer CRDTs or multi-user operational
    transformation) remain deferred as an external coordination layer.