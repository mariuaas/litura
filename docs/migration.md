# Migrating to the interaction and event contract

This release replaces how sessions, selections and results work. The changes are deliberate API breaks: every state change now goes through a declared request and is recorded in an owned block, and the shortcuts that changed state without one are gone. This note lists what a caller has to change. The contract itself is in the [specification](buffer-protocol/SPEC.md), §1.4, §2.6 and §7.

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

## Observing

`engine.snapshot(allocator)` returns every session's state with `next_sequence`, the first block the snapshot does not reflect. An observer applies blocks from that number on. Edit events list session endpoints whose fate the splices do not determine; every other endpoint shifts by the splice rule, so an observer never needs the text to follow selections. Client anchors are not part of the stream.

## Capabilities

`EngineCapabilities.sequencing` is new and reports `.synchronous`: each submission is applied when made, and intents carry no priority.
