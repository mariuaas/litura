# Incremental syntax views

**Status:** implemented. Measurements come from `zig build measure-syntax -Dtree-sitter=true`
(ReleaseFast).

junc turned syntax highlighting off above 128 KiB because a single keystroke made Litura's
Tree-sitter provider redo work proportional to the whole document. The limit treated the
symptom. This note records where the cost went, what we changed so that an edit or a query
costs roughly what it touches, and what still does not.

## Where the time went

The provider kept one parse shared by the `tokens` and `syntax` facades. When any query found
it stale, it rebuilt everything synchronously: it copied the document into one buffer, parsed
it without the previous tree, built a grapheme-to-byte table for every grapheme, ran the
highlight query over the whole tree, then sorted and filtered every capture. Measured on
generated Lua after inserting one character mid-document, in milliseconds:

| Document | Refresh | Text copy | Full parse | Grapheme map | 60-line token query | Node query |
| --- | --- | --- | --- | --- | --- | --- |
| 16 KiB | 17 | 0.002 | 6.8 | 0.26 | 0.011 | 0.08 |
| 128 KiB | 106 | 0.016 | 47 | 1.3 | 0.024 | 0.8 |
| 1 MiB | 902 | 0.13 | 438 | 9.9 | 0.54 | 7.4 |
| 8 MiB | 6,937 | 1.0 | 3,048 | 82 | 5.4 | 71 |

About half of each refresh was parsing and half was document-wide capture generation. The
grapheme map was not the dominant cost, but it was linear and redundant, since the piece tree
already sums graphemes and bytes per node; it is gone. Two defects surfaced as well: every node
query stored its path in the provider until the next refresh, and `enclosingNode` turned every
error, allocation failure included, into "no node".

## The design

Three decisions changed the protocol; the rest followed from them.

**Edits reach providers as byte coordinates.** Tree-sitter's `ts_tree_edit` needs each change
in byte offsets and (row, byte column) points of the text *at that moment*, and after a
multi-operation transition the intermediate texts no longer exist. So each realized splice now
carries `start_byte`, `old_end_byte`, `new_end_byte` and their points (SPEC §7.1), computed by
the engine while it applies the operation and still holds the old region and the inserted
text. The block becomes a complete description of the edit for any byte-oriented consumer,
and the provider edits its tree straight from the block it is notified of. A point's row
counts `\n` bytes, so the one in a CR LF pair counts, unlike Litura's own line queries, which
count line-feed graphemes.

**Queries never parse; the host schedules refresh.** `refreshView(view, budget)` is the only
place a view does maintenance work. The budget is a host callback (`RefreshBudget`), polled
through Tree-sitter's progress callback, so Litura owns no clock. A halted parse resumes on
the next call. Until a parse completes, both facades report `stale` with the last completed
revision, and queries fail with `error.ViewStale` rather than serving stale data as current.

**Node references are plain values.** `SyntaxNodeRef.id` is the node's preorder index among
visible nodes. The provider finds it by descending through the children that contain the node
and navigates back with `ts_tree_cursor_goto_descendant`, both in time proportional to depth.
A reference needs no storage, so references cannot accumulate.

The provider reads the document through Tree-sitter's input callback, one piece at a time,
without copying it. Token queries run the highlight query over the requested byte range only;
because captures are syntax nodes, any two are nested or disjoint, and mapping both ends of
each capture to graphemes by rounding down keeps them so. Resolving overlaps among the
captures that intersect a window therefore gives exactly the spans that resolving them over
the whole document gives inside it, which the tests check against whole-document queries.
The capture ends are mapped in one ascending pass (`PieceTable.positionsAtBytes`), which
segments each piece of the window once; mapping them one by one re-segmented a 512-grapheme
piece per capture end and cost 3.5 ms for a 60-line window.

Any grammar can be attached: a `tree_sitter.Grammar` names the generated parser's language
function and a highlight query, and Lua and Zig are built in that way.

## Halted parses and new edits

An edit used to abandon a halted parse, since the parse had read the old text. That is
correct, but a parse longer than the gaps between edits then never finishes, and with no
earlier tree to reuse, an abandoned first parse starts over from nothing: open a large file,
type at once, and highlighting never arrives.

A halted parse now keeps going. When a refresh halts, the provider copies the text into a
buffer it owns, and the resumed parse reads that copy; the splices of edits published
meanwhile are queued rather than applied. When the parse completes, the queued splices are
applied to its tree, and the same refresh carries on incrementally toward the current text.
Each halted parse costs one copy of the document, about a millisecond at 8 MiB, freed when it
completes. If the copy or the queue cannot be allocated, the provider falls back to abandoning
the parse.

## What Tree-sitter costs

