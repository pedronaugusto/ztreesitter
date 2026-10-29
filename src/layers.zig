//! A document's trees: the root and one per injection, with Neovim's
//! injection semantics (`runtime/lua/vim/treesitter/languagetree.lua`).
//!
//! An injection query's match names a language by `(#set!
//! injection.language "name")`, by the text of an `@injection.language`
//! capture (after any `gsub!` on it), or by `injection.self` (the layer's
//! own language) or `injection.parent` (its parent's). Its
//! `@injection.content` nodes, moved by any `offset!` on them, are the
//! ranges the injected language is parsed over; their named children are
//! left out unless the pattern sets `injection.include-children`. Each match
//! is one layer, except under `injection.combined`, where every match of a
//! pattern for one language is one layer over all their ranges.

const std = @import("std");
const types = @import("types.zig");
const tree_mod = @import("tree.zig");
const parser_mod = @import("parser.zig");
const language_mod = @import("language.zig");
const query_mod = @import("query.zig");
const node_mod = @import("node.zig");
const lua = @import("lua_pattern.zig");

const Range = types.Range;
const Point = types.Point;
const Input = types.Input;
const Grammar = language_mod.Grammar;
const Tree = tree_mod.Tree;
const Parser = parser_mod.Parser;
const Query = query_mod.Query;
const Node = node_mod.Node;

/// Finds the grammar an injection names. Embedded in the caller's state,
/// which `resolve` finds from the pointer it is given with `@fieldParentPtr`.
pub const Resolver = struct {
    /// The grammar for `name` as the query gives it, or null to leave the
    /// injection out. Aliases (`py`, `Python`) are the caller's to resolve.
    resolve: *const fn (resolver: *const Resolver, name: []const u8) ?*const Grammar,
};

/// One tree of the document.
pub const Layer = struct {
    /// Stable while the layer lives.
    id: u32,
    /// The id of the layer it was injected into; null for the root.
    parent: ?u32,
    grammar: *const Grammar,
    tree: Tree,
    /// What the tree was parsed over, ascending; empty for the root, which
    /// is parsed whole.
    ranges: []const Range,
    /// 0 for the root.
    depth: u8,
};

pub const Options = struct {
    /// Layers this deep resolve no injections of their own.
    max_depth: u8 = 8,
};

pub const UpdateOptions = struct {
    /// Stop with `error.Paused` once this time has passed. A later `update`
    /// parses that layer again, from its old tree.
    deadline: ?std.Io.Clock.Timestamp = null,
};

pub const UpdateError = error{ OutOfMemory, Canceled, Paused } || Parser.LanguageError || Query.Error;

