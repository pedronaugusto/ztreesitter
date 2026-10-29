//! Definitions and references from a tags query.
//!
//! The convention is tree-sitter's (`crates/tags/src/tags.rs` in the
//! tree-sitter repository, used by GitHub's code navigation): a pattern
//! captures the tag's node as `@definition.<kind>` or `@reference.<kind>`
//! and its name as `@name`; `@doc` captures documentation, which
//! `(#select-adjacent! @doc @node)` narrows to the comments directly above
//! `@node` and `(#strip! @doc "regex")` cleans. With a locals query,
//! `@local.scope` and `@local.definition` (or Neovim's
//! `@local.definition.<kind>`) mark where names are local, and a pattern with
//! `(#is-not? local)` drops a tag whose name is a local definition in scope;
//! a scope whose pattern sets `local.scope-inherits` to `false` hides its
//! parents' definitions.
//!
//! The tags query and the locals query may come in different dialects
//! (tags from a grammar's repository, locals from nvim-treesitter), so the
//! locals run as a pass of their own before the tags. As in `tags.rs`, a
//! definition counts only for names after it.

const std = @import("std");
const types = @import("types.zig");
const node_mod = @import("node.zig");
const language_mod = @import("language.zig");
const query_mod = @import("query.zig");
const regex = @import("regex.zig");

const Query = query_mod.Query;
const Node = node_mod.Node;
const Range = types.Range;

pub const Role = enum { definition, reference };

pub const Tag = struct {
    role: Role,
    /// The part after `definition.` or `reference.`: `function`, `class`,
    /// `call`. Borrowed from the query.
    kind: []const u8,
    /// The name's range.
    name: Range,
    /// The whole tagged node's range.
    node: Range,
    /// The documentation, from its first node to its last, when the pattern
    /// captures any.
    doc: ?Range,
    /// The documentation's nodes: `docs[start..][0..len]` of the list
    /// `collect` was given. `Tags.docText` joins them.
    docs: struct { start: u32 = 0, len: u32 = 0 } = .{},
    pattern: u16,
};

pub const InitOptions = struct {
    /// The grammar's locals query, for `(#is-not? local)`.
    locals: ?language_mod.QueryText = null,
};

pub const CollectError = query_mod.IterateError || error{OutOfMemory};

