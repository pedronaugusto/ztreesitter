//! A syntax tree.

const c = @import("c.zig");
const types = @import("types.zig");
const node = @import("node.zig");
const language_mod = @import("language.zig");
const memory = @import("memory.zig");

/// A parsed tree. Release each handle once with `deinit`. `copy` is a cheap
/// reference-counted handle for use on another thread; a tree handle itself
/// is used by one thread at a time.
pub const Tree = struct {
    raw: *c.Tree,

    pub fn deinit(t: *Tree) void {
        c.ts_tree_delete(t.raw);
        t.* = undefined;
    }

    pub fn copy(t: Tree) Tree {
        return .{ .raw = c.ts_tree_copy(t.raw) };
    }

    pub fn rootNode(t: Tree) node.Node {
        return .{ .raw = c.ts_tree_root_node(t.raw) };
    }

    /// The root node as if the tree started `offset_bytes` and `offset_point`
    /// into a larger text.
    pub fn rootNodeWithOffset(t: Tree, offset_bytes: u32, offset_point: types.Point) node.Node {
        return .{ .raw = c.ts_tree_root_node_with_offset(t.raw, offset_bytes, .{ .row = offset_point.row, .column = offset_point.column }) };
    }

    pub fn language(t: Tree) language_mod.Language {
        return .{ .ptr = c.ts_tree_language(t.raw) };
    }

    /// Adjust the tree for an edit to its text, before re-parsing with it as
    /// the old tree. Nodes taken from it before the edit are invalid after.
    pub fn edit(t: *Tree, e: types.InputEdit) void {
        c.ts_tree_edit(t.raw, @ptrCast(&e)); // aegis: no-danger: InputEdit has c.InputEdit's layout, asserted in types.zig
    }

    /// The ranges the tree was parsed over. Free with `RangeList.deinit`.
    pub fn includedRanges(t: Tree) RangeList {
        var n: u32 = 0;
        const p = c.ts_tree_included_ranges(t.raw, &n);
        return .init(p, n);
    }

    /// Where the syntactic structure of `new` differs from `old`, which must
    /// be the edited tree `new` was parsed from. Free with `deinit`.
    pub fn changedRanges(old: Tree, new: Tree) ChangedRanges {
        var n: u32 = 0;
        const p = c.ts_tree_get_changed_ranges(old.raw, new.raw, &n);
        return .init(p, n);
    }
};

/// Ranges the runtime allocated. `deinit` returns them through the runtime's
/// own free function, which is not necessarily libc's.
pub const RangeList = struct {
    items: []const types.Range,
    raw: ?[*]c.Range,

    fn init(p: ?[*]c.Range, n: u32) RangeList {
        const items: []const types.Range = if (p) |q| @as([*]const types.Range, @ptrCast(q))[0..n] else &.{}; // aegis: no-danger: Range has c.Range's layout, asserted in types.zig
        return .{ .items = items, .raw = p };
    }

    pub fn deinit(r: *RangeList) void {
        if (r.raw) |p| memory.freeRuntime(p);
        r.* = undefined;
    }
};

pub const ChangedRanges = RangeList;
