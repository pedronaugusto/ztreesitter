//! Regenerates the grammar catalogue from a pinned nvim-treesitter commit.
//!
//! The catalogue is nvim-treesitter's parser list: each grammar's repository
//! and revision, which nvim-treesitter's queries are written against. This
//! tool is the only way it changes. It writes three files and nothing else:
//!
//!   build.zig.zon           the dependency block between the GENERATED markers
//!   grammars/catalogue.zig  every grammar as data, read by build.zig and by the
//!                           `ztreesitter.catalogue` module
//!   docs/grammars.md        the per-grammar report
//!
//! For each grammar it downloads the repository at its commit, records where
//! the parser lives, whether it has an external scanner, the ABI version of
//! its parser.c, the symbol it exports, its licence and its query files, and
//! asks `zig fetch` for the package hash. A grammar whose repository commits
//! no parser.c is generated with the tree-sitter CLI pinned to the vendored
//! runtime's version, and the output is published as an orphan commit in this
//! repository.
//!
//! Needs network, git, and for generation the tree-sitter CLI.
//!
//!   zig build catalogue -- --nvim-treesitter <commit> --helix <commit>
//!                          [--tree-sitter PATH] [--only a,b]
//!
//! `--only` inspects the named grammars and prints their entries without
//! writing or publishing anything.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const github = @import("github.zig");

const runtime_version = "0.27.0";
const repository = "https://github.com/pedronaugusto/ztreesitter";
const nvim_url = "https://github.com/nvim-treesitter/nvim-treesitter";
const helix_url = "https://github.com/helix-editor/helix";
const nvim_kinds = [_][]const u8{ "highlights", "injections", "locals", "folds", "indents" };

/// Grammars excluded on purpose, with the reason the build prints. Empty
/// until a grammar is found that cannot be built unpatched.
const excluded = [_][2][]const u8{};

/// Grammars built and tested by CI. The rest are catalogued and fetchable
/// but reported as untested until the all-grammars job has compiled them.
const tested = [_][]const u8{
    "bash", "c",          "c_sharp",         "cpp",    "css",   "html",      "javascript", "json",
    "lua",  "markdown",   "markdown_inline", "python", "regex", "rust",      "scss",       "swift",
    "tsx",  "typescript", "zig",             "ecma",   "jsx",   "html_tags",
};

const Options = struct {
    root: []const u8,
    nvim_commit: []const u8,
    helix_commit: []const u8,
    tree_sitter: []const u8 = "tree-sitter",
    only: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    // From the build: ROOT CACHE ZIG, then the maintainer's arguments.
    if (args.len < 4) return usage();
    var options: Options = .{ .root = args[1], .nvim_commit = "", .helix_commit = "" };
    var i: usize = 4;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        if (i + 1 == args.len) return usage();
        i += 1;
        if (std.mem.eql(u8, flag, "--nvim-treesitter")) {
            options.nvim_commit = args[i];
        } else if (std.mem.eql(u8, flag, "--helix")) {
            options.helix_commit = args[i];
        } else if (std.mem.eql(u8, flag, "--tree-sitter")) {
            options.tree_sitter = args[i];
        } else if (std.mem.eql(u8, flag, "--only")) {
            options.only = args[i];
        } else return usage();
    }
    if (!github.isCommit(options.nvim_commit) or !github.isCommit(options.helix_commit)) return usage();

    var ctx: github.Context = try .init(arena, init.gpa, init.io, init.environ_map, args[2], args[3]);
    defer ctx.deinit();
    return catalogue(&ctx, options);
}

fn usage() u8 {
    std.log.err("usage: zig build catalogue -- --nvim-treesitter COMMIT --helix COMMIT [--tree-sitter PATH] [--only a,b]", .{});
    return 2;
}

//=========================================================================
// Lua table literals
//
// parsers.lua is `return { name = { key = 'value', ... }, ... }`. This reads
// that subset of Lua: tables, strings, numbers, booleans, comments.
//=========================================================================

const Lua = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    nil,
    list: []const Lua,
    table: std.array_hash_map.String(Lua),

    fn get(v: Lua, key: []const u8) ?Lua {
        return switch (v) {
            .table => |t| t.get(key),
            else => null,
        };
    }
};

const LuaReader = struct {
    arena: Allocator,
    text: []const u8,
    pos: usize = 0,

    const Token = struct {
        kind: enum { string, number, name, punct, end },
        text: []const u8,
    };

    fn read(arena: Allocator, text: []const u8) !Lua {
        var r: LuaReader = .{ .arena = arena, .text = text };
        const ret = try r.next();
        if (ret.kind != .name or !std.mem.eql(u8, ret.text, "return")) return error.LuaSyntax;
        const result = try r.value();
        if ((try r.next()).kind != .end) return error.LuaSyntax;
        return result;
    }

    fn skip(r: *LuaReader) void {
        while (r.pos < r.text.len) {
            const rest = r.text[r.pos..];
            if (std.ascii.isWhitespace(rest[0])) {
                r.pos += 1;
            } else if (std.mem.startsWith(u8, rest, "--[[") and std.mem.find(u8, rest, "]]") != null) {
                r.pos += std.mem.find(u8, rest, "]]").? + 2;
            } else if (std.mem.startsWith(u8, rest, "--")) {
                r.pos += std.mem.findScalar(u8, rest, '\n') orelse rest.len;
            } else return;
        }
    }

    fn peek(r: *LuaReader) !Token {
        const saved = r.pos;
        defer r.pos = saved;
        return r.next();
    }

    fn next(r: *LuaReader) !Token {
        r.skip();
        const rest = r.text[r.pos..];
        if (rest.len == 0) return .{ .kind = .end, .text = "" };
        const c = rest[0];
        var len: usize = 1;
        const kind: @FieldType(Token, "kind") = switch (c) {
            '\'', '"' => blk: {
                while (len < rest.len and rest[len] != c) : (len += 1) {
                    if (rest[len] == '\\') len += 1;
                }
                if (len >= rest.len) return error.LuaSyntax;
                len += 1;
                break :blk .string;
            },
            '0'...'9', '-' => blk: {
                if (c == '-' and (rest.len < 2 or !std.ascii.isDigit(rest[1]))) return error.LuaSyntax;
                while (len < rest.len and std.ascii.isDigit(rest[len])) len += 1;
                if (len + 1 < rest.len and rest[len] == '.' and std.ascii.isDigit(rest[len + 1])) {
                    len += 1;
                    while (len < rest.len and std.ascii.isDigit(rest[len])) len += 1;
                }
                break :blk .number;
            },
            'A'...'Z', 'a'...'z', '_' => blk: {
                while (len < rest.len and (std.ascii.isAlphanumeric(rest[len]) or rest[len] == '_')) len += 1;
                break :blk .name;
            },
            '{', '}', '=', ',', '[', ']' => .punct,
            else => return error.LuaSyntax,
        };
        r.pos += len;
        return .{ .kind = kind, .text = rest[0..len] };
    }

    fn expect(r: *LuaReader, text: []const u8) !void {
        const t = try r.next();
        if (!std.mem.eql(u8, t.text, text)) return error.LuaSyntax;
    }

    fn value(r: *LuaReader) anyerror!Lua {
        const t = try r.next();
        switch (t.kind) {
            .string => return .{ .string = try r.unescape(t.text[1 .. t.text.len - 1]) },
            .number => {
                if (std.mem.findScalar(u8, t.text, '.') != null) return .{ .float = try std.fmt.parseFloat(f64, t.text) };
                return .{ .integer = try std.fmt.parseInt(i64, t.text, 10) };
            },
            .name => {
                if (std.mem.eql(u8, t.text, "true")) return .{ .boolean = true };
                if (std.mem.eql(u8, t.text, "false")) return .{ .boolean = false };
                if (std.mem.eql(u8, t.text, "nil")) return .nil;
                return error.LuaSyntax;
            },
            .punct => if (std.mem.eql(u8, t.text, "{")) return r.table() else return error.LuaSyntax,
            .end => return error.LuaSyntax,
        }
    }

    fn table(r: *LuaReader) !Lua {
        var items: std.ArrayList(Lua) = .empty;
        var keyed: std.array_hash_map.String(Lua) = .empty;
        while (!std.mem.eql(u8, (try r.peek()).text, "}")) {
            const t = try r.peek();
            const saved = r.pos;
            _ = try r.next();
            const after = try r.peek();
            if (t.kind == .name and std.mem.eql(u8, after.text, "=")) {
                try r.expect("=");
                try keyed.put(r.arena, t.text, try r.value());
            } else if (t.kind == .punct and std.mem.eql(u8, t.text, "[")) {
                const key = try r.value();
                if (key != .string) return error.LuaSyntax;
                try r.expect("]");
                try r.expect("=");
                try keyed.put(r.arena, key.string, try r.value());
            } else {
                r.pos = saved;
                try items.append(r.arena, try r.value());
            }
            if (std.mem.eql(u8, (try r.peek()).text, ",")) _ = try r.next();
        }
        try r.expect("}");
        if (items.items.len != 0 and keyed.count() != 0) return error.LuaMixedTable;
        if (items.items.len != 0) return .{ .list = items.items };
        return .{ .table = keyed };
    }

    fn unescape(r: *LuaReader, body: []const u8) ![]const u8 {
        if (std.mem.findScalar(u8, body, '\\') == null) return body;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            if (body[i] != '\\' or i + 1 == body.len) {
                try out.append(r.arena, body[i]);
                continue;
            }
            i += 1;
            try out.append(r.arena, switch (body[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => body[i],
            });
        }
        return out.items;
    }
};

