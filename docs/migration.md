# Migrating to the interaction and event contract

This note lists what a caller has to change. Every state change now goes through a declared request and is recorded in an owned block. The contract itself is in the [specification](buffer-protocol/SPEC.md), §1.4, §2.6 and §7.

## Identities

Every intent carries a mandatory `id: types.IntentId`, an opaque 128-bit value. The engine echoes it in the block or report and never checks it for uniqueness. Use your own scheme, or `IntentId.random(io)`.

`source` is now typed: `.user_input` or `.{ .extension = "name" }`. The free-form `cause` string is gone; a descriptive `label` takes its place and is echoed in the block.

Origins are now required. `Intent.origin` and `SessionCreation.origin` state the document revision the request was built against; a request built against the current document says so with `engine.revision`. `InteractionMutation.origin` states the session's interaction revision (`engine.interactionRevision(session)`). Omitting either no longer means "head": it does not compile. Buffer operations, undo, redo and positions are rejected as stale against an old document origin; anchor-scoped interaction mutations are not.

## Submission results

`submit` returns `.committed` (an `events.Block`) or `.rejected` (a `ValidationReport`). A transition block holds the edit event, if the document changed, and one interaction event per session the intent changed, stating that session's net change. A composite no longer loses its interaction part. An endpoint created and released within one intent never receives an identity.

| Before | After |
| --- | --- |
| `.edit_event` | `.committed.transition.edit.?` |
| `.interaction_result` | `.committed.transition.interactions` |
| `.validation_report` | `.rejected` |
| `EditEvent.affected_ranges` | `EditEvent.splices` (`start`, `old_end`, `new_end` per operation) |
| `EditEvent.edit_class` string | `events.EditClass`, including `.mixed` |
| `ValidationReport.intent` (borrowed) | `ValidationReport.intent` (the `IntentId`; everything in the report is owned) |

A splice's `[start, new_end)` is the old affected range; `old_end` is new. Each splice is in the coordinates of the text just before its own operation, as before.

`apply`, `applyOps`, `applyMutation`, `undo` and `redo` are removed. Submit a `buffer_mutation`, `undo` or `redo` intent instead. An undo or redo whose history entry can no longer be applied now fails with `error.CorruptHistory` and leaves the entry in place.

Results own their contents. Deinit either the `SubmitResult` or the block you took out of it, not both.

## Sessions

Sessions own their selections' anchors. You no longer create an anchor and hand it to a session.

```zig
var block = try engine.createSession(.{
    .id = id,
    .selections = &.{.{ .start = .{ .new = .{ .position = at } } }},
});
defer block.deinit(allocator);
const created = block.lifecycle.change.session_created;
const session = created.session;
const cursor = created.selections[0].start.anchor;
```

`dropSession(.{ .id = id, .session = session })` releases every endpoint and register and returns a lifecycle block. It no longer takes a cursor or refuses sessions with several selections.

`dropAnchor` on a session endpoint fails with `error.AnchorOwned`. A dropped or released anchor now queries as `.disposed` instead of failing, and dropping it again succeeds. `queries.AnchorInfo.status` is therefore an `anchors.HandleStatus` (`live`, `dead`, `disposed`), and `stickiness` is optional: a disposed handle has none.

`createAnchor`, `dropAnchor`, `createSession` and `dropSession` fail with the named error set `BufferEngine.RequestError`, not with validation reports.

## Changing selections

`move_cursor_anchor`, `set_cursor_selection` and `place_cursor` are replaced by `set_selections`, which replaces the session's selection list and says for each endpoint whether it is kept, moved or new. A null `end` makes a caret. Endpoints the list omits are released.