/// A compiled tags query, what each of its captures and patterns means, and
/// the locals query. Immutable, so one serves any number of threads, each
/// with its own `QueryCursor`.
pub const Tags = struct {
    query: Query,
    meaning: []Meaning,
    patterns: []Pattern,
    locals: ?Locals,

    const Meaning = union(enum) {
        none,
        name,
        doc,
        tag: struct { role: Role, kind: []const u8 },
    };

    /// What a tags pattern's directives and assertions ask.
    const Pattern = struct {
        /// `select-adjacent!`: keep the docs that end on the line above
        /// this capture's node, or above another kept doc.
        adjacent: ?u32 = null,
        /// `strip!`: removed from each doc node's text.
        strip: ?regex.Program = null,
        /// `(#is-not? local)`.
        non_local: bool = false,
    };

    const Locals = struct {
        query: Query,
        scope: ?u32,
        /// By capture index: a definition capture.
        definition: []bool,
        /// By pattern: its scopes show their parents' definitions.
        inherits: []bool,
    };

    pub fn init(gpa: std.mem.Allocator, lang: language_mod.Language, text: language_mod.QueryText, options: InitOptions) Query.Error!Tags {
        var query = try Query.init(gpa, lang, text.text, .{ .dialect = text.dialect });
        errdefer query.deinit();
        const meaning = try gpa.alloc(Meaning, query.captureCount());
        errdefer gpa.free(meaning);
        for (meaning, 0..) |*m, i| {
            const name = query.captureName(@intCast(i));
            m.* = if (std.mem.eql(u8, name, "name"))
                .name
            else if (std.mem.eql(u8, name, "doc"))
                .doc
            else if (std.mem.startsWith(u8, name, "definition."))
                .{ .tag = .{ .role = .definition, .kind = name["definition.".len..] } }
            else if (std.mem.startsWith(u8, name, "reference."))
                .{ .tag = .{ .role = .reference, .kind = name["reference.".len..] } }
            else
                .none;
        }

        const patterns = try gpa.alloc(Pattern, query.patternCount());
        @memset(patterns, .{});
        errdefer {
            for (patterns) |*p| if (p.strip) |*r| r.deinit(gpa);
            gpa.free(patterns);
        }
        for (patterns, 0..) |*p, i| {
            const index: u32 = @intCast(i);
            for (query.assertions(index, false)) |a| {
                if (std.mem.eql(u8, a.key, "local")) p.non_local = true;
            }
            for (query.directives(index)) |d| {
                if (std.mem.eql(u8, d.name, "select-adjacent!")) {
                    if (d.args.len >= 2 and d.args[1] == .capture) p.adjacent = d.args[1].capture;
                } else if (std.mem.eql(u8, d.name, "strip!")) {
                    if (d.args.len < 2 or d.args[1] != .string) return error.InvalidPredicate;
                    if (p.strip) |*old| old.deinit(gpa);
                    // tags.rs compiles it with the `regex` crate.
                    p.strip = regex.compile(gpa, d.args[1].string, .rust) catch |err| switch (err) {
                        error.OutOfMemory => |e| return e,
                        error.InvalidPattern => return error.InvalidPattern,
                    };
                }
            }
        }

        const locals: ?Locals = if (options.locals) |l| try initLocals(gpa, lang, l) else null;
        return .{ .query = query, .meaning = meaning, .patterns = patterns, .locals = locals };
    }

    fn initLocals(gpa: std.mem.Allocator, lang: language_mod.Language, text: language_mod.QueryText) Query.Error!Locals {
        var query = try Query.init(gpa, lang, text.text, .{ .dialect = text.dialect });
        errdefer query.deinit();
        const definition = try gpa.alloc(bool, query.captureCount());
        errdefer gpa.free(definition);
        for (definition, 0..) |*d, i| {
            const name = query.captureName(@intCast(i));
            d.* = std.mem.eql(u8, name, "local.definition") or std.mem.startsWith(u8, name, "local.definition.");
        }
        const inherits = try gpa.alloc(bool, query.patternCount());
        for (inherits, 0..) |*h, i| {
            const p = query.property(@intCast(i), "local.scope-inherits", null);
            h.* = if (p) |set| !std.mem.eql(u8, set.value orelse "", "false") else true;
        }
        return .{ .query = query, .scope = query.captureIndex("local.scope"), .definition = definition, .inherits = inherits };
    }

    pub fn deinit(t: *Tags) void {
        const gpa = t.query.gpa;
        if (t.locals) |*l| {
            gpa.free(l.definition);
            gpa.free(l.inherits);
            l.query.deinit();
        }
        for (t.patterns) |*p| if (p.strip) |*r| r.deinit(gpa);
        gpa.free(t.patterns);
        gpa.free(t.meaning);
        t.query.deinit();
        t.* = undefined;
    }

    /// Append the tags under `root` to `out`, in match order, and their
    /// documentation's nodes to `docs`. A tag needs a `@name` without
    /// syntax errors, as in `tags.rs`.
    pub fn collect(
        t: *const Tags,
        gpa: std.mem.Allocator,
        io: std.Io,
        cursor: *query_mod.Cursor,
        root: Node,
        input: types.Input,
        out: *std.ArrayList(Tag),
        docs: *std.ArrayList(Range),
    ) CollectError!void {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var scopes: Scopes = .{};
        if (t.locals) |*l| try scopes.collect(arena, io, l, cursor, root, input);

        var doc_nodes: std.ArrayList(Node) = .empty;
        var matches = cursor.matches(io, &t.query, root, input, .{});
        while (try matches.next()) |m| {
            const pattern = &t.patterns[m.pattern];
            var name: ?Node = null;
            var tagged: ?struct { role: Role, kind: []const u8, range: Range } = null;
            var adjacent: ?Node = null;
            doc_nodes.clearRetainingCapacity();
            for (m.captures) |cap| {
                if (pattern.adjacent == cap.index) adjacent = cap.node;
                switch (t.meaning[cap.index]) {
                    .none => {},
                    .name => name = cap.node,
                    .doc => try doc_nodes.append(arena, cap.node),
                    .tag => |info| tagged = .{ .role = info.role, .kind = info.kind, .range = cap.node.range() },
                }
            }
            const tag = tagged orelse continue;
            const name_node = name orelse continue;
            if (name_node.hasError()) continue;
            if (pattern.non_local and scopes.isLocal(input, name_node.range())) continue;

            // `select-adjacent!`: the docs ending on the line above the node,
            // or above a doc already kept.
            var first: usize = 0;
            if (adjacent) |node| if (doc_nodes.items.len != 0) {
                first = doc_nodes.items.len;
                var row = node.startPoint().row;
                while (first > 0) {
                    const doc = doc_nodes.items[first - 1];
                    if (doc.endPoint().row + 1 < row) break;
                    first -= 1;
                    row = doc.startPoint().row;
                }
            };
            const kept = doc_nodes.items[first..];
            const start: u32 = @intCast(docs.items.len);
            for (kept) |d| try docs.append(gpa, d.range());
            try out.append(gpa, .{
                .role = tag.role,
                .kind = tag.kind,
                .name = name_node.range(),
                .node = tag.range,
                .doc = if (kept.len == 0) null else .{
                    .start_point = kept[0].startPoint(),
                    .start_byte = kept[0].startByte(),
                    .end_point = kept[kept.len - 1].endPoint(),
                    .end_byte = kept[kept.len - 1].endByte(),
                },
                .docs = .{ .start = start, .len = @intCast(kept.len) },
                .pattern = m.pattern,
            });
        }
    }

    /// A tag's documentation as `tags.rs` gives it: each node's text with the
    /// pattern's `strip!` removed, joined by newlines. `docs` is the list
    /// `collect` filled; UTF-16 input is written as UTF-8.
    pub fn docText(t: *const Tags, gpa: std.mem.Allocator, tag: Tag, docs: []const Range, input: types.Input, w: *std.Io.Writer) (std.Io.Writer.Error || error{OutOfMemory})!void {
        const strip = if (t.patterns[tag.pattern].strip) |*p| p else null;
        const finder: ?*regex.Finder = if (strip != null) try gpa.create(regex.Finder) else null;
        defer if (finder) |f| gpa.destroy(f);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        for (docs[tag.docs.start..][0..tag.docs.len], 0..) |r, i| {
            text.clearRetainingCapacity();
            try readUtf8(gpa, input, r, &text);
            if (i != 0) try w.writeByte('\n');
            if (strip) |p| try finder.?.replaceAll(p, text.items, "", w) else try w.writeAll(text.items);
        }
    }
};

