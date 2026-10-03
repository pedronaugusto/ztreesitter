#!/usr/bin/env python3
"""Regenerate the grammar catalogue from a pinned nvim-treesitter commit.

The catalogue is nvim-treesitter's parser list: each grammar's repository and
revision, which nvim-treesitter's queries are written against. This script is
the only way it changes. It writes three files and nothing else:

    build.zig.zon           the dependency block between the GENERATED markers
    grammars/catalogue.zig  every grammar as data, read by build.zig and by the
                            `ztreesitter.catalogue` module
    docs/grammars.md        the per-grammar report

For each grammar it downloads the repository at its commit, records where the
parser lives, whether it has an external scanner, the ABI version of its
parser.c, the symbol it exports, its licence and its query files, and asks
`zig fetch` for the package hash. A grammar whose repository commits no
parser.c is generated with the tree-sitter CLI pinned to the vendored
runtime's version, and the output is published as an orphan commit in this
repository (see --publish-generated).

Needs network, zig, git, and for generation the tree-sitter CLI.

Usage:
    tools/catalogue.py --nvim-treesitter <commit> --helix <commit>
                       [--cache DIR] [--tree-sitter PATH]
                       [--only a,b] [--jobs N]
"""

import argparse
import concurrent.futures
import hashlib
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import tomllib
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUNTIME_VERSION = "0.27.0"
REPOSITORY = "https://github.com/pedronaugusto/ztreesitter"
QUERY_KINDS = ("highlights", "injections", "locals", "folds", "indents", "tags")
NVIM_KINDS = ("highlights", "injections", "locals", "folds", "indents")

# Grammars excluded on purpose, with the reason the build prints. Empty until
# a grammar is found that cannot be built unpatched.
EXCLUDED = {}

# Grammars built and tested by CI. The rest are catalogued and fetchable but
# reported as untested until the all-grammars job has compiled them.
TESTED = {
    "bash", "c", "c_sharp", "cpp", "css", "html", "javascript", "json", "lua",
    "markdown", "markdown_inline", "python", "regex", "rust", "swift", "tsx",
    "typescript", "zig", "ecma", "jsx", "html_tags",
}


# ---------------------------------------------------------------------------
# Lua table literals
#
# parsers.lua is `return { name = { key = 'value', ... }, ... }`. This reads
# that subset of Lua: tables, strings, numbers, booleans, comments.
# ---------------------------------------------------------------------------

class LuaReader:
    TOKEN = re.compile(
        r"""\s+|--\[\[.*?\]\]|--[^\n]*|(?P<str>'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*")"""
        r"""|(?P<num>-?\d+(?:\.\d+)?)|(?P<name>[A-Za-z_][A-Za-z0-9_]*)|(?P<punct>[{}=,\[\]])""",
        re.S,
    )

    def __init__(self, text):
        self.tokens = []
        pos = 0
        while pos < len(text):
            m = self.TOKEN.match(text, pos)
            if not m:
                raise ValueError(f"lua: unexpected {text[pos:pos + 20]!r}")
            pos = m.end()
            for kind in ("str", "num", "name", "punct"):
                if m.group(kind) is not None:
                    self.tokens.append((kind, m.group(kind)))
        self.i = 0

    def peek(self):
        return self.tokens[self.i] if self.i < len(self.tokens) else (None, None)

    def take(self, value=None):
        tok = self.peek()
        if value is not None and tok[1] != value:
            raise ValueError(f"lua: expected {value!r}, found {tok[1]!r}")
        self.i += 1
        return tok

    def value(self):
        kind, text = self.take()
        if kind == "str":
            return bytes(text[1:-1], "utf-8").decode("unicode_escape")
        if kind == "num":
            return float(text) if "." in text else int(text)
        if kind == "name" and text in ("true", "false"):
            return text == "true"
        if kind == "name" and text == "nil":
            return None
        if text == "{":
            return self.table()
        raise ValueError(f"lua: unexpected {text!r}")

    def table(self):
        items, keyed = [], {}
        while self.peek()[1] != "}":
            kind, text = self.peek()
            if kind == "name" and self.tokens[self.i + 1][1] == "=":
                self.take()
                self.take("=")
                keyed[text] = self.value()
            elif text == "[":
                self.take()
                key = self.value()
                self.take("]")
                self.take("=")
                keyed[key] = self.value()
            else:
                items.append(self.value())
            if self.peek()[1] == ",":
                self.take()
        self.take("}")
        if items and keyed:
            raise ValueError("lua: mixed table")
        return items if items else keyed

    @classmethod
    def read_module(cls, text):
        reader = cls(text)
        reader.take("return")
        return reader.value()


