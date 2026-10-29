//! Queries and query cursors.

const std = @import("std");
const c = @import("c.zig");
const types = @import("types.zig");
const node_mod = @import("node.zig");
const language_mod = @import("language.zig");
const predicates = @import("predicates.zig");

const Node = node_mod.Node;

pub const Capture = predicates.Capture;
pub const Property = predicates.Property;
pub const Directive = predicates.Directive;
pub const Arg = predicates.Arg;

/// Where and why `Query.init` failed.
pub const Diagnostic = struct {
    /// Byte offset in the source of a syntax or structure error.
    offset: u32 = 0,
    /// The pattern and predicate name of a predicate error.
    pattern: u32 = 0,
    predicate: []const u8 = "",
};

pub const InitOptions = struct {
    dialect: language_mod.Dialect,
    /// Predicate names (`foo?`) that are neither evaluated nor refused: the
    /// consumer reads them with `Query.predicates`.
    passthrough: []const []const u8 = &.{},
};

/// A compiled query. Immutable after `init`, so one query serves any number
/// of cursors on any number of threads. Keeps the allocator it was given.
pub const Query = struct {
    raw: *c.Query,
    gpa: std.mem.Allocator,
    dialect: language_mod.Dialect,
    patterns: []predicates.Pattern,

    pub const Error = error{
        Syntax,
        NodeType,
        Field,
        Capture,
        Structure,
        Language,
        UnsupportedPredicate,
        InvalidPredicate,
        InvalidPattern,
        OutOfMemory,
    };

    pub fn init(gpa: std.mem.Allocator, lang: language_mod.Language, source: []const u8, options: InitOptions) Error!Query {
        var diagnostic: Diagnostic = .{};
        return initDiagnostic(gpa, lang, source, options, &diagnostic);
    }

    pub fn initDiagnostic(gpa: std.mem.Allocator, lang: language_mod.Language, source: []const u8, options: InitOptions, diagnostic: *Diagnostic) Error!Query {
        var offset: u32 = 0;
        var kind: c.QueryError = .None;
        const raw = c.ts_query_new(lang.ptr, source.ptr, @intCast(source.len), &offset, &kind) orelse {
            diagnostic.offset = offset;
            return switch (kind) {
                .None => error.OutOfMemory,
                .Syntax => error.Syntax,
                .NodeType => error.NodeType,
                .Field => error.Field,
                .Capture => error.Capture,
                .Structure => error.Structure,
                .Language => error.Language,
            };
        };
        errdefer c.ts_query_delete(raw);

        const count = c.ts_query_pattern_count(raw);
        const patterns = try gpa.alloc(predicates.Pattern, count);
        var done: usize = 0;
        errdefer {
            for (patterns[0..done]) |*p| predicates.deinitPattern(gpa, p);
            gpa.free(patterns);
        }
        var failure: predicates.Failure = .{};
        while (done < count) : (done += 1) {
            patterns[done] = predicates.compilePattern(gpa, raw, @intCast(done), options.dialect, options.passthrough, &failure) catch |err| {
                diagnostic.pattern = failure.pattern;
                diagnostic.predicate = failure.name;
                diagnostic.offset = c.ts_query_start_byte_for_pattern(raw, failure.pattern);
                return err;
            };
        }
        return .{ .raw = raw, .gpa = gpa, .dialect = options.dialect, .patterns = patterns };
    }

    pub fn deinit(q: *Query) void {
        for (q.patterns) |*p| predicates.deinitPattern(q.gpa, p);
        q.gpa.free(q.patterns);
        c.ts_query_delete(q.raw);
        q.* = undefined;
    }

    pub fn patternCount(q: *const Query) u32 {
        return c.ts_query_pattern_count(q.raw);
    }

    pub fn captureCount(q: *const Query) u32 {
        return c.ts_query_capture_count(q.raw);
    }

    pub fn stringCount(q: *const Query) u32 {
        return c.ts_query_string_count(q.raw);
    }

    /// A capture's name, without the `@`. Borrowed from the query.
    pub fn captureName(q: *const Query, id: u32) []const u8 {
        var len: u32 = 0;
        const p = c.ts_query_capture_name_for_id(q.raw, id, &len);
        return p[0..len];
    }

    pub fn captureIndex(q: *const Query, name: []const u8) ?u32 {
        var i: u32 = 0;
        while (i < q.captureCount()) : (i += 1) {
            if (std.mem.eql(u8, q.captureName(i), name)) return i;
        }
        return null;
    }

    pub const Quantifier = enum { zero, zero_or_one, zero_or_more, one, one_or_more };

    pub fn captureQuantifier(q: *const Query, pattern: u32, capture: u32) Quantifier {
        return switch (c.ts_query_capture_quantifier_for_id(q.raw, pattern, capture)) {
            .Zero => .zero,
            .ZeroOrOne => .zero_or_one,
            .ZeroOrMore => .zero_or_more,
            .One => .one,
            .OneOrMore => .one_or_more,
        };
    }

    pub fn startByteForPattern(q: *const Query, pattern: u32) u32 {
        return c.ts_query_start_byte_for_pattern(q.raw, pattern);
    }

    pub fn endByteForPattern(q: *const Query, pattern: u32) u32 {
        return c.ts_query_end_byte_for_pattern(q.raw, pattern);
    }

    pub fn isPatternRooted(q: *const Query, pattern: u32) bool {
        return c.ts_query_is_pattern_rooted(q.raw, pattern);
    }

    pub fn isPatternNonLocal(q: *const Query, pattern: u32) bool {
        return c.ts_query_is_pattern_non_local(q.raw, pattern);
    }

    pub fn isPatternGuaranteedAtStep(q: *const Query, byte_offset: u32) bool {
        return c.ts_query_is_pattern_guaranteed_at_step(q.raw, byte_offset);
    }

    /// `(#set! ...)` of a pattern.
    pub fn properties(q: *const Query, pattern: u32) []const Property {
        return q.patterns[pattern].properties;
    }

    /// `(#is? ...)` and `(#is-not? ...)` of a pattern.
    pub fn assertions(q: *const Query, pattern: u32, positive: bool) []const Property {
        return if (positive) q.patterns[pattern].is else q.patterns[pattern].is_not;
    }

    /// Every other `!` of a pattern, in order: `offset!`, `strip!`, ...
    pub fn directives(q: *const Query, pattern: u32) []const Directive {
        return q.patterns[pattern].directives;
    }

    /// Find a property by key, scoped to a capture or not.
    pub fn property(q: *const Query, pattern: u32, key: []const u8, capture: ?u32) ?Property {
        for (q.patterns[pattern].properties) |p| {
            if (std.mem.eql(u8, p.key, key) and p.capture == capture) return p;
        }
        return null;
    }

    /// Stop matching a capture. Mutates the query: do it before sharing.
    pub fn disableCapture(q: *Query, name: []const u8) void {
        c.ts_query_disable_capture(q.raw, name.ptr, @intCast(name.len));
    }

    /// Stop matching a pattern. Mutates the query: do it before sharing.
    pub fn disablePattern(q: *Query, pattern: u32) void {
        c.ts_query_disable_pattern(q.raw, pattern);
    }
};