/// A document's layers. One thread at a time; `snapshot` hands immutable
/// copies to others. The caller owns the text and passes an `Input` to every
/// `update`: the text the edits so far describe.
pub const Layers = struct {
    gpa: std.mem.Allocator,
    root: *const Grammar,
    resolver: *const Resolver,
    options: Options,
    /// Parents before their children.
    list: std.MultiArrayList(Entry) = .empty,
    next_id: u32 = 0,
    /// One parser per language, not per layer: Markdown makes a layer per
    /// inline node.
    parsers: std.array_hash_map.Auto(*const Grammar, Parser) = .empty,
    injections: std.array_hash_map.Auto(*const Grammar, ?Injections) = .empty,
    cursor: query_mod.Cursor,
    /// Where the layers changed since `update` last returned.
    changed: std.ArrayList(Range) = .empty,
    /// `changed` was returned: the next `update` starts it afresh.
    returned: bool = false,
    /// Edited since `update` last read the layers' moved ranges back.
    edited: bool = false,

    const Entry = struct {
        layer: Layer,
        /// Edited since parsed.
        dirty: bool = false,
        /// Where its injections were resolved since it was last parsed or
        /// edited.
        resolved: ?Range = null,
        /// The pattern whose matches it combines.
        combined: ?u16 = null,
    };

    /// A grammar's injection query and what layering reads of it.
    const Injections = struct {
        query: Query,
        content: u32,
        language: ?u32,
        /// Some pattern sets `injection.combined`: matches are resolved over
        /// the whole document, since a partial set would parse another tree.
        combined: bool,
    };

    /// No tree yet: the first `update` parses the root.
    pub fn init(gpa: std.mem.Allocator, root: *const Grammar, resolver: *const Resolver, options: Options) error{OutOfMemory}!Layers {
        return .{ .gpa = gpa, .root = root, .resolver = resolver, .options = options, .cursor = try .init(gpa) };
    }

    pub fn deinit(l: *Layers) void {
        for (l.list.items(.layer)) |*layer| {
            layer.tree.deinit();
            l.gpa.free(layer.ranges);
        }
        l.list.deinit(l.gpa);
        for (l.parsers.values()) |*p| p.deinit();
        l.parsers.deinit(l.gpa);
        for (l.injections.values()) |*maybe| if (maybe.*) |*inj| inj.query.deinit();
        l.injections.deinit(l.gpa);
        l.cursor.deinit();
        l.changed.deinit(l.gpa);
        l.* = undefined;
    }

    /// The layers, root first, parents before children. Valid until the
    /// next `edit` or `update`; after an `edit`, ranges are where they were
    /// until the next `update`.
    pub fn all(l: *const Layers) []const Layer {
        return l.list.items(.layer);
    }

    /// Record an edit to the text on every layer. The next `update` parses
    /// the layers it touches again, from their edited trees.
    pub fn edit(l: *Layers, e: types.InputEdit) error{OutOfMemory}!void {
        l.fresh();
        try l.changed.ensureUnusedCapacity(l.gpa, 1);
        const layers = l.list.items(.layer);
        const dirty = l.list.items(.dirty);
        const resolved = l.list.items(.resolved);
        for (layers, dirty, resolved, 0..) |*layer, *d, *r, i| {
            if (i == 0 or touches(layer.ranges, e.start_byte, e.old_end_byte)) d.* = true;
            r.* = null;
            // Moves the tree's included ranges too; `update` reads them back.
            layer.tree.edit(e);
        }
        l.edited = true;
        l.changed.appendAssumeCapacity(.{
            .start_byte = e.start_byte,
            .end_byte = e.new_end_byte,
            .start_point = e.start_point,
            .end_point = e.new_end_point,
        });
    }

    /// Each injected layer's ranges as its edited tree has them.
    fn readMovedRanges(l: *Layers) error{OutOfMemory}!void {
        for (l.list.items(.layer)) |*layer| {
            if (layer.ranges.len == 0) continue;
            var moved = layer.tree.includedRanges();
            defer moved.deinit();
            if (std.mem.eql(u8, std.mem.sliceAsBytes(moved.items), std.mem.sliceAsBytes(layer.ranges))) continue;
            const ranges = try l.gpa.dupe(Range, moved.items);
            l.gpa.free(layer.ranges);
            layer.ranges = ranges;
        }
        l.edited = false;
    }

    /// Parse the root if it needs it, resolve injections over `wanted`
    /// (combined injections over the whole document), and parse the
    /// injected layers that intersect it. Returns where the layers changed
    /// since the last `update` returned, ascending and merged; valid until
    /// the next call. Layers outside `wanted` keep their trees, edited but
    /// not parsed again, until an `update` wants them.
    pub fn update(l: *Layers, io: std.Io, input: Input, wanted: Range, options: UpdateOptions) UpdateError![]const Range {
        l.fresh();
        if (l.edited) try l.readMovedRanges();
        if (l.list.len == 0) {
            try l.changed.ensureUnusedCapacity(l.gpa, 1);
            var tree = try l.parse(io, input, l.root, &.{}, null, options);
            errdefer tree.deinit();
            try l.list.append(l.gpa, .{ .layer = .{ .id = l.newId(), .parent = null, .grammar = l.root, .tree = tree, .ranges = &.{}, .depth = 0 } });
            l.changed.appendAssumeCapacity(.everything);
        }
        // Layers left unparsed, whose injections are stale with them.
        var skipped: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer skipped.deinit(l.gpa);
        var i: usize = 0;
        while (i < l.list.len) : (i += 1) {
            const entry = l.list.get(i);
            if (entry.layer.parent) |p| if (skipped.contains(p)) {
                try skipped.put(l.gpa, entry.layer.id, {});
                continue;
            };
            if (entry.dirty) {
                if (i != 0 and entry.combined == null and !intersects(entry.layer.ranges, wanted)) {
                    try skipped.put(l.gpa, entry.layer.id, {});
                    continue;
                }
                try l.reparse(io, input, i, options);
            }
            try l.resolve(io, input, i, wanted, options);
        }
        mergeRanges(&l.changed);
        l.returned = true;
        return l.changed.items;
    }

    /// Immutable copies of the layers, for another thread.
    pub fn snapshot(l: *const Layers, gpa: std.mem.Allocator) error{OutOfMemory}!Snapshot {
        const layers = try gpa.alloc(Layer, l.list.len);
        var done: usize = 0;
        errdefer {
            for (layers[0..done]) |*layer| {
                layer.tree.deinit();
                gpa.free(layer.ranges);
            }
            gpa.free(layers);
        }
        for (l.all(), layers) |from, *to| {
            to.* = from;
            to.ranges = try gpa.dupe(Range, from.ranges);
            to.tree = from.tree.copy();
            done += 1;
        }
        return .{ .gpa = gpa, .layers = layers };
    }

    /// The first change after `update` returned starts a new record of
    /// where the layers changed.
    fn fresh(l: *Layers) void {
        if (!l.returned) return;
        l.changed.clearRetainingCapacity();
        l.returned = false;
    }

    fn newId(l: *Layers) u32 {
        defer l.next_id += 1;
        return l.next_id;
    }

    /// The parser for a grammar, set to it.
    fn parserFor(l: *Layers, grammar: *const Grammar) UpdateError!*Parser {
        const slot = try l.parsers.getOrPut(l.gpa, grammar);
        if (!slot.found_existing) {
            slot.value_ptr.* = .init();
            slot.value_ptr.setLanguage(grammar.language()) catch |err| {
                slot.value_ptr.deinit();
                _ = l.parsers.pop();
                return err;
            };
        }
        return slot.value_ptr;
    }

    fn parse(l: *Layers, io: std.Io, input: Input, grammar: *const Grammar, ranges: []const Range, old: ?*const Tree, options: UpdateOptions) UpdateError!Tree {
        const p = try l.parserFor(grammar);
        // unreachable: layers' ranges are ascending and disjoint (`normalize`), and the runtime's own edits keep them so
        p.setIncludedRanges(ranges) catch unreachable;
        return p.parse(io, input, old, .{ .deadline = options.deadline }) catch |err| switch (err) {
            error.NoLanguage => unreachable, // unreachable: parserFor set it
            error.Canceled, error.Paused => |e| {
                p.reset();
                return e;
            },
        };
    }

    /// Parse layer `i` again from its edited tree.
    fn reparse(l: *Layers, io: std.Io, input: Input, i: usize, options: UpdateOptions) UpdateError!void {
        const layer = &l.list.items(.layer)[i];
        var tree = try l.parse(io, input, layer.grammar, layer.ranges, &layer.tree, options);
        errdefer tree.deinit();
        var differ = layer.tree.changedRanges(tree);
        defer differ.deinit();
        try l.changed.appendSlice(l.gpa, differ.items);
        layer.tree.deinit();
        layer.tree = tree;
        l.list.items(.dirty)[i] = false;
        l.list.items(.resolved)[i] = null;
    }

    fn injectionsOf(l: *Layers, grammar: *const Grammar) UpdateError!?*const Injections {
        const slot = try l.injections.getOrPut(l.gpa, grammar);
        if (!slot.found_existing) {
            slot.value_ptr.* = null;
            const text = grammar.queries.injections orelse return null;
            var query = Query.init(l.gpa, grammar.language(), text.text, .{ .dialect = text.dialect }) catch |err| {
                _ = l.injections.pop();
                return err;
            };
            const content = query.captureIndex("injection.content") orelse {
                query.deinit();
                return null;
            };
            var combined = false;
            for (0..query.patternCount()) |p| {
                if (query.property(@intCast(p), "injection.combined", null) != null) combined = true;
            }
            slot.value_ptr.* = .{ .query = query, .content = content, .language = query.captureIndex("injection.language"), .combined = combined };
        }
        return if (slot.value_ptr.*) |*inj| inj else null;
    }

    /// Specs alike in these are one: same language, same span, as many
    /// ranges (the ranges between come from the same nodes).
    const SpecKey = struct { grammar: *const Grammar, start: u32, end: u32, count: usize };

    /// One layer the injection query asks for.
    const Spec = struct {
        grammar: *const Grammar,
        combined: ?u16,
        ranges: std.ArrayList(Range) = .empty,
    };

    /// Resolve layer `i`'s injections over `wanted` and bring its children
    /// in line: kept (parsed again if their ranges moved), added or removed.
    fn resolve(l: *Layers, io: std.Io, input: Input, i: usize, wanted: Range, options: UpdateOptions) UpdateError!void {
        const parent = l.list.items(.layer)[i];
        if (parent.depth >= l.options.max_depth) return;
        const inj = try l.injectionsOf(parent.grammar) orelse return;
        // Combined matches are taken from the whole document, the others
        // from `wanted`.
        const region: Range = if (inj.combined) .everything else wanted;
        if (l.list.items(.resolved)[i]) |r| if (r.start_byte <= wanted.start_byte and wanted.end_byte <= r.end_byte) return;

        var arena_state: std.heap.ArenaAllocator = .init(l.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var specs: std.ArrayList(Spec) = .empty;

        const q = &inj.query;
        l.cursor.setByteRange(region.start_byte, region.end_byte);
        var matches = l.cursor.matches(io, q, parent.tree.rootNode(), input, .{ .deadline = options.deadline });
        while (true) {
            const m = (matches.next() catch |err| switch (err) {
                // That match's predicate ran past its step budget: left out.
                error.TooManySteps => continue,
                error.Canceled, error.Paused => |e| return e,
            }) orelse break;
            const combined = q.property(m.pattern, "injection.combined", null) != null;
            var ranges: std.ArrayList(Range) = .empty;
            var contents = m.nodes(inj.content);
            while (contents.next()) |node| try contentRanges(arena, &ranges, q, m.pattern, inj.content, node, input);
            if (ranges.items.len == 0) continue;
            if (!combined and !intersects(ranges.items, wanted)) continue;
            const grammar = l.languageOf(io, input, q, inj, m, i) orelse continue;
            if (combined) {
                for (specs.items) |*s| {
                    if (s.combined == m.pattern and s.grammar == grammar) {
                        try s.ranges.appendSlice(arena, ranges.items);
                        break;
                    }
                } else try specs.append(arena, .{ .grammar = grammar, .combined = m.pattern, .ranges = ranges });
            } else try specs.append(arena, .{ .grammar = grammar, .combined = null, .ranges = ranges });
        }

        // Two patterns may inject one language over the same ranges (a
        // script both typed and untyped): one layer.
        var seen: std.AutoHashMapUnmanaged(SpecKey, void) = .empty;
        var unique: std.ArrayList(Spec) = .empty;
        for (specs.items) |*s| {
            try normalize(arena, &s.ranges, parent.ranges);
            if (s.ranges.items.len == 0) continue;
            if (s.combined == null) {
                const key: SpecKey = .{ .grammar = s.grammar, .start = s.ranges.items[0].start_byte, .end = s.ranges.items[s.ranges.items.len - 1].end_byte, .count = s.ranges.items.len };
                const slot = try seen.getOrPut(arena, key);
                if (slot.found_existing) continue;
            }
            try unique.append(arena, s.*);
        }
        try l.reconcile(io, input, i, wanted, unique.items, options);
        l.list.items(.resolved)[i] = wanted;
    }

    /// The grammar a match injects, or null when there is none to parse.
    fn languageOf(l: *Layers, io: std.Io, input: Input, q: *const Query, inj: *const Injections, m: query_mod.Match, i: usize) ?*const Grammar {
        const parent = l.list.items(.layer)[i];
        if (q.property(m.pattern, "injection.self", null) != null) return parent.grammar;
        if (q.property(m.pattern, "injection.parent", null) != null) {
            const id = parent.parent orelse return null;
            for (l.list.items(.layer)[0..i]) |p| if (p.id == id) return p.grammar;
            return null;
        }
        var buffer: [max_name]u8 = undefined;
        var replaced: [max_name]u8 = undefined;
        const name = if (q.property(m.pattern, "injection.language", null)) |p|
            p.value orelse return null
        else blk: {
            const capture = inj.language orelse return null;
            var nodes = m.nodes(capture);
            const node = nodes.next() orelse return null;
            var text = nodeText(input, node, &buffer) orelse return null;
            for (q.directives(m.pattern)) |d| {
                if (!std.mem.eql(u8, d.name, "gsub!") or d.args.len != 3) continue;
                if (d.args[0] != .capture or d.args[0].capture != capture) continue;
                if (d.args[1] != .string or d.args[2] != .string) continue;
                const pattern = lua.Pattern.init(d.args[1].string) catch return null;
                text = lua.gsub(io, text, pattern, d.args[2].string, &replaced) catch return null;
            }
            break :blk text;
        };
        return l.resolver.resolve(l.resolver, name);
    }

    /// Match `specs` to layer `i`'s children: a child of the same language
    /// (and combined pattern) whose ranges overlap the spec's is kept, and
    /// parsed again if its ranges moved; a spec with no such child is a new
    /// layer; a child no spec kept is removed with its descendants when the
    /// specs cover where it lies: anywhere for a combined layer, `wanted`
    /// for the others.
    fn reconcile(l: *Layers, io: std.Io, input: Input, i: usize, wanted: Range, specs: []Spec, options: UpdateOptions) UpdateError!void {
        const parent = l.list.items(.layer)[i];
        var kept: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer kept.deinit(l.gpa);
        for (specs) |s| {
            if (s.ranges.items.len == 0) continue;
            const found = for (l.list.items(.layer), l.list.items(.combined), 0..) |child, combined, j| {
                if (child.parent != parent.id or child.grammar != s.grammar or combined != s.combined) continue;
                if (kept.contains(child.id)) continue;
                if (s.combined != null or overlaps(child.ranges, s.ranges.items)) break j;
            } else null;
            if (found) |j| {
                const child = &l.list.items(.layer)[j];
                try kept.put(l.gpa, child.id, {});
                if (std.mem.eql(u8, std.mem.sliceAsBytes(child.ranges), std.mem.sliceAsBytes(s.ranges.items))) continue;
                try l.changed.appendSlice(l.gpa, child.ranges);
                const ranges = try l.gpa.dupe(Range, s.ranges.items);
                l.gpa.free(child.ranges);
                child.ranges = ranges;
                l.list.items(.dirty)[j] = true;
                continue;
            }
            // Room first: once the list owns the tree, nothing may fail.
            try kept.ensureUnusedCapacity(l.gpa, 1);
            try l.changed.ensureUnusedCapacity(l.gpa, s.ranges.items.len);
            const ranges = try l.gpa.dupe(Range, s.ranges.items);
            errdefer l.gpa.free(ranges);
            var tree = try l.parse(io, input, s.grammar, ranges, null, options);
            errdefer tree.deinit();
            const id = l.newId();
            try l.list.append(l.gpa, .{
                .layer = .{ .id = id, .parent = parent.id, .grammar = s.grammar, .tree = tree, .ranges = ranges, .depth = parent.depth + 1 },
                .combined = s.combined,
            });
            kept.putAssumeCapacity(id, {});
            l.changed.appendSliceAssumeCapacity(ranges);
        }

        // Children no spec kept, and their descendants.
        var gone: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer gone.deinit(l.gpa);
        var j: usize = i + 1;
        while (j < l.list.len) {
            const child = l.list.items(.layer)[j];
            const orphan = if (child.parent) |p| gone.contains(p) else false;
            const covered = l.list.items(.combined)[j] != null or inside(child.ranges, wanted);
            const dropped = child.parent == parent.id and !kept.contains(child.id) and covered;
            if (!orphan and !dropped) {
                j += 1;
                continue;
            }
            try gone.put(l.gpa, child.id, {});
            try l.changed.appendSlice(l.gpa, child.ranges);
            var removed = l.list.get(j);
            removed.layer.tree.deinit();
            l.gpa.free(removed.layer.ranges);
            l.list.orderedRemove(j);
        }
    }
};

/// Immutable copies of a document's layers, from `Layers.snapshot`.
pub const Snapshot = struct {
    gpa: std.mem.Allocator,
    layers: []Layer,

    pub fn deinit(s: *Snapshot) void {
        for (s.layers) |*layer| {
            layer.tree.deinit();
            s.gpa.free(layer.ranges);
        }
        s.gpa.free(s.layers);
        s.* = undefined;
    }
};

/// Language names longer than this are no language.
const max_name = 64;

/// A node's text as UTF-8, if it fits `buffer`.
fn nodeText(input: Input, node: Node, buffer: *[max_name]u8) ?[]const u8 {
    const start = node.startByte();
    const end = node.endByte();
    if (end - start > max_name) return null;
    var raw: [max_name]u8 = undefined;
    const bytes = input.copy(start, end, &raw);
    switch (input.encoding()) {
        .utf8 => {
            @memcpy(buffer[0..bytes.len], bytes);
            return buffer[0..bytes.len];
        },
        .utf16le, .utf16be => |e| {
            var units: [max_name / 2]u16 = undefined;
            const n = bytes.len / 2;
            for (units[0..n], 0..) |*u, k| u.* = std.mem.readInt(u16, bytes[2 * k ..][0..2], if (e == .utf16le) .little else .big);
            var w: std.Io.Writer = .fixed(buffer);
            var it = std.unicode.Utf16LeIterator.init(units[0..n]);
            while (it.nextCodepoint() catch return null) |cp| {
                var utf8: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &utf8) catch return null;
                w.writeAll(utf8[0..len]) catch return null;
            }
            return w.buffered();
        },
    }
}