# ---------------------------------------------------------------------------
# Downloads
# ---------------------------------------------------------------------------

def run(args, **kw):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kw).stdout


def github_parts(url):
    m = re.match(r"https://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$", url)
    if not m:
        raise ValueError(f"not a GitHub repository: {url}")
    return m.group(1), m.group(2)


def resolve_commit(url, revision):
    if re.fullmatch(r"[0-9a-f]{40}", revision):
        return revision
    out = run(["git", "ls-remote", url, f"refs/tags/{revision}", f"refs/tags/{revision}^{{}}",
               f"refs/heads/{revision}"])
    refs = dict(reversed(line.split("\t")) for line in out.splitlines())
    for ref in (f"refs/tags/{revision}^{{}}", f"refs/tags/{revision}", f"refs/heads/{revision}"):
        if ref in refs:
            return refs[ref]
    raise ValueError(f"{url}: cannot resolve {revision}")


def tarball_url(url, commit):
    owner, repo = github_parts(url)
    return f"https://github.com/{owner}/{repo}/archive/{commit}.tar.gz"


_locks = {}
_locks_guard = threading.Lock()


def download(url, commit, cache):
    owner, repo = github_parts(url)
    dest = cache / "src" / f"{owner}--{repo}--{commit}"
    with _locks_guard:
        lock = _locks.setdefault(dest, threading.Lock())
    with lock:
        return _download(url, commit, cache, dest)


def _download(url, commit, cache, dest):
    if dest.is_dir():
        return dest
    with urllib.request.urlopen(tarball_url(url, commit), timeout=300) as response:
        data = response.read()
    tmp = pathlib.Path(tempfile.mkdtemp(dir=cache))
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        tar.extractall(tmp, filter="tar")
    (top,) = list(tmp.iterdir())
    dest.parent.mkdir(parents=True, exist_ok=True)
    top.rename(dest)
    shutil.rmtree(tmp)
    return dest


def zig_hash(target, cache):
    """`zig fetch` in a cache of its own, so a catalogue run never fills the
    maintainer's global cache with every grammar."""
    project = cache / "project"
    project.mkdir(exist_ok=True)
    (project / "build.zig").write_text("pub fn build(_: *@import(\"std\").Build) void {}\n")
    target = os.path.abspath(target) if os.path.exists(target) else target
    out = run(["zig", "fetch", "--global-cache-dir", str(cache / "zig"), str(target)], cwd=project)
    package = project / "zig-pkg" / out.strip()
    if package.is_dir():  # the unpacked copy is not needed once hashed
        shutil.rmtree(package)
    return out.strip()


# ---------------------------------------------------------------------------
# Licences
# ---------------------------------------------------------------------------

LICENCE_FILE = re.compile(r"(?i)^(licen[cs]e|copying)([-._].*)?$")


def classify_licence(text):
    t = " ".join(text.lower().split())
    # The GNU licences name each other in their bodies; the title decides.
    head = t[:400]
    if "mozilla public license" in head and "2.0" in head:
        return "MPL-2.0"
    if "gnu lesser general public license" in head or "gnu library general public license" in head:
        return "LGPL-3.0" if "version 3" in head else "LGPL-2.1"
    if "gnu affero general public license" in head:
        return "AGPL-3.0"
    if "gnu general public license" in head:
        return "GPL-3.0" if "version 3" in head else "GPL-2.0"
    if "apache license" in t and "version 2.0" in t:
        return "Apache-2.0"
    if "the artistic license 2.0" in t:
        return "Artistic-2.0"
    if "eclipse public license" in t:
        return "EPL-2.0" if "2.0" in t else "EPL-1.0"
    if "boost software license" in t:
        return "BSL-1.0"
    if "this is free and unencumbered software released into the public domain" in t:
        return "Unlicense"
    if "cc0 1.0 universal" in t or "creativecommons.org/publicdomain/zero" in t:
        return "CC0-1.0"
    if "permission is hereby granted, free of charge" in t:
        return "MIT"
    if "permission to use, copy, modify, and/or distribute this software for any purpose" in t:
        return "0BSD" if "with or without fee" in t and "copyright notice" not in t else "ISC"
    if "permission to use, copy, modify, and distribute this software for any purpose" in t:
        return "ISC"
    if "redistribution and use in source and binary forms" in t:
        if "neither the name" in t or "endorse or promote" in t:
            return "BSD-3-Clause"
        return "BSD-2-Clause"
    if "altered source versions must be plainly marked" in t:
        return "Zlib"
    return None


