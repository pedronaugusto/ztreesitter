//! The C API of the vendored runtime, `lib/include/tree_sitter/api.h`, written
//! by hand. `abi_check.zig` compares every declaration here with the header,
//! in both directions, so a re-vendor that changes one fails the build.
//!
//! Names are the header's. Handles that the header documents as required are
//! non-optional pointers; results that can be NULL are optional.

pub const LANGUAGE_VERSION = 15;
pub const MIN_COMPATIBLE_LANGUAGE_VERSION = 13;

pub const TSStateId = u16;
pub const TSSymbol = u16;
pub const TSFieldId = u16;

pub const TSLanguage = opaque {};
pub const TSParser = opaque {};
pub const TSTree = opaque {};
pub const TSQuery = opaque {};
pub const TSQueryCursor = opaque {};
pub const TSLookaheadIterator = opaque {};
pub const TSWasmStore = opaque {};

pub const TSDecodeFunction = ?*const fn (string: [*]const u8, length: u32, code_point: *i32) callconv(.c) u32;

pub const TSInputEncoding = enum(c_uint) {
    UTF8 = 0,
    UTF16LE = 1,
    UTF16BE = 2,
    Custom = 3,
};

pub const TSSymbolType = enum(c_uint) {
    Regular = 0,
    Anonymous = 1,
    Supertype = 2,
    Auxiliary = 3,
};

pub const TSPoint = extern struct {
    row: u32,
    column: u32,
};

pub const TSRange = extern struct {
    start_point: TSPoint,
    end_point: TSPoint,
    start_byte: u32,
    end_byte: u32,
};

pub const TSInput = extern struct {
    payload: ?*anyopaque,
    read: *const fn (payload: ?*anyopaque, byte_index: u32, position: TSPoint, bytes_read: *u32) callconv(.c) ?[*]const u8,
    encoding: TSInputEncoding,
    decode: TSDecodeFunction,
};

pub const TSParseState = extern struct {
    payload: ?*anyopaque,
    current_byte_offset: u32,
    has_error: bool,
};

pub const TSParseOptions = extern struct {
    payload: ?*anyopaque,
    progress_callback: ?*const fn (state: *TSParseState) callconv(.c) bool,
};

pub const TSLogType = enum(c_uint) {
    Parse = 0,
    Lex = 1,
};

pub const TSLogger = extern struct {
    payload: ?*anyopaque,
    log: ?*const fn (payload: ?*anyopaque, log_type: TSLogType, buffer: [*:0]const u8) callconv(.c) void,
};

pub const TSInputEdit = extern struct {
    start_byte: u32,
    old_end_byte: u32,
    new_end_byte: u32,
    start_point: TSPoint,
    old_end_point: TSPoint,
    new_end_point: TSPoint,
};

pub const TSNode = extern struct {
    context: [4]u32,
    id: ?*const anyopaque,
    tree: ?*const TSTree,
};

pub const TSTreeCursor = extern struct {
    tree: ?*const anyopaque,
    id: ?*const anyopaque,
    context: [3]u32,
};

pub const TSQueryCapture = extern struct {
    node: TSNode,
    index: u32,
};

pub const TSQuantifier = enum(c_uint) {
    Zero = 0,
    ZeroOrOne = 1,
    ZeroOrMore = 2,
    One = 3,
    OneOrMore = 4,
};

pub const TSQueryMatch = extern struct {
    id: u32,
    pattern_index: u16,
    capture_count: u16,
    captures: ?[*]const TSQueryCapture,
};

pub const TSQueryPredicateStepType = enum(c_uint) {
    Done = 0,
    Capture = 1,
    String = 2,
};

pub const TSQueryPredicateStep = extern struct {
    type: TSQueryPredicateStepType,
    value_id: u32,
};

pub const TSQueryError = enum(c_uint) {
    None = 0,
    Syntax = 1,
    NodeType = 2,
    Field = 3,
    Capture = 4,
    Structure = 5,
    Language = 6,
};

pub const TSQueryCursorState = extern struct {
    payload: ?*anyopaque,
    current_byte_offset: u32,
};

