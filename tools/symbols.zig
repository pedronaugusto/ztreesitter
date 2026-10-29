//! The global symbols each grammar library defines, read from its static
//! archive's symbol index as `nm` reads them. Two grammars that define one
//! symbol cannot be linked into one program, so any symbol defined by two
//! libraries is reported and the check fails. `zig build check-grammars`
//! runs it over every selected grammar.
//!
//!   symbols LIBRARY...

const std = @import("std");
const Io = std.Io;
const aegis = @import("aegis");

/// A grammar archive's size: its parser's object, which runs to tens of MiB.
const max_archive_bytes = 1 << 30;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &buffer);
    const out = &stdout.interface;

    // Each symbol and the first library defining it.
    var owners: std.StringHashMapUnmanaged([]const u8) = .empty;
    var clashes: usize = 0;
    for (args[1..]) |path| {
        const bytes = try aegis.own.readFile(init.io, Io.Dir.cwd(), path, init.gpa, .fromRaw(max_archive_bytes));
        defer init.gpa.free(bytes);
        const library = std.fs.path.basename(path);
        var names = try symbolIndex(init.gpa, bytes);
        defer names.deinit(init.gpa);
        var it = names.keyIterator();
        while (it.next()) |name| {
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
    try out.print("symbols: {d} libraries, {d} global symbols, {d} defined twice\n", .{ args.len - 1, owners.count(), clashes });
    try out.flush();
    return @intFromBool(clashes != 0);
}

const Error = error{ NotAnArchive, NoSymbolIndex, BadSymbolIndex } || std.mem.Allocator.Error;

/// The names in the archive's symbol index, each once. GNU archives (`/`,
/// `/SYM64/`) list a count, the members' offsets and the names; BSD ones
/// (`__.SYMDEF`, `__.SYMDEF_64`, with or without ` SORTED`) list
/// (name, member) pairs and a string table.
fn symbolIndex(arena: std.mem.Allocator, bytes: []const u8) Error!std.StringHashMapUnmanaged(void) {
    const magic = "!<arch>\n";
    const header_len = 60;
    if (!std.mem.startsWith(u8, bytes, magic) or bytes.len < magic.len + header_len) return error.NotAnArchive;
    const header = bytes[magic.len..][0..header_len];
    const size = std.fmt.parseInt(usize, std.mem.trimEnd(u8, header[48..58], " "), 10) catch return error.NotAnArchive;
    const after = bytes[magic.len + header_len ..];
    if (size > after.len) return error.NotAnArchive;
    var member = after[0..size];

    const raw_name = std.mem.trimEnd(u8, header[0..16], " ");
    // BSD's long names: `#1/N`, the name the member's first N bytes.
    var name = raw_name;
    if (std.mem.startsWith(u8, raw_name, "#1/")) {
        const n = std.fmt.parseInt(usize, raw_name[3..], 10) catch return error.NotAnArchive;
        if (n > member.len) return error.NotAnArchive;
        name = std.mem.sliceTo(member[0..n], 0);
        member = member[n..];
    }

    var names: std.StringHashMapUnmanaged(void) = .empty;
    if (std.mem.eql(u8, name, "/") or std.mem.eql(u8, name, "/SYM64/")) {
        const width: usize = if (name.len == 1) 4 else 8;
        var r: Reader = .{ .bytes = member, .endian = .big };
        const count = try r.int(width);
        try r.skip(try mul(count, width));
        var strings = std.mem.splitScalar(u8, r.rest(), 0);
        for (0..count) |_| {
            const symbol = strings.next() orelse return error.BadSymbolIndex;
            try names.put(arena, symbol, {});
        }
        return names;
    }
    if (std.mem.startsWith(u8, name, "__.SYMDEF")) {
        const width: usize = if (std.mem.startsWith(u8, name, "__.SYMDEF_64")) 8 else 4;
        var r: Reader = .{ .bytes = member, .endian = .little };
        const table_len = try r.int(width);
        if (table_len % (2 * width) != 0) return error.BadSymbolIndex;
        var entries: Reader = .{ .bytes = try r.take(table_len), .endian = .little };
        const strings_len = try r.int(width);
        const strings = try r.take(strings_len);
        while (entries.bytes.len != 0) {
            const at = try entries.int(width);
            _ = try entries.int(width);
            if (at >= strings.len) return error.BadSymbolIndex;
            try names.put(arena, std.mem.sliceTo(strings[at..], 0), {});
        }
        return names;
    }
    return error.NoSymbolIndex;
}

fn mul(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch error.BadSymbolIndex;
}

const Reader = struct {
    bytes: []const u8,
    endian: std.builtin.Endian,

    fn take(r: *Reader, n: usize) Error![]const u8 {
        if (n > r.bytes.len) return error.BadSymbolIndex;
        const taken = r.bytes[0..n];
        r.bytes = r.bytes[n..];
        return taken;
    }

    fn skip(r: *Reader, n: usize) Error!void {
        _ = try r.take(n);
    }

    fn int(r: *Reader, width: usize) Error!usize {
        const bytes = try r.take(width);
        const value: u64 = if (width == 4)
            std.mem.readInt(u32, bytes[0..4], r.endian)
        else
            std.mem.readInt(u64, bytes[0..8], r.endian);
        return std.math.cast(usize, value) orelse error.BadSymbolIndex;
    }

    fn rest(r: *const Reader) []const u8 {
        return r.bytes;
    }
};