def declared_licences(*dirs):
    found = {}
    for d in dirs:
        for name, read in (("tree-sitter.json", lambda j: j.get("metadata", {}).get("license")),
                           ("package.json", lambda j: j.get("license"))):
            p = d / name
            if name in found or not p.is_file():
                continue
            try:
                value = read(json.loads(p.read_text(encoding="utf-8")))
            except (ValueError, AttributeError):
                continue
            if isinstance(value, str) and value:
                found[name] = value
    return found


def licence_of(repo, grammar_dir):
    files = []
    for d in dict.fromkeys([grammar_dir, repo]):
        files += sorted(p for p in d.iterdir() if p.is_file() and LICENCE_FILE.match(p.name))
    declared = declared_licences(grammar_dir, repo)
    detected = []
    for p in files:
        kind = classify_licence(p.read_text(encoding="utf-8", errors="replace"))
        detected.append((p.relative_to(repo).as_posix(), kind))
    spdx, note = "unknown", ""
    known = [k for _, k in detected if k]
    if known:
        spdx = known[0]
        decl = set(declared.values())
        if decl and spdx not in decl and not any(spdx in d for d in decl):
            note = "file says " + spdx + ", declared " + ", ".join(sorted(decl))
    elif detected:
        note = "licence file not recognised"
        if declared:
            note += "; declared " + ", ".join(sorted(set(declared.values())))
    elif declared:
        note = "no licence file; declared " + ", ".join(sorted(set(declared.values())))
    else:
        note = "no licence file and no declaration"
    return {
        "spdx": spdx,
        "file": detected[0][0] if detected else "",
        "note": note,
    }


# ---------------------------------------------------------------------------
# Grammar inspection
# ---------------------------------------------------------------------------

def tree_sitter_json_queries(repo, location):
    """Per-grammar query paths from tree-sitter.json, relative to the repo."""
    p = repo / "tree-sitter.json"
    if not p.is_file():
        return {}
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except ValueError:
        return {}
    for g in data.get("grammars", []):
        if (g.get("path") or ".").strip("./") == location.strip("./"):
            out = {}
            for kind in QUERY_KINDS:
                value = g.get(kind)
                if isinstance(value, str):
                    value = [value]
                if value:
                    out[kind] = [v.lstrip("./") for v in value]
            return out
    return {}


def upstream_tags(repo, location):
    declared = tree_sitter_json_queries(repo, location).get("tags")
    if declared:
        paths = [p for p in declared if (repo / p).is_file()]
        if paths:
            return paths
    for base in dict.fromkeys([pathlib.PurePosixPath(location) / "queries", pathlib.PurePosixPath("queries")]):
        candidate = (base / "tags.scm").as_posix().lstrip("./")
        if (repo / candidate).is_file():
            return [candidate]
    return []


ABI = re.compile(rb"#define LANGUAGE_VERSION (\d+)")
SYMBOL = re.compile(rb"\b(?:const\s+)?TSLanguage\s*\*\s*(tree_sitter_[A-Za-z0-9_]+)\s*\(\s*(?:void)?\s*\)\s*\{")


def parser_facts(src):
    with open(src / "parser.c", "rb") as f:
        data = f.read()
    abi = ABI.search(data[:20000])
    symbols = SYMBOL.findall(data)
    if not abi or len(symbols) != 1:
        raise ValueError(f"{src}/parser.c: ABI {abi} symbols {symbols}")
    return int(abi.group(1)), symbols[0].decode()


def same_generation(src, generated):
    return all((src / f).is_file() and (src / f).read_bytes() == (generated / f).read_bytes()
               for f in ("grammar.json", "node-types.json"))


