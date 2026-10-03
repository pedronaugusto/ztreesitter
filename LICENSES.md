# Licences

What reaches a program built with ztreesitter, and what its notices need.

| Part | Licence | Reaches your binary |
|---|---|---|
| ztreesitter's own code and `queries/` | MIT, [LICENSE](LICENSE) | always |
| tree-sitter runtime (`libs/tree-sitter`) | MIT, [libs/tree-sitter/LICENSE](libs/tree-sitter/LICENSE) | always |
| nvim-treesitter queries | Apache-2.0 | when a grammar's highlights, injections, locals, folds or indents are embedded |
| Helix `tags.scm` | MPL-2.0 | when a grammar takes its tags query from Helix |
| each grammar | its own; see [docs/grammars.md](docs/grammars.md) | when you name it |

Every `Grammar` value carries its grammar's SPDX identifier (`licence`) and
repository (`url`), so a program can print the notices for exactly the
grammars it links.

**nvim-treesitter** (<https://github.com/nvim-treesitter/nvim-treesitter>) is
Apache-2.0. Its queries are embedded unmodified. A program shipping them
includes the licence text and keeps the copyright notices; the queries carry
no NOTICE file.

**Helix** (<https://github.com/helix-editor/helix>) is MPL-2.0, a file-level
licence. The `tags.scm` files taken from it are embedded unmodified. MPL-2.0
section 3.2 asks a distributor of an executable to tell recipients how to get
the source of those files: point them at the Helix commit in
[UPSTREAM.md](UPSTREAM.md).

**Grammars.** Most are MIT. The current catalogue has copyleft ones —
GPL-3.0 (caddy, disassembly, objdump, usd, and rnoweb by declaration),
LGPL-3.0 (ralph), LGPL-2.1 (vala), MPL-2.0 (nim, inko), Artistic-2.0 (pod) —
and 23 that ship no licence file, only a declaration in `package.json` or
`tree-sitter.json`. `docs/grammars.md` lists each, with what the licence file
says and what the repository declares where the two disagree. Nothing is
compiled unless a program names it.
