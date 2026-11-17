//! The package's unchecked reads of the runtime, written once (a seam in
//! `glint.json`): the runtime's arrays as slices, its layout-equal types by
//! pointer cast, and the strncmp the runtime is compiled to call. Internal: no
//! file re-exports it, so none of it is API.

const std = @import("std");
const builtin = @import("builtin");

/// A pointer the runtime returns and the length it returns with it, as one slice; a
/// null pointer is the empty slice.
pub fn slice(comptime T: type, ptr: ?[*]const T, len: usize) []const T {
    const p = ptr orelse return &.{};
    return p[0..len];
}

/// `ptr` as `P`, a pointer to a type the package declares with the runtime's layout
/// (`types.Range` and `c.Range`, `types.InputEdit` and `c.InputEdit`, a query capture),
/// each layout asserted equal where the package's type is declared.
pub fn as(comptime P: type, ptr: anytype) P {
    return @ptrCast(ptr);
}

/// The strncmp the runtime is compiled to call (`src/strncmp.c`, through
/// `-Dstrncmp=ztreesitter_strncmp`): it reads no byte past `n`, where Zig 0.17's own reads one.
extern fn ztreesitter_strncmp(a: [*]const u8, b: [*]const u8, n: usize) c_int;

test "the runtime's strncmp reads no byte past its bound, where the next page is guarded" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const page = std.heap.pageSize();
    const pages = try std.posix.mmap(null, 2 * page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    defer std.posix.munmap(pages);
    // The second page, mapped again with no access: a read of it faults, and the test
    // dies there if the bound is not kept.
    const guard = try std.posix.mmap(@alignCast(pages[page..].ptr), page, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true }, -1, 0);
    const guarded = guard.ptr;
    // n = 0 reads nothing, though the first byte of each is guarded.
    try std.testing.expectEqual(0, ztreesitter_strncmp(guarded, guarded, 0));
    try std.testing.expectEqual(0, ztreesitter_strncmp("pair", guarded, 0));
    // A name that ends where the page ends, with no NUL after it, as a query's source
    // hands one over: compared to its length, and no further.
    const name = "pair";
    const end = pages[page - name.len .. page];
    @memcpy(end, name);
    try std.testing.expectEqual(0, ztreesitter_strncmp("pair", end.ptr, name.len));
    try std.testing.expect(ztreesitter_strncmp("pais", end.ptr, name.len) > 0);
    try std.testing.expect(ztreesitter_strncmp("paip", end.ptr, name.len) < 0);
    // NUL still ends a string before the bound.
    try std.testing.expectEqual(0, ztreesitter_strncmp("ab\x00x", "ab\x00y", 4));
}