def generate(repo, location, tree_sitter, workdir):
    """Generate in a copy of the whole repository: a grammar in a subdirectory
    may require files from its parent."""
    work = workdir / "repo"
    if work.exists():
        shutil.rmtree(work)
    shutil.copytree(repo, work, symlinks=True)
    version = run([tree_sitter, "--version"]).split()[1]
    if version != RUNTIME_VERSION:
        raise SystemExit(f"tree-sitter CLI is {version}; the runtime is {RUNTIME_VERSION}")
    gdir = work / location if location else work
    run([tree_sitter, "generate", "--js-runtime", "native"], cwd=gdir)
    return gdir / "src"


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

MODELINE = re.compile(r"^;+\s*inherits\s*:?\s*([a-z_,()]+)\s*$")
EXTENDS = re.compile(r"^;+\s*extends\s*$")


def nvim_files(queries, lang, kind, included=False):
    """nvim's vim.treesitter.query.get_files for one runtime path."""
    path = queries / lang / f"{kind}.scm"
    if not path.is_file():
        return []
    bases = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.startswith(";"):
            break
        m = MODELINE.match(line)
        if m:
            for item in m.group(1).split(","):
                optional = item.startswith("(") and item.endswith(")")
                name = item[1:-1] if optional else item
                if optional and included:
                    continue
                if name != lang:
                    bases.append(name)
    files = []
    for base in bases:
        files += nvim_files(queries, base, kind, True)
    return files + [f"runtime/queries/{lang}/{kind}.scm"]


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def inspect(name, info, cache, args, helix):
    inst = info["install_info"]
    url = inst["url"].rstrip("/").removesuffix(".git")
    revision = inst["revision"]
    commit = resolve_commit(url, revision)
    repo = download(url, commit, cache)
    location = inst.get("location", "")
    gdir = repo / location if location else repo
    src = gdir / "src"
    entry = {
        "name": name,
        "url": url,
        "revision": revision,
        "commit": commit,
        "location": location,
        "repo": str(repo),
        "tier": info.get("tier", 0),
        "requires": info.get("requires", []),
        "scanner": (src / "scanner.c").is_file(),
        "generated": None,
        "notes": [],
        "status": "ok" if name in TESTED else "untested",
        "reason": "",
    }
    if any((src / f).is_file() for f in ("scanner.cc", "scanner.cpp")):
        entry["status"], entry["reason"] = "excluded", "C++ scanner"
    needs_generation = not (src / "parser.c").is_file()
    if inst.get("generate") and not needs_generation:
        with tempfile.TemporaryDirectory(dir=cache) as tmp:
            try:
                fresh = generate(repo, location, args.tree_sitter, pathlib.Path(tmp))
                needs_generation = not same_generation(src, fresh)
            except subprocess.CalledProcessError as err:
                entry["notes"].append("regeneration fails (" + (err.stderr.strip().splitlines() or ["?"])[-1][:80]
                                      + "); the committed parser.c is used")
    if needs_generation:
        out = cache / "generated" / f"{name}-{commit[:12]}"
        if not (out / "parser.c").is_file():
            with tempfile.TemporaryDirectory(dir=cache) as tmp:
                fresh = generate(repo, location, args.tree_sitter, pathlib.Path(tmp))
                if out.exists():
                    shutil.rmtree(out)
                (out / "tree_sitter").mkdir(parents=True)
                shutil.copy2(fresh / "parser.c", out / "parser.c")
                for h in sorted((fresh / "tree_sitter").iterdir()):
                    shutil.copy2(h, out / "tree_sitter" / h.name)
        entry["generated"] = str(out)
        abi, symbol = parser_facts(out)
    else:
        abi, symbol = parser_facts(src)
    entry["abi"], entry["symbol"] = abi, symbol
    entry["licence"] = licence_of(repo, gdir)
    entry["tags"] = upstream_tags(repo, location)
    entry["helix_tags"] = helix.get((url.lower(), location.strip("/")))
    return entry


INCLUDE = re.compile(r'^\s*#\s*include\s*"([^"]+)"', re.M)