//=========================================================================
// Licences
//=========================================================================

/// `(?i)^(licen[cs]e|copying)([-._].*)?$`
fn isLicenceName(name: []const u8) bool {
    for ([_][]const u8{ "license", "licence", "copying" }) |stem| {
        if (name.len < stem.len or !std.ascii.eqlIgnoreCase(name[0..stem.len], stem)) continue;
        if (name.len == stem.len) return true;
        return switch (name[stem.len]) {
            '-', '.', '_' => std.mem.findScalar(u8, name, '\n') == null,
            else => false,
        };
    }
    return false;
}

/// Python's `str.isspace` for one code point.
fn isSpace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0d, 0x1c...0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

/// The text lowered (ASCII), its whitespace runs one space, and the byte
/// length of its first 400 code points: `" ".join(text.lower().split())`
/// and `t[:400]`.
fn normalise(gpa: Allocator, text: []const u8) !struct { t: []u8, head: usize } {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var points: usize = 0;
    var head: ?usize = null;
    var pending_space = false;
    var i: usize = 0;
    while (i < text.len) {
        // A byte that starts no valid sequence reads as U+FFFD, as Python's
        // errors="replace" reads it.
        var cp: u21 = 0xfffd;
        var bytes: []const u8 = "\u{fffd}";
        var len: usize = 1;
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const decoded: ?u21 = if (i + n > text.len) null else switch (n) {
            1 => text[i],
            2 => std.unicode.utf8Decode2(text[i..][0..2].*) catch null,
            3 => std.unicode.utf8Decode3(text[i..][0..3].*) catch null,
            else => std.unicode.utf8Decode4(text[i..][0..4].*) catch null,
        };
        if (decoded) |c| {
            cp = c;
            len = n;
            bytes = text[i..][0..n];
        }
        i += len;
        if (isSpace(cp)) {
            pending_space = out.items.len != 0;
            continue;
        }
        if (pending_space) {
            if (points == 400) head = head orelse out.items.len;
            try out.append(gpa, ' ');
            points += 1;
            pending_space = false;
        }
        if (points == 400) head = head orelse out.items.len;
        for (bytes) |b| try out.append(gpa, std.ascii.toLower(b));
        points += 1;
    }
    return .{ .t = try out.toOwnedSlice(gpa), .head = head orelse out.items.len };
}

fn has(text: []const u8, needle: []const u8) bool {
    return std.mem.find(u8, text, needle) != null;
}

fn classifyLicence(gpa: Allocator, text: []const u8) !?[]const u8 {
    const n = try normalise(gpa, text);
    defer gpa.free(n.t);
    const t = n.t;
    // The GNU licences name each other in their bodies; the title decides.
    const head = t[0..n.head];
    if (has(head, "mozilla public license") and has(head, "2.0")) return "MPL-2.0";
    if (has(head, "gnu lesser general public license") or has(head, "gnu library general public license"))
        return if (has(head, "version 3")) "LGPL-3.0" else "LGPL-2.1";
    if (has(head, "gnu affero general public license")) return "AGPL-3.0";
    if (has(head, "gnu general public license")) return if (has(head, "version 3")) "GPL-3.0" else "GPL-2.0";
    if (has(t, "apache license") and has(t, "version 2.0")) return "Apache-2.0";
    if (has(t, "the artistic license 2.0")) return "Artistic-2.0";
    if (has(t, "eclipse public license")) return if (has(t, "2.0")) "EPL-2.0" else "EPL-1.0";
    if (has(t, "boost software license")) return "BSL-1.0";
    if (has(t, "this is free and unencumbered software released into the public domain")) return "Unlicense";
    if (has(t, "cc0 1.0 universal") or has(t, "creativecommons.org/publicdomain/zero")) return "CC0-1.0";
    if (has(t, "permission is hereby granted, free of charge")) return "MIT";
    if (has(t, "permission to use, copy, modify, and/or distribute this software for any purpose"))
        return if (has(t, "with or without fee") and !has(t, "copyright notice")) "0BSD" else "ISC";
    if (has(t, "permission to use, copy, modify, and distribute this software for any purpose")) return "ISC";
    if (has(t, "redistribution and use in source and binary forms")) {
        if (has(t, "neither the name") or has(t, "endorse or promote")) return "BSD-3-Clause";
        return "BSD-2-Clause";
    }
    if (has(t, "altered source versions must be plainly marked")) return "Zlib";
    return null;
}

fn readJson(ctx: *github.Context, path: []const u8) ?std.json.Value {
    const text = github.readFile(ctx, ctx.arena, path) catch return null;
    return std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, text, .{ .duplicate_field_behavior = .use_last }) catch null;
}

fn jsonGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

const Declared = struct {
    /// Each declaration once, sorted.
    all: []const []const u8,
    /// tree-sitter.json's, else package.json's: tree-sitter.json is the
    /// grammar's own metadata.
    first: ?[]const u8,
};

/// `license` from tree-sitter.json's metadata and from package.json, the
/// first directory that has each file winning.
fn declaredLicences(ctx: *github.Context, dirs: []const []const u8) !Declared {
    var found: [2]?[]const u8 = .{ null, null };
    for (dirs) |d| {
        for ([_][]const u8{ "tree-sitter.json", "package.json" }, 0..) |name, k| {
            const p = ctx.path(&.{ d, name });
            if (found[k] != null or !github.isFile(ctx.io, p)) continue;
            const j = readJson(ctx, p) orelse continue;
            const value = if (k == 0) (if (jsonGet(j, "metadata")) |m| jsonGet(m, "license") else null) else jsonGet(j, "license");
            if (value) |v| switch (v) {
                .string => |s| if (s.len != 0) {
                    found[k] = s;
                },
                else => {},
            };
        }
    }
    // As a sorted set.
    var out: std.ArrayList([]const u8) = .empty;
    for (found) |f| if (f) |s| {
        for (out.items) |o| {
            if (std.mem.eql(u8, o, s)) break;
        } else try out.append(ctx.arena, s);
    };
    std.mem.sort([]const u8, out.items, {}, github.lessThan);
    return .{ .all = out.items, .first = found[0] orelse found[1] };
}

const Licence = struct {
    spdx: []const u8,
    file: []const u8,
    note: []const u8,
};

/// `a`, then `b` unless it is `a`: Python's `dict.fromkeys([a, b])`.
fn distinct(buffer: *[2][]const u8, a: []const u8, b: []const u8) []const []const u8 {
    buffer.* = .{ a, b };
    return if (std.mem.eql(u8, a, b)) buffer[0..1] else buffer[0..2];
}