/// A content node's ranges: its range, moved by an `offset!` on its
/// capture, less its named children's unless the pattern includes them.
fn contentRanges(arena: std.mem.Allocator, out: *std.ArrayList(Range), q: *const Query, pattern: u16, capture: u32, node: Node, input: Input) error{OutOfMemory}!void {
    var range = node.range();
    for (q.directives(pattern)) |d| {
        if (!std.mem.eql(u8, d.name, "offset!") or d.args.len < 2) continue;
        if (d.args[0] != .capture or d.args[0].capture != capture) continue;
        var delta: [4]i64 = @splat(0);
        for (d.args[1..@min(d.args.len, 5)], &delta) |arg, *v| {
            if (arg != .string) return;
            v.* = std.fmt.parseInt(i64, arg.string, 10) catch return;
        }
        // Neovim keeps the node's range when the offset would invert it.
        range = offsetRange(input, range, delta) orelse range;
    }
    if (q.property(pattern, "injection.include-children", null) != null or node.namedChildCount() == 0) {
        if (range.start_byte < range.end_byte) try out.append(arena, range);
        return;
    }
    // `get_node_ranges`: the gaps between named children.
    var from = range;
    for (0..node.namedChildCount()) |k| {
        const child = node.namedChild(@intCast(k)) orelse continue;
        if (child.startByte() >= range.end_byte) break;
        if (child.startByte() > from.start_byte) {
            try out.append(arena, .{ .start_byte = from.start_byte, .start_point = from.start_point, .end_byte = child.startByte(), .end_point = child.startPoint() });
        }
        if (child.endByte() > from.start_byte) {
            from.start_byte = child.endByte();
            from.start_point = child.endPoint();
        }
    }
    if (range.end_byte > from.start_byte) try out.append(arena, .{ .start_byte = from.start_byte, .start_point = from.start_point, .end_byte = range.end_byte, .end_point = range.end_point });
}