def include_closure(repo, src):
    """Files outside src/ that the C under src/ includes, transitively."""
    found, todo = set(), [p for p in src.rglob("*") if p.suffix in (".c", ".h", ".cc") and p.is_file()]
    seen = set(todo)
    while todo:
        path = todo.pop()
        text = path.read_text(encoding="utf-8", errors="replace")
        for name in INCLUDE.findall(text):
            target = (path.parent / name).resolve()
            try:
                rel = target.relative_to(repo.resolve())
            except ValueError:
                continue
            if not target.is_file() or target in seen:
                continue
            seen.add(target)
            todo.append(target)
            if not str(target).startswith(str(src.resolve()) + os.sep):
                found.add(rel.as_posix())
    return found


def mirror_files(repo, locations):
    """Every file a build or a query load reads, as repo-relative paths."""
    files = set()
    for location in locations:
        gdir = repo / location if location else repo
        for sub in ("src", "queries"):
            d = gdir / sub
            if d.is_dir():
                files |= {p.relative_to(repo).as_posix() for p in d.rglob("*") if p.is_file() and not p.is_symlink()}
        files |= include_closure(repo, gdir / "src")
        for d in dict.fromkeys([gdir, repo]):
            for p in d.iterdir():
                if p.is_symlink():
                    continue
                if p.is_file() and (LICENCE_FILE.match(p.name) or p.name == "tree-sitter.json"):
                    files.add(p.relative_to(repo).as_posix())
                elif p.is_dir() and LICENCE_FILE.match(p.name):
                    files |= {q.relative_to(repo).as_posix() for q in p.rglob("*") if q.is_file() and not q.is_symlink()}
    if (repo / "queries").is_dir():
        files |= {p.relative_to(repo).as_posix() for p in (repo / "queries").rglob("*") if p.is_file() and not p.is_symlink()}
    return files


def check_paths(files, url):
    """Paths that would fail to unpack on some host."""
    problems, lower = [], {}
    for f in files:
        key = f.lower()
        if key in lower and lower[key] != f:
            problems.append(f"case collision: {lower[key]} / {f}")
        lower[key] = f
        if len(f) > 160:
            problems.append(f"long path ({len(f)}): {f}")
    return problems


def mirror(group, cache):
    """One mirror tree per repository at a commit: the files the build reads,
    at upstream's own paths, plus generated parsers and a PROVENANCE note."""
    first = group[0]
    repo = pathlib.Path(first["repo"])
    owner, name = github_parts(first["url"])
    out = cache / "mirror" / f"{owner}--{name}--{first['commit']}"
    if out.exists():
        shutil.rmtree(out)
    files = mirror_files(repo, sorted({e["location"] for e in group}))
    for f in sorted(files):
        (out / f).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(repo / f, out / f)
    generated = []
    for e in group:
        if not e["generated"]:
            continue
        src = out / e["location"] / "src" if e["location"] else out / "src"
        src.mkdir(parents=True, exist_ok=True)
        shutil.copy2(pathlib.Path(e["generated"]) / "parser.c", src / "parser.c")
        (src / "tree_sitter").mkdir(exist_ok=True)
        for h in sorted((pathlib.Path(e["generated"]) / "tree_sitter").iterdir()):
            shutil.copy2(h, src / "tree_sitter" / h.name)
        generated.append((src / "parser.c").relative_to(out).as_posix())
    lines = [
        f"Mirrored from {first['url']} at {first['commit']} by ztreesitter's tools/catalogue.py.",
        "Every file here except this one and those listed below is that commit's, unmodified;",
        "files the build does not read (tests, bindings, build files) were left out.",
    ]
    for g in generated:
        lines.append(f"Generated: {g} and the tree_sitter/ headers beside it, by tree-sitter "
                     f"{RUNTIME_VERSION} (`tree-sitter generate --js-runtime native`).")
    lines.append(f"Licence: the repository's ({first['licence']['spdx']}).")
    (out / "PROVENANCE").write_text("\n".join(lines) + "\n", encoding="utf-8")
    problems = check_paths(files, first["url"])
    return out, f"refs/mirror/{owner}/{name}/{first['commit']}", problems


