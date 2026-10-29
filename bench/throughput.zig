//! Parse and tags-query throughput, measured through shakedown: for each
//! grammar built, `parse/<grammar>` parses its sample repeated to about
//! 1 MiB, and `tags/<grammar>` parses it and collects its tags, when the
//! catalogue gives the grammar a tags query. One row each; a unit is one pass.
//!
//!   throughput [--smoke] [--row <prefix>]

const std = @import("std");
const Io = std.Io;
const ts = @import("ztreesitter");
const grammars = @import("grammars");
const samples = @import("samples");
const shakedown = @import("shakedown");
const provenance = @import("preflight_bench_options");

const target_len = 1 << 20;

const Error = ts.Parser.ParseError || ts.IterateError || std.mem.Allocator.Error;

const Work = struct {
    gpa: std.mem.Allocator,
    io: Io,
    text: []const u8,
    parser: ts.Parser,
    tags: ?ts.Tags,
    cursor: ts.QueryCursor,
    out: std.ArrayList(ts.Tag) = .empty,
    docs: std.ArrayList(ts.Range) = .empty,

    fn parse(w: *Work, units: u64) Error!void {
        for (0..units) |_| {
            var tree = try w.parser.parse(w.io, .{ .slice = w.text }, null, .{});
            tree.deinit();
        }
    }

    fn tagged(w: *Work, units: u64) Error!void {
        for (0..units) |_| {
            w.out.clearRetainingCapacity();
            w.docs.clearRetainingCapacity();
            var tree = try w.parser.parse(w.io, .{ .slice = w.text }, null, .{});
            defer tree.deinit();
            try w.tags.?.collect(w.gpa, w.io, &w.cursor, tree.rootNode(), .{ .slice = w.text }, &w.out, &w.docs);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    const options = try shakedown.bench.Options.fromArguments(arguments[1..]);
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buffer);

    for (grammars.list) |g| {
        const sample = samples.find(g.name) orelse continue;
        // The sample repeated: one text the size of a large source file.
        const copies = if (options.smoke) 1 else @max(1, target_len / sample.len);
        const text = try arena.alloc(u8, sample.len * copies);
        for (0..copies) |i| @memcpy(text[i * sample.len ..][0..sample.len], sample);

        var work: Work = .{ .gpa = gpa, .io = io, .text = text, .parser = .init(), .tags = null, .cursor = try .init(gpa) };
        defer {
            work.out.deinit(gpa);
            work.docs.deinit(gpa);
            work.cursor.deinit();
            if (work.tags) |*t| t.deinit();
            work.parser.deinit();
        }
        try work.parser.setLanguage(g.language());
        if (g.queries.tags) |q| work.tags = try ts.Tags.init(gpa, g.language(), q, .{ .locals = g.queries.locals });

        var rows: std.ArrayList(shakedown.bench.Row(Work, Error)) = .empty;
        try rows.append(arena, .{ .name = try arena.print("parse/{s}", .{g.name}), .unit = "pass", .run = Work.parse });
        if (work.tags != null) try rows.append(arena, .{ .name = try arena.print("tags/{s}", .{g.name}), .unit = "pass", .run = Work.tagged });
        try shakedown.bench.run(Error, gpa, io, &stdout.interface, &work, rows.items, .{ .commit = provenance.commit }, options);
    }
    try stdout.interface.flush();
}