fn licenceOf(ctx: *github.Context, repo: []const u8, grammar_dir: []const u8) !Licence {
    var buffer: [2][]const u8 = undefined;
    const dirs = distinct(&buffer, grammar_dir, repo);
    var first_file: ?[]const u8 = null;
    var first_known: ?[]const u8 = null;
    var any_file = false;
    for (dirs) |d| {
        var names: std.ArrayList([]const u8) = .empty;
        var dir = try Io.Dir.cwd().openDir(ctx.io, d, .{ .iterate = true });
        defer dir.close(ctx.io);
        var it = dir.iterate();
        while (try it.next(ctx.io)) |entry| {
            if (!isLicenceName(entry.name)) continue;
            const full = ctx.path(&.{ d, entry.name });
            if (github.isFile(ctx.io, full)) try names.append(ctx.arena, try ctx.arena.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, github.lessThan);
        for (names.items) |name| {
            const full = ctx.path(&.{ d, name });
            const text = try github.readFile(ctx, ctx.gpa, full);
            defer ctx.gpa.free(text);
            const kind = try classifyLicence(ctx.gpa, text);
            if (!any_file) first_file = relative(repo, full);
            any_file = true;
            if (first_known == null) first_known = kind;
        }
    }
    const declarations = try declaredLicences(ctx, dirs);
    const declared = declarations.all;
    const joined = try std.mem.join(ctx.arena, ", ", declared);
    var note: []const u8 = "";
    var spdx: []const u8 = "unknown";
    if (first_known) |known| {
        spdx = known;
        var matches = declared.len == 0;
        for (declared) |d| {
            if (has(d, known)) matches = true;
        }
        if (!matches) note = try ctx.arena.print("file says {s}, declared {s}", .{ known, joined });
    } else if (any_file) {
        note = "licence file not recognised";
        if (declared.len != 0) note = try ctx.arena.print("{s}; declared {s}", .{ note, joined });
    } else if (declarations.first) |first| {
        // No licence file: the grammar ships on what it declares.
        spdx = first;
        note = try ctx.arena.print("no licence file; declared {s}", .{joined});
    } else {
        note = "no licence file and no declaration";
    }
    return .{ .spdx = spdx, .file = first_file orelse "", .note = note };
}

/// `full` relative to `root`, `/`-separated.
fn relative(root: []const u8, full: []const u8) []const u8 {
    std.debug.assert(std.mem.startsWith(u8, full, root));
    std.debug.assert(full.len > root.len);
    return full[root.len + 1 ..];
}

//=========================================================================
// Grammar inspection
//=========================================================================

/// Python's `str.strip(chars)`.
fn strip(s: []const u8, chars: []const u8) []const u8 {
    return std.mem.trim(u8, s, chars);
}

/// Per-grammar tags paths from tree-sitter.json, relative to the repository.
fn treeSitterJsonTags(ctx: *github.Context, repo: []const u8, location: []const u8) ![]const []const u8 {
    const j = readJson(ctx, ctx.path(&.{ repo, "tree-sitter.json" })) orelse return &.{};
    const grammars = jsonGet(j, "grammars") orelse return &.{};
    if (grammars != .array) return &.{};
    for (grammars.array.items) |g| {
        const p = if (jsonGet(g, "path")) |v| (if (v == .string and v.string.len != 0) v.string else ".") else ".";
        if (!std.mem.eql(u8, strip(p, "./"), strip(location, "./"))) continue;
        const value = jsonGet(g, "tags") orelse return &.{};
        var out: std.ArrayList([]const u8) = .empty;
        switch (value) {
            .string => |s| if (s.len != 0) try out.append(ctx.arena, std.mem.trimStart(u8, s, "./")),
            .array => |a| for (a.items) |v| {
                if (v == .string) try out.append(ctx.arena, std.mem.trimStart(u8, v.string, "./"));
            },
            else => {},
        }
        return out.items;
    }
    return &.{};
}

fn upstreamTags(ctx: *github.Context, repo: []const u8, location: []const u8) ![]const []const u8 {
    const declared = try treeSitterJsonTags(ctx, repo, location);
    var paths: std.ArrayList([]const u8) = .empty;
    for (declared) |p| {
        if (github.isFile(ctx.io, ctx.path(&.{ repo, p }))) try paths.append(ctx.arena, p);
    }
    if (paths.items.len != 0) return paths.items;
    const bases: []const []const u8 = if (location.len == 0) &.{"queries"} else &.{ try ctx.arena.print("{s}/queries", .{location}), "queries" };
    for (bases) |base| {
        const candidate = std.mem.trimStart(u8, try ctx.arena.print("{s}/tags.scm", .{base}), "./");
        if (github.isFile(ctx.io, ctx.path(&.{ repo, candidate }))) return try ctx.arena.dupe([]const u8, &.{candidate});
    }
    return &.{};
}

const ParserFacts = struct { abi: u8, symbol: []const u8 };

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn skipSpace(data: []const u8, i: *usize) void {
    while (i.* < data.len and std.ascii.isWhitespace(data[i.*])) i.* += 1;
}

/// `#define LANGUAGE_VERSION N` in the first 20000 bytes, and the one
/// `TSLanguage *tree_sitter_x(void) {` the file defines.
fn parserFacts(ctx: *github.Context, src: []const u8) !ParserFacts {
    const path = ctx.path(&.{ src, "parser.c" });
    const data = try github.readFile(ctx, ctx.gpa, path);
    defer ctx.gpa.free(data);

    const define = "#define LANGUAGE_VERSION ";
    const abi: ?u8 = blk: {
        const window = data[0..@min(data.len, 20000)];
        const at = std.mem.find(u8, window, define) orelse break :blk null;
        var end = at + define.len;
        while (end < window.len and std.ascii.isDigit(window[end])) end += 1;
        break :blk std.fmt.parseInt(u8, window[at + define.len .. end], 10) catch null;
    };

    var symbols: std.ArrayList([]const u8) = .empty;
    var from: usize = 0;
    while (std.mem.findPos(u8, data, from, "TSLanguage")) |at| {
        from = at + 1;
        if (at != 0 and isIdent(data[at - 1])) continue;
        var i = at + "TSLanguage".len;
        skipSpace(data, &i);
        if (i == data.len or data[i] != '*') continue;
        i += 1;
        skipSpace(data, &i);
        if (!std.mem.startsWith(u8, data[i..], "tree_sitter_")) continue;
        const start = i;
        while (i < data.len and isIdent(data[i])) i += 1;
        const name = data[start..i];
        skipSpace(data, &i);
        if (i == data.len or data[i] != '(') continue;
        i += 1;
        skipSpace(data, &i);
        if (std.mem.startsWith(u8, data[i..], "void")) i += "void".len;
        skipSpace(data, &i);
        if (i == data.len or data[i] != ')') continue;
        i += 1;
        skipSpace(data, &i);
        if (i == data.len or data[i] != '{') continue;
        try symbols.append(ctx.arena, try ctx.arena.dupe(u8, name));
    }
    if (abi == null or symbols.items.len != 1) {
        std.log.err("{s}: ABI {?d}, {d} symbols", .{ path, abi, symbols.items.len });
        return error.ParserFacts;
    }
    return .{ .abi = abi.?, .symbol = symbols.items[0] };
}

fn sameGeneration(ctx: *github.Context, src: []const u8, generated: []const u8) !bool {
    for ([_][]const u8{ "grammar.json", "node-types.json" }) |f| {
        if (!github.isFile(ctx.io, ctx.path(&.{ src, f }))) return false;
        if (!try github.sameFile(ctx, ctx.path(&.{ src, f }), ctx.path(&.{ generated, f }))) return false;
    }
    return true;
}

/// A copy of `from` at `to`, symbolic links kept as links.
fn copyTree(ctx: *github.Context, from: []const u8, to: []const u8) !void {
    try Io.Dir.cwd().createDirPath(ctx.io, to);
    var src = try Io.Dir.cwd().openDir(ctx.io, from, .{ .iterate = true });
    defer src.close(ctx.io);
    var dst = try Io.Dir.cwd().openDir(ctx.io, to, .{});
    defer dst.close(ctx.io);
    var walker = try src.walk(ctx.gpa);
    defer walker.deinit();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    while (try walker.next(ctx.io)) |entry| switch (entry.kind) {
        .directory => try dst.createDirPath(ctx.io, entry.path),
        .sym_link => {
            const n = try src.readLink(ctx.io, entry.path, &buffer);
            try dst.symLink(ctx.io, buffer[0..n], entry.path, .{});
        },
        else => try src.copyFile(entry.path, dst, entry.path, ctx.io, .{}),
    };
}

const TreeSitter = struct {
    path: []const u8,
    /// Checked once, at the first generation.
    checked: std.atomic.Value(bool) = .init(false),
};

/// Generates in a copy of the whole repository: a grammar in a subdirectory
/// may require files from its parent. Returns the generated `src`.
fn generate(ctx: *github.Context, cli: *TreeSitter, repo: []const u8, location: []const u8, workdir: []const u8) !union(enum) { src: []const u8, failed: []const u8 } {
    if (!cli.checked.load(.acquire)) {
        const version = try github.runChecked(ctx, &.{ cli.path, "--version" }, .{});
        var words = std.mem.tokenizeAny(u8, version, " \t\n");
        _ = words.next();
        const v = words.next() orelse "";
        if (!std.mem.eql(u8, v, runtime_version)) {
            std.log.err("tree-sitter CLI is {s}; the runtime is {s}", .{ v, runtime_version });
            return error.WrongTreeSitter;
        }
        cli.checked.store(true, .release);
    }
    const work = ctx.path(&.{ workdir, "repo" });
    try copyTree(ctx, repo, work);
    const gdir = if (location.len == 0) work else ctx.path(&.{ work, location });
    const out = try github.run(ctx, &.{ cli.path, "generate", "--js-runtime", "native" }, .{ .cwd = gdir });
    if (!out.ok()) return .{ .failed = out.lastLine() };
    return .{ .src = ctx.path(&.{ gdir, "src" }) };
}

//=========================================================================
// Queries
//=========================================================================

/// `^;+\s*inherits\s*:?\s*([a-z_,()]+)\s*$`: the list, or null.
fn modeline(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len and line[i] == ';') i += 1;
    if (i == 0) return null;
    while (i < line.len and std.ascii.isWhitespace(line[i])) i += 1;
    if (!std.mem.startsWith(u8, line[i..], "inherits")) return null;
    i += "inherits".len;
    while (i < line.len and std.ascii.isWhitespace(line[i])) i += 1;
    if (i < line.len and line[i] == ':') i += 1;
    while (i < line.len and std.ascii.isWhitespace(line[i])) i += 1;
    const start = i;
    while (i < line.len) : (i += 1) switch (line[i]) {
        'a'...'z', '_', ',', '(', ')' => {},
        else => break,
    };
    const list = line[start..i];
    if (list.len == 0) return null;
    for (line[i..]) |c| if (!std.ascii.isWhitespace(c)) return null;
    return list;
}