def helix_tags(helix_root):
    langs = tomllib.loads((helix_root / "languages.toml").read_text(encoding="utf-8"))
    out = {}
    for g in langs.get("grammar", []):
        source = g.get("source", {})
        if "git" not in source:
            continue
        key = (source["git"].rstrip("/").removesuffix(".git").lower(), source.get("subpath", "").strip("/"))
        if (helix_root / "runtime" / "queries" / g["name"] / "tags.scm").is_file():
            out.setdefault(key, f"runtime/queries/{g['name']}/tags.scm")
    return out


def publish_mirror(out, ref, url, commit):
    """An orphan commit in this repository holding the mirror, under a ref
    namespace `git clone` does not fetch."""
    if subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--verify", "-q", ref],
                      capture_output=True).returncode != 0:
        index = out.parent / (out.name + ".index")
        env = dict(os.environ, GIT_INDEX_FILE=str(index),
                   GIT_AUTHOR_DATE="2000-01-01T00:00:00Z", GIT_COMMITTER_DATE="2000-01-01T00:00:00Z")
        git = ["git", "-C", str(ROOT), "--work-tree", str(out)]
        subprocess.run(git + ["add", "-A", "-f", "."], check=True, env=env, capture_output=True)
        tree = run(git + ["write-tree"], env=env).strip()
        message = f"Mirror {url} at {commit}\n\nSee PROVENANCE.\n"
        orphan = run(["git", "-C", str(ROOT), "commit-tree", tree, "-m", message], env=env).strip()
        subprocess.run(["git", "-C", str(ROOT), "update-ref", ref, orphan], check=True)
        index.unlink()
    return run(["git", "-C", str(ROOT), "rev-parse", ref]).strip()


def zig_string(s):
    return json.dumps(s)


def write_catalogue(entries, query_only, nvim_commit, helix_commit, nvim_root):
    lines = [
        "//! GENERATED by tools/catalogue.py. Do not edit; rerun the tool.",
        f"//! nvim-treesitter {nvim_commit}, Helix {helix_commit}, tree-sitter {RUNTIME_VERSION}.",
        "const schema = @import(\"schema.zig\");",
        "",
        f"pub const nvim_treesitter_commit = {zig_string(nvim_commit)};",
        f"pub const helix_commit = {zig_string(helix_commit)};",
        f"pub const runtime_version = {zig_string(RUNTIME_VERSION)};",
        "",
        "pub const grammars: []const schema.Grammar = &.{",
    ]
    queries = nvim_root / "runtime" / "queries"
    for e in entries:
        lines.append("    .{")
        lines.append(f"        .name = {zig_string(e['name'])},")
        lines.append(f"        .symbol = {zig_string(e['symbol'])},")
        lines.append(f"        .url = {zig_string(e['url'])},")
        lines.append(f"        .revision = {zig_string(e['revision'])},")
        lines.append(f"        .commit = {zig_string(e['commit'])},")
        lines.append(f"        .location = {zig_string(e['location'])},")
        lines.append(f"        .scanner = {'true' if e['scanner'] else 'false'},")
        lines.append(f"        .abi = {e['abi']},")
        lines.append(f"        .generated = {'true' if e['generated'] else 'false'},")
        lines.append(f"        .mirror = {zig_string(e['mirror_commit'])},")
        lines.append(f"        .tier = {e['tier']},")
        lines.append(f"        .licence = {zig_string(e['licence']['spdx'])},")
        lines.append(f"        .licence_file = {zig_string(e['licence']['file'])},")
        lines.append(f"        .licence_note = {zig_string(e['licence']['note'])},")
        lines.append(f"        .notes = {zig_string('; '.join(e['notes']))},")
        lines.append("        .requires = &.{" + ", ".join(zig_string(r) for r in e["requires"]) + "},")
        lines.append(f"        .status = .{e['status']},")
        lines.append(f"        .reason = {zig_string(e['reason'])},")
        lines.append("        .queries = .{")
        for kind in NVIM_KINDS:
            files = nvim_files(queries, e["name"], kind)
            lines.append(f"            .{kind} = &.{{" + ", ".join(f".{{ .source = .nvim, .path = {zig_string(f)} }}" for f in files) + "},")
        own = ROOT / "queries" / e["name"] / "tags.scm"
        if own.is_file():
            tags = [f".{{ .source = .ztreesitter, .path = {zig_string(own.relative_to(ROOT).as_posix())} }}"]
        elif e["tags"]:
            tags = [f".{{ .source = .grammar, .path = {zig_string(p)} }}" for p in e["tags"]]
        elif e["helix_tags"]:
            tags = [f".{{ .source = .helix, .path = {zig_string(e['helix_tags'])} }}"]
        else:
            tags = []
        lines.append("            .tags = &.{" + ", ".join(tags) + "},")
        lines.append("        },")
        lines.append("    },")
    lines.append("};")
    lines.append("")
    lines.append("/// Languages nvim-treesitter ships queries for without a grammar; other")
    lines.append("/// languages' queries inherit them.")
    lines.append("pub const query_only: []const []const u8 = &.{" + ", ".join(zig_string(q) for q in query_only) + "};")
    lines.append("")
    out = ROOT / "grammars" / "catalogue.zig"
    out.write_text("\n".join(lines), encoding="utf-8")
    run(["zig", "fmt", str(out)])


