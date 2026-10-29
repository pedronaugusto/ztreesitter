//! tree-sitter for Zig: the vendored runtime, a Zig API over it, query
//! predicates in tree-sitter's and Neovim's dialects, tags, and a
//! document's injected layers.
//!
//! Grammars are not part of this module. An application compiles the ones it
//! wants with `addGrammars` in its `build.zig` and passes the resulting
//! `Grammar` values to whatever needs them.

const std = @import("std");
const options = @import("ztreesitter_options");

pub const c = @import("c.zig");
const types = @import("types.zig");
const memory = @import("memory.zig");
const language = @import("language.zig");
const parser = @import("parser.zig");
const tree = @import("tree.zig");
const node = @import("node.zig");
const cursor = @import("cursor.zig");
const query = @import("query.zig");
const tags = @import("tags.zig");
const layers = @import("layers.zig");

pub const Point = types.Point;
pub const Range = types.Range;
pub const InputEdit = types.InputEdit;
pub const Input = types.Input;
pub const Encoding = types.Encoding;

pub const setAllocator = memory.setAllocator;
pub const resetAllocator = memory.resetAllocator;

pub const Language = language.Language;
pub const Grammar = language.Grammar;
pub const Dialect = language.Dialect;
pub const QueryText = language.QueryText;
pub const Parser = parser.Parser;
pub const ParseOptions = parser.ParseOptions;
pub const Tree = tree.Tree;
pub const ChangedRanges = tree.ChangedRanges;
pub const Node = node.Node;
pub const TreeCursor = cursor.TreeCursor;
pub const Query = query.Query;
pub const QueryDiagnostic = query.Diagnostic;
pub const QueryCursor = query.Cursor;
pub const Capture = query.Capture;
pub const Match = query.Match;
pub const Property = query.Property;
pub const Directive = query.Directive;
pub const CaptureEvent = query.CaptureEvent;
pub const IterateError = query.IterateError;
pub const Tags = tags.Tags;
pub const Tag = tags.Tag;
pub const Layers = layers.Layers;
pub const Layer = layers.Layer;
pub const LayersOptions = layers.Options;
pub const LayersUpdateOptions = layers.UpdateOptions;
pub const LayersSnapshot = layers.Snapshot;
pub const InjectionResolver = layers.Resolver;

/// This package's version, from `build.zig.zon`.
pub const version = options.version;
/// The vendored runtime's version.
pub const runtime_version = "0.27.1";
/// The ABI versions of `parser.c` this runtime reads.
pub const min_language_version = c.min_compatible_language_version;
pub const max_language_version = c.language_version;

test {
    _ = @import("abi_check.zig");
    _ = @import("regex.zig");
    _ = @import("lua_pattern.zig");
    _ = @import("predicates.zig");
    _ = @import("types.zig");
    std.testing.refAllDecls(@This());
}
