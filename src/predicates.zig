//! Query predicates: compiled once per query, evaluated per match.
//!
//! The runtime parses `(#name? ...)` and `(#name! ...)` into steps and leaves
//! their meaning to the binding. This file gives them the meaning of the
//! query's dialect:
//!
//! - `.neovim` follows `runtime/lua/vim/treesitter/query.lua`: a predicate
//!   over a capture with no nodes holds, `not-` negates the whole result,
//!   `any-of?`, `has-ancestor?` and `has-parent?` hold when any node does.
//! - `.tree_sitter` follows the Rust binding (`lib/binding_rust/lib.rs`):
//!   every node must satisfy the predicate (or any node, with `any-`), so a
//!   capture with no nodes satisfies everything but an `any-` predicate.

const std = @import("std");
const c = @import("c.zig");
const types = @import("types.zig");
const node_mod = @import("node.zig");
const language = @import("language.zig");
const regex = @import("regex.zig");
const lua = @import("lua_pattern.zig");

const Dialect = language.Dialect;
const Node = node_mod.Node;

pub const Arg = union(enum) {
    capture: u32,
    string: []const u8,
};

/// `(#set! key value)` or `(#set! @capture key value)`; also `is?` and
/// `is-not?`, which tags queries use as assertions.
pub const Property = struct {
    key: []const u8,
    value: ?[]const u8 = null,
    /// A value that names a capture: `(#set! @label url @url)`.
    value_capture: ?u32 = null,
    capture: ?u32 = null,
};

/// A directive the query states and the consumer applies: `offset!`,
/// `trim!`, `gsub!`, `strip!`, `select-adjacent!`, or any other `!`.
pub const Directive = struct {
    name: []const u8,
    args: []const Arg,
};

pub const Filter = struct {
    capture: u32,
    negate: bool = false,
    any: bool = false,
    test_: Test,

    pub const Test = union(enum) {
        eq_string: []const u8,
        eq_capture: u32,
        any_of: []const []const u8,
        regex: regex.Program,
        lua: lua.Pattern,
        contains: []const []const u8,
        has_ancestor: []const []const u8,
        has_parent: []const []const u8,
        kind_eq: []const []const u8,
    };
};

pub const Pattern = struct {
    filters: []Filter = &.{},
    properties: []Property = &.{},
    is: []Property = &.{},
    is_not: []Property = &.{},
    directives: []Directive = &.{},
};

pub const CompileError = error{ UnsupportedPredicate, InvalidPredicate, InvalidPattern, OutOfMemory };

pub const Failure = struct {
    pattern: u32 = 0,
    name: []const u8 = "",
};

/// Compile one pattern's steps. Strings are borrowed from the query, whose
/// string table lives as long as it does.
pub fn compilePattern(
    gpa: std.mem.Allocator,
    query: *const c.Query,
    pattern_index: u32,
    dialect: Dialect,
    passthrough: []const []const u8,
    failure: *Failure,
) CompileError!Pattern {
    var count: u32 = 0;
    const steps_ptr = c.ts_query_predicates_for_pattern(query, pattern_index, &count);
    const steps: []const c.QueryPredicateStep = if (steps_ptr) |p| p[0..count] else &.{};

    var filters: std.ArrayList(Filter) = .empty;
    var properties: std.ArrayList(Property) = .empty;
    var is: std.ArrayList(Property) = .empty;
    var is_not: std.ArrayList(Property) = .empty;
    var directives: std.ArrayList(Directive) = .empty;
    errdefer {
        for (filters.items) |*f| deinitFilter(gpa, f);
        filters.deinit(gpa);
        properties.deinit(gpa);
        is.deinit(gpa);
        is_not.deinit(gpa);
        for (directives.items) |d| gpa.free(d.args);
        directives.deinit(gpa);
    }

    var args: std.ArrayList(Arg) = .empty;
    defer args.deinit(gpa);
    var start: usize = 0;
    for (steps, 0..) |step, i| {
        if (step.type != .Done) continue;
        const pred = steps[start..i];
        start = i + 1;
        if (pred.len == 0 or pred[0].type != .String) return error.InvalidPredicate;
        const name = string(query, pred[0].value_id);
        failure.* = .{ .pattern = pattern_index, .name = name };
        args.clearRetainingCapacity();
        for (pred[1..]) |a| try args.append(gpa, switch (a.type) {
            .Capture => .{ .capture = a.value_id },
            .String => .{ .string = string(query, a.value_id) },
            .Done => unreachable,
        });

        if (std.mem.endsWith(u8, name, "!")) {
            if (std.mem.eql(u8, name, "set!")) {
                try properties.append(gpa, try property(args.items));
            } else {
                try directives.append(gpa, .{ .name = name, .args = try gpa.dupe(Arg, args.items) });
            }
            continue;
        }
        if (std.mem.eql(u8, name, "is?")) {
            try is.append(gpa, try property(args.items));
            continue;
        }
        if (std.mem.eql(u8, name, "is-not?")) {
            try is_not.append(gpa, try property(args.items));
            continue;
        }
        if (try filter(gpa, name, args.items, dialect)) |f| {
            try filters.append(gpa, f);
            continue;
        }
        const allowed = for (passthrough) |pass| {
            if (std.mem.eql(u8, pass, name)) break true;
        } else false;
        if (!allowed) return error.UnsupportedPredicate;
    }
    if (start != steps.len) return error.InvalidPredicate;

    return .{
        .filters = try filters.toOwnedSlice(gpa),
        .properties = try properties.toOwnedSlice(gpa),
        .is = try is.toOwnedSlice(gpa),
        .is_not = try is_not.toOwnedSlice(gpa),
        .directives = try directives.toOwnedSlice(gpa),
    };
}

