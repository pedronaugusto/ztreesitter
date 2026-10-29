//! A static archive's symbol index: the global symbols its members define,
//! as `nm` reads them, for `tools/symbols.zig` and the catalogue tool.

const std = @import("std");

/// The C name of `name`, a symbol as the archive spells it with the
/// target's `prefix` (`_` on Apple's platforms, else empty); null for a name
/// without the prefix, which no C definition makes.
pub fn cName(name: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    return name[prefix.len..];
}

/// Whether `name`, spelt as the archive does, is in the namespace of the
/// grammar whose language function is `symbol`: `symbol` itself, or a name
/// beginning with it and `_`.
pub fn inNamespace(name: []const u8, prefix: []const u8, symbol: []const u8) bool {
    const c = cName(name, prefix) orelse return false;
    if (!std.mem.startsWith(u8, c, symbol)) return false;
    return c.len == symbol.len or c[symbol.len] == '_';
}

test inNamespace {
    try std.testing.expect(inNamespace("_tree_sitter_c", "_", "tree_sitter_c"));
    try std.testing.expect(inNamespace("tree_sitter_c_external_scanner_scan", "", "tree_sitter_c"));
    try std.testing.expect(inNamespace("tree_sitter_c__keywords", "", "tree_sitter_c"));
    try std.testing.expect(!inNamespace("tree_sitter_cpp", "", "tree_sitter_c"));
    try std.testing.expect(!inNamespace("tree_sitter_c", "_", "tree_sitter_c"));
    try std.testing.expect(!inNamespace("keywords", "", "tree_sitter_c"));
}

pub const Error = error{ NotAnArchive, NoSymbolIndex, BadSymbolIndex } || std.mem.Allocator.Error;

/// The names in the archive's symbol index, each once. GNU archives (`/`,
/// `/SYM64/`) list a count, the members' offsets and the names; BSD ones
/// (`__.SYMDEF`, `__.SYMDEF_64`, with or without ` SORTED`) list
/// (name, member) pairs and a string table.
pub fn symbolIndex(arena: std.mem.Allocator, bytes: []const u8) Error!std.StringHashMapUnmanaged(void) {
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
