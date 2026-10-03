# Upstream

## The runtime

`libs/tree-sitter` is a copy of the tree-sitter runtime, unmodified.

| | |
|---|---|
| Source | <https://github.com/tree-sitter/tree-sitter> |
| Version | 0.27.0 |
| Tag | `v0.27.0` |
| Commit | `6070dbfefd326bd735e5683eb128cc1b57dad0c0` |
| Licence | MIT (`libs/tree-sitter/LICENSE`) |

Taken: `lib/src`, `lib/include` and `LICENSE`, at their upstream paths. Left
out: the CLI, the bindings, the WebAssembly runtime's prebuilt pieces, the
tests and every build system; `build.zig` compiles `lib/src/lib.c`, the one
translation unit upstream's own builds use, with the same macros.
`ci/verify-vendor.sh` clones the tag and diffs the three paths with no
exclusions.

Not compiled: WebAssembly grammar support (`TREE_SITTER_FEATURE_WASM`), which
needs wasmtime. The five entry points that exist only with it are excluded by
name in `src/abi_check.zig`.

To re-vendor: replace the three paths from the new tag, update this table,
the constants at the top of `ci/verify-vendor.sh`, `runtime_version` in
`src/ztreesitter.zig` and `RUNTIME_VERSION` in `tools/catalogue.py`, then run
the suite. The ABI guard fails the build if the header changed under
`src/c.zig`.

## The grammar catalogue

The catalogue is nvim-treesitter's parser list, pinned by commit, with each
grammar at the revision nvim-treesitter's queries are written against.
`tools/catalogue.py` regenerates it:

```sh
tools/catalogue.py --nvim-treesitter <commit> --helix <commit> --tree-sitter <tree-sitter 0.27.0 CLI>
```

| | |
|---|---|
| nvim-treesitter | `910fdf6f49e9dee7e7257c7d11a76b040fdfb9de` (2026-09-30) |
| Helix (tags queries) | `ba40e547426b0f9896c8bdc699a4ab11f2b37dbc` |

It writes `build.zig.zon`'s generated block, `grammars/catalogue.zig` and
`docs/grammars.md`, and publishes one mirror per grammar repository as an
orphan commit under `refs/mirror/<owner>/<repo>/<commit>` in this repository.
Push them with `git push origin 'refs/mirror/*'`. A mirror holds the files a
grammar's build and queries read, at upstream's paths, unmodified, plus any
`parser.c` the tool generated; its `PROVENANCE` file says which.

Four grammars commit no `parser.c` (latex, perl, pod, swift). The tool
generates theirs with the tree-sitter CLI at the runtime's version, using its
built-in JavaScript engine (`--js-runtime native`), so no Node.js is involved.