/// nvim's `vim.treesitter.query.get_files` for one runtime path.
fn nvimFiles(ctx: *github.Context, out: *std.ArrayList([]const u8), queries: []const u8, lang: []const u8, kind: []const u8, included: bool) !void {
    const file = try ctx.arena.print("{s}.scm", .{kind});
    const path = ctx.path(&.{ queries, lang, file });
    if (!github.isFile(ctx.io, path)) return;
    const text = try github.readFile(ctx, ctx.gpa, path);
    defer ctx.gpa.free(text);
    var bases: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, ";")) break;
        const list = modeline(line) orelse continue;
        var items = std.mem.splitScalar(u8, list, ',');
        while (items.next()) |item| {
            const optional = item.len >= 2 and item[0] == '(' and item[item.len - 1] == ')';
            const name = if (optional) item[1 .. item.len - 1] else item;
            if (optional and included) continue;
            if (!std.mem.eql(u8, name, lang)) try bases.append(ctx.arena, try ctx.arena.dupe(u8, name));
        }
    }
    for (bases.items) |base| try nvimFiles(ctx, out, queries, base, kind, true);
    try out.append(ctx.arena, try ctx.arena.print("runtime/queries/{s}/{s}.scm", .{ lang, kind }));
}

//=========================================================================
// Inspection
//=========================================================================

const Status = enum { ok, untested, excluded };

const Entry = struct {
    name: []const u8,
    url: []const u8,
    revision: []const u8,
    commit: []const u8,
    location: []const u8,
    repo: []const u8,
    tier: i64,
    requires: []const []const u8,
    scanner: bool,
    generated: ?[]const u8 = null,
    notes: std.ArrayList([]const u8) = .empty,
    status: Status,
    reason: []const u8 = "",
    abi: u8 = 0,
    symbol: []const u8 = "",
    licence: Licence = undefined,
    tags: []const []const u8 = &.{},
    helix_tags: ?[]const u8 = null,
    mirror_commit: []const u8 = "",
    package_url: []const u8 = "",
    package_dir: []const u8 = "",
    hash: []const u8 = "",
};

/// A Helix tags query, by the grammar repository and subdirectory it is for.
const HelixTag = struct { url: []const u8, subpath: []const u8, path: []const u8 };

const Shared = struct {
    cli: TreeSitter,
    helix: []const HelixTag,

    fn helixTags(s: *const Shared, url: []const u8, location: []const u8) ?[]const u8 {
        for (s.helix) |h| {
            if (std.ascii.eqlIgnoreCase(h.url, url) and std.mem.eql(u8, h.subpath, strip(location, "/"))) return h.path;
        }
        return null;
    }
};

fn isTested(name: []const u8) bool {
    for (tested) |t| if (std.mem.eql(u8, t, name)) return true;
    return false;
}

fn stringField(v: Lua, key: []const u8) ?[]const u8 {
    const f = v.get(key) orelse return null;
    return if (f == .string) f.string else null;
}

fn inspect(ctx: *github.Context, shared: *Shared, name: []const u8, info: Lua) !Entry {
    const inst = info.get("install_info") orelse return error.NoInstallInfo;
    var url = std.mem.trimEnd(u8, stringField(inst, "url") orelse return error.NoUrl, "/");
    if (std.mem.endsWith(u8, url, ".git")) url = url[0 .. url.len - ".git".len];
    const revision = stringField(inst, "revision") orelse return error.NoRevision;
    const commit = try github.resolveCommit(ctx, url, revision);
    const repo = try github.download(ctx, url, commit);
    const location = stringField(inst, "location") orelse "";
    const gdir = if (location.len == 0) repo else ctx.path(&.{ repo, location });
    const src = ctx.path(&.{ gdir, "src" });

    var requires: std.ArrayList([]const u8) = .empty;
    if (info.get("requires")) |r| if (r == .list) for (r.list) |item| {
        if (item == .string) try requires.append(ctx.arena, item.string);
    };
    var entry: Entry = .{
        .name = name,
        .url = url,
        .revision = revision,
        .commit = commit,
        .location = location,
        .repo = repo,
        .tier = if (info.get("tier")) |t| (if (t == .integer) t.integer else 0) else 0,
        .requires = requires.items,
        .scanner = github.isFile(ctx.io, ctx.path(&.{ src, "scanner.c" })),
        .status = if (isTested(name)) .ok else .untested,
    };
    for ([_][]const u8{ "scanner.cc", "scanner.cpp" }) |f| {
        if (github.isFile(ctx.io, ctx.path(&.{ src, f }))) {
            entry.status = .excluded;
            entry.reason = "C++ scanner";
        }
    }

    var needs_generation = !github.isFile(ctx.io, ctx.path(&.{ src, "parser.c" }));
    const wants_generate = if (inst.get("generate")) |g| g == .boolean and g.boolean else false;
    if (wants_generate and !needs_generation) {
        const tmp = try ctx.temporary();
        defer github.remove(ctx, tmp);
        switch (try generate(ctx, &shared.cli, repo, location, tmp)) {
            .src => |fresh| needs_generation = !try sameGeneration(ctx, src, fresh),
            .failed => |why| try entry.notes.append(ctx.arena, try ctx.arena.print("regeneration fails ({s}); the committed parser.c is used", .{why[0..@min(why.len, 80)]})),
        }
    }
    const facts = if (needs_generation) blk: {
        const out = ctx.path(&.{ ctx.cache, "generated", try ctx.arena.print("{s}-{s}", .{ name, commit[0..12] }) });
        if (!github.isFile(ctx.io, ctx.path(&.{ out, "parser.c" }))) {
            const tmp = try ctx.temporary();
            defer github.remove(ctx, tmp);
            const fresh = switch (try generate(ctx, &shared.cli, repo, location, tmp)) {
                .src => |s| s,
                .failed => |why| {
                    std.log.err("{s}: generation fails: {s}", .{ name, why });
                    return error.GenerationFailed;
                },
            };
            try Io.Dir.cwd().deleteTree(ctx.io, out);
            try copyGenerated(ctx, fresh, out);
        }
        entry.generated = out;
        break :blk try parserFacts(ctx, out);
    } else try parserFacts(ctx, src);
    entry.abi = facts.abi;
    entry.symbol = facts.symbol;
    entry.licence = try licenceOf(ctx, repo, gdir);
    entry.tags = try upstreamTags(ctx, repo, location);
    entry.helix_tags = shared.helixTags(url, location);
    return entry;
}

