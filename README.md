# Litura

Litura is a document editing library for Zig, distilled from Substrate, a private project I've been working on. It keeps text, anchors, selections and edit history together, with revision-checked edits and optional syntax views.

It's an early draft. The API is still moving, and there are [known allocation-failure and transaction-safety gaps](docs/known-issues.md). It isn't hardened yet. The [draft Litura specification](docs/buffer-protocol/SPEC.md) describes the protocol we're working towards; the [implementation status](docs/buffer-protocol/STATUS.md) covers what works today.

## Trying it

Use **Zig 0.16.0**:

```sh
zig build
zig build check
zig build test
zig build example
```

Tree-sitter support for Lua, Zig and Fennel is optional:

```sh
zig build test -Dtree-sitter=true
```

The package exports one module, `litura`. Start with the [basic example](examples/basic.zig). The core uses `zg` for Unicode handling and runs independently of Substrate's application runtime.

Before submitting changes:

```sh
zig fmt --check build.zig build.zig.zon src tests examples
```

Licensed under [MIT](LICENSE).
