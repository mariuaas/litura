# Zig style guide

Shared conventions for this family of Zig libraries and applications. They describe how code is structured, named, and reviewed. They do not change specified behavior.

## Principles and precedence

When a rule here and a specified contract disagree, the contract wins.

1. A project's specification is authoritative for observable behavior. Style is not a reason to change that behavior, including while a specification is still a draft.
2. Correctness outranks style: documented ownership, what a function does on failure, and invariants a caller can rely on.
3. These are defaults for new and edited code. Leave an existing name or shape alone during ordinary maintenance. A deliberate, behavior-preserving change of structure is a valid reason to rename or reshape it, and it does not need to ride along with another edit.
4. Libraries and applications share the rules. A library does not grow a process, a window, or host policy. An application composes library instances. Projects need not share one internal architecture.

## Modules, naming, and public APIs

A package exposes one module root, `src/root.zig`. That file publishes the namespaces and the few aliases a caller is meant to write. A caller who needs a submodule imports it. Re-export a name only when that spelling is the supported one. A file kept only so an old import still resolves says, on its first line, what deletes it.

One file holds one concept. A file that opens with a catalogue of re-exports is several files. Directories are `snake_case`. A namespace file is `snake_case.zig`. A file whose only job is one instantiable type may be `TitleCase.zig`.

Names follow ordinary Zig:

- Functions are `camelCase`. Types, and functions that return a type, are `TitleCase`.
- Values, fields, and constants are `snake_case`.
- An acronym is a word: `readU32Be`, not `readU32BE`.
- Spell words out: `message`, `source`, `target`. A single letter is enough for an index in a tight numeric loop.
- Put the unit or qualifier last, so related names align: `latency_ms_min` beside `latency_ms_max`.
- Do not repeat the module in the type. In `smf.zig` the type is `File`, so the call reads `smf.File`.
- Skip empty words (`Manager`, `Context`, `Utils`) unless the word is the domain term.
- Name an allocator for the policy it carries when that changes cleanup: `gpa` or `arena`.

A closed set of modes is an enum. An open wire value is a non-exhaustive enum (`enum(u16) { _, }`) or a raw field beside a known-kind enum. Strings are for text that is actually text.

`anytype` is for a documented caller-supplied source at a library boundary, or a tiny local helper. If the concrete type lives in this repository, name it. Two arguments of the same integer type that a caller could swap take an options struct, or names that make the call unambiguous. A nullable argument is a named field, so `null` means something at the call site.

The public surface is what another file may call. The rest is private. Inside a struct, write fields, then nested types, then methods. A nested type that needs its own screen becomes a top-level declaration.

Mutable state sits on an instance the caller creates, not in a file-scope `var`. A file-scope variable is for something the process truly has one of, and it should be rare. `main` wires instances and runs the loop. Parsing, editing, and mixing do not live there. Host policy (paths, quit, assets) lives on one host type.

A library does not initialize its platform, open a window, or read process arguments. Declare every dependency, and say what it is for. Keep it out of subsystems that do not use it. An application may depend on the platform it is. New C bindings are produced with `translate-c` in `build.zig`.

## Types, memory, errors, and invariants

Document ownership on the type, or on the function that returns it: who allocates, who frees, whether the caller must keep the input alive, and what a shallow copy would do. After `deinit` releases its resources, it sets `self.* = undefined`, so a later use is visible in safe builds.

The allocator is a parameter of `init`, or of the function that allocates, and is stored on the object that frees. There is no process-wide allocator variable.

Borrowed input and an owning value stay separate when a library offers both. A borrowed view does not take ownership of its input. If it retains a pointer or a slice, the caller keeps that memory alive for the documented lifetime. Borrowing does not by itself forbid allocation; a view that also promises not to allocate says so. The owning value copies what it keeps and frees it in `deinit`. On failure after a partial allocation, free what was taken. `errdefer` is the usual tool. A cursor that cannot take the next bytes reports the error before those bytes are consumed.

Failure has defined semantics. An operation that promises atomicity, including an editing transaction, preserves its prior state when it returns an error. An operation that may make partial progress says how far it got, and what the caller must do next. Do not leave that implicit.

A large object, such as a renderer, a synth, or a piece table, is initialized in place and kept at a stable address. A small owning document may still be returned by value.

