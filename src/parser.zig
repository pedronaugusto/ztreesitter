//! A parser: text in, tree out.

const std = @import("std");
const c = @import("c.zig");
const types = @import("types.zig");
const tree = @import("tree.zig");
const language_mod = @import("language.zig");

pub const ParseOptions = struct {
    /// Stop with `error.Paused` once this time has passed. Calling `parse`
    /// again with the same input and old tree resumes where it stopped.
    deadline: ?std.Io.Clock.Timestamp = null,
};

/// A parser. One thread at a time; reusable across texts and languages.
pub const Parser = struct {
    raw: *c.Parser,

    pub fn init() Parser {
        return .{ .raw = c.ts_parser_new() orelse unreachable }; // the runtime aborts rather than return NULL
    }

    pub fn deinit(p: *Parser) void {
        c.ts_parser_delete(p.raw);
        p.* = undefined;
    }

    pub const LanguageError = error{IncompatibleVersion};

    /// Set the language. Fails when the grammar's ABI version is outside
    /// what this runtime reads (`min_language_version` to
    /// `max_language_version`).
    pub fn setLanguage(p: *Parser, lang: language_mod.Language) LanguageError!void {
        if (!c.ts_parser_set_language(p.raw, lang.ptr)) return error.IncompatibleVersion;
    }

    pub fn language(p: *const Parser) ?language_mod.Language {
        return if (c.ts_parser_language(p.raw)) |l| .{ .ptr = l } else null;
    }

    pub const RangesError = error{OverlappingRanges};

    /// Parse only these ranges of the text, in order and not overlapping;
    /// empty means the whole text. Nodes keep absolute positions.
    pub fn setIncludedRanges(p: *Parser, ranges: []const types.Range) RangesError!void {
        const ptr: ?[*]const c.Range = if (ranges.len == 0) null else @ptrCast(ranges.ptr); // aegis: no-danger: Range has c.Range's layout, asserted in types.zig
        if (!c.ts_parser_set_included_ranges(p.raw, ptr, @intCast(ranges.len))) return error.OverlappingRanges;
    }

    /// The included ranges. Borrowed from the parser until the next change.
    pub fn includedRanges(p: *const Parser) []const types.Range {
        var n: u32 = 0;
        const ptr = c.ts_parser_included_ranges(p.raw, &n);
        return @as([*]const types.Range, @ptrCast(ptr))[0..n]; // aegis: no-danger: Range has c.Range's layout, asserted in types.zig
    }

    /// Forget a paused or cancelled parse, so the next call starts afresh.
    pub fn reset(p: *Parser) void {
        c.ts_parser_reset(p.raw);
    }

    pub const ParseError = error{
        /// The Io was cancelled. The parser can resume the same parse.
        Canceled,
        /// `options.deadline` passed. The parser can resume the same parse.
        Paused,
        /// No language set.
        NoLanguage,
    };

    /// Parse `input`. With `old`, the edited tree of a previous version of
    /// the text, unchanged parts are reused. A cancellation point on `io`.
    pub fn parse(p: *Parser, io: std.Io, input: types.Input, old: ?*const tree.Tree, options: ParseOptions) ParseError!tree.Tree {
        if (c.ts_parser_language(p.raw) == null) return error.NoLanguage;
        var progress: Progress = .{ .io = io, .deadline = options.deadline };
        var source: Source = .{ .input = input };
        const raw_input: c.Input = .{
            .payload = &source,
            .read = Source.read,
            .encoding = input.encoding().toC(),
            .decode = null,
        };
        const result = c.ts_parser_parse_with_options(p.raw, if (old) |o| o.raw else null, raw_input, .{
            .payload = &progress,
            .progress_callback = Progress.check,
        });
        if (result) |t| return .{ .raw = t };
        return progress.stopped orelse unreachable; // the runtime only halts when asked to
    }

    /// Parse a contiguous UTF-8 text without cancellation or deadline.
    pub fn parseSlice(p: *Parser, text: []const u8, old: ?*const tree.Tree) error{NoLanguage}!tree.Tree {
        if (c.ts_parser_language(p.raw) == null) return error.NoLanguage;
        const t = c.ts_parser_parse_string(p.raw, if (old) |o| o.raw else null, text.ptr, @intCast(text.len)) orelse unreachable;
        return .{ .raw = t };
    }
};

const Progress = struct {
    io: std.Io,
    deadline: ?std.Io.Clock.Timestamp,
    stopped: ?Parser.ParseError = null,

    fn check(state: *c.ParseState) callconv(.c) bool {
        const self: *Progress = @ptrCast(@alignCast(state.payload.?)); // aegis: boundary: the runtime hands back the payload it was given: the Progress `parse` installed
        self.io.checkCancel() catch {
            self.stopped = error.Canceled;
            return true;
        };
        if (self.deadline) |d| {
            if (std.Io.Clock.Timestamp.now(self.io, d.clock).compare(.gte, d)) {
                self.stopped = error.Paused;
                return true;
            }
        }
        return false;
    }
};

const Source = struct {
    input: types.Input,

    fn read(payload: ?*anyopaque, byte: u32, position: c.Point, bytes_read: *u32) callconv(.c) ?[*]const u8 {
        const self: *Source = @ptrCast(@alignCast(payload.?)); // aegis: boundary: the runtime hands back the payload it was given: the Source `parse` installed
        const chunk: []const u8 = switch (self.input) {
            .slice => |s| if (byte < s.len) s[byte..] else "",
            .reader => |r| r.read(r, byte, .{ .row = position.row, .column = position.column }),
        };
        bytes_read.* = @intCast(@min(chunk.len, std.math.maxInt(u32)));
        return chunk.ptr;
    }
};