pub const TSQueryCursorOptions = extern struct {
    payload: ?*anyopaque,
    progress_callback: ?*const fn (state: *TSQueryCursorState) callconv(.c) bool,
};

pub const TSLanguageMetadata = extern struct {
    major_version: u8,
    minor_version: u8,
    patch_version: u8,
};

// Parser

pub extern fn ts_parser_new() ?*TSParser;
pub extern fn ts_parser_delete(self: *TSParser) void;
pub extern fn ts_parser_language(self: *const TSParser) ?*const TSLanguage;
pub extern fn ts_parser_set_language(self: *TSParser, language: ?*const TSLanguage) bool;
pub extern fn ts_parser_set_included_ranges(self: *TSParser, ranges: ?[*]const TSRange, count: u32) bool;
pub extern fn ts_parser_included_ranges(self: *const TSParser, count: *u32) [*]const TSRange;
pub extern fn ts_parser_parse(self: *TSParser, old_tree: ?*const TSTree, input: TSInput) ?*TSTree;
pub extern fn ts_parser_parse_with_options(self: *TSParser, old_tree: ?*const TSTree, input: TSInput, parse_options: TSParseOptions) ?*TSTree;
pub extern fn ts_parser_parse_string(self: *TSParser, old_tree: ?*const TSTree, string: [*]const u8, length: u32) ?*TSTree;
pub extern fn ts_parser_parse_string_encoding(self: *TSParser, old_tree: ?*const TSTree, string: [*]const u8, length: u32, encoding: TSInputEncoding) ?*TSTree;
pub extern fn ts_parser_reset(self: *TSParser) void;
pub extern fn ts_parser_set_logger(self: *TSParser, logger: TSLogger) void;
pub extern fn ts_parser_logger(self: *const TSParser) TSLogger;
pub extern fn ts_parser_print_dot_graphs(self: *TSParser, fd: c_int) void;

// Tree

pub extern fn ts_tree_copy(self: *const TSTree) *TSTree;
pub extern fn ts_tree_delete(self: *TSTree) void;
pub extern fn ts_tree_root_node(self: *const TSTree) TSNode;
pub extern fn ts_tree_root_node_with_offset(self: *const TSTree, offset_bytes: u32, offset_extent: TSPoint) TSNode;
pub extern fn ts_tree_language(self: *const TSTree) *const TSLanguage;
pub extern fn ts_tree_included_ranges(self: *const TSTree, length: *u32) ?[*]TSRange;
pub extern fn ts_tree_edit(self: *TSTree, edit: *const TSInputEdit) void;
pub extern fn ts_tree_get_changed_ranges(old_tree: *const TSTree, new_tree: *const TSTree, length: *u32) ?[*]TSRange;
pub extern fn ts_tree_print_dot_graph(self: *const TSTree, file_descriptor: c_int) void;

// Node

