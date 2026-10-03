//! Parse and tags-query throughput on real files.
//!
//!     zig build bench -Doptimize=ReleaseFast -Dgrammars=c,swift -- c big.c swift big.swift
//!
//! For each (grammar, file) pair: the best of five full parses, and the best
//! of five parse-plus-tags runs, in MB/s. Tags are the grammar's own query,
//! or Helix's, as the catalogue chose.

const std = @import("std");
const ts = @import("ztreesitter");
const grammars = @import("grammars");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3 or (args.len - 1) % 2 != 0) {
        std.debug.print("usage: throughput GRAMMAR FILE [GRAMMAR FILE...]\n", .{});
        return;
    }
    std.debug.print("{s:<12} {s:<36} {s:>9} {s:>10} {s:>12} {s:>7}\n", .{ "grammar", "file", "MB", "parse MB/s", "+tags MB/s", "tags" });
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const name = args[i];
        const path = args[i + 1];
        const g = for (grammars.list) |g| {
            if (std.mem.eql(u8, g.name, name)) break g;
        } else {
            std.debug.print("{s}: not built; add it to -Dgrammars\n", .{name});
            continue;
        };
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(text);
        const mb = @as(f64, @floatFromInt(text.len)) / (1024 * 1024);

        var parser: ts.Parser = .init();
        defer parser.deinit();
        try parser.setLanguage(g.language());

        var best_parse: f64 = std.math.inf(f64);
        for (0..5) |_| {
            const t0 = std.Io.Clock.Timestamp.now(io, .awake);
            var tree = try parser.parse(io, .{ .slice = text }, null, .{});
            const dt = seconds(t0.durationTo(std.Io.Clock.Timestamp.now(io, .awake)));
            tree.deinit();
            best_parse = @min(best_parse, dt);
        }

        var best_tags: f64 = std.math.nan(f64);
        var tag_count: usize = 0;
        if (g.queries.tags) |q| {
            var tags = try ts.Tags.init(gpa, g.language(), q);
            defer tags.deinit();
            var cursor = try ts.QueryCursor.init(gpa);
            defer cursor.deinit();
            var out: std.ArrayList(ts.Tag) = .empty;
            defer out.deinit(gpa);
            best_tags = std.math.inf(f64);
            for (0..5) |_| {
                out.clearRetainingCapacity();
                const t0 = std.Io.Clock.Timestamp.now(io, .awake);
                var tree = try parser.parse(io, .{ .slice = text }, null, .{});
                try tags.collect(gpa, io, &cursor, tree.rootNode(), .{ .slice = text }, &out);
                const dt = seconds(t0.durationTo(std.Io.Clock.Timestamp.now(io, .awake)));
                tree.deinit();
                best_tags = @min(best_tags, dt);
            }
            tag_count = out.items.len;
        }
        std.debug.print("{s:<12} {s:<36} {d:>9.2} {d:>10.1} {d:>12.1} {d:>7}\n", .{
            name, std.fs.path.basename(path), mb, mb / best_parse, mb / best_tags, tag_count,
        });
    }
}

fn seconds(d: std.Io.Clock.Duration) f64 {
    return @as(f64, @floatFromInt(d.raw.nanoseconds)) / 1e9;
}
