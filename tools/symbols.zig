//! The global symbols each grammar library defines, read from its static
//! archive's symbol index as `nm` reads them. A grammar's library defines
//! only names in its namespace (its language function, and names beginning
//! with it and `_`): a name outside it could be defined again by another
//! grammar or by the program. Two libraries defining one name could not be
//! linked into one program either. Both are reported and the check fails.
//! `zig build check-grammars` runs it over every selected grammar.
//!
//!   symbols PREFIX (SYMBOL LIBRARY)...
//!
//! PREFIX is what the target's object format puts before a C name (`_` on
//! Apple's platforms, else empty); SYMBOL is the grammar's language function.

const std = @import("std");
const Io = std.Io;
const aegis = @import("aegis");
const archive = @import("archive.zig");

/// A grammar archive's size: its parser's object, which runs to tens of MiB.
const max_archive_bytes = 1 << 30;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &buffer);
    const out = &stdout.interface;

    if (args.len < 2 or args.len % 2 != 0) {
        std.log.err("usage: symbols PREFIX (SYMBOL LIBRARY)...", .{});
        return 2;
    }
    const prefix = args[1];

    // Each symbol and the first library defining it.
    var owners: std.StringHashMapUnmanaged([]const u8) = .empty;
    var clashes: usize = 0;
    var outside: usize = 0;
    var pairs = std.mem.window([]const u8, args[2..], 2, 2);
    while (pairs.next()) |pair| {
        const symbol, const path = pair[0..2].*;
        const bytes = try aegis.own.readFile(init.io, Io.Dir.cwd(), path, init.gpa, .fromRaw(max_archive_bytes));
        defer init.gpa.free(bytes);
        const library = std.fs.path.basename(path);
        var names = try archive.symbolIndex(init.gpa, bytes);
        defer names.deinit(init.gpa);
        var it = names.keyIterator();
        while (it.next()) |name| {
            if (!archive.inNamespace(name.*, prefix, symbol)) {
                try out.print("  {s}: defined by {s}, outside {s}'s names\n", .{ name.*, library, symbol });
                outside += 1;
            }
            const slot = try owners.getOrPut(arena, name.*);
            if (!slot.found_existing) {
                // The key outlives the archive's bytes.
                slot.key_ptr.* = try arena.dupe(u8, name.*);
                slot.value_ptr.* = library;
                continue;
            }
            try out.print("  {s}: defined by {s} and {s}\n", .{ name.*, slot.value_ptr.*, library });
            clashes += 1;
        }
    }
    try out.print("symbols: {d} libraries, {d} global symbols, {d} outside their grammar's names, {d} defined twice\n", .{ (args.len - 2) / 2, owners.count(), outside, clashes });
    try out.flush();
    return @intFromBool(clashes != 0 or outside != 0);
}