pub fn deinitPattern(gpa: std.mem.Allocator, p: *Pattern) void {
    for (p.filters) |*f| deinitFilter(gpa, f);
    gpa.free(p.filters);
    gpa.free(p.properties);
    gpa.free(p.is);
    gpa.free(p.is_not);
    for (p.directives) |d| gpa.free(d.args);
    gpa.free(p.directives);
    p.* = undefined;
}

fn deinitFilter(gpa: std.mem.Allocator, f: *Filter) void {
    switch (f.test_) {
        .regex => |*r| r.deinit(gpa),
        .any_of, .contains, .has_ancestor, .has_parent, .kind_eq => |list| gpa.free(list),
        else => {},
    }
}

fn string(query: *const c.Query, id: u32) []const u8 {
    var len: u32 = 0;
    const p = c.ts_query_string_value_for_id(query, id, &len);
    return p[0..len];
}

fn property(args: []const Arg) CompileError!Property {
    var p: Property = .{ .key = "" };
    var rest = args;
    if (rest.len > 0 and rest[0] == .capture) {
        p.capture = rest[0].capture;
        rest = rest[1..];
    }
    if (rest.len == 0 or rest[0] != .string) return error.InvalidPredicate;
    p.key = rest[0].string;
    if (rest.len > 1) switch (rest[1]) {
        .string => |v| p.value = v,
        .capture => |k| p.value_capture = k,
    };
    if (rest.len > 2) return error.InvalidPredicate;
    return p;
}

fn strings(gpa: std.mem.Allocator, args: []const Arg) CompileError![]const []const u8 {
    const out = try gpa.alloc([]const u8, args.len);
    errdefer gpa.free(out);
    for (args, out) |a, *o| {
        if (a != .string) return error.InvalidPredicate;
        o.* = a.string;
    }
    return out;
}

