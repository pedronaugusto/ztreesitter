//! Tests that need grammars, run against the module a consumer gets. Each
//! grammar test skips when its grammar was not selected (`-Dgrammars`).

const std = @import("std");
const ts = @import("ztreesitter");
const grammars = @import("grammars");
const catalogue = @import("ztreesitter.catalogue");
const samples = @import("samples.zig");

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

test "tags: references in Rust" {
    const g = try need("rust");
    const text = g.queries.tags orelse return error.SkipZigTest;
    const source = "fn area(w: i32, h: i32) -> i32 { w * h }\nfn main() { let _ = area(2, 3); }\n";
    var tags = try ts.Tags.init(gpa, g.language(), text);
    defer tags.deinit();
    var parser: ts.Parser = .init();
    defer parser.deinit();
    var tree = try parse(&parser, g, source);
    defer tree.deinit();
    var cursor = try ts.QueryCursor.init(gpa);
    defer cursor.deinit();
    var out: std.ArrayList(ts.Tag) = .empty;
    defer out.deinit(gpa);
    try tags.collect(gpa, io, &cursor, tree.rootNode(), .{ .slice = source }, &out);
    var calls: usize = 0;
    for (out.items) |t| {
        if (t.role != .reference) continue;
        try std.testing.expectEqualStrings("call", t.kind);
        try std.testing.expectEqualStrings("area", source[t.name.start_byte..t.name.end_byte]);
        calls += 1;
    }
    try std.testing.expectEqual(1, calls);
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
        var tags = try ts.Tags.init(gpa, g.language(), text);
        defer tags.deinit();
        var parser: ts.Parser = .init();
        defer parser.deinit();
        var tree = try parse(&parser, g, case[1]);
        defer tree.deinit();
        var cursor = try ts.QueryCursor.init(gpa);
        defer cursor.deinit();
        var out: std.ArrayList(ts.Tag) = .empty;
        defer out.deinit(gpa);
        try tags.collect(gpa, io, &cursor, tree.rootNode(), .{ .slice = case[1] }, &out);
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