/// `r`'s text from `input`, as UTF-8.
fn readUtf8(gpa: std.mem.Allocator, input: types.Input, r: Range, out: *std.ArrayList(u8)) error{OutOfMemory}!void {
    const raw = try gpa.alloc(u8, r.end_byte - r.start_byte);
    defer gpa.free(raw);
    const bytes = input.copy(r.start_byte, r.end_byte, raw);
    const endian: std.builtin.Endian = switch (input.encoding()) {
        .utf8 => return out.appendSlice(gpa, bytes),
        .utf16le => .little,
        .utf16be => .big,
    };
    var k: usize = 0;
    while (k + 1 < bytes.len) : (k += 2) {
        var cp: u21 = std.mem.readInt(u16, bytes[k..][0..2], endian);
        if (std.unicode.utf16IsHighSurrogate(@intCast(cp)) and k + 3 < bytes.len) {
            const low = std.mem.readInt(u16, bytes[k + 2 ..][0..2], endian);
            if (std.unicode.utf16IsLowSurrogate(low)) {
                cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
                k += 2;
            }
        }
        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &utf8) catch std.unicode.utf8Encode(std.unicode.replacement_character, &utf8) catch unreachable; // unreachable: U+FFFD encodes
        try out.appendSlice(gpa, utf8[0..n]);
    }
}

/// The locals query's scopes and definitions, in the order it found them.
const Scopes = struct {
    list: std.ArrayList(Scope) = .empty,

    const Scope = struct {
        range: Range,
        inherits: bool,
        definitions: std.ArrayList(Definition) = .empty,
    };

    const Definition = struct { start: u32, text: []const u8 };

    /// Longer names are never local.
    const max_name = 1024;

    fn collect(s: *Scopes, arena: std.mem.Allocator, io: std.Io, l: *const Tags.Locals, cursor: *query_mod.Cursor, root: Node, input: types.Input) CollectError!void {
        // The whole text is a scope that inherits nothing, as in tags.rs.
        try s.list.append(arena, .{ .range = .everything, .inherits = false });
        var matches = cursor.matches(io, &l.query, root, input, .{});
        while (try matches.next()) |m| for (m.captures) |cap| {
            const r = cap.node.range();
            if (l.scope == cap.index) {
                try s.list.append(arena, .{ .range = r, .inherits = l.inherits[m.pattern] });
            } else if (l.definition[cap.index]) {
                if (r.end_byte - r.start_byte > max_name) continue;
                const scope = s.innermost(r, s.list.items.len) orelse continue;
                const text = try arena.alloc(u8, r.end_byte - r.start_byte);
                try scope.definitions.append(arena, .{ .start = r.start_byte, .text = input.copy(r.start_byte, r.end_byte, text) });
            }
        };
    }

    /// The last scope found among the first `n` that contains `r`.
    fn innermost(s: *Scopes, r: Range, n: usize) ?*Scope {
        var i = n;
        while (i > 0) {
            i -= 1;
            const scope = &s.list.items[i];
            if (scope.range.start_byte <= r.start_byte and r.end_byte <= scope.range.end_byte) return scope;
        }
        return null;
    }

    /// `name` is defined at or before it in a scope around it that it can
    /// see. tags.rs runs locals patterns first, so a definition at the
    /// name itself counts.
    fn isLocal(s: *const Scopes, input: types.Input, name: Range) bool {
        if (s.list.items.len == 0) return false;
        if (name.end_byte - name.start_byte > max_name) return false;
        var buffer: [max_name]u8 = undefined;
        const text = input.copy(name.start_byte, name.end_byte, &buffer);
        var i = s.list.items.len;
        while (i > 0) {
            i -= 1;
            const scope = s.list.items[i];
            // Scopes found after the name were not there yet in tags.rs.
            if (scope.range.start_byte > name.start_byte) continue;
            if (!(scope.range.start_byte <= name.start_byte and name.end_byte <= scope.range.end_byte)) continue;
            for (scope.definitions.items) |d| {
                if (d.start <= name.start_byte and std.mem.eql(u8, d.text, text)) return true;
            }
            if (!scope.inherits) return false;
        }
        return false;
    }
};