The design leaves one cost proportional to the document. A reparse after a one-character edit
spends about 15 µs per KiB of generated Lua, and a plain `ts_parser_parse` on a contiguous
string with the same edit spends the same, so the time is inside Tree-sitter. Its reparse
visits every item of each long list it passes. A grammar's `repeat` becomes a hidden binary
rule, which Tree-sitter balances so that a list is a tree of logarithmic depth, but it marks
every node of that tree fragile, and fragile nodes are never reused whole: the parse table
entry for combining two repetitions also holds a repetition shift, and the parser counts any
entry with more than one action as a conflict.

We tried to change that, by not counting the never-taken repetition shift and by giving nodes
rotated during balancing the parse state of their first child. Litura's own tests passed, and
the reparse became constant at about 20 µs. Tree-sitter's own test suite, run locally on its
master branch, disagreed: with randomized edits over its fixture corpora, the patched parser
produced incorrect trees for valid code (C, C++, Ruby, TypeScript and TSX with the first-child
rule; Go, Bash, TypeScript and TSX with a variant), losing enclosing constructs to a
top-level `ERROR`. A correct parse state is evidently not enough to make a
rotated repetition node safe to reuse, and we did not find what else is. The change is not
part of Litura; it runs on unmodified upstream Tree-sitter, and the cost stays. It is
scheduled work, not blocking: see the measurements below.

## Correctness

Full reparsing is the reference. Two suites compare the provider with a fresh engine parsing
the same text: the tree, token spans over the whole document and over random windows, and
enclosing nodes with their references.

`tests/syntax_incremental_test.zig` covers the built-in grammars with targeted workloads:
long lists edited only in ways that keep them valid, stale queries, resumption, a parse
overtaken by an edit after every call, allocation-free node references, and allocation failure
in token queries and while a parse is halted.

The grammar-diversity suite (`-Dsyntax-corpus=true`, `tests/syntax_corpus_test.zig`) runs the
same comparison over fourteen grammars pinned as test fixtures. Each grammar's own corpus and
a hand-written sample, under random edits and halted refreshes, must match a fresh parse
where that parse has no errors.

The suite found that Tree-sitter's own incremental parse sometimes does not: after several
precise edits, tree-sitter-ocaml's quoted strings came out as an `ERROR` that a fresh parse
does not produce. An oracle runs beside the provider: raw Tree-sitter given one edit per
committed block, derived from the texts alone. A difference from the fresh parse that the
oracle reproduces exactly is Tree-sitter's; any other fails the test. Where the fresh parse
has errors, recovery is history-dependent, so the suite checks coherence instead: the views
describe the current revision, the tree spans the text, tokens are ordered and disjoint,
windows agree with the whole document, and every node reference resolves to a node of the
provider's tree with the reported kind and range.

In ReleaseSafe with the default twelve steps per document, the suite exercised 2,490
documents and 49,455 edit steps. Nine exact comparisons, all in OCaml documents with quoted
strings, were Tree-sitter's divergences, each reproduced by the oracle; there were no others.

## Measurements

Generated Lua, ReleaseFast, without any change to Tree-sitter, in microseconds. Typing 200
characters mid-document, with refresh scheduled as a host's idle loop would run it, in calls
with a 4 ms deadline each. *Submit* is what the editor waits for; *work* is the refresh
calls together, how long highlighting lags; *longest* is the longest single call, the only
part that can delay input in the host's loop.

| Document | Submit p50 | Work p50 | Work max | Longest call | 60-line query p50 |
| --- | --- | --- | --- | --- | --- |
| 16 KiB | 7 | 303 | 1,383 | 1,383 | 593 |
| 128 KiB | 11 | 1,737 | 4,474 | 4,295 | 601 |
| 1 MiB | 13 | 12,935 | 35,316 | 5,477 | 618 |
| 8 MiB | 20 | 124,663 | 291,550 | 25,768 | 646 |

The worst cases, as total work and longest call:

| Document | First parse | Four distant edits | Undo | Open `--[[` at the top | 1000 carets |
| --- | --- | --- | --- | --- | --- |
| 1 MiB | 364,636 / 5,259 | 24,862 / 4,496 | 18,119 / 4,842 | 431,554 / 32,353 | 96,588 / 4,432 |
| 8 MiB | 2,950,942 / 25,888 | 206,248 / 15,114 | 166,014 / 13,590 | 3,448,064 / 254,217 | 363,661 / 21,456 |

Against the baseline, an edit no longer blocks a query for the whole document's worth of work:
at 1 MiB a keystroke's refresh fell from 902 ms, all of it inside the next query, to 13 ms
of scheduled work in calls of at most about 5 ms, and the visible window highlights in
0.6 ms. Large documents remain expensive in total, because of the per-item reparse above.
Calls overrun their budget because Tree-sitter checks it only between tokens and every
hundred or so operations; opening an unterminated block comment makes the rest of the file
one token, which one call must lex. Remaining costs and limits are listed in
[known issues](../known-issues.md).
