//! Definitions and references from a tags query.
//!
//! The convention is tree-sitter's (`crates/tags` in the tree-sitter
//! repository, used by GitHub's code navigation): a pattern captures the tag's
//! node as `@definition.<kind>` or `@reference.<kind>` and its name as
//! `@name`; `@doc` captures documentation.
//!
//! Not yet applied: the `strip!` and `select-adjacent!` directives on docs,
//! and the locals query that drops references to local definitions. Both are
//! readable from the query (`Query.directives`) for a consumer that needs
//! them now.

const std = @import("std");
const types = @import("types.zig");
const node_mod = @import("node.zig");
const language_mod = @import("language.zig");
const query_mod = @import("query.zig");

const Query = query_mod.Query;

pub const Role = enum { definition, reference };

pub const Tag = struct {
    role: Role,
    /// The part after `definition.` or `reference.`: `function`, `class`,
    /// `call`. Borrowed from the query.
    kind: []const u8,
    /// The name's range.
    name: types.Range,
    /// The whole tagged node's range.
    node: types.Range,
    /// The documentation's range, when the pattern captures one.
    doc: ?types.Range,
    pattern: u16,
};

/// A compiled tags query and what each of its captures means. Immutable, so
/// one serves any number of threads, each with its own `QueryCursor`.
pub const Tags = struct {
    query: Query,
    meaning: []Meaning,

    const Meaning = union(enum) {
        none,
        name,
        doc,
        tag: struct { role: Role, kind: []const u8 },
    };

    pub fn init(gpa: std.mem.Allocator, lang: language_mod.Language, text: language_mod.QueryText) Query.Error!Tags {
        var query = try Query.init(gpa, lang, text.text, .{ .dialect = text.dialect });
        errdefer query.deinit();
        const meaning = try gpa.alloc(Meaning, query.captureCount());
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
        return .{ .query = query, .meaning = meaning };
    }

    pub fn deinit(t: *Tags) void {
        t.query.gpa.free(t.meaning);
        t.query.deinit();
        t.* = undefined;
    }

    /// Append the tags under `root` to `out`, in match order.
    pub fn collect(
        t: *const Tags,
        gpa: std.mem.Allocator,
        io: std.Io,
        cursor: *query_mod.Cursor,
        root: node_mod.Node,
        input: types.Input,
        out: *std.ArrayList(Tag),
    ) (query_mod.IterateError || error{OutOfMemory})!void {
        var matches = cursor.matches(io, &t.query, root, input, .{});
        while (try matches.next()) |m| {
            var name: ?types.Range = null;
            var tagged: ?struct { role: Role, kind: []const u8, range: types.Range } = null;
            var doc: ?types.Range = null;
            for (m.captures) |cap| switch (t.meaning[cap.index]) {
                .none => {},
                .name => name = cap.node.range(),
                .doc => {
                    const r = cap.node.range();
                    doc = if (doc) |d| .{
                        .start_point = d.start_point,
                        .start_byte = d.start_byte,
                        .end_point = r.end_point,
                        .end_byte = r.end_byte,
                    } else r;
                },
                .tag => |info| tagged = .{ .role = info.role, .kind = info.kind, .range = cap.node.range() },
            };
            const tag = tagged orelse continue;
            try out.append(gpa, .{
                .role = tag.role,
                .kind = tag.kind,
                .name = name orelse tag.range,
                .node = tag.range,
                .doc = doc,
                .pattern = m.pattern,
            });
        }
    }
};