/// `offset!`'s rows and columns applied to `r`, with the bytes found in
/// the text; null when the result is inverted or leaves the node's lines.
fn offsetRange(input: Input, r: Range, delta: [4]i64) ?Range {
    const start: Point = .{
        .row = std.math.cast(u32, @as(i64, r.start_point.row) + delta[0]) orelse return null,
        .column = std.math.cast(u32, @as(i64, r.start_point.column) + delta[1]) orelse return null,
    };
    const end: Point = .{
        .row = std.math.cast(u32, @as(i64, r.end_point.row) + delta[2]) orelse return null,
        .column = std.math.cast(u32, @as(i64, r.end_point.column) + delta[3]) orelse return null,
    };
    if (start.order(end) == .gt) return null;
    return .{
        .start_point = start,
        .end_point = end,
        .start_byte = byteAt(input, r, start) orelse return null,
        .end_byte = byteAt(input, r, end) orelse return null,
    };
}

/// The byte at `p`, a point on one of `r`'s lines: columns are bytes, so
/// only the line's start needs finding.
fn byteAt(input: Input, r: Range, p: Point) ?u32 {
    const line_start = if (p.row == r.start_point.row)
        r.start_byte - r.start_point.column
    else if (p.row == r.end_point.row)
        r.end_byte - r.end_point.column
    else if (p.row > r.start_point.row and p.row < r.end_point.row)
        lineStart(input, r, p.row) orelse return null
    else
        return null;
    return std.math.add(u32, line_start, p.column) catch null;
}

