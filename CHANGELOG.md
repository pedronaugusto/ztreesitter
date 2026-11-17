# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- State the stability policy in the README: 0.x, tracking Zig 0.17.x; a breaking change only in a minor release, with its CHANGELOG entry; a patch release never breaks.
- Vendor the tree-sitter 0.27.1 runtime and build it with `zig build`.
- Fix tree-sitter's query parser: a field before a predicate is a syntax error, where upstream wrote one step past the query's steps (`libs/tree-sitter.patch`, UPSTREAM.md).
- Give the runtime a `strncmp` that reads no byte past its bound (`src/strncmp.c`, through `-Dstrncmp=ztreesitter_strncmp`): Zig 0.17's own, which every musl target links, reads byte n (byte 0 at n = 0), and the runtime compares strings a length bounds and no NUL ends, so a query on riscv64 faulted in `ts_language_symbol_for_name` (scheduled run 44079310151). It goes when the pinned Zig's `strncmp` stops at n.
- Pin aegis f52eabe, preflight ci-standard 9c18016 and shakedown b99b768: one aegis, where the hardened jobs held two (`file exists in modules 'aegis' and 'aegis0'`). The catalogue tool's tests take aegis in their own target and mode, the one the hardened run's quarantine (shakedown, declared with them) reaches, where the host tools' Debug aegis made a second copy in that run (release run 44104720824). The tests are portable (`.portable_tests`), so the native link jobs `compile_once` plans have their `ci-build`; the sanitized job runs in the `ci` tier, where it ran in the retired `merge` tier.
- Hold glint 0.8's rules with no suppression: the runtime's C declarations and the allocator are seams in `glint.json`, the package's files read the runtime's arrays and layout-equal types through one internal seam file (`src/seam.zig`), and errors are returned or handled by name.
- Take no build option in a consumer's build: two dependents asking for two argument sets would make two instances of ztreesitter, which Zig refuses for one file in two modules. A consumer's runtime is never sanitized; the suite runs once more with it sanitized under `-Dsanitize_c`, a development option.
- Bind every function and type of `api.h` the build compiles, checked against the header by reflection in both directions.
- Add the Zig API: `Parser`, `Tree`, `Node`, `TreeCursor`, `Query`, `QueryCursor`, `Language`, with chunked text input, included ranges, changed ranges, cancellation and a deadline that pauses and resumes a parse.
- Evaluate query predicates in tree-sitter's dialect and Neovim's, with a Pike VM for both regular expression syntaxes and a Lua pattern matcher; allocate nothing while matching.
- Collect definitions and references from tags queries as tree-sitter's `tags` crate does: docs narrowed by `select-adjacent!` and cleaned by `strip!` (`Tags.docText`), names a locals query defines in scope dropped under `(#is-not? local)`, honouring `local.scope-inherits`.
- Write tags queries for Swift and C# (`queries/`, MIT), taking precedence over upstream's: type and member definitions, and references from calls, member access, inheritance, generic arguments, parameter and field types, attributes and imports.
- Add `Layers`: a document's trees, the root and one per injection, resolved with Neovim's injection semantics over a wanted range, re-parsed after edits only where touched.
- Catalogue nvim-treesitter's 320 grammars with `zig build catalogue` (`tools/catalogue.zig`), mirrored in this repository, each a lazy dependency compiled only when named through `addGrammars`, with its queries and licence.
- Link grammars beside each other and the program: globals a grammar's C defines outside its namespace are recorded by the catalogue tool and renamed by the build (`renamed`), and `check-grammars` refuses any left.
- Name a mirror's generator in its ref: a grammar whose parser this repository generates is mirrored under `<commit>-tree-sitter-<version>`, and the tool refuses one whose ref does not name its generator.
- Put a Zig allocator behind the runtime with `setAllocator`.