/// One match: a pattern and its captures, valid until the next call to the
/// iterator that returned it.
pub const Match = struct {
    id: u32,
    pattern: u16,
    captures: []const Capture,

    fn fromC(m: c.QueryMatch) Match {
        const caps: []const Capture = if (m.captures) |p| @as([*]const Capture, @ptrCast(p))[0..m.capture_count] else &.{}; // aegis: no-danger: Capture has c.QueryCapture's layout, asserted in predicates.zig
        return .{ .id = m.id, .pattern = m.pattern_index, .captures = caps };
    }

    /// The nodes captured under `index`.
    pub fn nodes(m: Match, index: u32) NodeIterator {
        return .{ .captures = m.captures, .index = index };
    }

    pub const NodeIterator = struct {
        captures: []const Capture,
        index: u32,
        at: usize = 0,

        pub fn next(it: *NodeIterator) ?Node {
            while (it.at < it.captures.len) {
                const cap = it.captures[it.at];
                it.at += 1;
                if (cap.index == it.index) return cap.node;
            }
            return null;
        }
    };
};

/// A query cursor: runs a query over a node. One thread at a time; reuse it
/// for any number of queries and trees. Holds about 72 KB of working memory
/// so that matching allocates nothing.
pub const Cursor = struct {
    raw: *c.QueryCursor,
    gpa: std.mem.Allocator,
    scratch: *predicates.Scratch,
    progress: Progress = .{},
    /// The runtime keeps a pointer to this for the length of an iteration.
    options: c.QueryCursorOptions = .{ .payload = null, .progress_callback = null },

    pub fn init(gpa: std.mem.Allocator) error{OutOfMemory}!Cursor {
        const scratch = try gpa.create(predicates.Scratch);
        // The matcher's sparse sets are read before they are written; give
        // them defined contents once.
        @memset(std.mem.asBytes(&scratch.matcher.lists), 0);
        return .{ .raw = c.ts_query_cursor_new() orelse unreachable, .gpa = gpa, .scratch = scratch };
    }

    pub fn deinit(cur: *Cursor) void {
        c.ts_query_cursor_delete(cur.raw);
        cur.gpa.destroy(cur.scratch);
        cur.* = undefined;
    }

    /// Restrict matches to those intersecting this byte range.
    pub fn setByteRange(cur: *Cursor, start: u32, end: u32) void {
        _ = c.ts_query_cursor_set_byte_range(cur.raw, start, end);
    }

    pub fn setPointRange(cur: *Cursor, start: types.Point, end: types.Point) void {
        _ = c.ts_query_cursor_set_point_range(cur.raw, .{ .row = start.row, .column = start.column }, .{ .row = end.row, .column = end.column });
    }

    /// Restrict matches to those whose nodes contain this byte range.
    pub fn setContainingByteRange(cur: *Cursor, start: u32, end: u32) void {
        _ = c.ts_query_cursor_set_containing_byte_range(cur.raw, start, end);
    }

    pub fn setContainingPointRange(cur: *Cursor, start: types.Point, end: types.Point) void {
        _ = c.ts_query_cursor_set_containing_point_range(cur.raw, .{ .row = start.row, .column = start.column }, .{ .row = end.row, .column = end.column });
    }

    /// Bound the matches in progress at once. Neovim and Helix use 256.
    pub fn setMatchLimit(cur: *Cursor, limit: u32) void {
        c.ts_query_cursor_set_match_limit(cur.raw, limit);
    }

    pub fn matchLimit(cur: *const Cursor) u32 {
        return c.ts_query_cursor_match_limit(cur.raw);
    }

    pub fn didExceedMatchLimit(cur: *const Cursor) bool {
        return c.ts_query_cursor_did_exceed_match_limit(cur.raw);
    }

    pub fn setMaxStartDepth(cur: *Cursor, depth: ?u32) void {
        c.ts_query_cursor_set_max_start_depth(cur.raw, depth orelse std.math.maxInt(u32));
    }

    pub const IterateOptions = struct {
        /// Stop with `error.Paused` once this time has passed.
        deadline: ?std.Io.Clock.Timestamp = null,
    };

    fn exec(cur: *Cursor, io: std.Io, query: *const Query, start: Node, options: IterateOptions) void {
        cur.progress = .{ .io = io, .deadline = options.deadline };
        cur.options = .{ .payload = &cur.progress, .progress_callback = Progress.check };
        c.ts_query_cursor_exec_with_options(cur.raw, query.raw, start.raw, &cur.options);
    }

    /// Iterate the matches of `query` under `start`, filtered by its
    /// predicates. Node text for predicates is read from `input`, which must
    /// be the text the tree was parsed from. A cancellation point on `io`.
    pub fn matches(cur: *Cursor, io: std.Io, query: *const Query, start: Node, input: types.Input, options: IterateOptions) Matches {
        cur.exec(io, query, start, options);
        return .{ .io = io, .cursor = cur, .query = query, .input = input };
    }

    /// Iterate the captures of `query` under `start` in document order,
    /// filtered by its predicates.
    pub fn captures(cur: *Cursor, io: std.Io, query: *const Query, start: Node, input: types.Input, options: IterateOptions) Captures {
        cur.exec(io, query, start, options);
        return .{ .io = io, .cursor = cur, .query = query, .input = input };
    }
};