def write_zon(entries, nvim_commit, nvim_hash, helix_commit, helix_hash):
    zon = (ROOT / "build.zig.zon").read_text(encoding="utf-8")
    begin, end = "        // BEGIN GENERATED tools/catalogue.py\n", "        // END GENERATED\n"
    head, rest = zon.split(begin)
    _, tail = rest.split(end)
    block = [
        "        .nvim_treesitter = .{",
        f"            .url = \"https://github.com/nvim-treesitter/nvim-treesitter/archive/{nvim_commit}.tar.gz\",",
        f"            .hash = \"{nvim_hash}\",",
        "            .lazy = true,",
        "        },",
        "        .helix = .{",
        f"            .url = \"https://github.com/helix-editor/helix/archive/{helix_commit}.tar.gz\",",
        f"            .hash = \"{helix_hash}\",",
        "            .lazy = true,",
        "        },",
    ]
    for e in entries:
        block += [
            f"        .grammar_{e['name']} = .{{",
            f"            .url = \"{e['package_url']}\",",
            f"            .hash = \"{e['hash']}\",",
            "            .lazy = true,",
            "        },",
        ]
    (ROOT / "build.zig.zon").write_text(head + begin + "\n".join(block) + "\n" + end + tail, encoding="utf-8")


def write_report(entries, query_only, nvim_commit, helix_commit):
    count = lambda pred: sum(1 for e in entries if pred(e))
    out = [
        "# Grammars",
        "",
        "<!-- GENERATED by tools/catalogue.py. Do not edit; rerun the tool. -->",
        "",
        f"The catalogue is nvim-treesitter's parser list at `{nvim_commit}`: each",
        "grammar at the revision nvim-treesitter's queries are written against.",
        f"Tags queries come from the grammar's own repository, else Helix at `{helix_commit[:12]}`.",
        "",
        "| | |",
        "|---:|---|",
        f"| {len(entries)} | grammars |",
        f"| {count(lambda e: e['status'] == 'ok')} | built and tested by CI |",
        f"| {count(lambda e: e['status'] == 'untested')} | catalogued, not yet built by CI |",
        f"| {count(lambda e: e['status'] == 'excluded')} | excluded |",
        f"| {count(lambda e: e['generated'])} | parser generated by this repository |",
        f"| {count(lambda e: e['scanner'])} | with an external scanner (C) |",
        f"| {count(lambda e: e['tags'])} | tags query from the grammar |",
        f"| {count(lambda e: not e['tags'] and e['helix_tags'])} | tags query from Helix |",
        f"| {count(lambda e: e['licence']['note'])} | licence needing a reading (see notes) |",
        "",
        f"Query-only languages, inherited by others: {', '.join(query_only)}.",
        "",
        "Every grammar is fetched from a mirror in this repository: the files its build",
        "and its queries read, at the grammar repository's own paths, published as an",
        "orphan commit under `refs/mirror/<owner>/<repo>/<commit>`. Its `PROVENANCE` file",
        "says what was generated; every other file is upstream's, unmodified.",
        "",
        "| grammar | status | ABI | scanner | parser | tags | licence | notes |",
        "|---|---|---:|:---:|---|---|---|---|",
    ]
    for e in entries:
        own = (ROOT / "queries" / e["name"] / "tags.scm").is_file()
        tags = "ztreesitter" if own else ("grammar" if e["tags"] else ("Helix" if e["helix_tags"] else ""))
        notes = "; ".join(x for x in [e["reason"]] + e["notes"] + [e["licence"]["note"]] if x)
        out.append(f"| [{e['name']}]({e['url']}) | {e['status']} | {e['abi']} | "
                   f"{'yes' if e['scanner'] else ''} | {'generated' if e['generated'] else 'upstream'} | {tags} | "
                   f"{e['licence']['spdx']} | {notes} |")
    out.append("")
    (ROOT / "docs" / "grammars.md").write_text("\n".join(out), encoding="utf-8")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--nvim-treesitter", required=True, help="nvim-treesitter commit")
    ap.add_argument("--helix", required=True, help="Helix commit")
    ap.add_argument("--cache", default=os.path.join(tempfile.gettempdir(), "ztreesitter-catalogue"))
    ap.add_argument("--tree-sitter", default="tree-sitter", help="tree-sitter CLI, version " + RUNTIME_VERSION)
    ap.add_argument("--only", help="comma list: inspect only these grammars (for a quick look)")
    ap.add_argument("--jobs", type=int, default=12)
    args = ap.parse_args()

    cache = pathlib.Path(args.cache)
    cache.mkdir(parents=True, exist_ok=True)
    nvim_url = "https://github.com/nvim-treesitter/nvim-treesitter"
    helix_url = "https://github.com/helix-editor/helix"
    nvim_root = download(nvim_url, args.nvim_treesitter, cache)
    helix_root = download(helix_url, args.helix, cache)
    nvim_hash = zig_hash(tarball_url(nvim_url, args.nvim_treesitter), cache)
    helix_hash = zig_hash(tarball_url(helix_url, args.helix), cache)

    parsers = LuaReader.read_module((nvim_root / "lua" / "nvim-treesitter" / "parsers.lua").read_text(encoding="utf-8"))
    query_only = sorted(n for n, i in parsers.items() if not i.get("install_info"))
    names = sorted(n for n, i in parsers.items() if i.get("install_info"))
    if args.only:
        wanted = set(args.only.split(","))
        names = [n for n in names if n in wanted]
    helix = helix_tags(helix_root)

    entries, failures = [], []
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        futures = {pool.submit(inspect, n, parsers[n], cache, args, helix): n for n in names}
        for future in concurrent.futures.as_completed(futures):
            name = futures[future]
            try:
                entries.append(future.result())
            except Exception as err:  # reported, never dropped
                failures.append((name, f"{type(err).__name__}: {err}"))
    for name, why in sorted(failures):
        print(f"catalogue: {name}: {why}", file=sys.stderr)
    if failures:
        raise SystemExit(f"catalogue: {len(failures)} grammars could not be inspected")
    entries.sort(key=lambda e: e["name"])

    groups = {}
    for e in entries:
        if e["name"] in EXCLUDED:
            e["status"], e["reason"] = "excluded", EXCLUDED[e["name"]]
        groups.setdefault((e["url"], e["commit"]), []).append(e)

    if args.only:
        json.dump(entries, sys.stdout, indent=1)
        return

    def make_mirror(item):
        (url, commit), group = item
        out, ref, problems = mirror(group, cache)
        return url, commit, group, out, ref, problems

    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        made = list(pool.map(make_mirror, sorted(groups.items())))
    for url, commit, group, out, ref, problems in made:
        sha = publish_mirror(out, ref, url, commit)
        for e in group:
            e["package_url"] = f"{REPOSITORY}/archive/{sha}.tar.gz"
            e["package_dir"] = str(out)
            e["mirror_commit"] = sha
            e["notes"] += problems

    def hash_of(e):
        return zig_hash(e.get("package_dir") or e["package_url"], cache)

    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        unique = {}
        for e in entries:
            unique.setdefault(e["package_dir"], e)
        hashes = dict(zip(unique, pool.map(hash_of, unique.values())))
    for e in entries:
        e["hash"] = hashes[e["package_dir"]]

    write_catalogue(entries, query_only, args.nvim_treesitter, args.helix, nvim_root)
    write_zon(entries, args.nvim_treesitter, nvim_hash, args.helix, helix_hash)
    write_report(entries, query_only, args.nvim_treesitter, args.helix)
    print(f"catalogue: {len(entries)} grammars written")


if __name__ == "__main__":
    main()
