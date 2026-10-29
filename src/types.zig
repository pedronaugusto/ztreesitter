//! Value types shared by the API: positions, ranges, edits and text input.

const std = @import("std");
const c = @import("c.zig");

/// A row and a column, both zero-based. The column counts bytes.
pub const Point = extern struct {
    row: u32 = 0,
    column: u32 = 0,

    pub fn order(a: Point, b: Point) std.math.Order {
        if (a.row != b.row) return std.math.order(a.row, b.row);
        return std.math.order(a.column, b.column);
    }

    comptime {
        std.debug.assert(@sizeOf(Point) == @sizeOf(c.Point));
    }
};

/// A span of text in both byte offsets and points. Same layout as `TSRange`.
pub const Range = extern struct {
    start_point: Point = .{},
    end_point: Point = .{},
    start_byte: u32 = 0,
    end_byte: u32 = 0,

    /// A range covering every byte, for callers that address by byte only.
    pub const everything: Range = .{
        .end_point = .{ .row = std.math.maxInt(u32), .column = std.math.maxInt(u32) },
        .end_byte = std.math.maxInt(u32),
    };

    comptime {
        std.debug.assert(@sizeOf(Range) == @sizeOf(c.Range));
        std.debug.assert(@offsetOf(Range, "start_byte") == @offsetOf(c.Range, "start_byte"));
    }
};

/// One edit to a text a tree was parsed from: the bytes from `start_byte`
/// to `old_end_byte` were replaced by bytes ending at `new_end_byte`.
pub const InputEdit = extern struct {
    start_byte: u32,
    old_end_byte: u32,
    new_end_byte: u32,
    start_point: Point,
    old_end_point: Point,
    new_end_point: Point,

    comptime {
        std.debug.assert(@sizeOf(InputEdit) == @sizeOf(c.InputEdit));
    }
};

pub const Encoding = enum {
    utf8,
    utf16le,
    utf16be,

    pub fn toC(e: Encoding) c.InputEncoding {
        return switch (e) {
            .utf8 => .UTF8,
            .utf16le => .UTF16LE,
            .utf16be => .UTF16BE,
        };
    }
};

/// The text a tree is parsed from, and that predicates and tags read node
/// text from. The caller owns it; nothing here copies a document.
pub const Input = union(enum) {
    /// The whole text, contiguous.
    slice: []const u8,
    /// Text in chunks: a rope, a gap buffer, a file read on demand.
    reader: Reader,

    pub const Reader = struct {
        context: *anyopaque,
        /// The bytes starting at `byte`, as many as are contiguous there; an
        /// empty slice at or past the end. `point` is the position of `byte`
        /// and may be ignored. The slice must stay valid until the next call.
        read: *const fn (context: *anyopaque, byte: u32, point: Point) []const u8,
        encoding: Encoding = .utf8,
    };

    pub fn encoding(input: Input) Encoding {
        return switch (input) {
            .slice => .utf8,
            .reader => |r| r.encoding,
        };
    }

    /// Copy the bytes of `[start, end)` into `buffer`, returning how many fit.
    pub fn copy(input: Input, start: u32, end: u32, buffer: []u8) []u8 {
        switch (input) {
            .slice => |s| {
                const lo = @min(start, s.len);
                const hi = @min(end, s.len);
                const n = @min(hi - lo, buffer.len);
                @memcpy(buffer[0..n], s[lo..][0..n]);
                return buffer[0..n];
            },
            .reader => |r| {
                var filled: usize = 0;
                var at = start;
                while (at < end and filled < buffer.len) {
                    const chunk = r.read(r.context, at, .{});
                    if (chunk.len == 0) break;
                    const n = @min(chunk.len, end - at, buffer.len - filled);
                    @memcpy(buffer[filled..][0..n], chunk[0..n]);
                    filled += n;
                    at += @intCast(n);
                }
                return buffer[0..filled];
            },
        }
    }

    /// Visit the bytes of `[start, end)` chunk by chunk, without copying.
    /// `visit` returns false to stop.
    pub fn chunks(input: Input, start: u32, end: u32, context: anytype, comptime visit: fn (@TypeOf(context), []const u8) bool) void {
        switch (input) {
            .slice => |s| {
                const lo = @min(start, s.len);
                const hi = @min(end, s.len);
                _ = visit(context, s[lo..hi]);
            },
            .reader => |r| {
                var at = start;
                while (at < end) {
                    const chunk = r.read(r.context, at, .{});
                    if (chunk.len == 0) return;
                    const n: u32 = @intCast(@min(chunk.len, end - at));
                    if (!visit(context, chunk[0..n])) return;
                    at += n;
                }
            },
        }
    }
};

test "Input copies from a slice and from a reader alike" {
    const text = "hello, world";
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("world", (Input{ .slice = text }).copy(7, 12, &buf));

    const Pieces = struct {
        fn read(_: *anyopaque, byte: u32, _: Point) []const u8 {
            // Three-byte chunks.
            if (byte >= text.len) return "";
            return text[byte..@min(text.len, (byte / 3 + 1) * 3)];
        }
    };
    var dummy: u8 = 0;
    const reader: Input = .{ .reader = .{ .context = &dummy, .read = Pieces.read } };
    try std.testing.expectEqualStrings("lo, wor", reader.copy(3, 10, &buf));
    try std.testing.expectEqualStrings("lo,", reader.copy(3, 10, buf[0..3]));
}