/// The first byte of line `row`, inside `r`, found by counting newlines
/// from `r`'s start, a code unit at a time.
fn lineStart(input: Input, r: Range, row: u32) ?u32 {
    const unit: u32 = if (input.encoding() == .utf8) 1 else 2;
    var line = r.start_point.row;
    var buffer: [256]u8 = undefined;
    var at = r.start_byte;
    while (at < r.end_byte) {
        const bytes = input.copy(at, r.end_byte, &buffer);
        if (bytes.len < unit) return null;
        const usable = bytes.len - bytes.len % unit;
        var k: usize = 0;
        while (k < usable) : (k += unit) {
            const newline = switch (input.encoding()) {
                .utf8 => bytes[k] == '\n',
                .utf16le => bytes[k] == '\n' and bytes[k + 1] == 0,
                .utf16be => bytes[k] == 0 and bytes[k + 1] == '\n',
            };
            if (!newline) continue;
            line += 1;
            if (line == row) return at + @as(u32, @intCast(k)) + unit;
        }
        at += @intCast(usable);
    }
    return null;
}

/// Sort `ranges`, clip them to `within` (unless empty, the whole text),
/// drop empty ones and merge overlapping ones: what the runtime accepts as
/// included ranges.
fn normalize(arena: std.mem.Allocator, ranges: *std.ArrayList(Range), within: []const Range) error{OutOfMemory}!void {
    if (within.len != 0) {
        var clipped: std.ArrayList(Range) = .empty;
        for (ranges.items) |r| for (within) |w| {
            // The later start and the earlier end.
            const lo = if (r.start_byte >= w.start_byte) r else w;
            const hi = if (r.end_byte <= w.end_byte) r else w;
            if (lo.start_byte >= hi.end_byte) continue;
            try clipped.append(arena, .{ .start_byte = lo.start_byte, .start_point = lo.start_point, .end_byte = hi.end_byte, .end_point = hi.end_point });
        };
        ranges.* = clipped;
    }
    sortRanges(ranges.items);
    mergeInPlace(ranges);
}