| Before | After, for a cursor `c` with mark `m` |
| --- | --- |
| `place_cursor(c, at, mark: null)` | `.{ .start = .{ .move = .{ .anchor = c, .to = at } } }` |
| `place_cursor(c, at, mark: q)` | `.{ .start = .{ .new = q }, .end = .{ .move = .{ .anchor = c, .to = at } }, .active = .end }` |
| `move_cursor_anchor(c, p)`, keeping the mark | `.{ .start = .{ .keep = m }, .end = .{ .move = .{ .anchor = c, .to = .{ .position = p } } } }` (with the cursor in the `end` slot, the default active edge) |
| `addSessionCursor` | add a selection with a `new` endpoint |
| `dropSessionCursor` | omit that selection |
| `setSessionMarkAnchor(c, a)` | a `new` endpoint with target `.{ .anchor = a }` (the position is sampled; `a` stays yours) |

Every other selection in the list must be repeated, usually with `.keep`, or it is released. `types.InteractionTarget` is now `types.Target`: a `position`, an `edit` reference (in composites, as before) or an `anchor` whose current position is sampled. Endpoint stickiness follows its role: the active endpoint is Sticky, the fixed one Weak.

`querySessionMark` and `sessionCursors` are replaced by `querySelections`, which returns each selection's endpoints with their positions. Registers are new: `write_register`, `clear_register` and `queryRegister`.

`moveAnchor`, `addSessionCursor`, `dropSessionCursor`, `setSessionMarkPosition` and `setSessionMarkAnchor` are removed.

## Provider callbacks

`onBufferEvent` now receives a `*const events.Block`, borrowed for the call, once the whole transition or lifecycle request is published. Lifecycle and interaction-only blocks are delivered too; `views.changesText(block)` tells a text-derived view whether to go stale. Every state-changing entry point, including `createAnchor`, `createSession` and provider registration, returns `error.ReentrantMutation` from inside the callback.

## Refreshing views

Queries no longer refresh. Call `engine.refreshView(view, budget)` first. A query against a registered view that is not current fails with `error.ViewStale` or `error.ViewUnavailable` instead of returning empty results.

`views.RefreshBudget.unlimited` refreshes to completion. A budget whose `exhausted` callback reports when to stop returns the view as `stale`; the next call resumes. Providers implement `refreshFn(ptr, engine, budget)`.

## Syntax and splices

`SyntaxNodeRef.path` is replaced by `id: u32`, a plain value with no lifetime beyond its revision. `enclosingNodeFn` returns `anyerror!?SyntaxNodeInfo`; `queryEnclosingSyntaxNode` reports provider errors instead of returning null, and returns null for text outside every node (for example whitespace before the first token), where it used to return the root.

`RealizedSplice` gains byte offsets and `events.Point` fields for the same three boundaries. Code that builds splices must fill them in.

Syntax providers implement `enclosingNodeFn(ptr, engine, start, end, revision)`, the smallest node containing a grapheme range (empty only at the end of the text), in place of the point form, and the new `parentNodeFn(ptr, engine, ref)`, the immediate parent or null at the root. A provider that issues no references can return `error.KeyError` from `parentNodeFn`, as from `nodeInfoFn`. `queryEnclosingSyntaxNode(position, revision)` is unchanged for callers; `queryEnclosingSyntaxNodeRange(start, end, revision)` and `querySyntaxNodeParent(ref)` are new.

With `-Dtree-sitter=true`, Litura now builds the Tree-sitter v0.27.2 release instead of a development snapshot from June 2026. A grammar you attach must be compatible with that runtime (ABI 13 to 15).

The built-in Fennel grammar is removed; `attachBuiltin(engine, "fennel")` now returns false. Attach Fennel, or any other language, by compiling its generated parser and passing a `tree_sitter.Grammar` to `TreeSitterTokenProvider.attach`.

## Observing

`engine.snapshot(allocator)` returns every session's state with `next_sequence`, the first block the snapshot does not reflect. An observer applies blocks from that number on. Edit events list session endpoints whose fate the splices do not determine; every other endpoint shifts by the splice rule. Client anchors are not part of the stream.

## Capabilities

`EngineCapabilities.sequencing` is new and reports `.synchronous`: each submission is applied when made, and intents carry no priority.
