# Upstream

## The runtime

`libs/tree-sitter` is a copy of the tree-sitter runtime with one fix,
`libs/tree-sitter.patch` (below).

| | |
|---|---|
| Source | <https://github.com/tree-sitter/tree-sitter> |
| Version | 0.27.1 |
| Tag | `v0.27.1` |
| Commit | `10eb5ac119eec9cb4267a8e035066473983f5f3a` |
| Licence | MIT (`libs/tree-sitter/LICENSE`) |

Taken: `lib/src`, `lib/include` and `LICENSE`, at their upstream paths. Left
out: the CLI, the bindings, the WebAssembly runtime's prebuilt pieces, the
tests and every build system; `build.zig` compiles `lib/src/lib.c`, the one
translation unit upstream's own builds use, with the same macros.
`zig build check-vendor` checks the tag still names the commit, downloads
that commit, applies `libs/tree-sitter.patch` to it with `git apply` and
compares the three paths with no exclusions.

Not compiled: WebAssembly grammar support (`TREE_SITTER_FEATURE_WASM`), which
needs wasmtime. The five entry points that exist only with it are excluded by
name in `src/abi_check.zig`.

Patched: `libs/tree-sitter.patch`, against `v0.27.1`
(`10eb5ac119eec9cb4267a8e035066473983f5f3a`), one change:

- `lib/src/query.c`, `ts_query__parse_pattern`, line 2886 at `v0.27.1`:
  for a field before a predicate, `(pair key: (#set! x))` on json, the
  field is set on `steps[steps.size]` (an assertion failure in a debug
  build, a write past the array in a release build). The patch returns
  `TSQueryErrorSyntax` at the field name. Unchanged upstream at `master`
  `ad067fddf76a32c3071f8f3a31e8719d348e2737`. Test: "a field before a
  predicate is a syntax error at the field" in `tests/tests.zig`.

Known upstream behaviour, recorded rather than patched: `lib/src/query.c`
(`symbol_table_insert_name`, line 960) copies a query's empty string literal
with `memcpy(dst, NULL, 0)`. That is undefined behaviour in C before C2y and
harmless in practice; glibc's headers declare `memcpy`'s arguments non-null,
so the undefined-behaviour sanitizer stops on it on Linux. With
`-Dsanitize_c` the runtime is compiled with every check but that one
(`-fno-sanitize=nonnull-attribute`). Found by CI on 2026-10-03 compiling
nvim-treesitter's `(#set! conceal "")`.

To re-vendor: replace the three paths from the new tag, apply
`libs/tree-sitter.patch` (dropping any change the new tag already makes, and
regenerating it with `git diff` against the tag), update this table,
the constants at the top of `tools/upstream.zig`, `runtime_version` in
`src/ztreesitter.zig` and in `tools/catalogue.zig`, then run
the suite. The ABI guard fails the build if the header changed under
`src/c.zig`.

## The grammar catalogue

The catalogue is nvim-treesitter's parser list, pinned by commit, with each
grammar at the revision nvim-treesitter's queries are written against.
`zig build catalogue` (`tools/catalogue.zig`) regenerates it:

```sh
zig build catalogue -- --nvim-treesitter <commit> --helix <commit> --tree-sitter <tree-sitter 0.27.1 CLI>
```

| | |
|---|---|
| nvim-treesitter | `910fdf6f49e9dee7e7257c7d11a76b040fdfb9de` (2026-09-30) |
| Helix (tags queries) | `ba40e547426b0f9896c8bdc699a4ab11f2b37dbc` |

It writes `build.zig.zon`'s generated block, `grammars/catalogue.zig` and
`docs/grammars.md`, and publishes one mirror per grammar repository as an
orphan commit in this repository. Push them with `git push origin
'refs/mirror/*'`. A mirror holds the files a grammar's build and queries read,
at upstream's paths, unmodified, plus any `parser.c` the tool generated; its
`PROVENANCE` file says which, and by which generator.

A mirror's ref names everything that determined its bytes:
`refs/mirror/<owner>/<repo>/<commit>` for upstream's files alone, and
`<commit>-tree-sitter-<version>` when the tool generated a parser in it. A
published ref never moves: a new CLI writes generated mirrors under new refs,
and the tool refuses a generated mirror under a ref that does not name its
generator.

Four grammars commit no `parser.c` (latex, perl, pod, swift). The tool
generates theirs with the tree-sitter CLI at the runtime's version, using its
built-in JavaScript engine (`--js-runtime native`), so no Node.js is involved.
