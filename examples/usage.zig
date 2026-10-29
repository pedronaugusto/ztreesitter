const std = @import("std");
const ts = @import("ztreesitter");
const grammars = @import("grammars"); // made by addGrammars, see Install

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const out = &stdout.interface;
    if (@hasDecl(grammars, "zig")) {
        try run(init.gpa, init.io, out);
    } else {
        try out.writeAll("usage: built without the zig grammar\n");
    }
    try out.flush();
}

fn run(gpa: std.mem.Allocator, io: std.Io, out: *std.Io.Writer) !void {
    // --- README:usage ---
    const zig = &grammars.zig;
    const source = "pub fn add(a: u32, b: u32) u32 {\n    return a + b;\n}\n";

    var parser: ts.Parser = .init();
    defer parser.deinit();
    try parser.setLanguage(zig.language());

    // The text stays the caller's. `parse` is a cancellation point on `io`
    // and can stop at a deadline and resume.
    var tree = try parser.parse(io, .{ .slice = source }, null, .{});
    defer tree.deinit();

    // Queries come with the grammar, each in the dialect it was written in.
    const highlights = zig.queries.highlights.?;
    var query: ts.Query = try .init(gpa, zig.language(), highlights.text, .{ .dialect = highlights.dialect });
    defer query.deinit();

    // A cursor is reusable and allocates nothing while matching.
    var cursor: ts.QueryCursor = try .init(gpa);
    defer cursor.deinit();
    var captures = cursor.captures(io, &query, tree.rootNode(), .{ .slice = source }, .{});
    while (try captures.next()) |event| {
        const name = query.captureName(event.capture().index);
        try out.print("{s:<24} {s}\n", .{ name, event.node().text(source) });
    }
    // --- README:usage ---
}