/// The filter a predicate name means in `dialect`, or null for a name it does
/// not know.
fn filter(gpa: std.mem.Allocator, full: []const u8, args: []const Arg, dialect: Dialect) CompileError!?Filter {
    var name = full;
    var f: Filter = .{ .capture = 0, .test_ = undefined };
    if (std.mem.startsWith(u8, name, "not-")) {
        f.negate = true;
        name = name[4..];
    }
    if (std.mem.startsWith(u8, name, "any-")) {
        f.any = true;
        name = name[4..];
    }
    // Neovim also spells the negation `any-not-`; tree-sitter does too.
    if (!f.negate and std.mem.startsWith(u8, name, "not-")) {
        f.negate = true;
        name = name[4..];
    }
    if (args.len == 0 or args[0] != .capture) {
        return if (isKnown(name, dialect)) error.InvalidPredicate else null;
    }
    f.capture = args[0].capture;
    const rest = args[1..];

    if (std.mem.eql(u8, name, "eq?")) {
        if (rest.len != 1) return error.InvalidPredicate;
        f.test_ = switch (rest[0]) {
            .string => |s| .{ .eq_string = s },
            .capture => |k| .{ .eq_capture = k },
        };
    } else if (std.mem.eql(u8, name, "of?")) {
        // `any-of?`: "any" here is part of the name, not the quantifier.
        if (!f.any) return null;
        f.any = false;
        f.test_ = .{ .any_of = try strings(gpa, rest) };
    } else if (std.mem.eql(u8, name, "match?") or (dialect == .neovim and std.mem.eql(u8, name, "vim-match?"))) {
        if (rest.len != 1 or rest[0] != .string) return error.InvalidPredicate;
        f.test_ = .{ .regex = try regex.compile(gpa, rest[0].string, if (dialect == .neovim) .vim else .rust) };
    } else if (dialect == .neovim and std.mem.eql(u8, name, "lua-match?")) {
        if (rest.len != 1 or rest[0] != .string) return error.InvalidPredicate;
        f.test_ = .{ .lua = lua.Pattern.init(rest[0].string) catch return error.InvalidPattern };
    } else if (dialect == .neovim and std.mem.eql(u8, name, "contains?")) {
        f.test_ = .{ .contains = try strings(gpa, rest) };
    } else if (dialect == .neovim and std.mem.eql(u8, name, "has-ancestor?")) {
        f.test_ = .{ .has_ancestor = try strings(gpa, rest) };
    } else if (dialect == .neovim and std.mem.eql(u8, name, "has-parent?")) {
        f.test_ = .{ .has_parent = try strings(gpa, rest) };
    } else if (dialect == .neovim and std.mem.eql(u8, name, "kind-eq?")) {
        f.test_ = .{ .kind_eq = try strings(gpa, rest) };
    } else return null;
    return f;
}

