//! The C API of the vendored runtime, `lib/include/tree_sitter/api.h`, written
//! by hand. `abi_check.zig` compares every declaration here with the header,
//! in both directions, so a re-vendor that changes one fails the build.
//!
//! Names are the header's, without the `TS` prefix on types (`TSParser` is
//! `Parser`) and in snake case on constants. Handles that the header documents as required are
//! non-optional pointers; results that can be NULL are optional.

pub const language_version = 15;
pub const min_compatible_language_version = 13;

pub const StateId = u16;
pub const Symbol = u16;
pub const FieldId = u16;

pub const Language = opaque {};
pub const Parser = opaque {};
pub const Tree = opaque {};
pub const Query = opaque {};
pub const QueryCursor = opaque {};
pub const LookaheadIterator = opaque {};
pub const WasmStore = opaque {};

pub const DecodeFunction = ?*const fn (string: [*]const u8, length: u32, code_point: *i32) callconv(.c) u32;

pub const InputEncoding = enum(c_uint) {
    UTF8 = 0,
    UTF16LE = 1,
    UTF16BE = 2,
    Custom = 3,
};

pub const SymbolType = enum(c_uint) {
    Regular = 0,
    Anonymous = 1,
    Supertype = 2,
    Auxiliary = 3,
};

pub const Point = extern struct {
    row: u32,
    column: u32,
};

pub const Range = extern struct {
    start_point: Point,
    end_point: Point,
    start_byte: u32,
    end_byte: u32,
};

pub const Input = extern struct {
    payload: ?*anyopaque,
    read: *const fn (payload: ?*anyopaque, byte_index: u32, position: Point, bytes_read: *u32) callconv(.c) ?[*]const u8,
    encoding: InputEncoding,
    decode: DecodeFunction,
};

pub const ParseState = extern struct {
    payload: ?*anyopaque,
    current_byte_offset: u32,
    has_error: bool,
};

pub const ParseOptions = extern struct {
    payload: ?*anyopaque,
    progress_callback: ?*const fn (state: *ParseState) callconv(.c) bool,
};

pub const LogType = enum(c_uint) {
    Parse = 0,
    Lex = 1,
};

pub const Logger = extern struct {
    payload: ?*anyopaque,
    log: ?*const fn (payload: ?*anyopaque, log_type: LogType, buffer: [*:0]const u8) callconv(.c) void,
};

pub const InputEdit = extern struct {
    start_byte: u32,
    old_end_byte: u32,
    new_end_byte: u32,
    start_point: Point,
    old_end_point: Point,
    new_end_point: Point,
};

pub const Node = extern struct {
    context: [4]u32,
    id: ?*const anyopaque,
    tree: ?*const Tree,
};

pub const TreeCursor = extern struct {
    tree: ?*const anyopaque,
    id: ?*const anyopaque,
    context: [3]u32,
};

pub const QueryCapture = extern struct {
    node: Node,
    index: u32,
};

pub const Quantifier = enum(c_uint) {
    Zero = 0,
    ZeroOrOne = 1,
    ZeroOrMore = 2,
    One = 3,
    OneOrMore = 4,
};

pub const QueryMatch = extern struct {
    id: u32,
    pattern_index: u16,
    capture_count: u16,
    captures: ?[*]const QueryCapture,
};

pub const QueryPredicateStepType = enum(c_uint) {
    Done = 0,
    Capture = 1,
    String = 2,
};

pub const QueryPredicateStep = extern struct {
    type: QueryPredicateStepType,
    value_id: u32,
};

pub const QueryError = enum(c_uint) {
    None = 0,
    Syntax = 1,
    NodeType = 2,
    Field = 3,
    Capture = 4,
    Structure = 5,
    Language = 6,
};

pub const QueryCursorState = extern struct {
    payload: ?*anyopaque,
    current_byte_offset: u32,
};

pub const QueryCursorOptions = extern struct {
    payload: ?*anyopaque,
    progress_callback: ?*const fn (state: *QueryCursorState) callconv(.c) bool,
};

pub const LanguageMetadata = extern struct {
    major_version: u8,
    minor_version: u8,
    patch_version: u8,
};

// Parser

pub extern fn ts_parser_new() ?*Parser; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_parser_delete(self: *Parser) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_parser_language(self: *const Parser) ?*const Language; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_parser_set_language(self: *Parser, language: ?*const Language) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_parser_set_included_ranges(self: *Parser, ranges: ?[*]const Range, count: u32) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_parser_included_ranges(self: *const Parser, count: *u32) [*]const Range; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_parser_parse(self: *Parser, old_tree: ?*const Tree, input: Input) ?*Tree; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_parser_parse_with_options(self: *Parser, old_tree: ?*const Tree, input: Input, parse_options: ParseOptions) ?*Tree; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_parser_parse_string(self: *Parser, old_tree: ?*const Tree, string: [*]const u8, length: u32) ?*Tree; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_parser_parse_string_encoding(self: *Parser, old_tree: ?*const Tree, string: [*]const u8, length: u32, encoding: InputEncoding) ?*Tree; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_parser_reset(self: *Parser) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_parser_set_logger(self: *Parser, logger: Logger) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_parser_logger(self: *const Parser) Logger; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_parser_print_dot_graphs(self: *Parser, fd: c_int) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig

// Tree

pub extern fn ts_tree_copy(self: *const Tree) *Tree; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_delete(self: *Tree) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_root_node(self: *const Tree) Node; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_root_node_with_offset(self: *const Tree, offset_bytes: u32, offset_extent: Point) Node; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_language(self: *const Tree) *const Language; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_included_ranges(self: *const Tree, length: *u32) ?[*]Range; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_edit(self: *Tree, edit: *const InputEdit) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_get_changed_ranges(old_tree: *const Tree, new_tree: *const Tree, length: *u32) ?[*]Range; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_print_dot_graph(self: *const Tree, file_descriptor: c_int) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig

// Node

pub extern fn ts_node_type(self: Node) [*:0]const u8; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_symbol(self: Node) Symbol; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_language(self: Node) *const Language; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_grammar_type(self: Node) [*:0]const u8; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_grammar_symbol(self: Node) Symbol; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_start_byte(self: Node) u32; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_start_point(self: Node) Point; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_end_byte(self: Node) u32; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_end_point(self: Node) Point; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_string(self: Node) ?[*:0]u8; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_is_null(self: Node) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_is_named(self: Node) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_is_missing(self: Node) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_is_extra(self: Node) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_has_changes(self: Node) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_has_error(self: Node) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_is_error(self: Node) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_parse_state(self: Node) StateId; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_next_parse_state(self: Node) StateId; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_parent(self: Node) Node; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_child_with_descendant(self: Node, descendant: Node) Node; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_child(self: Node, child_index: u32) Node; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_field_name_for_child(self: Node, child_index: u32) ?[*:0]const u8; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_field_name_for_named_child(self: Node, named_child_index: u32) ?[*:0]const u8; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_child_count(self: Node) u32; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_named_child(self: Node, child_index: u32) Node; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_named_child_count(self: Node) u32; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_child_by_field_name(self: Node, name: [*]const u8, name_length: u32) Node; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_child_by_field_id(self: Node, field_id: FieldId) Node; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_next_sibling(self: Node) Node; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_prev_sibling(self: Node) Node; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_next_named_sibling(self: Node) Node; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_prev_named_sibling(self: Node) Node; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_first_child_for_byte(self: Node, byte: u32) Node; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_first_named_child_for_byte(self: Node, byte: u32) Node; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_descendant_count(self: Node) u32; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_descendant_for_byte_range(self: Node, start: u32, end: u32) Node; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_descendant_for_point_range(self: Node, start: Point, end: Point) Node; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_named_descendant_for_byte_range(self: Node, start: u32, end: u32) Node; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_named_descendant_for_point_range(self: Node, start: Point, end: Point) Node; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_edit(self: *Node, edit: *const InputEdit) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_node_eq(self: Node, other: Node) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_point_edit(point: *Point, point_byte: *u32, edit: *const InputEdit) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_range_edit(range: *Range, edit: *const InputEdit) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig

// Tree cursor

pub extern fn ts_tree_cursor_new(node: Node) TreeCursor; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_cursor_delete(self: *TreeCursor) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_cursor_reset(self: *TreeCursor, node: Node) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_cursor_reset_to(dst: *TreeCursor, src: *const TreeCursor) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_cursor_current_node(self: *const TreeCursor) Node; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_cursor_current_field_name(self: *const TreeCursor) ?[*:0]const u8; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_cursor_current_field_id(self: *const TreeCursor) FieldId; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_cursor_goto_parent(self: *TreeCursor) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_cursor_goto_next_sibling(self: *TreeCursor) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_cursor_goto_previous_sibling(self: *TreeCursor) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_cursor_goto_first_child(self: *TreeCursor) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_cursor_goto_last_child(self: *TreeCursor) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_cursor_goto_descendant(self: *TreeCursor, goal_descendant_index: u32) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_cursor_current_descendant_index(self: *const TreeCursor) u32; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_cursor_current_depth(self: *const TreeCursor) u32; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_cursor_goto_first_child_for_byte(self: *TreeCursor, goal_byte: u32) i64; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_cursor_goto_first_child_for_point(self: *TreeCursor, goal_point: Point) i64; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_tree_cursor_copy(cursor: *const TreeCursor) TreeCursor; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig

// Query

pub extern fn ts_query_new(language: *const Language, source: [*]const u8, source_len: u32, error_offset: *u32, error_type: *QueryError) ?*Query; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_delete(self: *Query) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_copy(self: *const Query) ?*Query; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_pattern_count(self: *const Query) u32; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_capture_count(self: *const Query) u32; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_string_count(self: *const Query) u32; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_start_byte_for_pattern(self: *const Query, pattern_index: u32) u32; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_end_byte_for_pattern(self: *const Query, pattern_index: u32) u32; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_predicates_for_pattern(self: *const Query, pattern_index: u32, step_count: *u32) ?[*]const QueryPredicateStep; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_is_pattern_rooted(self: *const Query, pattern_index: u32) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_is_pattern_non_local(self: *const Query, pattern_index: u32) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_is_pattern_guaranteed_at_step(self: *const Query, byte_offset: u32) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_capture_name_for_id(self: *const Query, index: u32, length: *u32) [*]const u8; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_capture_quantifier_for_id(self: *const Query, pattern_index: u32, capture_index: u32) Quantifier; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_string_value_for_id(self: *const Query, index: u32, length: *u32) [*]const u8; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_disable_capture(self: *Query, name: [*]const u8, length: u32) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_disable_pattern(self: *Query, pattern_index: u32) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig

// Query cursor

pub extern fn ts_query_cursor_new() ?*QueryCursor; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_cursor_delete(self: *QueryCursor) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_cursor_exec(self: *QueryCursor, query: *const Query, node: Node) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_cursor_exec_with_options(self: *QueryCursor, query: *const Query, node: Node, query_options: ?*const QueryCursorOptions) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_cursor_did_exceed_match_limit(self: *const QueryCursor) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_cursor_match_limit(self: *const QueryCursor) u32; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_cursor_set_match_limit(self: *QueryCursor, limit: u32) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_cursor_set_byte_range(self: *QueryCursor, start_byte: u32, end_byte: u32) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_cursor_set_point_range(self: *QueryCursor, start_point: Point, end_point: Point) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_cursor_set_containing_byte_range(self: *QueryCursor, start_byte: u32, end_byte: u32) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_cursor_set_containing_point_range(self: *QueryCursor, start_point: Point, end_point: Point) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_cursor_next_match(self: *QueryCursor, match: *QueryMatch) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_cursor_remove_match(self: *QueryCursor, match_id: u32) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_cursor_next_capture(self: *QueryCursor, match: *QueryMatch, capture_index: *u32) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_query_cursor_set_max_start_depth(self: *QueryCursor, max_start_depth: u32) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig

// Language

pub extern fn ts_language_copy(self: *const Language) *const Language; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_language_delete(self: *const Language) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_language_is_parseable(self: *const Language) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_language_symbol_count(self: *const Language) u32; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_language_state_count(self: *const Language) u32; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_language_symbol_for_name(self: *const Language, string: [*]const u8, length: u32, is_named: bool) Symbol; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_language_field_count(self: *const Language) u32; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_language_field_name_for_id(self: *const Language, id: FieldId) ?[*:0]const u8; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_language_field_id_for_name(self: *const Language, name: [*]const u8, name_length: u32) FieldId; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_language_supertypes(self: *const Language, length: *u32) ?[*]const Symbol; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_language_subtypes(self: *const Language, supertype: Symbol, length: *u32) ?[*]const Symbol; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_language_symbol_name(self: *const Language, symbol: Symbol) ?[*:0]const u8; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_language_symbol_type(self: *const Language, symbol: Symbol) SymbolType; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_language_abi_version(self: *const Language) u32; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_language_metadata(self: *const Language) ?*const LanguageMetadata; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_language_next_state(self: *const Language, state: StateId, symbol: Symbol) StateId; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_language_name(self: *const Language) ?[*:0]const u8; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig

// Lookahead iterator

pub extern fn ts_lookahead_iterator_new(self: *const Language, state: StateId) ?*LookaheadIterator; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_lookahead_iterator_delete(self: *LookaheadIterator) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_lookahead_iterator_reset_state(self: *LookaheadIterator, state: StateId) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_lookahead_iterator_reset(self: *LookaheadIterator, language: *const Language, state: StateId) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_lookahead_iterator_language(self: *const LookaheadIterator) *const Language; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_lookahead_iterator_next(self: *LookaheadIterator) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_lookahead_iterator_current_symbol(self: *const LookaheadIterator) Symbol; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_lookahead_iterator_current_symbol_name(self: *const LookaheadIterator) [*:0]const u8; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig

// WebAssembly: only the two entry points this build compiles without it.

pub extern fn ts_wasm_store_delete(store: ?*WasmStore) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig
pub extern fn ts_language_is_wasm(language: *const Language) bool; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig

// Allocator

pub const MallocFn = *const fn (size: usize) callconv(.c) ?*anyopaque;
pub const CallocFn = *const fn (count: usize, size: usize) callconv(.c) ?*anyopaque;
pub const ReallocFn = *const fn (ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;
pub const FreeFn = *const fn (ptr: ?*anyopaque) callconv(.c) void;

pub extern fn ts_set_allocator(new_malloc: ?MallocFn, new_calloc: ?CallocFn, new_realloc: ?ReallocFn, new_free: ?FreeFn) void; // aegis: boundary: api.h's declaration, proved against the header by abi_check.zig

/// The runtime's current free function: memory the runtime returns to its
/// caller (`ts_node_string`, `ts_tree_included_ranges`,
/// `ts_tree_get_changed_ranges`) is released through it. Declared in
/// `lib/src/alloc.h`, exported by the library.
pub extern var ts_current_free: FreeFn; // aegis: boundary: alloc.h's variable, the runtime's free function, exported by the library