/// parser.c and the tree_sitter/ headers beside it.
fn copyGenerated(ctx: *github.Context, from: []const u8, to: []const u8) !void {
    try Io.Dir.cwd().createDirPath(ctx.io, ctx.path(&.{ to, "tree_sitter" }));
    try Io.Dir.copyFile(Io.Dir.cwd(), ctx.path(&.{ from, "parser.c" }), Io.Dir.cwd(), ctx.path(&.{ to, "parser.c" }), ctx.io, .{});
    const headers = ctx.path(&.{ from, "tree_sitter" });
    var dir = try Io.Dir.cwd().openDir(ctx.io, headers, .{ .iterate = true });
    defer dir.close(ctx.io);
    var it = dir.iterate();
    while (try it.next(ctx.io)) |e| {
        try Io.Dir.copyFile(dir, e.name, Io.Dir.cwd(), ctx.path(&.{ to, "tree_sitter", e.name }), ctx.io, .{});
    }
}

//=========================================================================
// Mirrors
//=========================================================================

const Set = std.array_hash_map.String(void);

/// Every file under `dir` whose path a build reads, recursively, not
/// following or listing symbolic links, added to `files` relative to `repo`.
fn addRegular(ctx: *github.Context, files: *Set, repo: []const u8, dir: []const u8) !void {
    for (try github.regularFiles(ctx, dir)) |f| {
        try files.put(ctx.arena, ctx.path(&.{ relative(repo, dir), f }), {});
    }
}

/// `"name"` of each `^\s*#\s*include\s*"name"` line.
fn includes(ctx: *github.Context, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var i: usize = 0;
        skipSpace(line, &i);
        if (i == line.len or line[i] != '#') continue;
        i += 1;
        skipSpace(line, &i);
        if (!std.mem.startsWith(u8, line[i..], "include")) continue;
        i += "include".len;
        skipSpace(line, &i);
        if (i == line.len or line[i] != '"') continue;
        i += 1;
        const end = std.mem.findScalar(u8, line[i..], '"') orelse continue;
        if (end == 0) continue;
        try out.append(ctx.arena, try ctx.arena.dupe(u8, line[i..][0..end]));
    }
    return out.items;
}

/// Files outside src/ that the C under src/ includes, transitively.
fn includeClosure(ctx: *github.Context, files: *Set, repo: []const u8, src: []const u8) !void {
    if (!github.isDir(ctx.io, src)) return;
    const real_repo = try Io.Dir.cwd().realPathFileAlloc(ctx.io, repo, ctx.arena);
    const real_src = try Io.Dir.cwd().realPathFileAlloc(ctx.io, src, ctx.arena);
    var seen: Set = .empty;
    var todo: std.ArrayList([]const u8) = .empty;
    {
        var dir = try Io.Dir.cwd().openDir(ctx.io, real_src, .{ .iterate = true });
        defer dir.close(ctx.io);
        var walker = try dir.walk(ctx.gpa);
        defer walker.deinit();
        while (try walker.next(ctx.io)) |entry| {
            const ext = std.fs.path.extension(entry.basename);
            if (!std.mem.eql(u8, ext, ".c") and !std.mem.eql(u8, ext, ".h") and !std.mem.eql(u8, ext, ".cc")) continue;
            const full = ctx.path(&.{ real_src, entry.path });
            if (!github.isFile(ctx.io, full)) continue;
            try todo.append(ctx.arena, full);
            try seen.put(ctx.arena, full, {});
        }
    }
    while (todo.pop()) |path| {
        const text = try github.readFile(ctx, ctx.gpa, path);
        defer ctx.gpa.free(text);
        for (try includes(ctx, text)) |name| {
            const joined = ctx.path(&.{ std.fs.path.dirname(path).?, name });
            const target = Io.Dir.cwd().realPathFileAlloc(ctx.io, joined, ctx.arena) catch continue;
            if (!std.mem.startsWith(u8, target, real_repo) or target.len <= real_repo.len or target[real_repo.len] != std.fs.path.sep) continue;
            if (!github.isFile(ctx.io, target) or seen.contains(target)) continue;
            try seen.put(ctx.arena, target, {});
            try todo.append(ctx.arena, target);
            const under_src = std.mem.startsWith(u8, target, real_src) and target.len > real_src.len and target[real_src.len] == std.fs.path.sep;
            if (!under_src) try files.put(ctx.arena, relative(real_repo, target), {});
        }
    }
}

/// Every file a build or a query load reads, as repository-relative paths.
fn mirrorFiles(ctx: *github.Context, repo: []const u8, locations: []const []const u8) ![]const []const u8 {
    var files: Set = .empty;
    for (locations) |location| {
        const gdir = if (location.len == 0) repo else ctx.path(&.{ repo, location });
        for ([_][]const u8{ "src", "queries" }) |sub| try addRegular(ctx, &files, repo, ctx.path(&.{ gdir, sub }));
        try includeClosure(ctx, &files, repo, ctx.path(&.{ gdir, "src" }));
        var buffer: [2][]const u8 = undefined;
        for (distinct(&buffer, gdir, repo)) |d| {
            var dir = try Io.Dir.cwd().openDir(ctx.io, d, .{ .iterate = true });
            defer dir.close(ctx.io);
            var it = dir.iterate();
            while (try it.next(ctx.io)) |e| {
                const full = ctx.path(&.{ d, e.name });
                switch (e.kind) {
                    .file => if (isLicenceName(e.name) or std.mem.eql(u8, e.name, "tree-sitter.json")) {
                        try files.put(ctx.arena, relative(repo, full), {});
                    },
                    .directory => if (isLicenceName(e.name)) try addRegular(ctx, &files, repo, full),
                    else => {},
                }
            }
        }
    }
    try addRegular(ctx, &files, repo, ctx.path(&.{ repo, "queries" }));
    const out = files.keys();
    std.mem.sort([]const u8, out, {}, github.lessThan);
    return out;
}

/// Paths that would fail to unpack on some host.
fn checkPaths(ctx: *github.Context, files: []const []const u8) ![]const []const u8 {
    var problems: std.ArrayList([]const u8) = .empty;
    var lower: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (files) |f| {
        const key = try std.ascii.allocLowerString(ctx.arena, f);
        const slot = try lower.getOrPut(ctx.arena, key);
        if (slot.found_existing and !std.mem.eql(u8, slot.value_ptr.*, f)) {
            try problems.append(ctx.arena, try ctx.arena.print("case collision: {s} / {s}", .{ slot.value_ptr.*, f }));
        }
        slot.value_ptr.* = f;
        if (f.len > 160) try problems.append(ctx.arena, try ctx.arena.print("long path ({d}): {s}", .{ f.len, f }));
    }
    return problems.items;
}

const Group = struct {
    entries: std.ArrayList(*Entry) = .empty,
    out: []const u8 = "",
    ref: []const u8 = "",
    problems: []const []const u8 = &.{},
    err: ?anyerror = null,
};

/// One mirror tree per repository at a commit: the files the build reads,
/// at upstream's own paths, plus generated parsers and a PROVENANCE note.
fn mirror(ctx: *github.Context, group: *Group) !void {
    const first = group.entries.items[0];
    const repo = try github.Repository.parse(first.url);
    const out = ctx.path(&.{ ctx.cache, "mirror", try ctx.arena.print("{s}--{s}--{s}", .{ repo.owner, repo.name, first.commit }) });
    try Io.Dir.cwd().deleteTree(ctx.io, out);

    var locations: std.ArrayList([]const u8) = .empty;
    for (group.entries.items) |e| {
        for (locations.items) |l| {
            if (std.mem.eql(u8, l, e.location)) break;
        } else try locations.append(ctx.arena, e.location);
    }
    std.mem.sort([]const u8, locations.items, {}, github.lessThan);
    const files = try mirrorFiles(ctx, first.repo, locations.items);
    for (files) |f| {
        const dest = ctx.path(&.{ out, f });
        try Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(dest).?);
        try Io.Dir.copyFile(Io.Dir.cwd(), ctx.path(&.{ first.repo, f }), Io.Dir.cwd(), dest, ctx.io, .{});
    }

    var text: std.ArrayList(u8) = .empty;
    try text.print(ctx.arena, "Mirrored from {s} at {s} by ztreesitter's catalogue tool (zig build catalogue).\n", .{ first.url, first.commit });
    try text.appendSlice(ctx.arena, "Every file here except this one and those listed below is that commit's, unmodified;\n");
    try text.appendSlice(ctx.arena, "files the build does not read (tests, bindings, build files) were left out.\n");
    for (group.entries.items) |e| {
        const generated = e.generated orelse continue;
        const src_rel = if (e.location.len == 0) "src" else try ctx.arena.print("{s}/src", .{e.location});
        try copyGenerated(ctx, generated, ctx.path(&.{ out, src_rel }));
        try text.print(ctx.arena, "Generated: {s}/parser.c and the tree_sitter/ headers beside it, by tree-sitter {s} (`tree-sitter generate --js-runtime native`).\n", .{ src_rel, runtime_version });
    }
    try text.print(ctx.arena, "Licence: the repository's ({s}).\n", .{first.licence.spdx});
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = ctx.path(&.{ out, "PROVENANCE" }), .data = text.items });

    group.out = out;
    group.ref = try ctx.arena.print("refs/mirror/{s}/{s}/{s}", .{ repo.owner, repo.name, first.commit });
    group.problems = try checkPaths(ctx, files);
}