/// `Canceled` and `Paused` stop an iteration, which a later call resumes
/// after `Paused`. `TooManySteps`: a `lua-match?` search ran past its step
/// budget (`lua_pattern.step_budget`); its match is dropped undecided, and a
/// later call goes on with the next.
pub const IterateError = error{ Canceled, Paused } || predicates.EvalError;

pub const Matches = struct {
    io: std.Io,
    cursor: *Cursor,
    query: *const Query,
    input: types.Input,

    pub fn next(it: *Matches) IterateError!?Match {
        var raw: c.QueryMatch = undefined;
        while (c.ts_query_cursor_next_match(it.cursor.raw, &raw)) {
            const m = Match.fromC(raw);
            if (try predicates.satisfies(it.io, it.query.patterns[m.pattern].filters, m.captures, it.input, it.query.dialect, it.cursor.scratch)) return m;
        }
        if (it.cursor.progress.stopped) |err| return err;
        return null;
    }
};

pub const CaptureEvent = struct {
    match: Match,
    /// Which of `match.captures` this event is.
    index: u32,

    pub fn capture(e: CaptureEvent) Capture {
        return e.match.captures[e.index];
    }

    pub fn node(e: CaptureEvent) Node {
        return e.match.captures[e.index].node;
    }
};

pub const Captures = struct {
    io: std.Io,
    cursor: *Cursor,
    query: *const Query,
    input: types.Input,
    /// The last match that passed its predicates: captures of one match
    /// arrive one by one, and its predicates need checking once.
    passed: ?u32 = null,

    pub fn next(it: *Captures) IterateError!?CaptureEvent {
        var raw: c.QueryMatch = undefined;
        var index: u32 = 0;
        while (c.ts_query_cursor_next_capture(it.cursor.raw, &raw, &index)) {
            const m = Match.fromC(raw);
            if (it.passed != m.id) {
                const passes = predicates.satisfies(it.io, it.query.patterns[m.pattern].filters, m.captures, it.input, it.query.dialect, it.cursor.scratch) catch |err| {
                    // Undecided: dropped, so a later call goes on with the next match.
                    c.ts_query_cursor_remove_match(it.cursor.raw, m.id);
                    return err;
                };
                if (!passes) {
                    c.ts_query_cursor_remove_match(it.cursor.raw, m.id);
                    continue;
                }
                it.passed = m.id;
            }
            return .{ .match = m, .index = index };
        }
        if (it.cursor.progress.stopped) |err| return err;
        return null;
    }
};

const Progress = struct {
    io: ?std.Io = null,
    deadline: ?std.Io.Clock.Timestamp = null,
    stopped: ?IterateError = null,

    fn check(state: *c.QueryCursorState) callconv(.c) bool {
        const self: *Progress = @ptrCast(@alignCast(state.payload.?)); // aegis: boundary: the runtime hands back the payload it was given: the cursor's own Progress
        const io = self.io orelse return false;
        io.checkCancel() catch {
            self.stopped = error.Canceled;
            return true;
        };
        if (self.deadline) |d| {
            if (std.Io.Clock.Timestamp.now(io, d.clock).compare(.gte, d)) {
                self.stopped = error.Paused;
                return true;
            }
        }
        return false;
    }
};
