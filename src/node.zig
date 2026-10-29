//! A syntax node: a 32-byte value borrowing its tree.

const std = @import("std");
const c = @import("c.zig");
const types = @import("types.zig");
const language_mod = @import("language.zig");
const memory = @import("memory.zig");

const Point = types.Point;
const Range = types.Range;

/// A node of a tree. It borrows the tree: it is invalid once the `Tree`
/// handle it came from is released or edited. Copying it is free.
pub const Node = extern struct {
    raw: c.Node,

    pub fn isNull(n: Node) bool {
        return c.ts_node_is_null(n.raw);
    }

    fn wrap(raw: c.Node) ?Node {
        return if (c.ts_node_is_null(raw)) null else .{ .raw = raw };
    }

    /// The node's kind, as the grammar names it (`function_definition`, `{`).
    pub fn kind(n: Node) []const u8 {
        return std.mem.span(c.ts_node_type(n.raw));
    }

    pub fn symbol(n: Node) u16 {
        return c.ts_node_symbol(n.raw);
    }

    /// The kind before aliasing.
    pub fn grammarKind(n: Node) []const u8 {
        return std.mem.span(c.ts_node_grammar_type(n.raw));
    }

    pub fn grammarSymbol(n: Node) u16 {
        return c.ts_node_grammar_symbol(n.raw);
    }

    pub fn language(n: Node) language_mod.Language {
        return .{ .ptr = c.ts_node_language(n.raw) };
    }

    pub fn startByte(n: Node) u32 {
        return c.ts_node_start_byte(n.raw);
    }

    pub fn endByte(n: Node) u32 {
        return c.ts_node_end_byte(n.raw);
    }

    pub fn startPoint(n: Node) Point {
        const p = c.ts_node_start_point(n.raw);
        return .{ .row = p.row, .column = p.column };
    }

    pub fn endPoint(n: Node) Point {
        const p = c.ts_node_end_point(n.raw);
        return .{ .row = p.row, .column = p.column };
    }

    pub fn range(n: Node) Range {
        return .{ .start_point = n.startPoint(), .end_point = n.endPoint(), .start_byte = n.startByte(), .end_byte = n.endByte() };
    }

    pub fn isNamed(n: Node) bool {
        return c.ts_node_is_named(n.raw);
    }

    /// Inserted by error recovery: present in the tree, absent in the text.
    pub fn isMissing(n: Node) bool {
        return c.ts_node_is_missing(n.raw);
    }

    /// Not part of the grammar's structure (comments, usually).
    pub fn isExtra(n: Node) bool {
        return c.ts_node_is_extra(n.raw);
    }

    pub fn isError(n: Node) bool {
        return c.ts_node_is_error(n.raw);
    }

    /// The node or a descendant is an error or missing node.
    pub fn hasError(n: Node) bool {
        return c.ts_node_has_error(n.raw);
    }

    /// Edited since the tree was parsed.
    pub fn hasChanges(n: Node) bool {
        return c.ts_node_has_changes(n.raw);
    }

    pub fn parseState(n: Node) u16 {
        return c.ts_node_parse_state(n.raw);
    }

    pub fn nextParseState(n: Node) u16 {
        return c.ts_node_next_parse_state(n.raw);
    }

    pub fn parent(n: Node) ?Node {
        return wrap(c.ts_node_parent(n.raw));
    }

    /// The child of `n` that contains `descendant`.
    pub fn childWithDescendant(n: Node, descendant: Node) ?Node {
        return wrap(c.ts_node_child_with_descendant(n.raw, descendant.raw));
    }

    pub fn childCount(n: Node) u32 {
        return c.ts_node_child_count(n.raw);
    }

    pub fn child(n: Node, index: u32) ?Node {
        return wrap(c.ts_node_child(n.raw, index));
    }

    pub fn namedChildCount(n: Node) u32 {
        return c.ts_node_named_child_count(n.raw);
    }

    pub fn namedChild(n: Node, index: u32) ?Node {
        return wrap(c.ts_node_named_child(n.raw, index));
    }

    pub fn childByFieldName(n: Node, field: []const u8) ?Node {
        return wrap(c.ts_node_child_by_field_name(n.raw, field.ptr, @intCast(field.len)));
    }

    pub fn childByFieldId(n: Node, field: u16) ?Node {
        return wrap(c.ts_node_child_by_field_id(n.raw, field));
    }

    pub fn fieldNameForChild(n: Node, index: u32) ?[]const u8 {
        return if (c.ts_node_field_name_for_child(n.raw, index)) |f| std.mem.span(f) else null;
    }

    pub fn fieldNameForNamedChild(n: Node, index: u32) ?[]const u8 {
        return if (c.ts_node_field_name_for_named_child(n.raw, index)) |f| std.mem.span(f) else null;
    }

    pub fn nextSibling(n: Node) ?Node {
        return wrap(c.ts_node_next_sibling(n.raw));
    }

    pub fn prevSibling(n: Node) ?Node {
        return wrap(c.ts_node_prev_sibling(n.raw));
    }

    pub fn nextNamedSibling(n: Node) ?Node {
        return wrap(c.ts_node_next_named_sibling(n.raw));
    }

    pub fn prevNamedSibling(n: Node) ?Node {
        return wrap(c.ts_node_prev_named_sibling(n.raw));
    }

    pub fn firstChildForByte(n: Node, byte: u32) ?Node {
        return wrap(c.ts_node_first_child_for_byte(n.raw, byte));
    }

    pub fn firstNamedChildForByte(n: Node, byte: u32) ?Node {
        return wrap(c.ts_node_first_named_child_for_byte(n.raw, byte));
    }

    pub fn descendantCount(n: Node) u32 {
        return c.ts_node_descendant_count(n.raw);
    }

    /// The smallest node within `n` spanning the byte range.
    pub fn descendantForByteRange(n: Node, start: u32, end: u32) ?Node {
        return wrap(c.ts_node_descendant_for_byte_range(n.raw, start, end));
    }

    pub fn namedDescendantForByteRange(n: Node, start: u32, end: u32) ?Node {
        return wrap(c.ts_node_named_descendant_for_byte_range(n.raw, start, end));
    }

    pub fn descendantForPointRange(n: Node, start: Point, end: Point) ?Node {
        return wrap(c.ts_node_descendant_for_point_range(n.raw, toC(start), toC(end)));
    }

    pub fn namedDescendantForPointRange(n: Node, start: Point, end: Point) ?Node {
        return wrap(c.ts_node_named_descendant_for_point_range(n.raw, toC(start), toC(end)));
    }

    /// Adjust a node held across an edit, as `Tree.edit` adjusts the tree.
    pub fn edit(n: *Node, e: *const types.InputEdit) void {
        c.ts_node_edit(&n.raw, @ptrCast(e)); // aegis: no-danger: InputEdit has c.InputEdit's layout, asserted in types.zig
    }

    pub fn eql(a: Node, b: Node) bool {
        return c.ts_node_eq(a.raw, b.raw);
    }

    /// The node as an S-expression, written to `writer`.
    pub fn format(n: Node, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const s = c.ts_node_string(n.raw) orelse return;
        defer memory.freeRuntime(s);
        try writer.writeAll(std.mem.span(s));
    }

    /// The node's text, when the input is contiguous.
    pub fn text(n: Node, source: []const u8) []const u8 {
        return source[@min(n.startByte(), source.len)..@min(n.endByte(), source.len)];
    }
};

fn toC(p: Point) c.Point {
    return .{ .row = p.row, .column = p.column };
}