fn mirrorTask(ctx: *github.Context, group: *Group) void {
    mirror(ctx, group) catch |err| {
        group.err = err;
    };
}

/// An orphan commit in this repository holding the mirror, under a ref
/// namespace `git clone` does not fetch. A ref that exists is the mirror:
/// an upstream commit does not change, so neither may the files chosen from
/// it, and a run that would choose others stops (PROVENANCE's wording may
/// differ).
fn publishMirror(ctx: *github.Context, root: []const u8, group: *const Group) ![]const u8 {
    const first = group.entries.items[0];
    const index = try ctx.arena.print("{s}.index", .{group.out});
    defer github.remove(ctx, index);
    var env = try ctx.environ.clone(ctx.arena);
    try env.put("GIT_INDEX_FILE", index);
    try env.put("GIT_AUTHOR_DATE", "2000-01-01T00:00:00Z");
    try env.put("GIT_COMMITTER_DATE", "2000-01-01T00:00:00Z");
    const git: []const []const u8 = &.{ "git", "-C", root, "--work-tree", group.out };
    _ = try github.runChecked(ctx, try std.mem.concat(ctx.arena, []const u8, &.{ git, &.{ "add", "-A", "-f", "." } }), .{ .environ = &env });
    const tree = try github.runChecked(ctx, try std.mem.concat(ctx.arena, []const u8, &.{ git, &.{"write-tree"} }), .{ .environ = &env });

    const exists = try github.run(ctx, &.{ "git", "-C", root, "rev-parse", "--verify", "-q", group.ref }, .{});
    if (exists.ok()) {
        const published = try ctx.arena.print("{s}^{{tree}}", .{group.ref});
        const changed = try github.runChecked(ctx, &.{ "git", "-C", root, "diff-tree", "-r", "--name-status", published, tree, "--", ".", ":(exclude)PROVENANCE" }, .{});
        if (changed.len != 0) {
            std.log.err("{s} exists with other files than this run chose:\n{s}", .{ group.ref, changed });
            return error.MirrorChanged;
        }
    } else {
        const message = try ctx.arena.print("Mirror {s} at {s}\n\nSee PROVENANCE.\n", .{ first.url, first.commit });
        const orphan = try github.runChecked(ctx, &.{ "git", "-C", root, "commit-tree", tree, "-m", message }, .{ .environ = &env });
        _ = try github.runChecked(ctx, &.{ "git", "-C", root, "update-ref", group.ref, orphan }, .{});
    }
    return github.runChecked(ctx, &.{ "git", "-C", root, "rev-parse", group.ref }, .{});
}

/// The commit's tree as GitHub's archive of it unpacks, for `zig fetch` to
/// hash what the build will download.
fn exportCommit(ctx: *github.Context, root: []const u8, sha: []const u8) ![]const u8 {
    const dest = ctx.path(&.{ ctx.cache, "published", sha });
    if (github.isDir(ctx.io, dest)) return dest;
    const archive = try std.process.run(ctx.gpa, ctx.io, .{ .argv = &.{ "git", "-C", root, "archive", "--format=tar", sha } });
    defer ctx.gpa.free(archive.stdout);
    defer ctx.gpa.free(archive.stderr);
    if (!archive.term.success()) {
        std.log.err("git archive {s}: {s}", .{ sha, archive.stderr });
        return error.CommandFailed;
    }
    const tmp = try ctx.temporary();
    {
        var dir = try Io.Dir.cwd().openDir(ctx.io, tmp, .{});
        defer dir.close(ctx.io);
        var input: Io.Reader = .fixed(archive.stdout);
        try std.tar.extract(ctx.io, dir, &input, .{});
    }
    try Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(dest).?);
    try Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), dest, ctx.io);
    return dest;
}

fn helixTags(ctx: *github.Context, helix_root: []const u8) ![]const HelixTag {
    const text = try github.readFile(ctx, ctx.arena, ctx.path(&.{ helix_root, "languages.toml" }));
    var out: std.ArrayList(HelixTag) = .empty;
    // `[[grammar]]` tables of `name = "..."` and an inline
    // `source = { git = "...", rev = "...", subpath = "..." }`; anything else
    // in a grammar table is refused rather than misread.
    var in_grammar = false;
    var name: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "[")) {
            in_grammar = std.mem.eql(u8, line, "[[grammar]]");
            name = null;
            continue;
        }
        if (!in_grammar or line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.findScalar(u8, line, '=') orelse return error.HelixToml;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "name")) {
            name = try tomlString(value);
        } else if (std.mem.eql(u8, key, "source")) {
            const source = try tomlInline(ctx, value);
            const git = source.get("git") orelse continue;
            const n = name orelse return error.HelixToml;
            var url = std.mem.trimEnd(u8, git, "/");
            if (std.mem.endsWith(u8, url, ".git")) url = url[0 .. url.len - ".git".len];
            const query = try ctx.arena.print("runtime/queries/{s}/tags.scm", .{n});
            if (!github.isFile(ctx.io, ctx.path(&.{ helix_root, query }))) continue;
            const item: HelixTag = .{ .url = url, .subpath = strip(source.get("subpath") orelse "", "/"), .path = query };
            for (out.items) |o| {
                if (std.ascii.eqlIgnoreCase(o.url, item.url) and std.mem.eql(u8, o.subpath, item.subpath)) break;
            } else try out.append(ctx.arena, item);
        } else return error.HelixToml;
    }
    return out.items;
}

fn tomlString(value: []const u8) ![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.HelixToml;
    const body = value[1 .. value.len - 1];
    if (std.mem.findAny(u8, body, "\"\\") != null) return error.HelixToml;
    return body;
}

fn tomlInline(ctx: *github.Context, value: []const u8) !std.array_hash_map.String([]const u8) {
    if (value.len < 2 or value[0] != '{' or value[value.len - 1] != '}') return error.HelixToml;
    var out: std.array_hash_map.String([]const u8) = .empty;
    var pairs = std.mem.splitScalar(u8, value[1 .. value.len - 1], ',');
    while (pairs.next()) |pair| {
        const eq = std.mem.findScalar(u8, pair, '=') orelse return error.HelixToml;
        try out.put(ctx.arena, std.mem.trim(u8, pair[0..eq], " \t"), try tomlString(std.mem.trim(u8, pair[eq + 1 ..], " \t")));
    }
    return out;
}

//=========================================================================
// Output
//=========================================================================

/// A Zig string literal. Non-ASCII stays UTF-8.
fn zigString(w: *std.ArrayList(u8), arena: Allocator, s: []const u8) !void {
    try w.append(arena, '"');
    for (s) |c| switch (c) {
        '"' => try w.appendSlice(arena, "\\\""),
        '\\' => try w.appendSlice(arena, "\\\\"),
        '\n' => try w.appendSlice(arena, "\\n"),
        '\r' => try w.appendSlice(arena, "\\r"),
        '\t' => try w.appendSlice(arena, "\\t"),
        0...8, 11, 12, 14...0x1f, 0x7f => try w.print(arena, "\\x{x:0>2}", .{c}),
        else => try w.append(arena, c),
    };
    try w.append(arena, '"');
}

fn zigBool(b: bool) []const u8 {
    return if (b) "true" else "false";
}

