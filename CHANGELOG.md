# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Vendor the tree-sitter 0.27.0 runtime and build it with `zig build`.
- Bind every function and type of `api.h` the build compiles, checked against the header by reflection in both directions.
- Add the Zig API: `Parser`, `Tree`, `Node`, `TreeCursor`, `Query`, `QueryCursor`, `Language`, with chunked text input, included ranges, changed ranges, cancellation and a deadline that pauses and resumes a parse.
- Evaluate query predicates in tree-sitter's dialect and Neovim's, with a Pike VM for both regular expression syntaxes and a Lua pattern matcher; allocate nothing while matching.
- Collect definitions and references from tags queries.
- Catalogue nvim-treesitter's 320 grammars with `zig build catalogue` (`tools/catalogue.zig`), mirrored in this repository, each a lazy dependency compiled only when named through `addGrammars`, with its queries and licence.
- Put a Zig allocator behind the runtime with `setAllocator`.
