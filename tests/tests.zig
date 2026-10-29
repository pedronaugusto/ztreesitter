//! Tests that need grammars, run against the module a consumer gets. Each
//! grammar test skips when its grammar was not selected (`-Dgrammars`).

const std = @import("std");
const ts = @import("ztreesitter");
const grammars = @import("grammars");
const catalogue = @import("ztreesitter.catalogue");
const samples = @import("samples.zig");
const shakedown = @import("shakedown");

const gpa = std.testing.allocator;
const io = std.testing.io;

fn grammar(name: []const u8) ?*const ts.Grammar {
    for (grammars.list) |g| if (std.mem.eql(u8, g.name, name)) return g;
    return null;
}

fn need(name: []const u8) !*const ts.Grammar {
    return grammar(name) orelse error.SkipZigTest;
}

fn parse(parser: *ts.Parser, g: *const ts.Grammar, text: []const u8) !ts.Tree {
    try parser.setLanguage(g.language());
    return parser.parse(io, .{ .slice = text }, null, .{});
}

fn sexp(node: ts.Node) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try node.format(&out.writer);
    return out.toOwnedSlice();
}

test "every selected grammar loads, parses its sample and compiles its queries" {
    var failures: usize = 0;
    for (grammars.list) |g| {
        var parser: ts.Parser = .init();
        defer parser.deinit();
        const lang = g.language();
        if (lang.abiVersion() < ts.min_language_version or lang.abiVersion() > ts.max_language_version) {
            std.debug.print("{s}: ABI {d} outside {d}..{d}\n", .{ g.name, lang.abiVersion(), ts.min_language_version, ts.max_language_version });
            failures += 1;
            continue;
        }
        try parser.setLanguage(lang);
        if (samples.find(g.name)) |text| {
            var tree = try parser.parse(io, .{ .slice = text }, null, .{});
            defer tree.deinit();
            if (tree.rootNode().hasError()) {
                const s = try sexp(tree.rootNode());
                defer gpa.free(s);
                std.debug.print("{s}: the sample parses with errors: {s}\n", .{ g.name, s });
                failures += 1;
            }
        } else {
            std.debug.print("{s}: no sample in tests/samples.zig\n", .{g.name});
            failures += 1;
        }
        inline for (@typeInfo(ts.Grammar.Queries).@"struct".field_names) |field_name| {
            if (@field(g.queries, field_name)) |text| {
                var diagnostic: ts.QueryDiagnostic = .{};
                if (ts.Query.initDiagnostic(gpa, lang, text.text, .{ .dialect = text.dialect }, &diagnostic)) |q| {
                    var query = q;
                    query.deinit();
                } else |err| {
                    std.debug.print("{s}: {s} query: {s} at byte {d} {s}\n", .{ g.name, field_name, @errorName(err), diagnostic.offset, diagnostic.predicate });
                    failures += 1;
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "every selected grammar is in the catalogue under its own name" {
    for (grammars.list) |g| {
        const entry = for (catalogue.grammars) |e| {
            if (std.mem.eql(u8, e.name, g.name)) break e;
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(entry.symbol, g.symbol);
        try std.testing.expectEqualStrings(entry.commit, g.commit);
    }
}

/// Apply an edit to `text` (owned by gpa) and return the new text and edit.
fn applyEdit(text: []const u8, start: usize, old_len: usize, insert: []const u8) !struct { []u8, ts.InputEdit } {
    const new = try std.mem.concat(gpa, u8, &.{ text[0..start], insert, text[start + old_len ..] });
    return .{ new, .{
        .start_byte = @intCast(start),
        .old_end_byte = @intCast(start + old_len),
        .new_end_byte = @intCast(start + insert.len),
        .start_point = pointAt(text, start),
        .old_end_point = pointAt(text, start + old_len),
        .new_end_point = pointAt(new, start + insert.len),
    } };
}

fn pointAt(text: []const u8, byte: usize) ts.Point {
    var p: ts.Point = .{};
    for (text[0..byte]) |ch| {
        if (ch == '\n') {
            p.row += 1;
            p.column = 0;
        } else p.column += 1;
    }
    return p;
}

test "incremental: edits re-parsed with the old tree equal fresh parses" {
    const g = try need("c");
    var parser: ts.Parser = .init();
    defer parser.deinit();
    try parser.setLanguage(g.language());

    var text = try gpa.dupe(u8, "int f(int a) {\n  return a + 1;\n}\n\nint g(void) { return f(2); }\n");
    defer gpa.free(text);
    var tree = try parser.parse(io, .{ .slice = text }, null, .{});
    defer tree.deinit();

    var prng: std.Random.DefaultPrng = .init(0x7ee5);
    const random = prng.random();
    const inserts = [_][]const u8{ "x", " * 2", "\n", "int h;\n", "}", "/* c */", "" };
    for (0..200) |_| {
        const start = random.uintAtMost(usize, text.len);
        const old_len = random.uintAtMost(usize, @min(4, text.len - start));
        const insert = inserts[random.uintLessThan(usize, inserts.len)];
        const new_text, const edit = try applyEdit(text, start, old_len, insert);
        gpa.free(text);
        text = new_text;

        tree.edit(edit);
        var next = try parser.parse(io, .{ .slice = text }, &tree, .{});
        var fresh = try parser.parse(io, .{ .slice = text }, null, .{});
        defer fresh.deinit();

        const a = try sexp(next.rootNode());
        defer gpa.free(a);
        const b = try sexp(fresh.rootNode());
        defer gpa.free(b);
        try std.testing.expectEqualStrings(b, a);

        var changed = ts.Tree.changedRanges(tree, next);
        defer changed.deinit();
        for (changed.items) |r| try std.testing.expect(r.start_byte <= r.end_byte);

        tree.deinit();
        tree = next;
    }
}

test "incremental: changed ranges cover a renamed identifier" {
    const g = try need("json");
    var parser: ts.Parser = .init();
    defer parser.deinit();
    const old_text = "{\"a\": 1, \"b\": [true]}";
    var old = try parse(&parser, g, old_text);
    defer old.deinit();
    const new_text, const edit = try applyEdit(old_text, 15, 4, "\"str\"");
    defer gpa.free(new_text);
    old.edit(edit);
    var new = try parser.parse(io, .{ .slice = new_text }, &old, .{});
    defer new.deinit();
    var changed = ts.Tree.changedRanges(old, new);
    defer changed.deinit();
    try std.testing.expect(changed.items.len >= 1);
    try std.testing.expect(changed.items[0].start_byte <= 15 and changed.items[changed.items.len - 1].end_byte >= 20);
}

test "a reader input parses the same tree as a slice" {
    const g = try need("python");
    const text = samples.find("python").?;
    var parser: ts.Parser = .init();
    defer parser.deinit();
    var a = try parse(&parser, g, text);
    defer a.deinit();

    const Pieces = struct {
        reader: ts.Input.Reader = .{ .read = read },
        text: []const u8,
        fn read(reader: *const ts.Input.Reader, byte: u32, _: ts.Point) []const u8 {
            const self: *const @This() = @fieldParentPtr("reader", reader);
            if (byte >= self.text.len) return "";
            return self.text[byte..@min(self.text.len, byte + 5)];
        }
    };
    const pieces: Pieces = .{ .text = text };
    var b = try parser.parse(io, .{ .reader = &pieces.reader }, null, .{});
    defer b.deinit();
    const sa = try sexp(a.rootNode());
    defer gpa.free(sa);
    const sb = try sexp(b.rootNode());
    defer gpa.free(sb);
    try std.testing.expectEqualStrings(sa, sb);
}

test "a parse past its deadline pauses, then resumes to the same tree" {
    const g = try need("c");
    var parser: ts.Parser = .init();
    defer parser.deinit();
    try parser.setLanguage(g.language());
    // Big enough that the runtime checks its progress callback.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..2000) |i| try text.print(gpa, "int f{d}(int a) {{ return a * {d}; }}\n", .{ i, i });

    const past = std.Io.Clock.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Paused, parser.parse(io, .{ .slice = text.items }, null, .{ .deadline = past }));
    var resumed = try parser.parse(io, .{ .slice = text.items }, null, .{});
    defer resumed.deinit();
    parser.reset();
    var fresh = try parser.parse(io, .{ .slice = text.items }, null, .{});
    defer fresh.deinit();
    try std.testing.expect(!resumed.rootNode().hasError());
    try std.testing.expectEqual(fresh.rootNode().endByte(), resumed.rootNode().endByte());
    try std.testing.expectEqual(fresh.rootNode().descendantCount(), resumed.rootNode().descendantCount());
}

test "a canceled parse stops with error.Canceled" {
    const g = try need("c");
    var parser: ts.Parser = .init();
    defer parser.deinit();
    try parser.setLanguage(g.language());
    // Long enough that the cancel lands well before the parse could end.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..50_000) |i| try text.print(gpa, "int f{d}(int a) {{ return a * {d}; }}\n", .{ i, i });

    const Task = struct {
        fn run(p: *ts.Parser, t: []const u8) ts.Parser.ParseError!ts.Tree {
            return p.parse(io, .{ .slice = t }, null, .{});
        }
    };
    var future = io.concurrent(Task.run, .{ &parser, text.items }) catch return error.SkipZigTest;
    if (future.cancel(io)) |finished| {
        var tree = finished;
        tree.deinit();
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.Canceled, err);

    // The parser is usable again once reset.
    parser.reset();
    var tree = try parser.parse(io, .{ .slice = "int x;" }, null, .{});
    defer tree.deinit();
    try std.testing.expect(!tree.rootNode().hasError());
}

test "injections: HTML's script and style parsed over included ranges" {
    const html = try need("html");
    const js = try need("javascript");
    const css = try need("css");
    const text = samples.find("html").?;
    var parser: ts.Parser = .init();
    defer parser.deinit();
    var host = try parse(&parser, html, text);
    defer host.deinit();

    var query = try ts.Query.init(gpa, html.language(), html.queries.injections.?.text, .{ .dialect = html.queries.injections.?.dialect });
    defer query.deinit();
    var cursor = try ts.QueryCursor.init(gpa);
    defer cursor.deinit();
    const content = query.captureIndex("injection.content").?;

    var found_js = false;
    var found_css = false;
    var matches = cursor.matches(io, &query, host.rootNode(), .{ .slice = text }, .{});
    while (try matches.next()) |m| {
        const lang_name = (query.property(m.pattern, "injection.language", null) orelse continue).value orelse continue;
        var nodes = m.nodes(content);
        const node = nodes.next() orelse continue;
        const target = if (std.mem.eql(u8, lang_name, "javascript")) js else if (std.mem.eql(u8, lang_name, "css")) css else continue;
        try parser.setLanguage(target.language());
        try parser.setIncludedRanges(&.{node.range()});
        var injected = try parser.parse(io, .{ .slice = text }, null, .{});
        defer injected.deinit();
        const root = injected.rootNode();
        try std.testing.expect(!root.hasError());
        // Positions are absolute: the injected tree starts where the
        // content node does.
        try std.testing.expectEqual(node.startByte(), root.startByte());
        if (target == js) found_js = true else found_css = true;
        try parser.setIncludedRanges(&.{});
    }
    try std.testing.expect(found_js and found_css);
}

test "injections: Markdown fences name their language, nested twice" {
    const md = try need("markdown");
    const inline_md = try need("markdown_inline");
    _ = inline_md;
    const zig = try need("zig");
    const text = "# T\n\n```zig\nconst s = \"x\";\n```\n\n```markdown\n```zig\nconst y = 2;\n```\n```\n";
    var parser: ts.Parser = .init();
    defer parser.deinit();
    var tree = try parse(&parser, md, text);
    defer tree.deinit();

    var query = try ts.Query.init(gpa, md.language(), md.queries.injections.?.text, .{ .dialect = md.queries.injections.?.dialect });
    defer query.deinit();
    var cursor = try ts.QueryCursor.init(gpa);
    defer cursor.deinit();
    const lang_capture = query.captureIndex("injection.language").?;
    const content = query.captureIndex("injection.content").?;

    var zig_blocks: usize = 0;
    var matches = cursor.matches(io, &query, tree.rootNode(), .{ .slice = text }, .{});
    while (try matches.next()) |m| {
        var langs = m.nodes(lang_capture);
        const lang_node = langs.next() orelse continue;
        var contents = m.nodes(content);
        const body = contents.next() orelse continue;
        const name = lang_node.text(text);
        if (std.mem.eql(u8, name, "zig")) {
            try parser.setLanguage(zig.language());
            try parser.setIncludedRanges(&.{body.range()});
            var inner = try parser.parse(io, .{ .slice = text }, null, .{});
            defer inner.deinit();
            try std.testing.expect(!inner.rootNode().hasError());
            try parser.setIncludedRanges(&.{});
            zig_blocks += 1;
        } else if (std.mem.eql(u8, name, "markdown")) {
            // The nested document: parse it as Markdown and find its fence.
            try parser.setLanguage(md.language());
            try parser.setIncludedRanges(&.{body.range()});
            var inner = try parser.parse(io, .{ .slice = text }, null, .{});
            defer inner.deinit();
            try parser.setIncludedRanges(&.{});
            var nested_cursor = try ts.QueryCursor.init(gpa);
            defer nested_cursor.deinit();
            var inner_matches = nested_cursor.matches(io, &query, inner.rootNode(), .{ .slice = text }, .{});
            while (try inner_matches.next()) |im| {
                var l = im.nodes(lang_capture);
                const ln = l.next() orelse continue;
                if (std.mem.eql(u8, ln.text(text), "zig")) zig_blocks += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 2), zig_blocks);
}

test "predicates filter matches: Neovim's dialect on the zig highlights" {
    const g = try need("zig");
    const text = "const Foo = struct {};\nconst bar = 1;\nconst BAZ = 2;\n";
    var parser: ts.Parser = .init();
    defer parser.deinit();
    var tree = try parse(&parser, g, text);
    defer tree.deinit();
    var query = try ts.Query.init(gpa, g.language(),
        \\((identifier) @type (#lua-match? @type "^%u%l"))
        \\((identifier) @constant (#match? @constant "^[A-Z][A-Z_0-9]+$"))
        \\((identifier) @kw (#any-of? @kw "bar" "qux"))
        \\((identifier) @not (#not-eq? @not "Foo"))
    , .{ .dialect = .neovim });
    defer query.deinit();
    var cursor = try ts.QueryCursor.init(gpa);
    defer cursor.deinit();
    var counts: [4]usize = @splat(0);
    var captures = cursor.captures(io, &query, tree.rootNode(), .{ .slice = text }, .{});
    while (try captures.next()) |e| {
        // The grammar has zero-width identifiers in places; count words.
        if (e.node().text(text).len != 0) counts[e.capture().index] += 1;
    }
    try std.testing.expectEqual([_]usize{ 1, 1, 1, 2 }, counts);
}

/// A reader over `text` in seven-byte chunks, in `encoding`.
const Chunks = struct {
    reader: ts.Input.Reader,
    text: []const u8,

    fn init(text: []const u8, encoding: ts.Encoding) Chunks {
        return .{ .reader = .{ .read = read, .encoding = encoding }, .text = text };
    }

    fn read(reader: *const ts.Input.Reader, byte: u32, _: ts.Point) []const u8 {
        const self: *const Chunks = @fieldParentPtr("reader", reader);
        if (byte >= self.text.len) return "";
        return self.text[byte..@min(self.text.len, byte + 7)];
    }
};

/// How many matches `source` finds in `text`, read through `Chunks`.
fn countMatches(g: *const ts.Grammar, text: []const u8, encoding: ts.Encoding, source: []const u8) !usize {
    var parser: ts.Parser = .init();
    defer parser.deinit();
    try parser.setLanguage(g.language());
    const chunks: Chunks = .init(text, encoding);
    var tree = try parser.parse(io, .{ .reader = &chunks.reader }, null, .{});
    defer tree.deinit();
    var query = try ts.Query.init(gpa, g.language(), source, .{ .dialect = .tree_sitter });
    defer query.deinit();
    var cursor = try ts.QueryCursor.init(gpa);
    defer cursor.deinit();
    var count: usize = 0;
    var matches = cursor.matches(io, &query, tree.rootNode(), .{ .reader = &chunks.reader }, .{});
    while (try matches.next()) |_| count += 1;
    return count;
}

test "eq? compares whole texts from a reader, past the predicate scratch" {
    const g = try need("json");
    // Two strings longer than the 16 KiB scratch, equal but for their last byte.
    const long = 40 * 1024;
    const body = try gpa.alloc(u8, long);
    defer gpa.free(body);
    @memset(body, 'a');
    const same = try gpa.print("{{\"{s}\": \"{s}\"}}", .{ body, body });
    defer gpa.free(same);
    const differ = try gpa.dupe(u8, same);
    defer gpa.free(differ);
    differ[differ.len - 3] = 'b';

    const captures = "((pair key: (string) @k value: (string) @v) (#eq? @k @v))";
    try std.testing.expectEqual(1, try countMatches(g, same, .utf8, captures));
    try std.testing.expectEqual(0, try countMatches(g, differ, .utf8, captures));

    const literal = try gpa.print("((pair value: (string) @v) (#eq? @v \"\\\"{s}\\\"\"))", .{body});
    defer gpa.free(literal);
    try std.testing.expectEqual(1, try countMatches(g, same, .utf8, literal));
    try std.testing.expectEqual(0, try countMatches(g, differ, .utf8, literal));
}

test "eq? and any-of? compare UTF-16 text with UTF-8 literals, astral code points too" {
    const g = try need("json");
    const utf8 = "{\"k\": \"h\u{e9}llo \u{1f600}\"}";
    var units: [64]u16 = undefined;
    const n = try std.unicode.utf8ToUtf16Le(&units, utf8);
    // utf8ToUtf16Le stores each unit little-endian: these bytes are UTF-16LE.
    const text = std.mem.sliceAsBytes(units[0..n]);
    try std.testing.expectEqual(1, try countMatches(g, text, .utf16le, "((string) @s (#eq? @s \"\\\"h\u{e9}llo \u{1f600}\\\"\"))"));
    try std.testing.expectEqual(0, try countMatches(g, text, .utf16le, "((string) @s (#eq? @s \"\\\"h\u{e9}llo \u{1f601}\\\"\"))"));
    try std.testing.expectEqual(1, try countMatches(g, text, .utf16le, "((string) @s (#any-of? @s \"x\" \"\\\"k\\\"\"))"));
}

test "a field before a predicate is a syntax error at the field (libs/tree-sitter.patch)" {
    const g = try need("json");
    // Found by the query-source fuzz target: upstream wrote the field one
    // past its steps (UPSTREAM.md).
    const source = "(pair key: (#set! x))";
    var diagnostic: ts.QueryDiagnostic = .{};
    try std.testing.expectError(error.Syntax, ts.Query.initDiagnostic(gpa, g.language(), source, .{ .dialect = .tree_sitter }, &diagnostic));
    try std.testing.expectEqual(std.mem.find(u8, source, "key").?, diagnostic.offset);
}

test "tags: references in Rust" {
    const g = try need("rust");
    const text = g.queries.tags orelse return error.SkipZigTest;
    const source = "fn area(w: i32, h: i32) -> i32 { w * h }\nfn main() { let _ = area(2, 3); }\n";
    var tags = try ts.Tags.init(gpa, g.language(), text, .{ .locals = g.queries.locals });
    defer tags.deinit();
    var parser: ts.Parser = .init();
    defer parser.deinit();
    var tree = try parse(&parser, g, source);
    defer tree.deinit();
    var cursor = try ts.QueryCursor.init(gpa);
    defer cursor.deinit();
    var out: std.ArrayList(ts.Tag) = .empty;
    defer out.deinit(gpa);
    var docs: std.ArrayList(ts.Range) = .empty;
    defer docs.deinit(gpa);
    try tags.collect(gpa, io, &cursor, tree.rootNode(), .{ .slice = source }, &out, &docs);
    var calls: usize = 0;
    for (out.items) |t| {
        if (t.role != .reference) continue;
        try std.testing.expectEqualStrings("call", t.kind);
        try std.testing.expectEqualStrings("area", source[t.name.start_byte..t.name.end_byte]);
        calls += 1;
    }
    try std.testing.expectEqual(1, calls);
}

/// The tags of `source` under `tags`, with their docs.
fn collectTags(g: *const ts.Grammar, tags: *const ts.Tags, source: []const u8, out: *std.ArrayList(ts.Tag), docs: *std.ArrayList(ts.Range)) !void {
    var parser: ts.Parser = .init();
    defer parser.deinit();
    var tree = try parse(&parser, g, source);
    defer tree.deinit();
    var cursor = try ts.QueryCursor.init(gpa);
    defer cursor.deinit();
    try tags.collect(gpa, io, &cursor, tree.rootNode(), .{ .slice = source }, out, docs);
}

test "tags: JavaScript docs selected by select-adjacent! and cleaned by strip!" {
    const g = try need("javascript");
    const text = g.queries.tags orelse return error.SkipZigTest;
    var tags = try ts.Tags.init(gpa, g.language(), text, .{});
    defer tags.deinit();
    const source = "// unrelated\n\n/** Adds. */\n// Twice.\nfunction add() {}\n";
    var out: std.ArrayList(ts.Tag) = .empty;
    defer out.deinit(gpa);
    var docs: std.ArrayList(ts.Range) = .empty;
    defer docs.deinit(gpa);
    try collectTags(g, &tags, source, &out, &docs);
    const add = for (out.items) |t| {
        if (t.role == .definition and std.mem.eql(u8, source[t.name.start_byte..t.name.end_byte], "add")) break t;
    } else return error.TestUnexpectedResult;
    // The comment above the blank line is not adjacent.
    try std.testing.expectEqual(2, add.docs.len);
    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try tags.docText(gpa, add, docs.items, .{ .slice = source }, &w);
    // tags.rs's strip! for JavaScript leaves a block comment's closing `*/`.
    try std.testing.expectEqualStrings("Adds. */\nTwice.", w.buffered());
}

test "tags: (#is-not? local) drops names a locals query defines in scope, as far as scopes inherit" {
    const g = try need("python");
    const tags_query: ts.QueryText = .{ .dialect = .tree_sitter, .text =
    \\((call function: (identifier) @name) @reference.call
    \\  (#is-not? local))
    };
    const source =
        \\def f(g):
        \\    g()
        \\    h()
        \\    def inner():
        \\        g()
        \\g()
        \\
    ;
    // Called names left: with inheriting scopes, `inner` sees `f`'s `g`;
    // without, it does not.
    const cases = [_]struct { []const u8, []const []const u8 }{
        .{
            \\(function_definition) @local.scope
            \\(parameters (identifier) @local.definition)
            , &.{ "h", "g" },
        },
        .{
            \\((function_definition) @local.scope
            \\  (#set! local.scope-inherits false))
            \\(parameters (identifier) @local.definition)
            , &.{ "h", "g", "g" },
        },
    };
    for (cases) |case| {
        var tags = try ts.Tags.init(gpa, g.language(), tags_query, .{ .locals = .{ .dialect = .tree_sitter, .text = case[0] } });
        defer tags.deinit();
        var out: std.ArrayList(ts.Tag) = .empty;
        defer out.deinit(gpa);
        var docs: std.ArrayList(ts.Range) = .empty;
        defer docs.deinit(gpa);
        try collectTags(g, &tags, source, &out, &docs);
        try std.testing.expectEqual(case[1].len, out.items.len);
        for (out.items, case[1]) |t, name| try std.testing.expectEqualStrings(name, source[t.name.start_byte..t.name.end_byte]);
    }
}

test "tags: definitions in C, Swift and C#" {
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "c", "int area(int w, int h) { return w * h; }\nstruct point { int x; };\n", "area" },
        .{ "swift", "class Shape { func area() -> Double { return 0 } }\n", "Shape" },
        .{ "c_sharp", "namespace N { class Shape { int Area() { return 0; } } }\n", "Shape" },
    };
    var any = false;
    for (cases) |case| {
        const g = grammar(case[0]) orelse continue;
        const text = g.queries.tags orelse continue;
        any = true;
        var tags = try ts.Tags.init(gpa, g.language(), text, .{ .locals = g.queries.locals });
        defer tags.deinit();
        var parser: ts.Parser = .init();
        defer parser.deinit();
        var tree = try parse(&parser, g, case[1]);
        defer tree.deinit();
        var cursor = try ts.QueryCursor.init(gpa);
        defer cursor.deinit();
        var out: std.ArrayList(ts.Tag) = .empty;
        defer out.deinit(gpa);
        var docs: std.ArrayList(ts.Range) = .empty;
        defer docs.deinit(gpa);
        try tags.collect(gpa, io, &cursor, tree.rootNode(), .{ .slice = case[1] }, &out, &docs);
        var found = false;
        for (out.items) |t| {
            const name = case[1][t.name.start_byte..t.name.end_byte];
            if (t.role == .definition and std.mem.eql(u8, name, case[2])) found = true;
        }
        if (!found) {
            std.debug.print("{s}: no definition of {s} among {d} tags\n", .{ case[0], case[2], out.items.len });
            return error.TestUnexpectedResult;
        }
    }
    if (!any) return error.SkipZigTest;
}

test "the allocator seam balances: a parse, an edit and a query" {
    const g = try need("json");
    ts.setAllocator(gpa);
    defer ts.resetAllocator();
    var parser: ts.Parser = .init();
    defer parser.deinit();
    var tree = try parse(&parser, g, "[1, 2, {\"a\": 3}]");
    defer tree.deinit();
    var query = try ts.Query.init(gpa, g.language(), "(number) @n", .{ .dialect = .tree_sitter });
    defer query.deinit();
    var cursor = try ts.QueryCursor.init(gpa);
    defer cursor.deinit();
    var matches = cursor.matches(io, &query, tree.rootNode(), .{ .slice = "[1, 2, {\"a\": 3}]" }, .{});
    var n: usize = 0;
    while (try matches.next()) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 3), n);
    const s = try sexp(tree.rootNode());
    gpa.free(s);
}

// ---------------------------------------------------------------------------
// Fuzz targets, as shakedown properties, on the json grammar
// ---------------------------------------------------------------------------

/// `n` at most `max` bytes, each from `alphabet`.
fn drawn(case: *shakedown.Case, alphabet: []const u8, max: usize) ![]u8 {
    const s = case.source;
    const out = try case.gpa.alloc(u8, shakedown.gen.intRange(s, usize, 0, max));
    for (out) |*b| b.* = alphabet[shakedown.gen.intRange(s, usize, 0, alphabet.len - 1)];
    return out;
}

/// A reader over `text` in pieces whose lengths the case draws. Pieces end
/// on code-unit boundaries, as `Input.Reader` requires; `text` holds no
/// surrogate pairs or multi-byte UTF-8 to split.
const Drawn = struct {
    reader: ts.Input.Reader,
    text: []const u8,
    /// Where each piece ends, ascending, the last at `text.len`.
    ends: []const usize,

    fn init(case: *shakedown.Case, text: []const u8, encoding: ts.Encoding) !Drawn {
        const unit: usize = if (encoding == .utf8) 1 else 2;
        var ends: std.ArrayList(usize) = .empty;
        var at: usize = 0;
        while (at < text.len) {
            at += unit * shakedown.gen.intRange(case.source, usize, 1, @min((text.len - at) / unit, 8));
            try ends.append(case.gpa, at);
        }
        return .{ .reader = .{ .read = read, .encoding = encoding }, .text = text, .ends = ends.items };
    }

    fn read(reader: *const ts.Input.Reader, byte: u32, _: ts.Point) []const u8 {
        const self: *const Drawn = @fieldParentPtr("reader", reader);
        // The first piece ending after `byte`.
        const i = std.sort.upperBound(usize, self.ends, @as(usize, byte), order);
        if (i == self.ends.len) return "";
        return self.text[byte..self.ends[i]];
    }

    fn order(byte: usize, end: usize) std.math.Order {
        return std.math.order(byte, end);
    }
};

/// Any bytes parse without fault, and read in any pieces they parse to the
/// same tree.
fn parsesAnyBytes(g: *const ts.Grammar, case: *shakedown.Case) !void {
    const text = try drawn(case, "{}[]\":,0123456789.eE+-truefalsn \n\\\x00\xff", 200);
    case.note("\"{s}\"", .{text});
    var parser: ts.Parser = .init();
    defer parser.deinit();
    try parser.setLanguage(g.language());
    var whole = try parser.parseSlice(text, null);
    defer whole.deinit();
    try std.testing.expect(whole.rootNode().endByte() <= text.len);
    const pieces: Drawn = try .init(case, text, .utf8);
    var read = try parser.parse(case.io(), .{ .reader = &pieces.reader }, null, .{});
    defer read.deinit();
    const a = try sexp(whole.rootNode());
    defer gpa.free(a);
    const b = try sexp(read.rootNode());
    defer gpa.free(b);
    try std.testing.expectEqualStrings(a, b);
}

test "fuzz: parseSlice takes any bytes, and a reader in any pieces parses the same tree" {
    const g = try need("json");
    try shakedown.check(gpa, g, parsesAnyBytes, .{ .cases = 1000, .seed = 0x750 });
}

/// Any query source compiles or is refused, in either dialect.
fn compilesOrRefuses(g: *const ts.Grammar, case: *shakedown.Case) !void {
    const pieces = [_][]const u8{
        "(",       ")",                 "[",       "]",        "@a",          "@b",         " ",
        "(pair",   "(string",           "(object", "(number",  "key:",        "value:",     "_",
        "#eq?",    "#not-eq?",          "#match?", "#any-of?", "#lua-match?", "#contains?", "#set!",
        "#strip!", "#select-adjacent!", "#is?",    "\"x\"",    "\"^%a+\"",    "\"(?i)a\"",  "\"[\"",
        "*",       "+",                 "?",       "!",        ".",           "\"",         "#any-eq?",
    };
    var text: std.ArrayList(u8) = .empty;
    for (0..shakedown.gen.intRange(case.source, usize, 0, 24)) |_| {
        try text.appendSlice(case.gpa, pieces[shakedown.gen.intRange(case.source, usize, 0, pieces.len - 1)]);
    }
    const dialect: ts.Dialect = if (shakedown.gen.boolean(case.source)) .neovim else .tree_sitter;
    case.note("{t}: {s}", .{ dialect, text.items });
    var query = ts.Query.init(gpa, g.language(), text.items, .{ .dialect = dialect }) catch return;
    query.deinit();
}

test "fuzz: a query source compiles or is refused" {
    const g = try need("json");
    try shakedown.check(gpa, g, compilesOrRefuses, .{ .cases = 3000, .seed = 0x9e7 });
}

/// `eq?` between a pair's key and value holds exactly for the pairs whose
/// texts are equal, read whole from a slice, from a reader in any pieces,
/// and from UTF-16.
fn eqMatchesText(g: *const ts.Grammar, case: *shakedown.Case) !void {
    const s = case.source;
    var text: std.ArrayList(u8) = .empty;
    var equal: usize = 0;
    try text.append(case.gpa, '{');
    const pairs = shakedown.gen.intRange(s, usize, 0, 6);
    for (0..pairs) |i| {
        // Strings around the 16 KiB predicate scratch, alike for a long run.
        const len = if (shakedown.gen.boolean(s)) shakedown.gen.intRange(s, usize, 0, 8) else shakedown.gen.intRange(s, usize, 16 * 1024 - 8, 16 * 1024 + 8);
        const key = try case.gpa.alloc(u8, len);
        @memset(key, 'k');
        const value = try case.gpa.dupe(u8, key);
        if (len != 0 and shakedown.gen.boolean(s)) value[shakedown.gen.intRange(s, usize, 0, len - 1)] = 'v';
        if (std.mem.eql(u8, key, value)) equal += 1;
        if (i != 0) try text.append(case.gpa, ',');
        try text.print(case.gpa, "\"{s}\":\"{s}\"", .{ key, value });
    }
    try text.append(case.gpa, '}');
    case.note("{d} pairs, {d} equal", .{ pairs, equal });

    const source = "((pair key: (string) @k value: (string) @v) (#eq? @k @v))";
    var units = try case.gpa.alloc(u16, text.items.len);
    const n = try std.unicode.utf8ToUtf16Le(units, text.items);
    // utf8ToUtf16Le stores each unit little-endian: these bytes are UTF-16LE.
    const utf16 = std.mem.sliceAsBytes(units[0..n]);
    for ([_]struct { []const u8, ts.Encoding, bool }{
        .{ text.items, .utf8, false },
        .{ text.items, .utf8, true },
        .{ utf16, .utf16le, true },
    }) |form| {
        var parser: ts.Parser = .init();
        defer parser.deinit();
        try parser.setLanguage(g.language());
        const pieces: Drawn = try .init(case, form[0], form[1]);
        const input: ts.Input = if (form[2]) .{ .reader = &pieces.reader } else .{ .slice = form[0] };
        var tree = try parser.parse(case.io(), input, null, .{});
        defer tree.deinit();
        var query = try ts.Query.init(gpa, g.language(), source, .{ .dialect = .tree_sitter });
        defer query.deinit();
        var cursor = try ts.QueryCursor.init(gpa);
        defer cursor.deinit();
        var count: usize = 0;
        var matches = cursor.matches(case.io(), &query, tree.rootNode(), input, .{});
        while (try matches.next()) |_| count += 1;
        try std.testing.expectEqual(equal, count);
    }
}

test "fuzz: eq? holds exactly for equal texts, from a slice, a reader in pieces and UTF-16" {
    const g = try need("json");
    try shakedown.check(gpa, g, eqMatchesText, .{ .cases = 200, .seed = 0xe9 });
}

// ---------------------------------------------------------------------------
// Layers
// ---------------------------------------------------------------------------

/// Injections resolved to the selected grammars by name, some renamed.
const Names = struct {
    resolver: ts.InjectionResolver = .{ .resolve = resolve },
    renames: []const [2][]const u8 = &.{},

    fn resolve(r: *const ts.InjectionResolver, name: []const u8) ?*const ts.Grammar {
        const self: *const Names = @fieldParentPtr("resolver", r);
        for (self.renames) |pair| if (std.mem.eql(u8, pair[0], name)) return grammar(pair[1]);
        return grammar(name);
    }
};

/// The text of each layer of `name`, its ranges joined, in layer order.
fn layerTexts(layers: *const ts.Layers, text: []const u8, name: []const u8, buffer: [][]const u8) [][]const u8 {
    var n: usize = 0;
    for (layers.all()) |l| {
        if (!std.mem.eql(u8, l.grammar.name, name)) continue;
        buffer[n] = text[l.ranges[0].start_byte..l.ranges[l.ranges.len - 1].end_byte];
        n += 1;
    }
    return buffer[0..n];
}

fn countLayers(layers: *const ts.Layers, name: []const u8) usize {
    var n: usize = 0;
    for (layers.all()) |l| n += @intFromBool(std.mem.eql(u8, l.grammar.name, name));
    return n;
}

fn layerOf(layers: *const ts.Layers, name: []const u8) ?ts.Layer {
    for (layers.all()) |l| if (std.mem.eql(u8, l.grammar.name, name)) return l;
    return null;
}

test "layers: HTML scripts by type (gsub!) and as modules, styles in elements and attributes" {
    const html = try need("html");
    _ = try need("javascript");
    _ = try need("css");
    const names: Names = .{};
    const text = "<html><script type=\"text/javascript\">let a = 1;</script><script type=\"module\">b();</script><style>p { color: red; }</style><p style=\"color: blue\">x</p></html>";
    var layers: ts.Layers = try .init(gpa, html, &names.resolver, .{});
    defer layers.deinit();
    const changed = try layers.update(io, .{ .slice = text }, .everything, .{});
    try std.testing.expectEqualSlices(ts.Range, &.{.everything}, changed);
    var buffer: [8][]const u8 = undefined;
    const scripts = layerTexts(&layers, text, "javascript", &buffer);
    try std.testing.expectEqual(2, scripts.len);
    try std.testing.expectEqualStrings("let a = 1;", scripts[0]);
    try std.testing.expectEqualStrings("b();", scripts[1]);
    const styles = layerTexts(&layers, text, "css", &buffer);
    try std.testing.expectEqual(2, styles.len);
    try std.testing.expectEqualStrings("p { color: red; }", styles[0]);
    try std.testing.expectEqualStrings("color: blue", styles[1]);
    for (layers.all()[1..]) |l| {
        try std.testing.expectEqual(@as(?u32, layers.all()[0].id), l.parent);
        // Positions are absolute: the tree starts where its range does.
        try std.testing.expectEqual(l.ranges[0].start_byte, l.tree.rootNode().startByte());
    }
}

test "layers: Markdown front matter by rows (offset!), inline text, fences nested twice, combined HTML blocks" {
    const md = try need("markdown");
    _ = try need("markdown_inline");
    _ = try need("zig");
    _ = try need("html");
    _ = try need("json");
    // No YAML grammar in the test set: its layer is parsed as JSON.
    const names: Names = .{ .renames = &.{.{ "yaml", "json" }} };
    const text = "---\ntitle: x\n---\n\n# T *e*\n\n```zig\nconst s = 1;\n```\n\n````markdown\n```zig\nconst y = 2;\n```\n````\n\n<div>\nhi\n</div>\n\npara\n\n<div>\nyo\n</div>\n";
    var layers: ts.Layers = try .init(gpa, md, &names.resolver, .{});
    defer layers.deinit();
    _ = try layers.update(io, .{ .slice = text }, .everything, .{});
    var buffer: [8][]const u8 = undefined;
    // `(#offset! @injection.content 1 0 -1 0)`: the lines between the fences.
    try std.testing.expectEqualStrings("title: x\n", layerTexts(&layers, text, "json", &buffer)[0]);
    const inline_texts = layerTexts(&layers, text, "markdown_inline", &buffer);
    try std.testing.expectEqual(2, inline_texts.len);
    try std.testing.expectEqualStrings("T *e*", inline_texts[0]);
    try std.testing.expectEqualStrings("para", inline_texts[1]);
    const zig_texts = layerTexts(&layers, text, "zig", &buffer);
    try std.testing.expectEqual(2, zig_texts.len);
    try std.testing.expectEqualStrings("const s = 1;\n", zig_texts[0]);
    try std.testing.expectEqualStrings("const y = 2;\n", zig_texts[1]);
    var depths: [2]u8 = undefined;
    var n: usize = 0;
    for (layers.all()) |l| if (std.mem.eql(u8, l.grammar.name, "zig")) {
        try std.testing.expect(!l.tree.rootNode().hasError());
        depths[n] = l.depth;
        n += 1;
    };
    try std.testing.expectEqual([2]u8{ 1, 2 }, depths);
    // `injection.combined`: both blocks, one tree.
    const html_layer = layerOf(&layers, "html").?;
    try std.testing.expectEqual(2, html_layer.ranges.len);
    try std.testing.expectEqual(1, countLayers(&layers, "html"));
    try std.testing.expect(!html_layer.tree.rootNode().hasError());
}

/// `text[0..at] ++ insert ++ text[at + remove..]`, and the edit saying so
/// (one line: columns are bytes).
fn splice(buffer: []u8, text: []const u8, at: u32, remove: u32, insert: []const u8) struct { []const u8, ts.InputEdit } {
    @memcpy(buffer[0..at], text[0..at]);
    @memcpy(buffer[at..][0..insert.len], insert);
    const rest = text[at + remove ..];
    @memcpy(buffer[at + insert.len ..][0..rest.len], rest);
    const new_end: u32 = at + @as(u32, @intCast(insert.len));
    return .{ buffer[0 .. at + insert.len + rest.len], .{
        .start_byte = at,
        .old_end_byte = at + remove,
        .new_end_byte = new_end,
        .start_point = .{ .column = at },
        .old_end_point = .{ .column = at + remove },
        .new_end_point = .{ .column = new_end },
    } };
}

test "layers: an edit parses again only the layers it touches, and an injection that goes is removed" {
    const html = try need("html");
    _ = try need("javascript");
    _ = try need("css");
    const names: Names = .{};
    const text = "<script>let a = 1;</script><style>p { color: red; }</style>";
    var layers: ts.Layers = try .init(gpa, html, &names.resolver, .{});
    defer layers.deinit();
    _ = try layers.update(io, .{ .slice = text }, .everything, .{});
    const css_tree = layerOf(&layers, "css").?.tree.raw;

    var buffer: [128]u8 = undefined;
    const at: u32 = @intCast(std.mem.find(u8, text, "1;").?);
    const edited, const e = splice(&buffer, text, at, 1, "22");
    try layers.edit(e);
    const changed = try layers.update(io, .{ .slice = edited }, .everything, .{});
    var texts: [4][]const u8 = undefined;
    try std.testing.expectEqualStrings("let a = 22;", layerTexts(&layers, edited, "javascript", &texts)[0]);
    var covered = false;
    for (changed) |r| covered = covered or (r.start_byte <= at and at + 2 <= r.end_byte);
    try std.testing.expect(covered);
    // The style's layer was left alone.
    try std.testing.expectEqual(css_tree, layerOf(&layers, "css").?.tree.raw);

    // The script goes, and its layer with it.
    var buffer2: [128]u8 = undefined;
    const end: u32 = @intCast(std.mem.find(u8, edited, "<style>").?);
    const removed, const e2 = splice(&buffer2, edited, 0, end, "");
    try layers.edit(e2);
    _ = try layers.update(io, .{ .slice = removed }, .everything, .{});
    try std.testing.expectEqual(0, countLayers(&layers, "javascript"));
    try std.testing.expectEqualStrings("p { color: red; }", layerTexts(&layers, removed, "css", &texts)[0]);
}

test "layers: injections resolve over the wanted range, combined ones over the whole document" {
    const md = try need("markdown");
    _ = try need("markdown_inline");
    _ = try need("zig");
    _ = try need("html");
    const names: Names = .{};
    var text_buffer: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&text_buffer);
    try w.writeAll("<div>\nx\n</div>\n\n```zig\nconst a = 1;\n```\n\n");
    for (0..40) |_| try w.writeAll("filler paragraph\n\n");
    try w.writeAll("```zig\nconst b = 2;\n```\n\n<div>\ny\n</div>\n");
    const text = w.buffered();
    var layers: ts.Layers = try .init(gpa, md, &names.resolver, .{});
    defer layers.deinit();
    _ = try layers.update(io, .{ .slice = text }, .{ .end_byte = 45, .end_point = .{ .row = 7 } }, .{});
    try std.testing.expectEqual(1, countLayers(&layers, "zig"));
    // The first filler paragraph starts at byte 41.
    try std.testing.expectEqual(1, countLayers(&layers, "markdown_inline"));
    try std.testing.expectEqual(2, layerOf(&layers, "html").?.ranges.len);
    _ = try layers.update(io, .{ .slice = text }, .everything, .{});
    try std.testing.expectEqual(2, countLayers(&layers, "zig"));
    try std.testing.expectEqual(40, countLayers(&layers, "markdown_inline"));
}

test "layers: a snapshot keeps its trees after the layers change" {
    const html = try need("html");
    _ = try need("javascript");
    const names: Names = .{};
    const text = "<script>let a = 1;</script>";
    var layers: ts.Layers = try .init(gpa, html, &names.resolver, .{});
    defer layers.deinit();
    _ = try layers.update(io, .{ .slice = text }, .everything, .{});
    var snapshot = try layers.snapshot(gpa);
    defer snapshot.deinit();
    var buffer: [64]u8 = undefined;
    const removed, const e = splice(&buffer, text, 0, @intCast(text.len), "<p></p>");
    try layers.edit(e);
    _ = try layers.update(io, .{ .slice = removed }, .everything, .{});
    try std.testing.expectEqual(1, layers.all().len);
    try std.testing.expectEqual(2, snapshot.layers.len);
    try std.testing.expectEqualStrings("program", snapshot.layers[1].tree.rootNode().kind());
}

test "layers: UTF-16 text names its injections the same" {
    const html = try need("html");
    _ = try need("javascript");
    _ = try need("css");
    const names: Names = .{};
    const utf8 = "<script type=\"text/javascript\">let a = 1;</script><style>p { color: red; }</style>";
    var units: [128]u16 = undefined;
    const n = try std.unicode.utf8ToUtf16Le(&units, utf8);
    // utf8ToUtf16Le stores each unit little-endian: these bytes are UTF-16LE.
    const text = std.mem.sliceAsBytes(units[0..n]);
    const Whole = struct {
        reader: ts.Input.Reader = .{ .read = read, .encoding = .utf16le },
        text: []const u8,
        fn read(reader: *const ts.Input.Reader, byte: u32, _: ts.Point) []const u8 {
            const self: *const @This() = @fieldParentPtr("reader", reader);
            return if (byte < self.text.len) self.text[byte..] else "";
        }
    };
    const whole: Whole = .{ .text = text };
    var layers: ts.Layers = try .init(gpa, html, &names.resolver, .{});
    defer layers.deinit();
    _ = try layers.update(io, .{ .reader = &whole.reader }, .everything, .{});
    const script = layerOf(&layers, "javascript").?;
    // Ranges are in bytes of the UTF-16 text.
    const start: u32 = @intCast(2 * std.mem.find(u8, utf8, "let").?);
    try std.testing.expectEqual(start, script.ranges[0].start_byte);
    try std.testing.expect(!script.tree.rootNode().hasError());
    try std.testing.expectEqual(1, countLayers(&layers, "css"));
}

test "layers: an update past its deadline pauses, and the next one finishes the layers" {
    const html = try need("html");
    _ = try need("javascript");
    const names: Names = .{};
    // Big enough that the runtime checks its progress callback.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "<script>\n");
    for (0..2000) |i| try text.print(gpa, "function f{d}(a) {{ return a * {d}; }}\n", .{ i, i });
    try text.appendSlice(gpa, "</script>\n");
    var layers: ts.Layers = try .init(gpa, html, &names.resolver, .{});
    defer layers.deinit();
    const past = std.Io.Clock.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Paused, layers.update(io, .{ .slice = text.items }, .everything, .{ .deadline = past }));
    _ = try layers.update(io, .{ .slice = text.items }, .everything, .{});
    const script = layerOf(&layers, "javascript").?;
    try std.testing.expect(!script.tree.rootNode().hasError());
    try std.testing.expectEqual(1, countLayers(&layers, "javascript"));
}