fn tagsSource(ctx: *github.Context, root: []const u8, e: *const Entry) ![]const u8 {
    if (github.isFile(ctx.io, ctx.path(&.{ root, "queries", e.name, "tags.scm" }))) return "ztreesitter";
    if (e.tags.len != 0) return "grammar";
    if (e.helix_tags != null) return "Helix";
    return "";
}

fn entryLines(ctx: *github.Context, w: *std.ArrayList(u8), root: []const u8, nvim_root: []const u8, e: *const Entry) !void {
    const a = ctx.arena;
    try w.appendSlice(a, "    .{\n");
    const strings = [_][2][]const u8{
        .{ "name", e.name },         .{ "symbol", e.symbol }, .{ "url", e.url },
        .{ "revision", e.revision }, .{ "commit", e.commit }, .{ "location", e.location },
    };
    for (strings) |kv| {
        try w.print(a, "        .{s} = ", .{kv[0]});
        try zigString(w, a, kv[1]);
        try w.appendSlice(a, ",\n");
    }
    try w.print(a, "        .scanner = {s},\n        .abi = {d},\n        .generated = {s},\n        .mirror = ", .{ zigBool(e.scanner), e.abi, zigBool(e.generated != null) });
    try zigString(w, a, e.mirror_commit);
    try w.print(a, ",\n        .tier = {d},\n", .{e.tier});
    const tail = [_][2][]const u8{
        .{ "licence", e.licence.spdx },
        .{ "licence_file", e.licence.file },
        .{ "licence_note", e.licence.note },
        .{ "notes", try std.mem.join(a, "; ", e.notes.items) },
    };
    for (tail) |kv| {
        try w.print(a, "        .{s} = ", .{kv[0]});
        try zigString(w, a, kv[1]);
        try w.appendSlice(a, ",\n");
    }
    try w.appendSlice(a, "        .requires = &.{");
    for (e.requires, 0..) |r, i| {
        if (i != 0) try w.appendSlice(a, ", ");
        try zigString(w, a, r);
    }
    try w.print(a, "}},\n        .status = .{t},\n        .reason = ", .{e.status});
    try zigString(w, a, e.reason);
    try w.appendSlice(a, ",\n        .queries = .{\n");
    const queries = ctx.path(&.{ nvim_root, "runtime", "queries" });
    for (nvim_kinds) |kind| {
        var files: std.ArrayList([]const u8) = .empty;
        try nvimFiles(ctx, &files, queries, e.name, kind, false);
        try w.print(a, "            .{s} = &.{{", .{kind});
        for (files.items, 0..) |f, i| {
            if (i != 0) try w.appendSlice(a, ", ");
            try w.appendSlice(a, ".{ .source = .nvim, .path = ");
            try zigString(w, a, f);
            try w.appendSlice(a, " }");
        }
        try w.appendSlice(a, "},\n");
    }
    try w.appendSlice(a, "            .tags = &.{");
    const own = try a.print("queries/{s}/tags.scm", .{e.name});
    if (github.isFile(ctx.io, ctx.path(&.{ root, own }))) {
        try w.appendSlice(a, ".{ .source = .ztreesitter, .path = ");
        try zigString(w, a, own);
        try w.appendSlice(a, " }");
    } else if (e.tags.len != 0) {
        for (e.tags, 0..) |p, i| {
            if (i != 0) try w.appendSlice(a, ", ");
            try w.appendSlice(a, ".{ .source = .grammar, .path = ");
            try zigString(w, a, p);
            try w.appendSlice(a, " }");
        }
    } else if (e.helix_tags) |p| {
        try w.appendSlice(a, ".{ .source = .helix, .path = ");
        try zigString(w, a, p);
        try w.appendSlice(a, " }");
    }
    try w.appendSlice(a, "},\n        },\n    },\n");
}

fn writeCatalogue(ctx: *github.Context, o: Options, entries: []const *Entry, query_only: []const []const u8, nvim_root: []const u8) !void {
    const a = ctx.arena;
    var w: std.ArrayList(u8) = .empty;
    try w.appendSlice(a, "//! GENERATED by tools/catalogue.zig (zig build catalogue). Do not edit; rerun the tool.\n");
    try w.print(a, "//! nvim-treesitter {s}, Helix {s}, tree-sitter {s}.\n", .{ o.nvim_commit, o.helix_commit, runtime_version });
    try w.appendSlice(a, "const schema = @import(\"schema.zig\");\n\n");
    try w.print(a, "pub const nvim_treesitter_commit = \"{s}\";\npub const helix_commit = \"{s}\";\npub const runtime_version = \"{s}\";\n\n", .{ o.nvim_commit, o.helix_commit, runtime_version });
    try w.appendSlice(a, "pub const grammars: []const schema.Grammar = &.{\n");
    for (entries) |e| try entryLines(ctx, &w, o.root, nvim_root, e);
    try w.appendSlice(a, "};\n\n/// Languages nvim-treesitter ships queries for without a grammar; other\n/// languages' queries inherit them.\npub const query_only: []const []const u8 = &.{");
    for (query_only, 0..) |q, i| {
        if (i != 0) try w.appendSlice(a, ", ");
        try zigString(&w, a, q);
    }
    try w.appendSlice(a, "};\n");
    const out = ctx.path(&.{ o.root, "grammars", "catalogue.zig" });
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = out, .data = w.items });
    _ = try github.runChecked(ctx, &.{ ctx.zig, "fmt", out }, .{});
}

fn writeZon(ctx: *github.Context, o: Options, entries: []const *Entry, nvim_hash: []const u8, helix_hash: []const u8) !void {
    const a = ctx.arena;
    const path = ctx.path(&.{ o.root, "build.zig.zon" });
    const zon = try github.readFile(ctx, a, path);
    const begin = "        // BEGIN GENERATED tools/catalogue.zig\n";
    const end = "        // END GENERATED\n";
    const b = std.mem.find(u8, zon, begin) orelse return error.ZonMarkers;
    const e = std.mem.findPos(u8, zon, b, end) orelse return error.ZonMarkers;
    var w: std.ArrayList(u8) = .empty;
    try w.appendSlice(a, zon[0 .. b + begin.len]);
    try w.print(a,
        \\        .nvim_treesitter = .{{
        \\            .url = "{s}/archive/{s}.tar.gz",
        \\            .hash = "{s}",
        \\            .lazy = true,
        \\        }},
        \\        .helix = .{{
        \\            .url = "{s}/archive/{s}.tar.gz",
        \\            .hash = "{s}",
        \\            .lazy = true,
        \\        }},
        \\
    , .{ nvim_url, o.nvim_commit, nvim_hash, helix_url, o.helix_commit, helix_hash });
    for (entries) |entry| {
        try w.print(a,
            \\        .grammar_{s} = .{{
            \\            .url = "{s}",
            \\            .hash = "{s}",
            \\            .lazy = true,
            \\        }},
            \\
        , .{ entry.name, entry.package_url, entry.hash });
    }
    try w.appendSlice(a, zon[e..]);
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = w.items });
}