fn isKnown(name: []const u8, dialect: Dialect) bool {
    const common = [_][]const u8{ "eq?", "of?", "match?" };
    const neovim = [_][]const u8{ "vim-match?", "lua-match?", "contains?", "has-ancestor?", "has-parent?", "kind-eq?" };
    for (common) |n| if (std.mem.eql(u8, n, name)) return true;
    if (dialect == .neovim) for (neovim) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------------

pub const scratch_size = 16 * 1024;

/// Per-cursor working memory: nothing is allocated while matching.
pub const Scratch = struct {
    matcher: regex.Matcher,
    text: [scratch_size]u8,
    other: [scratch_size]u8,
};

pub const Capture = extern struct {
    node: Node,
    index: u32,

    comptime {
        std.debug.assert(@sizeOf(Capture) == @sizeOf(c.QueryCapture));
    }
};

/// A node's text: borrowed from a slice input, or copied (and transcoded to
/// UTF-8) into `buffer`. `complete` is false when it did not fit.
const Text = struct { bytes: []const u8, complete: bool };

fn nodeText(input: types.Input, n: Node, buffer: []u8, spare: []u8) Text {
    const start = n.startByte();
    const end = n.endByte();
    switch (input.encoding()) {
        .utf8 => {
            if (input == .slice) {
                const s = input.slice;
                return .{ .bytes = s[@min(start, s.len)..@min(end, s.len)], .complete = true };
            }
            const got = input.copy(start, end, buffer);
            return .{ .bytes = got, .complete = got.len == end - start };
        },
        .utf16le, .utf16be => |e| {
            const raw = input.copy(start, end, spare);
            var units: [scratch_size / 2]u16 = undefined;
            const n_units = raw.len / 2;
            for (0..n_units) |i| {
                const pair = raw[2 * i ..][0..2];
                units[i] = if (e == .utf16le) std.mem.readInt(u16, pair, .little) else std.mem.readInt(u16, pair, .big);
            }
            var out: usize = 0;
            var it = std.unicode.Utf16LeIterator.init(units[0..n_units]);
            // Whole only when every unit was read and transcoded: UTF-8 can
            // be longer than the UTF-16 it comes from, and a malformed
            // sequence stops the copy.
            const transcoded = while (true) {
                const cp = (it.nextCodepoint() catch break false) orelse break true;
                const len = std.unicode.utf8CodepointSequenceLength(cp) catch break false;
                if (out + len > buffer.len) break false;
                _ = std.unicode.utf8Encode(cp, buffer[out..][0..len]) catch break false;
                out += len;
            };
            return .{ .bytes = buffer[0..out], .complete = transcoded and raw.len == end - start };
        },
    }
}

fn kindIn(n: Node, kinds: []const []const u8) bool {
    const k = n.kind();
    for (kinds) |want| if (std.mem.eql(u8, want, k)) return true;
    return false;
}

fn hasAncestor(n: Node, kinds: []const []const u8) bool {
    // Down from the root, as Neovim's __has_ancestor does: one descent.
    const tree: *const c.Tree = n.raw.tree orelse return false;
    var at: Node = .{ .raw = c.ts_tree_root_node(tree) };
    while (!at.eql(n)) {
        if (kindIn(at, kinds)) return true;
        at = at.childWithDescendant(n) orelse return false;
    }
    return false;
}

fn substring(haystack: []const u8, needles: []const []const u8, any: bool) bool {
    for (needles) |needle| {
        const found = std.mem.find(u8, haystack, needle) != null;
        if (any and found) return true;
        if (!any and !found) return false;
    }
    return !any;
}

/// Whether two nodes' texts are equal, compared whole, however long. In
/// any encoding the texts are equal exactly when their bytes are. A reader's
/// text goes in blocks of the scratch's size: a block of one node copied,
/// the same span of the other compared with it as it is read.
fn sameText(input: types.Input, a: Node, b: Node, scratch: *Scratch) bool {
    const a_start = a.startByte();
    const b_start = b.startByte();
    const len = a.endByte() - a_start;
    if (b.endByte() - b_start != len) return false;
    if (input == .slice) {
        const s = input.slice;
        if (a_start + len > s.len or b_start + len > s.len) return false;
        return std.mem.eql(u8, s[a_start..][0..len], s[b_start..][0..len]);
    }
    var done: u32 = 0;
    while (done < len) {
        const step: u32 = @intCast(@min(len - done, scratch_size));
        const block = input.copy(a_start + done, a_start + done + step, &scratch.text);
        // A reader that ends inside the node has no text to compare.
        if (block.len != step) return false;
        if (!sameBytes(input, b_start + done, block)) return false;
        done += step;
    }
    return true;
}

/// Whether the input holds `expected` from byte `start`.
fn sameBytes(input: types.Input, start: u32, expected: []const u8) bool {
    const Compare = struct {
        expected: []const u8,
        equal: bool = true,

        fn visit(cmp: *@This(), chunk: []const u8) bool {
            if (chunk.len > cmp.expected.len or !std.mem.eql(u8, chunk, cmp.expected[0..chunk.len])) {
                cmp.equal = false;
                return false;
            }
            cmp.expected = cmp.expected[chunk.len..];
            return true;
        }
    };
    var cmp: Compare = .{ .expected = expected };
    input.chunks(start, start + @as(u32, @intCast(expected.len)), &cmp, Compare.visit);
    return cmp.equal and cmp.expected.len == 0;
}

/// Whether a node's text is `literal` (UTF-8), compared whole, however long:
/// UTF-8 text byte for byte as it is read; UTF-16 text against the literal
/// encoded the same way, a scratch-sized block at a time.
fn isLiteral(input: types.Input, n: Node, literal: []const u8, scratch: *Scratch) bool {
    const start = n.startByte();
    const end = n.endByte();
    const e = input.encoding();
    if (e == .utf8) return end - start == literal.len and sameBytes(input, start, literal);
    var points = (std.unicode.Utf8View.init(literal) catch return false).iterator();
    var at = start;
    var pending = points.nextCodepoint();
    while (pending != null) {
        var filled: usize = 0;
        while (pending) |cp| : (pending = points.nextCodepoint()) {
            // One unit, or a surrogate pair above the Basic Multilingual Plane.
            const units: [2]u16, const count: usize = if (cp < 0x10000)
                .{ .{ @intCast(cp), 0 }, 1 }
            else
                .{ .{ @intCast(0xd800 + ((cp - 0x10000) >> 10)), @intCast(0xdc00 + ((cp - 0x10000) & 0x3ff)) }, 2 };
            if (filled + 2 * count > scratch.other.len) break;
            for (units[0..count]) |unit| {
                std.mem.writeInt(u16, scratch.other[filled..][0..2], unit, if (e == .utf16le) .little else .big);
                filled += 2;
            }
        }
        if (filled > end - at or !sameBytes(input, at, scratch.other[0..filled])) return false;
        at += @intCast(filled);
    }
    return at == end;
}

/// Why evaluating a match's predicates stops without an answer: a Lua
/// pattern's search was canceled or ran past its step budget.
pub const EvalError = lua.FindError;

/// Does one node satisfy the base test (before negation)?
fn holds(io: std.Io, f: *const Filter, n: Node, match: []const Capture, input: types.Input, scratch: *Scratch) EvalError!bool {
    switch (f.test_) {
        .has_parent => |kinds| return if (n.parent()) |p| kindIn(p, kinds) else false,
        .has_ancestor => |kinds| return hasAncestor(n, kinds),
        .kind_eq => |kinds| return kindIn(n, kinds),
        .regex => |*program| {
            const m = &scratch.matcher;
            m.start(program);
            if (input.encoding() == .utf8) {
                input.chunks(n.startByte(), n.endByte(), m, struct {
                    fn feed(matcher: *regex.Matcher, chunk: []const u8) bool {
                        matcher.feed(chunk);
                        return !matcher.matched;
                    }
                }.feed);
            } else {
                m.feed(nodeText(input, n, &scratch.text, &scratch.other).bytes);
            }
            return m.finish();
        },
        else => {},
    }
    const text = nodeText(input, n, &scratch.text, &scratch.other);
    switch (f.test_) {
        .eq_string => |s| return isLiteral(input, n, s, scratch),
        .eq_capture => |k| {
            for (match) |cap| if (cap.index == k) return sameText(input, n, cap.node, scratch);
            return false;
        },
        .any_of => |list| {
            for (list) |s| if (isLiteral(input, n, s, scratch)) return true;
            return false;
        },
        .lua => |pattern| return lua.find(io, text.bytes, pattern),
        .contains => |list| return substring(text.bytes, list, f.any),
        else => unreachable,
    }
}

/// Does the match satisfy every filter of its pattern? A cancellation point
/// on `io`, in Lua patterns' searches.
pub fn satisfies(io: std.Io, filters: []const Filter, match: []const Capture, input: types.Input, dialect: Dialect, scratch: *Scratch) EvalError!bool {
    for (filters) |*f| if (!try satisfiesOne(io, f, match, input, dialect, scratch)) return false;
    return true;
}

fn satisfiesOne(io: std.Io, f: *const Filter, match: []const Capture, input: types.Input, dialect: Dialect, scratch: *Scratch) EvalError!bool {
    // `any-of?`, `has-ancestor?` and `has-parent?` hold when any node does,
    // in Neovim; `contains?` folds `any` into its strings.
    const any = f.any or (dialect == .neovim and switch (f.test_) {
        .any_of, .has_ancestor, .has_parent => true,
        else => false,
    });
    const per_string = f.test_ == .contains;
    var seen = false;
    switch (dialect) {
        .neovim => {
            var result: bool = if (any and !per_string) false else true;
            for (match) |cap| {
                if (cap.index != f.capture) continue;
                seen = true;
                const r = try holds(io, f, cap.node, match, input, scratch);
                if (per_string) {
                    if (f.any and r) {
                        result = true;
                        break;
                    }
                    if (!f.any and !r) {
                        result = false;
                        break;
                    }
                    continue;
                }
                if (any and r) {
                    result = true;
                    break;
                }
                if (!any and !r) {
                    result = false;
                    break;
                }
            }
            if (!seen) result = true;
            return result != f.negate;
        },
        .tree_sitter => {
            // nodes.all(test == positive), or nodes.any(...) with `any-`.
            for (match) |cap| {
                if (cap.index != f.capture) continue;
                const r = (try holds(io, f, cap.node, match, input, scratch)) != f.negate;
                if (any and r) return true;
                if (!any and !r) return false;
            }
            return !any;
        },
    }
}
