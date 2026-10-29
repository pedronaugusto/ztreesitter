//! A tree cursor: the cheapest way to walk a tree.

const std = @import("std");
const c = @import("c.zig");
const types = @import("types.zig");
const node_mod = @import("node.zig");

/// A cursor over a tree, starting at a node. Borrows the tree; `deinit`.
pub const TreeCursor = struct {
    raw: c.TreeCursor,

    pub fn init(start: node_mod.Node) TreeCursor {
        return .{ .raw = c.ts_tree_cursor_new(start.raw) };
    }

    pub fn deinit(cur: *TreeCursor) void {
        c.ts_tree_cursor_delete(&cur.raw);
        cur.* = undefined;
    }

    pub fn copy(cur: *const TreeCursor) TreeCursor {
        return .{ .raw = c.ts_tree_cursor_copy(&cur.raw) };
    }

    pub fn reset(cur: *TreeCursor, start: node_mod.Node) void {
        c.ts_tree_cursor_reset(&cur.raw, start.raw);
    }

    pub fn resetTo(cur: *TreeCursor, other: *const TreeCursor) void {
        c.ts_tree_cursor_reset_to(&cur.raw, &other.raw);
    }

    pub fn node(cur: *const TreeCursor) node_mod.Node {
        return .{ .raw = c.ts_tree_cursor_current_node(&cur.raw) };
    }

    pub fn fieldName(cur: *const TreeCursor) ?[]const u8 {
        return if (c.ts_tree_cursor_current_field_name(&cur.raw)) |f| std.mem.span(f) else null;
    }

    pub fn fieldId(cur: *const TreeCursor) ?u16 {
        const id = c.ts_tree_cursor_current_field_id(&cur.raw);
        return if (id == 0) null else id;
    }

    pub fn gotoParent(cur: *TreeCursor) bool {
        return c.ts_tree_cursor_goto_parent(&cur.raw);
    }

    pub fn gotoNextSibling(cur: *TreeCursor) bool {
        return c.ts_tree_cursor_goto_next_sibling(&cur.raw);
    }

    pub fn gotoPreviousSibling(cur: *TreeCursor) bool {
        return c.ts_tree_cursor_goto_previous_sibling(&cur.raw);
    }

    pub fn gotoFirstChild(cur: *TreeCursor) bool {
        return c.ts_tree_cursor_goto_first_child(&cur.raw);
    }

    pub fn gotoLastChild(cur: *TreeCursor) bool {
        return c.ts_tree_cursor_goto_last_child(&cur.raw);
    }

    /// Move to the first child that extends past `byte`; its index, or null.
    pub fn gotoFirstChildForByte(cur: *TreeCursor, byte: u32) ?u32 {
        const i = c.ts_tree_cursor_goto_first_child_for_byte(&cur.raw, byte);
        return if (i < 0) null else @intCast(i);
    }

    pub fn gotoFirstChildForPoint(cur: *TreeCursor, point: types.Point) ?u32 {
        const i = c.ts_tree_cursor_goto_first_child_for_point(&cur.raw, .{ .row = point.row, .column = point.column });
        return if (i < 0) null else @intCast(i);
    }

    pub fn gotoDescendant(cur: *TreeCursor, index: u32) void {
        c.ts_tree_cursor_goto_descendant(&cur.raw, index);
    }

    pub fn descendantIndex(cur: *const TreeCursor) u32 {
        return c.ts_tree_cursor_current_descendant_index(&cur.raw);
    }

    pub fn depth(cur: *const TreeCursor) u32 {
        return c.ts_tree_cursor_current_depth(&cur.raw);
    }
};