fn writeReport(ctx: *github.Context, o: Options, entries: []const *Entry, query_only: []const []const u8) !void {
    const a = ctx.arena;
    var counts: struct { ok: usize = 0, untested: usize = 0, excluded: usize = 0, generated: usize = 0, scanner: usize = 0, tags: usize = 0, helix: usize = 0, noted: usize = 0 } = .{};
    for (entries) |e| {
        switch (e.status) {
            .ok => counts.ok += 1,
            .untested => counts.untested += 1,
            .excluded => counts.excluded += 1,
        }
        if (e.generated != null) counts.generated += 1;
        if (e.scanner) counts.scanner += 1;
        if (e.tags.len != 0) counts.tags += 1;
        if (e.tags.len == 0 and e.helix_tags != null) counts.helix += 1;
        if (e.licence.note.len != 0) counts.noted += 1;
    }
    var w: std.ArrayList(u8) = .empty;
    try w.print(a,
        \\# Grammars
        \\
        \\<!-- GENERATED by tools/catalogue.zig (zig build catalogue). Do not edit; rerun the tool. -->
        \\
        \\The catalogue is nvim-treesitter's parser list at `{s}`: each
        \\grammar at the revision nvim-treesitter's queries are written against.
        \\Tags queries come from the grammar's own repository, else Helix at `{s}`.
        \\
        \\| | |
        \\|---:|---|
        \\| {d} | grammars |
        \\| {d} | built and tested by CI |
        \\| {d} | catalogued, not yet built by CI |
        \\| {d} | excluded |
        \\| {d} | parser generated by this repository |
        \\| {d} | with an external scanner (C) |
        \\| {d} | tags query from the grammar |
        \\| {d} | tags query from Helix |
        \\| {d} | licence needing a reading (see notes) |
        \\
        \\Query-only languages, inherited by others: {s}.
        \\
        \\Every grammar is fetched from a mirror in this repository: the files its build
        \\and its queries read, at the grammar repository's own paths, published as an
        \\orphan commit under `refs/mirror/<owner>/<repo>/<commit>`. Its `PROVENANCE` file
        \\says what was generated; every other file is upstream's, unmodified.
        \\
        \\| grammar | status | ABI | scanner | parser | tags | licence | notes |
        \\|---|---|---:|:---:|---|---|---|---|
        \\
    , .{
        o.nvim_commit,    o.helix_commit[0..12], entries.len, counts.ok,    counts.untested, counts.excluded,
        counts.generated, counts.scanner,        counts.tags, counts.helix, counts.noted,    try std.mem.join(a, ", ", query_only),
    });
    for (entries) |e| {
        var notes: std.ArrayList([]const u8) = .empty;
        for ([_][]const []const u8{ &.{e.reason}, e.notes.items, &.{e.licence.note} }) |group| for (group) |n| {
            if (n.len != 0) try notes.append(a, n);
        };
        try w.print(a, "| [{s}]({s}) | {t} | {d} | {s} | {s} | {s} | {s} | {s} |\n", .{
            e.name,                                 e.url,                                                e.status,                       e.abi,
            if (e.scanner) "yes" else "",           if (e.generated != null) "generated" else "upstream", try tagsSource(ctx, o.root, e), e.licence.spdx,
            try std.mem.join(a, "; ", notes.items),
        });
    }
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = ctx.path(&.{ o.root, "docs", "grammars.md" }), .data = w.items });
}

//=========================================================================
// Main
//=========================================================================

const Slot = struct {
    name: []const u8,
    info: Lua,
    entry: ?Entry = null,
    err: ?anyerror = null,
};

fn inspectTask(ctx: *github.Context, shared: *Shared, slot: *Slot) void {
    slot.entry = inspect(ctx, shared, slot.name, slot.info) catch |err| {
        slot.err = err;
        return;
    };
}

const Hashed = struct {
    dir: []const u8,
    hash: []const u8 = "",
    err: ?anyerror = null,
};

fn hashTask(ctx: *github.Context, h: *Hashed) void {
    h.hash = github.zigHash(ctx, h.dir) catch |err| {
        h.err = err;
        return;
    };
}

fn catalogue(ctx: *github.Context, o: Options) !u8 {
    const a = ctx.arena;
    const nvim_root = try github.download(ctx, nvim_url, o.nvim_commit);
    const helix_root = try github.download(ctx, helix_url, o.helix_commit);

    const parsers = try LuaReader.read(a, try github.readFile(ctx, a, ctx.path(&.{ nvim_root, "lua", "nvim-treesitter", "parsers.lua" })));
    if (parsers != .table) return error.LuaSyntax;
    var query_only: std.ArrayList([]const u8) = .empty;
    var slots: std.ArrayList(Slot) = .empty;
    var wanted = std.mem.tokenizeScalar(u8, o.only orelse "", ',');
    for (parsers.table.keys(), parsers.table.values()) |name, info| {
        if (info.get("install_info") == null) {
            try query_only.append(a, name);
            continue;
        }
        if (o.only != null) {
            wanted.reset();
            while (wanted.next()) |w| {
                if (std.mem.eql(u8, w, name)) break;
            } else continue;
        }
        try slots.append(a, .{ .name = name, .info = info });
    }
    std.mem.sort([]const u8, query_only.items, {}, github.lessThan);
    std.mem.sort(Slot, slots.items, {}, struct {
        fn lt(_: void, x: Slot, y: Slot) bool {
            return github.lessThan({}, x.name, y.name);
        }
    }.lt);

    var shared: Shared = .{ .cli = .{ .path = o.tree_sitter }, .helix = try helixTags(ctx, helix_root) };
    {
        var group: Io.Group = .init;
        for (slots.items) |*slot| group.async(ctx.io, inspectTask, .{ ctx, &shared, slot });
        try group.await(ctx.io);
    }
    var failures: usize = 0;
    var entries: std.ArrayList(*Entry) = .empty;
    for (slots.items) |*slot| {
        if (slot.err) |err| {
            std.log.err("catalogue: {s}: {t}", .{ slot.name, err });
            failures += 1;
        } else try entries.append(a, &slot.entry.?);
    }
    if (failures != 0) {
        std.log.err("catalogue: {d} grammars could not be inspected", .{failures});
        return 1;
    }

    for (entries.items) |e| for (excluded) |x| {
        if (std.mem.eql(u8, x[0], e.name)) {
            e.status = .excluded;
            e.reason = x[1];
        }
    };

    if (o.only != null) {
        var w: std.ArrayList(u8) = .empty;
        for (entries.items) |e| try entryLines(ctx, &w, o.root, nvim_root, e);
        var buffer: [4096]u8 = undefined;
        var stdout = Io.File.stdout().writerStreaming(ctx.io, &buffer);
        try stdout.interface.writeAll(w.items);
        try stdout.interface.flush();
        return 0;
    }

    // One mirror per repository at a commit, in (url, commit) order.
    var groups: std.ArrayList(Group) = .empty;
    for (entries.items) |e| {
        for (groups.items) |*g| {
            const f = g.entries.items[0];
            if (std.mem.eql(u8, f.url, e.url) and std.mem.eql(u8, f.commit, e.commit)) {
                try g.entries.append(a, e);
                break;
            }
        } else {
            try groups.append(a, .{});
            try groups.items[groups.items.len - 1].entries.append(a, e);
        }
    }
    std.mem.sort(Group, groups.items, {}, struct {
        fn lt(_: void, x: Group, y: Group) bool {
            const p = x.entries.items[0];
            const q = y.entries.items[0];
            return switch (std.mem.order(u8, p.url, q.url)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.order(u8, p.commit, q.commit) == .lt,
            };
        }
    }.lt);
    {
        var group: Io.Group = .init;
        for (groups.items) |*g| group.async(ctx.io, mirrorTask, .{ ctx, g });
        try group.await(ctx.io);
    }
    for (groups.items) |*g| {
        if (g.err) |err| {
            std.log.err("catalogue: mirror of {s}: {t}", .{ g.entries.items[0].url, err });
            return 1;
        }
        const sha = try publishMirror(ctx, o.root, g);
        g.out = try exportCommit(ctx, o.root, sha);
        for (g.entries.items) |e| {
            e.package_url = try a.print("{s}/archive/{s}.tar.gz", .{ repository, sha });
            e.package_dir = g.out;
            e.mirror_commit = sha;
            try e.notes.appendSlice(a, g.problems);
        }
    }

    // The nvim-treesitter and Helix archives, and each mirror, as zig hashes.
    var hashed: std.ArrayList(Hashed) = .empty;
    try hashed.append(a, .{ .dir = try github.tarballUrl(a, nvim_url, o.nvim_commit) });
    try hashed.append(a, .{ .dir = try github.tarballUrl(a, helix_url, o.helix_commit) });
    for (groups.items) |g| try hashed.append(a, .{ .dir = g.out });
    {
        var group: Io.Group = .init;
        for (hashed.items) |*h| group.async(ctx.io, hashTask, .{ ctx, h });
        try group.await(ctx.io);
    }
    for (hashed.items) |h| if (h.err) |err| {
        std.log.err("catalogue: zig fetch {s}: {t}", .{ h.dir, err });
        return 1;
    };
    for (entries.items) |e| {
        for (hashed.items[2..]) |h| {
            if (std.mem.eql(u8, h.dir, e.package_dir)) e.hash = h.hash;
        }
    }

    try writeCatalogue(ctx, o, entries.items, query_only.items, nvim_root);
    try writeZon(ctx, o, entries.items, hashed.items[0].hash, hashed.items[1].hash);
    try writeReport(ctx, o, entries.items, query_only.items);
    std.log.info("catalogue: {d} grammars written", .{entries.items.len});
    return 0;
}
