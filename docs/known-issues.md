# Known correctness and contract gaps

The v0.1 specification is a draft. This is not a complete audit. Transaction atomicity, including under allocator exhaustion, is implemented as described in [the piece-tree study](development/piece-tree-atomicity-study.md). What follows is still true of the library.

## Differences from the specification

Litura carries the interaction origin on each interaction mutation rather than once per intent, so a composite can change several sessions; for one session the two are equivalent.

zg 0.16.2's `Graphemes.Iterator` sums cluster length in a `u8`, so a grapheme longer than 255 bytes panics in safe builds and is mismeasured otherwise. `text_segmentation.Iterator` drives zg's `graphemeBreak` with a full-width length instead; remove it once upstream is fixed.

## Costs

Each buffer operation rebases every anchor, and each buffer transaction snapshots the anchor map, so a transition costs time proportional to its operations times the anchors held. Composites that use edit references add two transaction-scoped anchors per buffer operation. `set_selections` checks endpoint ownership with a linear scan per endpoint, which is quadratic in a session's selection count. `zig build measure` reports these costs; with a thousand carets, typing one character at each takes milliseconds per submission.

Public dead anchors whose resurrection path was discarded stay in storage until their owner disposes of them, by design (SPEC §2.5.6).

## Syntax views

Litura is pinned to the Tree-sitter v0.27.2 release. Before 2026-11-19 it was pinned to a June development snapshot (`57420529`) whose package metadata said 0.27.0.

The provider's tree is always the tree Tree-sitter itself produces from the same operations: the grammar-diversity suite drives raw Tree-sitter beside the provider with the same edits and the same interruptions, and the two have agreed at every check. That tree is not always the tree a fresh parse would give. Tree-sitter's incremental result depends on the edits it was given and, for a parse halted by its budget, on where it resumed, even for text without syntax errors: the suite has seen this with tree-sitter-ocaml's quoted strings and quoted extensions (`{id|…|id}`, `{%ext|…|}`), tree-sitter-bash's nested heredocs, and tree-sitter-c. Inside syntax errors such differences are common. Either way the views are consistent with the provider's tree. Rationale, measurements and the rejected Tree-sitter patch are in [the design note](development/incremental-syntax.md).

On the earlier snapshot, a parse halted and resumed produced a structurally inconsistent tree for tree-sitter-javascript: a node reported more visible children than could be traversed. Litura's node references depend on those counts, so such a tree is unsafe to navigate. The defect is Tree-sitter's: raw Tree-sitter reproduces it deterministically from the captured operations. It does not occur on v0.27.0 or v0.27.2 with the same operations, but those versions halt at different points of the same sequence, so it is unknown whether the defect was fixed or is no longer reached. The suite fails on any inconsistent tree; none has occurred on v0.27.2. The reproduction is kept outside this repository for a possible upstream report.

A reparse costs time proportional to the number of items in each long list it passes. `zig build measure-syntax -Dtree-sitter=true` shows about 13 ms of refresh work per keystroke at 1 MiB of generated Lua and about 150 ms at 8 MiB. Submission stays near 20 µs. Edits that change how the rest of the document parses, such as opening a block comment near the top, reparse everything after them.

A refresh can overrun its budget. Tree-sitter asks whether to stop only between tokens and every hundred or so operations. While typing, the longest single call measured 5.3 ms at 1 MiB and 29 ms at 8 MiB with a 4 ms budget; opening an unterminated Lua block comment at the top of 8 MiB took 184 ms in one call.

A halted parse copies the document so it can finish while edits continue. The view becomes current only when a parse finishes before the next edit. If the copy cannot be allocated, the next edit abandons the halted parse, and an abandoned first parse starts over.

Highlight predicates are evaluated only partly: `#eq?`, `#any-of?` and a few `#match?` patterns. Any other predicate is treated as satisfied.

Tree-sitter allocates with its own allocator, which aborts on exhaustion rather than reporting it. Those allocations are outside Litura's allocation-failure contract.

## Borrowed results and evaluation

Provider callbacks use opaque engine and block pointers. Array ownership is defined for token, diagnostic and semantic-token queries, but nested strings and syntax/type/hover/symbol lifetimes depend on the provider. Evaluation values do not own intent backing storage. `queryRegister` returns a value borrowed until the session next changes.

The native evaluation carrier meters view operations, not arbitrary callback execution. It is not a sandbox or a CPU-time bound.

`queryCapabilities` returns its supported-view list in engine-owned scratch storage, so the result is valid only until the next call.

## Persistence

Save copies the full document and writes synchronously. Save is not an atomic filesystem replacement: a failed write can leave the target file partly written, although the stored path and saved revision change only after the write succeeds. Dirty state compares revision numbers rather than text identity, so undoing to identical text does not necessarily clear it.
