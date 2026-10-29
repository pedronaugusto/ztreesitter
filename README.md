# ztreesitter

[tree-sitter](https://tree-sitter.github.io/) for Zig 0.17: the runtime,
vendored and built with `zig build`, a Zig API over it, query predicates in
both the dialect tree-sitter's own bindings use and Neovim's, tags, a
document's injected layers, and a catalogue of the 320 grammars nvim-treesitter pins, each compiled only when a
program names it.

## Usage

The block below is a region of [`examples/usage.zig`](examples/usage.zig),
which `zig build test` builds and runs. preflight's docs check keeps the two
the same; `zig build docs -- usage` prints the block.

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const ts = @import("ztreesitter");
const grammars = @import("grammars"); // made by addGrammars, see Install

const zig = &grammars.zig;
const source = "pub fn add(a: u32, b: u32) u32 {\n    return a + b;\n}\n";

var parser: ts.Parser = .init();
defer parser.deinit();
try parser.setLanguage(zig.language());

// The text stays the caller's. `parse` is a cancellation point on `io`
// and can stop at a deadline and resume.
var tree = try parser.parse(io, .{ .slice = source }, null, .{});
defer tree.deinit();

// Queries come with the grammar, each in the dialect it was written in.
const highlights = zig.queries.highlights.?;
var query: ts.Query = try .init(gpa, zig.language(), highlights.text, .{ .dialect = highlights.dialect });
defer query.deinit();

// A cursor is reusable and allocates nothing while matching.
var cursor: ts.QueryCursor = try .init(gpa);
defer cursor.deinit();
var captures = cursor.captures(io, &query, tree.rootNode(), .{ .slice = source }, .{});
while (try captures.next()) |event| {
    const name = query.captureName(event.capture().index);
    try out.print("{s:<24} {s}\n", .{ name, event.node().text(source) });
}
```
<!-- END GENERATED -->

## Install

```sh
zig fetch --save git+https://github.com/pedronaugusto/ztreesitter
```

In `build.zig`, the application names its grammars once:

```zig
const ztreesitter = @import("ztreesitter");

const ts_dep = b.dependency("ztreesitter", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("ztreesitter", ts_dep.module("ztreesitter"));
if (ztreesitter.addGrammars(b, ts_dep, &.{ "zig", "c", "swift" }, .{})) |grammars| {
    exe.root_module.addImport("grammars", grammars);
}
```

`addGrammars` requests each grammar's lazy dependency, so only named grammars
are fetched, and returns null on the first configure pass while they are.
The module it returns has one `ts.Grammar` per grammar (`grammars.zig`,
`grammars.swift`, and `grammars.list`), each with its language, its queries,
its licence and where it comes from. Grammars a named one needs, such as
markdown_inline for markdown, are added. `"all"` names every grammar the
catalogue does not exclude, but for the GPL and LGPL ones, which a program
gets only by naming them ([LICENSES.md](LICENSES.md)).

Grammars are an application's choice. A library built on ztreesitter takes
an option-free dependency and receives `ts.Grammar` values at run time:
two libraries asking ztreesitter for different grammar sets would get two
instances of it, with two runtimes, and trees that cannot cross between them.
For the same reason a library re-exports its ztreesitter module, and an
application takes it from there rather than pinning a second copy.

`.linkage = .dynamic` builds each grammar as a shared library instead; the
module then carries queries only, and `ts.Language.load(path, symbol)` opens a
language at run time. That is how a program with hundreds of grammars stays
small.

A statically linked grammar defines only names in its own namespace: its
language function and names beginning with it. Some grammars' C defines
other globals (`keywords`, `end`, another grammar's scanner functions); the
catalogue records them and the build renames each to
`tree_sitter_<name>__<global>`, so grammars link beside each other and
beside the program.

## Grammars

[docs/grammars.md](docs/grammars.md) lists every grammar with its ABI
version, scanner, tags query, licence, and anything the catalogue tool had to
say about it. It is generated, with `grammars/catalogue.zig` and the
dependency block of `build.zig.zon`, by `zig build catalogue`
(`tools/catalogue.zig`) from a pinned nvim-treesitter commit;
[UPSTREAM.md](UPSTREAM.md) has the procedure.

Each grammar is fetched from a mirror in this repository: the files its build
and its queries read, at the grammar repository's own paths, published as an
orphan commit. Grammar repositories that ship their own `build.zig` would
otherwise have it compiled into the build (several do not compile on current Zig),
some contain symlinks Windows cannot create, and four commit no `parser.c`;
the mirror holds the parser this repository generates for those.

Queries come from four places: highlights, injections, locals, folds and
indents from nvim-treesitter, written against the same grammar revisions;
tags from this repository's `queries/` (Swift and C#: definitions of every
kind, and references from calls, member access, inheritance, generic
arguments, parameter, field and property types, attributes and imports),
else the grammar's own repository, else Helix. `; inherits:` lines
are resolved as Neovim resolves them. Not every language has every query:
of nvim-treesitter's 323, all have highlights, 300 injections, 224 folds,
168 indents and 151 locals; 70 grammars have a tags query, and most of those
describe definitions only.

## API

| | |
|---|---|
| `Parser` | one thread at a time; `setLanguage`, `setIncludedRanges`, `parse`, `reset` |
| `Tree` | owns a `TSTree`; `copy` for another thread, `edit`, `changedRanges`, `includedRanges` |
| `Node` | a value borrowing its tree; kind, positions, navigation, `text` |
| `TreeCursor` | the cheapest walk of a tree |
| `Query` | compiled once with its predicates, shared across threads |
| `QueryCursor` | one thread; `matches` and `captures`, filtered by predicates |
| `Tags` | definitions and references from a tags query, with docs (`select-adjacent!`, `strip!`) and a locals query for `(#is-not? local)` |
| `Layers` | a document's trees: the root and one per injection; `update`, `edit`, `snapshot` |
| `Language` | ABI version, symbols, fields; `load` for a shared-library grammar |
| `c` | every function and type of `api.h` this build compiles |

The text is always the caller's. `Input` is a slice or a reader that returns
chunks, so a rope or a gap buffer is parsed and queried in place. UTF-16 input
is accepted.

`Parser.parse` and the cursor iterators take a `std.Io`. They are
cancellation points (`error.Canceled`), and a `deadline` stops them with
`error.Paused`; calling again resumes where they stopped, which is how an
editor parses in time slices. Nothing here starts a thread. Parsing many files
in parallel is an `Io.Group` with a parser and a cursor per task, sharing the
languages and queries.

`Layers` resolves injections with Neovim's semantics: the language from
`#set! injection.language`, an `@injection.language` capture (after `gsub!`),
`injection.self` or `injection.parent`; the ranges from `@injection.content`,
moved by `offset!`, without named children unless
`injection.include-children`; one layer per match, or per pattern and
language under `injection.combined`. An `InjectionResolver` the caller embeds
in its own state turns a language name into a `Grammar`, so aliases are the
caller's. `update(io, input, wanted, options)` parses the root, resolves
injections over `wanted` only (combined ones over the whole document, since a
partial set would parse another tree), parses the layers that meet it, and
returns where the layers changed. `edit` records an edit on every tree; the
next `update` parses again only the layers it touched. One parser per
language serves every layer of it, nesting stops at `max_depth` (8), and a
`snapshot` copies the trees for another thread.

## Design

- **Predicates have two dialects.** The runtime leaves predicates to the
  binding. nvim-treesitter's queries are written for Neovim, where `match?`
  is a Vim regular expression in very-magic mode and `lua-match?` a Lua
  pattern; grammar repositories and Helix write `match?` in the Rust
  `regex` crate's syntax. Each embedded query carries its dialect, and
  `Query.init` takes one. Both regex syntaxes compile to one Pike VM, which
  reads text in chunks and runs in linear time; Lua patterns follow Lua 5.1's
  matcher.
- **Matching allocates nothing, and is bounded.** A `QueryCursor` holds its
  working memory (about 72 KB) from `init`. A Lua pattern backtracks, as in
  Lua: its search is a cancellation point and stops with
  `error.TooManySteps` past a step budget, dropping that match undecided. A query's predicates are compiled once, with the
  allocator given to `Query.init`, which the query keeps.
- **Unknown predicates are refused.** `Query.init` fails with
  `UnsupportedPredicate`, naming the predicate and pattern in a
  `QueryDiagnostic`, unless the caller lists it as pass-through. `set!`,
  `is?`, `is-not?` and the directives (`offset!`, `gsub!`, `strip!`, ...)
  are kept for the consumer.
- **The allocator seam covers the runtime only.** `setAllocator` puts a Zig
  allocator behind `ts_set_allocator`, process-wide, before any parser
  exists. The runtime never checks an allocation, so a failure through the
  seam panics. Grammar scanners allocate with libc: some mix the runtime's
  functions with libc's, so they are not pointed at the seam.
- **Grammar C is never sanitized.** It is third-party and unpatched, and
  Zig's Debug default would trap on its undefined behaviour in every
  consumer's Debug build. `-Dsanitize_c` turns the sanitizer on for the
  runtime.
- **The C surface is checked against the header.** `src/c.zig` is written by
  hand and `src/abi_check.zig` compares it with `api.h` by reflection in both
  directions, so a re-vendor that changes the API fails to compile.

## Scope

- No WebAssembly grammars: they need wasmtime.
- No parser generation at build time; generated parsers are committed by the
  catalogue tool.
- No highlighting or themes.
- `lua-match?` and `contains?` read a node's text from a reader input
  through a 16 KB buffer, so on a longer node they see its first 16 KB.
  `eq?` and `any-of?` compare whole texts, however long.
- Grammars outside the catalogue are compiled by the caller and passed in
  with `Language.fromC`.

## Testing

`zig build test` runs the unit tests and the grammar tests with the
representative set: bash, c, c_sharp, cpp, css, html, javascript, json, lua,
markdown, markdown_inline, python, regex, rust, scss, swift, tsx, typescript and zig.
They cover one repository with its own Zig build (c), query inheritance (cpp,
tsx), the largest parse tables in the set (c_sharp), a generated parser
(swift), an ABI 13 grammar with a C scanner (scss), two grammars in one
repository (typescript and tsx; markdown and
markdown_inline), and injection hosts (html, markdown). `-Dgrammars=a,b` or
`all` changes the set.

Every selected grammar must load, parse a sample without errors and compile
every query in its dialect. Other tests check incremental parsing against
fresh parses over 200 random edits, included ranges for HTML and nested
Markdown injections, `Layers` over HTML (scripts by type, styles) and
Markdown (front matter, inline text, nested fences, combined HTML blocks)
through edits, a wanted range, UTF-16, a deadline and a snapshot, predicates in Neovim's dialect, `eq?` and `any-of?` on
long and UTF-16 reader text, tag definitions in C, Swift and C#,
references in Rust, JavaScript docs through `select-adjacent!` and `strip!`,
locals scopes with and without `local.scope-inherits`, a deadline that pauses and resumes a parse, a canceled
parse, and the allocator seam's balance.

Fuzz targets, as shakedown properties: any bytes parse, and parse to the same
tree from a reader in any pieces; any query source compiles or is refused;
`eq?` holds exactly for equal texts from a slice, a reader and UTF-16; a
regular expression in either dialect compiles or is refused and answers the
same fed in pieces; and matching never refuses a Lua pattern validation
accepted, though it may stop at the step budget.

`bench/throughput.zig` measures parse and parse-plus-tags throughput for each
grammar built, through preflight's `bench` step.

Two checks need the network and run on their own: `zig build check-vendor`
compares `libs/tree-sitter` with the pinned upstream commit plus
`libs/tree-sitter.patch` (one fix, described in UPSTREAM.md), and
`zig build verify-mirror` compares each selected grammar's mirror with its
repository at the catalogued commit (`-Dgrammars=all` for every one).

While this repository is private, Zig cannot fetch the mirrors from GitHub;
`ci/seed-mirrors.sh GRAMMAR...` puts them in the package cache from the local
refs.

[CI](.github/workflows/ci.yml) is preflight's gate, generated from
`ci/workflow.json` by `bay generate`: the source checks (formatting, glint's
rules, layers, this README's usage block), the suite on Linux, macOS and
Windows, compile-only targets, and the suite with the runtime sanitized. The
nightly adds the full matrix, the vendor check, and every grammar of the
catalogue compiled and linked, each defining only names in its namespace and
none defined twice (`zig build check-grammars -Dgrammars=all`).

## Licence

MIT, see [LICENSE](LICENSE). The runtime is MIT. Queries and grammars keep
their own licences; [LICENSES.md](LICENSES.md) says what reaches a binary.