pub extern fn ts_node_type(self: TSNode) [*:0]const u8;
pub extern fn ts_node_symbol(self: TSNode) TSSymbol;
pub extern fn ts_node_language(self: TSNode) *const TSLanguage;
pub extern fn ts_node_grammar_type(self: TSNode) [*:0]const u8;
pub extern fn ts_node_grammar_symbol(self: TSNode) TSSymbol;
pub extern fn ts_node_start_byte(self: TSNode) u32;
pub extern fn ts_node_start_point(self: TSNode) TSPoint;
pub extern fn ts_node_end_byte(self: TSNode) u32;
pub extern fn ts_node_end_point(self: TSNode) TSPoint;
pub extern fn ts_node_string(self: TSNode) ?[*:0]u8;
pub extern fn ts_node_is_null(self: TSNode) bool;
pub extern fn ts_node_is_named(self: TSNode) bool;
pub extern fn ts_node_is_missing(self: TSNode) bool;
pub extern fn ts_node_is_extra(self: TSNode) bool;
pub extern fn ts_node_has_changes(self: TSNode) bool;
pub extern fn ts_node_has_error(self: TSNode) bool;
pub extern fn ts_node_is_error(self: TSNode) bool;
pub extern fn ts_node_parse_state(self: TSNode) TSStateId;
pub extern fn ts_node_next_parse_state(self: TSNode) TSStateId;
pub extern fn ts_node_parent(self: TSNode) TSNode;
pub extern fn ts_node_child_with_descendant(self: TSNode, descendant: TSNode) TSNode;
pub extern fn ts_node_child(self: TSNode, child_index: u32) TSNode;
pub extern fn ts_node_field_name_for_child(self: TSNode, child_index: u32) ?[*:0]const u8;
pub extern fn ts_node_field_name_for_named_child(self: TSNode, named_child_index: u32) ?[*:0]const u8;
pub extern fn ts_node_child_count(self: TSNode) u32;
pub extern fn ts_node_named_child(self: TSNode, child_index: u32) TSNode;
pub extern fn ts_node_named_child_count(self: TSNode) u32;
pub extern fn ts_node_child_by_field_name(self: TSNode, name: [*]const u8, name_length: u32) TSNode;
pub extern fn ts_node_child_by_field_id(self: TSNode, field_id: TSFieldId) TSNode;
pub extern fn ts_node_next_sibling(self: TSNode) TSNode;
pub extern fn ts_node_prev_sibling(self: TSNode) TSNode;
pub extern fn ts_node_next_named_sibling(self: TSNode) TSNode;
pub extern fn ts_node_prev_named_sibling(self: TSNode) TSNode;
pub extern fn ts_node_first_child_for_byte(self: TSNode, byte: u32) TSNode;
pub extern fn ts_node_first_named_child_for_byte(self: TSNode, byte: u32) TSNode;
pub extern fn ts_node_descendant_count(self: TSNode) u32;
pub extern fn ts_node_descendant_for_byte_range(self: TSNode, start: u32, end: u32) TSNode;
pub extern fn ts_node_descendant_for_point_range(self: TSNode, start: TSPoint, end: TSPoint) TSNode;
pub extern fn ts_node_named_descendant_for_byte_range(self: TSNode, start: u32, end: u32) TSNode;
pub extern fn ts_node_named_descendant_for_point_range(self: TSNode, start: TSPoint, end: TSPoint) TSNode;
pub extern fn ts_node_edit(self: *TSNode, edit: *const TSInputEdit) void;
pub extern fn ts_node_eq(self: TSNode, other: TSNode) bool;
pub extern fn ts_point_edit(point: *TSPoint, point_byte: *u32, edit: *const TSInputEdit) void;
pub extern fn ts_range_edit(range: *TSRange, edit: *const TSInputEdit) void;

// Tree cursor

pub extern fn ts_tree_cursor_new(node: TSNode) TSTreeCursor;
pub extern fn ts_tree_cursor_delete(self: *TSTreeCursor) void;
pub extern fn ts_tree_cursor_reset(self: *TSTreeCursor, node: TSNode) void;
pub extern fn ts_tree_cursor_reset_to(dst: *TSTreeCursor, src: *const TSTreeCursor) void;
pub extern fn ts_tree_cursor_current_node(self: *const TSTreeCursor) TSNode;
pub extern fn ts_tree_cursor_current_field_name(self: *const TSTreeCursor) ?[*:0]const u8;
pub extern fn ts_tree_cursor_current_field_id(self: *const TSTreeCursor) TSFieldId;
pub extern fn ts_tree_cursor_goto_parent(self: *TSTreeCursor) bool;
pub extern fn ts_tree_cursor_goto_next_sibling(self: *TSTreeCursor) bool;
pub extern fn ts_tree_cursor_goto_previous_sibling(self: *TSTreeCursor) bool;
pub extern fn ts_tree_cursor_goto_first_child(self: *TSTreeCursor) bool;
pub extern fn ts_tree_cursor_goto_last_child(self: *TSTreeCursor) bool;
pub extern fn ts_tree_cursor_goto_descendant(self: *TSTreeCursor, goal_descendant_index: u32) void;
pub extern fn ts_tree_cursor_current_descendant_index(self: *const TSTreeCursor) u32;
pub extern fn ts_tree_cursor_current_depth(self: *const TSTreeCursor) u32;
pub extern fn ts_tree_cursor_goto_first_child_for_byte(self: *TSTreeCursor, goal_byte: u32) i64;
pub extern fn ts_tree_cursor_goto_first_child_for_point(self: *TSTreeCursor, goal_point: TSPoint) i64;
pub extern fn ts_tree_cursor_copy(cursor: *const TSTreeCursor) TSTreeCursor;