Return a named error set, or the set inferred by `try`. Use `anyerror` only for a callback this code does not control, and name that function so the open set is obvious. `catch unreachable` and `@panic` mean this program is broken. A short file, a bad byte, or a full table is an operating error and returns. Exhaustion returns `error.OutOfMemory` or a domain error. An error is not discarded with `catch return` or an empty `catch`.

An invariant this program must uphold is `std.debug.assert`. Assert the case you expect. Where data is stored and later read back, check it on both sides. Split `assert(a and b)` into two asserts, so a failure names the clause. Do not assert a condition the caller can cause, and do not catch an assertion. There is no quota of asserts per function.

`unreachable` follows a local proof that the branch is empty, such as a switch arm already excluded by a range check. It is not a stand-in for an unlikely input. Some release modes delete it.

`index`, `count`, and `size` name different quantities even when they share a width. An index is 0-based, a count is how many, and a size is a count times a unit. Prefer `index < count` for the branch that means "inside." When rounding matters, use `@divFloor`, `@divExact`, or an explicit ceiling. Slice lengths stay `usize`. A count on a wire, in a file, or in a realtime callback uses the width of that domain. `usize` is not a handle. Widths and non-exhaustive enums match the protocol, not a convenient machine word.

A loop ends because its structure ends: a counted `for`, a cursor that stops at `len`, or a walk whose depth the data already bounds. Add an explicit maximum only when termination is not structural, and then return or assert if it is hit. A loop that runs for the life of the process says so. Do not invent a limit the data cannot reach.

`undefined` fills storage the next lines overwrite, or poisons an object inside `deinit`. It is not a default for live state.

## Functions, control flow, and performance

A function does one phase a reviewer can name: parse a header, apply one edit, write one chunk. About 70 lines is a signal that the control flow may no longer fit on a screen. Judge the branches, not the count. A straight table of constants or build steps may be longer. A function that is already clear stays whole. Helpers that only forward arguments make it harder to follow.

When a split helps, keep the branches in the parent and move straight work into the helper. Pass a library option that selects a real behavior, such as endian, rounding, or an allocation limit. An empty options struct is right when every default is the one you mean.

A hot path says whether it allocates, locks, or calls out. A path that has promised not to allocate, such as a realtime callback or a frame composite, keeps that promise, and the comment says so. Setup and policy stay outside the inner loop. For such a change, the comment also says which resource is spent and whether the work is batched or per event. Changing a signature so that values stay in registers is a measured optimization, done when a profile says the current shape matters.

A capacity that is a design limit is a comptime config or a named constant, not a mutable global.

A multi-line `if` uses braces. A single-line `if (cond) assert(other);` is fine. Split a compound condition when a reader cannot see that every case was considered.

## Testing, documentation, and workflow

Behavioral tests import the public module the way a caller would, and they live in `tests/`. A small test of a pure function may sit at the bottom of its file. When the tests outweigh the implementation, move them. A test name states one contract. A long test opens with a sentence on the goal and the method.

Use `std.testing.allocator` wherever a test allocates. Exercise allocation failure for constructors, multi-step transactions, and any operation where a partial failure could break an invariant: a document left half-built, an undo entry without its inverse. A single obvious allocation does not need that treatment by default.

`zig build test` runs the suite. A library also offers `zig build check`, which compiles the tests and does not run them. Format with `zig fmt`, and run `zig fmt --check` on the build files, `src`, and `tests` before the change is finished. Stay near 100 columns. A trailing comma on a multi-line list keeps later edits to one line. Break a long condition by hand when the formatted line is still hard to check.

`///` on a public declaration states the contract: ownership, units, what is preserved, what is rejected, and the failure behavior when it is not obvious. `//!` at the top of a file says what the file is for, in a line or two. A `//` comment states a constraint the types cannot express, as a sentence, and says why. It does not restate the next line. A design note lives in `docs/` only when a later edit would be wrong without it.

The README says how to fetch, build, test, and format, and it points at the contract document. When behavior changes, update the comment or that document in the same change. History and measurements stay off the path a reader needs in order to edit a function.

`build.zig` declares modules, options, and steps. An option has a description. A missing optional dependency skips its step. The build does not search another tree and splice source into a generated file.

Library diagnostics use `std.log.scoped`. The host raises the scope when it wants the output.

A reader of the diff should be able to answer, from the code, the doc comment, or the specification:

- Who allocates, and who frees?
- What input is rejected, and with which error?
- On failure, what happens to the values that were passed in?
- Which test fails if that contract regresses?