fn sortRanges(items: []Range) void {
    std.mem.sort(Range, items, {}, struct {
        fn less(_: void, a: Range, b: Range) bool {
            return a.start_byte < b.start_byte;
        }
    }.less);
}

fn mergeInPlace(ranges: *std.ArrayList(Range)) void {
    var n: usize = 0;
    for (ranges.items) |r| {
        if (r.start_byte >= r.end_byte) continue;
        if (n > 0 and r.start_byte < ranges.items[n - 1].end_byte) {
            const last = &ranges.items[n - 1];
            if (r.end_byte > last.end_byte) {
                last.end_byte = r.end_byte;
                last.end_point = r.end_point;
            }
            continue;
        }
        ranges.items[n] = r;
        n += 1;
    }
    ranges.shrinkRetainingCapacity(n);
}

/// `changed` ascending, with overlapping and touching ranges merged.
fn mergeRanges(changed: *std.ArrayList(Range)) void {
    sortRanges(changed.items);
    var n: usize = 0;
    for (changed.items) |r| {
        if (n > 0 and r.start_byte <= changed.items[n - 1].end_byte) {
            const last = &changed.items[n - 1];
            if (r.end_byte > last.end_byte) {
                last.end_byte = r.end_byte;
                last.end_point = r.end_point;
            }
            continue;
        }
        changed.items[n] = r;
        n += 1;
    }
    changed.shrinkRetainingCapacity(n);
}

/// Some range of `ranges` (the whole text when empty) meets `r`.
fn intersects(ranges: []const Range, r: Range) bool {
    if (ranges.len == 0) return true;
    for (ranges) |x| if (x.start_byte < r.end_byte and r.start_byte < x.end_byte) return true;
    return false;
}

/// Some range of `ranges` lies in `r`: meets it, or, emptied by an edit,
/// sits inside it.
fn inside(ranges: []const Range, r: Range) bool {
    for (ranges) |x| {
        if (x.start_byte == x.end_byte) {
            if (r.start_byte <= x.start_byte and x.start_byte <= r.end_byte) return true;
        } else if (x.start_byte < r.end_byte and r.start_byte < x.end_byte) return true;
    }
    return false;
}

/// An edit of `[start, old_end]` touches a range of `ranges`, ends included.
fn touches(ranges: []const Range, start: u32, old_end: u32) bool {
    for (ranges) |x| if (x.start_byte <= old_end and start <= x.end_byte) return true;
    return false;
}

fn overlaps(a: []const Range, b: []const Range) bool {
    for (b) |r| if (intersects(a, r)) return true;
    return false;
}