// Query

pub extern fn ts_query_new(language: *const TSLanguage, source: [*]const u8, source_len: u32, error_offset: *u32, error_type: *TSQueryError) ?*TSQuery;
pub extern fn ts_query_delete(self: *TSQuery) void;
pub extern fn ts_query_copy(self: *const TSQuery) ?*TSQuery;
pub extern fn ts_query_pattern_count(self: *const TSQuery) u32;
pub extern fn ts_query_capture_count(self: *const TSQuery) u32;
pub extern fn ts_query_string_count(self: *const TSQuery) u32;
pub extern fn ts_query_start_byte_for_pattern(self: *const TSQuery, pattern_index: u32) u32;
pub extern fn ts_query_end_byte_for_pattern(self: *const TSQuery, pattern_index: u32) u32;
pub extern fn ts_query_predicates_for_pattern(self: *const TSQuery, pattern_index: u32, step_count: *u32) ?[*]const TSQueryPredicateStep;
pub extern fn ts_query_is_pattern_rooted(self: *const TSQuery, pattern_index: u32) bool;
pub extern fn ts_query_is_pattern_non_local(self: *const TSQuery, pattern_index: u32) bool;
pub extern fn ts_query_is_pattern_guaranteed_at_step(self: *const TSQuery, byte_offset: u32) bool;
pub extern fn ts_query_capture_name_for_id(self: *const TSQuery, index: u32, length: *u32) [*]const u8;
pub extern fn ts_query_capture_quantifier_for_id(self: *const TSQuery, pattern_index: u32, capture_index: u32) TSQuantifier;
pub extern fn ts_query_string_value_for_id(self: *const TSQuery, index: u32, length: *u32) [*]const u8;
pub extern fn ts_query_disable_capture(self: *TSQuery, name: [*]const u8, length: u32) void;
pub extern fn ts_query_disable_pattern(self: *TSQuery, pattern_index: u32) void;

// Query cursor

pub extern fn ts_query_cursor_new() ?*TSQueryCursor;
pub extern fn ts_query_cursor_delete(self: *TSQueryCursor) void;
pub extern fn ts_query_cursor_exec(self: *TSQueryCursor, query: *const TSQuery, node: TSNode) void;
pub extern fn ts_query_cursor_exec_with_options(self: *TSQueryCursor, query: *const TSQuery, node: TSNode, query_options: ?*const TSQueryCursorOptions) void;
pub extern fn ts_query_cursor_did_exceed_match_limit(self: *const TSQueryCursor) bool;
pub extern fn ts_query_cursor_match_limit(self: *const TSQueryCursor) u32;
pub extern fn ts_query_cursor_set_match_limit(self: *TSQueryCursor, limit: u32) void;
pub extern fn ts_query_cursor_set_byte_range(self: *TSQueryCursor, start_byte: u32, end_byte: u32) bool;
pub extern fn ts_query_cursor_set_point_range(self: *TSQueryCursor, start_point: TSPoint, end_point: TSPoint) bool;
pub extern fn ts_query_cursor_set_containing_byte_range(self: *TSQueryCursor, start_byte: u32, end_byte: u32) bool;
pub extern fn ts_query_cursor_set_containing_point_range(self: *TSQueryCursor, start_point: TSPoint, end_point: TSPoint) bool;
pub extern fn ts_query_cursor_next_match(self: *TSQueryCursor, match: *TSQueryMatch) bool;
pub extern fn ts_query_cursor_remove_match(self: *TSQueryCursor, match_id: u32) void;
pub extern fn ts_query_cursor_next_capture(self: *TSQueryCursor, match: *TSQueryMatch, capture_index: *u32) bool;
pub extern fn ts_query_cursor_set_max_start_depth(self: *TSQueryCursor, max_start_depth: u32) void;

