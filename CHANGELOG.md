# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Vendor the tree-sitter 0.27.1 runtime and build it with `zig build`.
- Fix tree-sitter's query parser: a field before a predicate is a syntax error, where upstream wrote one step past the query's steps (`libs/tree-sitter.patch`, UPSTREAM.md).
- Bind every function and type of `api.h` the build compiles, checked against the header by reflection in both directions.
- Add the Zig API: `Parser`, `Tree`, `Node`, `TreeCursor`, `Query`, `QueryCursor`, `Language`, with chunked text input, included ranges, changed ranges, cancellation and a deadline that pauses and resumes a parse.
- Evaluate query predicates in tree-sitter's dialect and Neovim's, with a Pike VM for both regular expression syntaxes and a Lua pattern matcher; allocate nothing while matching.
- Collect definitions and references from tags queries as tree-sitter's `tags` crate does: docs narrowed by `select-adjacent!` and cleaned by `strip!` (`Tags.docText`), names a locals query defines in scope dropped under `(#is-not? local)`, honouring `local.scope-inherits`.
- Write tags queries for Swift and C# (`queries/`, MIT), taking precedence over upstream's: type and member definitions, and references from calls, member access, inheritance, generic arguments, parameter and field types, attributes and imports.
- Add `Layers`: a document's trees, the root and one per injection, resolved with Neovim's injection semantics over a wanted range, re-parsed after edits only where touched.
- Catalogue nvim-treesitter's 320 grammars with `zig build catalogue` (`tools/catalogue.zig`), mirrored in this repository, each a lazy dependency compiled only when named through `addGrammars`, with its queries and licence.
- Name a mirror's generator in its ref: a grammar whose parser this repository generates is mirrored under `<commit>-tree-sitter-<version>`, and the tool refuses one whose ref does not name its generator.
- Put a Zig allocator behind the runtime with `setAllocator`.
