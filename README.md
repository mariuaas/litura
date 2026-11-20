# Litura

Litura is a document editing library for Zig, distilled from a private project I've been working on. It keeps text, anchors, selections and edit history together, with revision-checked edits and optional syntax views.

Early draft, so the API is still moving, spec and code still hardening. [Known issues](docs/known-issues.md) lists costs and remaining gaps. The [draft specification](docs/buffer-protocol/SPEC.md) is the protocol we're working towards; [implementation status](docs/buffer-protocol/STATUS.md) is what of that protocol works today. Callers moving from an earlier snapshot should read [migration](docs/migration.md).

## Trying it

Use **Zig 0.16.0**:

```sh
zig build
zig build check
zig build test
zig build example
```

The package exports one module, `litura`. `BufferEngine` is the document. Intents, sessions and results live in `litura.types`; a committed change returns an owned `litura.events.Block`. Start with the [basic example](examples/basic.zig).

For a sibling checkout, add `.litura = .{ .path = "../litura" }` to `build.zig.zon` and:

```zig
const litura = b.dependency("litura", .{
    .target = target,
    .optimize = optimize,
    .@"tree-sitter" = false,
});
exe.root_module.addImport("litura", litura.module("litura"));
```

Tree-sitter support is optional and uses Zig's C toolchain. Lua and Zig grammars are built in; other grammars attach through `tree_sitter.Grammar`. After `attach`, call `refreshView` before querying tokens or syntax, or the query fails with `error.ViewStale`.

```sh
zig build test -Dtree-sitter=true
zig build example -Dtree-sitter=true
```

`-Dsyntax-corpus=true` runs the views against further grammars pinned as test fixtures and fetched only for that run. Each grammar runs as its own test step, in parallel. Use `-Doptimize=ReleaseSafe`: the run then takes about five minutes on a laptop, against hours in Debug.

The core uses `zg` for Unicode handling and runs independently of Substrate's application runtime.

Before submitting changes:

```sh
zig fmt --check build.zig build.zig.zon src tests examples
```

Licensed under [MIT](LICENSE).