// Language

pub extern fn ts_language_copy(self: *const TSLanguage) *const TSLanguage;
pub extern fn ts_language_delete(self: *const TSLanguage) void;
pub extern fn ts_language_is_parseable(self: *const TSLanguage) bool;
pub extern fn ts_language_symbol_count(self: *const TSLanguage) u32;
pub extern fn ts_language_state_count(self: *const TSLanguage) u32;
pub extern fn ts_language_symbol_for_name(self: *const TSLanguage, string: [*]const u8, length: u32, is_named: bool) TSSymbol;
pub extern fn ts_language_field_count(self: *const TSLanguage) u32;
pub extern fn ts_language_field_name_for_id(self: *const TSLanguage, id: TSFieldId) ?[*:0]const u8;
pub extern fn ts_language_field_id_for_name(self: *const TSLanguage, name: [*]const u8, name_length: u32) TSFieldId;
pub extern fn ts_language_supertypes(self: *const TSLanguage, length: *u32) ?[*]const TSSymbol;
pub extern fn ts_language_subtypes(self: *const TSLanguage, supertype: TSSymbol, length: *u32) ?[*]const TSSymbol;
pub extern fn ts_language_symbol_name(self: *const TSLanguage, symbol: TSSymbol) ?[*:0]const u8;
pub extern fn ts_language_symbol_type(self: *const TSLanguage, symbol: TSSymbol) TSSymbolType;
pub extern fn ts_language_abi_version(self: *const TSLanguage) u32;
pub extern fn ts_language_metadata(self: *const TSLanguage) ?*const TSLanguageMetadata;
pub extern fn ts_language_next_state(self: *const TSLanguage, state: TSStateId, symbol: TSSymbol) TSStateId;
pub extern fn ts_language_name(self: *const TSLanguage) ?[*:0]const u8;

// Lookahead iterator

pub extern fn ts_lookahead_iterator_new(self: *const TSLanguage, state: TSStateId) ?*TSLookaheadIterator;
pub extern fn ts_lookahead_iterator_delete(self: *TSLookaheadIterator) void;
pub extern fn ts_lookahead_iterator_reset_state(self: *TSLookaheadIterator, state: TSStateId) bool;
pub extern fn ts_lookahead_iterator_reset(self: *TSLookaheadIterator, language: *const TSLanguage, state: TSStateId) bool;
pub extern fn ts_lookahead_iterator_language(self: *const TSLookaheadIterator) *const TSLanguage;
pub extern fn ts_lookahead_iterator_next(self: *TSLookaheadIterator) bool;
pub extern fn ts_lookahead_iterator_current_symbol(self: *const TSLookaheadIterator) TSSymbol;
pub extern fn ts_lookahead_iterator_current_symbol_name(self: *const TSLookaheadIterator) [*:0]const u8;

// WebAssembly: only the two entry points this build compiles without it.

pub extern fn ts_wasm_store_delete(store: ?*TSWasmStore) void;
pub extern fn ts_language_is_wasm(language: *const TSLanguage) bool;

// Allocator

pub const MallocFn = *const fn (size: usize) callconv(.c) ?*anyopaque;
pub const CallocFn = *const fn (count: usize, size: usize) callconv(.c) ?*anyopaque;
pub const ReallocFn = *const fn (ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;
pub const FreeFn = *const fn (ptr: ?*anyopaque) callconv(.c) void;

pub extern fn ts_set_allocator(new_malloc: ?MallocFn, new_calloc: ?CallocFn, new_realloc: ?ReallocFn, new_free: ?FreeFn) void;

/// The runtime's current free function: memory the runtime returns to its
/// caller (`ts_node_string`, `ts_tree_included_ranges`,
/// `ts_tree_get_changed_ranges`) is released through it. Declared in
/// `lib/src/alloc.h`, exported by the library.
pub extern var ts_current_free: FreeFn;
