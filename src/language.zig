//! A grammar's compiled language, and the `Grammar` values `addGrammars`
//! generates around it.

const std = @import("std");
const c = @import("c.zig");

/// A parser's language: the tables a grammar's `parser.c` compiles to.
///
/// A linked language is static data, valid for the process and shareable
/// across threads. A loaded one (`load`) is valid until `unload`.
pub const Language = struct {
    ptr: *const c.Language,
    library: ?std.DynLib = null,

    pub fn fromC(ptr: *const c.Language) Language {
        return .{ .ptr = ptr };
    }

    pub const LoadError = error{ LibraryNotFound, SymbolNotFound } || std.DynLib.Error;

    /// Open a grammar built as a shared library (`addGrammars` with
    /// `.linkage = .dynamic`) and find `symbol`, e.g. `tree_sitter_zig`.
    pub fn load(path: []const u8, symbol: [:0]const u8) LoadError!Language {
        var lib = try std.DynLib.open(path);
        errdefer lib.close();
        const f = lib.lookup(*const fn () callconv(.c) *const c.Language, symbol) orelse return error.SymbolNotFound;
        return .{ .ptr = f(), .library = lib };
    }

    /// Close a loaded language's library. Every tree, query and parser using
    /// it must be gone first. Nothing for a linked language.
    pub fn unload(language: *Language) void {
        if (language.library) |*lib| lib.close();
        language.library = null;
    }

    /// The `LANGUAGE_VERSION` the grammar was generated with.
    pub fn abiVersion(language: Language) u32 {
        return c.ts_language_abi_version(language.ptr);
    }

    /// The grammar's name, for ABI 15 grammars; null before that.
    pub fn name(language: Language) ?[]const u8 {
        return if (c.ts_language_name(language.ptr)) |n| std.mem.span(n) else null;
    }

    pub fn metadata(language: Language) ?std.SemanticVersion {
        const m = c.ts_language_metadata(language.ptr) orelse return null;
        return .{ .major = m.major_version, .minor = m.minor_version, .patch = m.patch_version };
    }

    pub fn symbolCount(language: Language) u32 {
        return c.ts_language_symbol_count(language.ptr);
    }

    pub fn stateCount(language: Language) u32 {
        return c.ts_language_state_count(language.ptr);
    }

    pub fn symbolName(language: Language, symbol: u16) ?[]const u8 {
        return if (c.ts_language_symbol_name(language.ptr, symbol)) |n| std.mem.span(n) else null;
    }

    /// The symbol for a node kind, or null when the grammar has none.
    pub fn symbolForName(language: Language, kind: []const u8, named: bool) ?u16 {
        const s = c.ts_language_symbol_for_name(language.ptr, kind.ptr, @intCast(kind.len), named);
        return if (s == 0) null else s;
    }

    pub const SymbolType = enum { regular, anonymous, supertype, auxiliary };

    pub fn symbolType(language: Language, symbol: u16) SymbolType {
        return switch (c.ts_language_symbol_type(language.ptr, symbol)) {
            .Regular => .regular,
            .Anonymous => .anonymous,
            .Supertype => .supertype,
            .Auxiliary => .auxiliary,
        };
    }

    pub fn fieldCount(language: Language) u32 {
        return c.ts_language_field_count(language.ptr);
    }

    pub fn fieldName(language: Language, id: u16) ?[]const u8 {
        return if (c.ts_language_field_name_for_id(language.ptr, id)) |n| std.mem.span(n) else null;
    }

    pub fn fieldId(language: Language, field: []const u8) ?u16 {
        const id = c.ts_language_field_id_for_name(language.ptr, field.ptr, @intCast(field.len));
        return if (id == 0) null else id;
    }

    pub fn supertypes(language: Language) []const u16 {
        var n: u32 = 0;
        const p = c.ts_language_supertypes(language.ptr, &n) orelse return &.{};
        return p[0..n];
    }

    pub fn subtypes(language: Language, supertype: u16) []const u16 {
        var n: u32 = 0;
        const p = c.ts_language_subtypes(language.ptr, supertype, &n) orelse return &.{};
        return p[0..n];
    }

    pub fn nextState(language: Language, state: u16, symbol: u16) u16 {
        return c.ts_language_next_state(language.ptr, state, symbol);
    }
};

/// Which predicate dialect a query is written in. The same predicate names
/// mean different regular expressions in each.
pub const Dialect = enum {
    /// nvim-treesitter's queries: `match?` is a Vim regular expression in
    /// very-magic mode, `lua-match?` a Lua pattern.
    neovim,
    /// tree-sitter's, used by grammar repositories and Helix: `match?` is a
    /// Rust `regex`-style expression.
    tree_sitter,
};

/// One query's text, with the dialect it is written in.
pub const QueryText = struct {
    dialect: Dialect,
    text: []const u8,
};

/// A grammar as `addGrammars` generates it: the language, its queries, and
/// where it comes from.
pub const Grammar = struct {
    /// The catalogue's name, which is also the language name in injections.
    name: []const u8,
    /// The function `parser.c` exports. Null when the grammar was built as a
    /// shared library; load it with `Language.load(path, symbol)`.
    language_fn: ?*const fn () callconv(.c) *const c.Language = null,
    symbol: []const u8,
    /// SPDX identifier, or "unknown".
    licence: []const u8,
    url: []const u8,
    commit: []const u8,
    queries: Queries = .{},

    pub const Queries = struct {
        highlights: ?QueryText = null,
        injections: ?QueryText = null,
        locals: ?QueryText = null,
        folds: ?QueryText = null,
        indents: ?QueryText = null,
        tags: ?QueryText = null,
    };

    /// The linked language. Panics for a grammar built as a shared library.
    pub fn language(grammar: *const Grammar) Language {
        const f = grammar.language_fn orelse std.debug.panic("grammar {s} is a shared library; use Language.load", .{grammar.name});
        return .{ .ptr = f() };
    }
};
