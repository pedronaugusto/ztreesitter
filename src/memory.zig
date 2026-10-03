//! The runtime's allocator seam.
//!
//! The runtime allocates through four process-wide function pointers
//! (`ts_set_allocator`). `setAllocator` points them at a Zig allocator. Each
//! block carries a 16-byte header holding its size, because the runtime
//! frees and reallocates without one.
//!
//! What it covers: the runtime only. Grammars are compiled without
//! `TREE_SITTER_REUSE_ALLOCATOR`, so scanners use libc (several mix the two
//! families, allocating with `ts_calloc` and freeing with `free`).
//!
//! The runtime never checks an allocation for NULL, so a failure through
//! this seam panics rather than handing it one.

const std = @import("std");
const c = @import("c.zig");

const header = 16;

var installed: ?std.mem.Allocator = null;

/// Install `allocator` behind the runtime. Start-up, not an operation: call
/// it before any parser, tree, query or cursor exists, from one thread.
pub fn setAllocator(allocator: std.mem.Allocator) void {
    installed = allocator;
    c.ts_set_allocator(&zigMalloc, &zigCalloc, &zigRealloc, &zigFree);
}

/// Put libc's allocator back. Every block allocated through the installed
/// allocator must have been freed first.
pub fn resetAllocator() void {
    c.ts_set_allocator(null, null, null, null);
    installed = null;
}

fn base(ptr: *anyopaque) [*]align(header) u8 {
    const p: [*]u8 = @ptrCast(ptr); // safe: every block this seam hands out starts `header` bytes into an allocation aligned to `header`
    return @alignCast(p - header); // safe: as above
}

fn sizeOf(block: [*]align(header) u8) usize {
    return std.mem.readInt(usize, block[0..@sizeOf(usize)], .little);
}

fn allocate(size: usize) [*]u8 {
    const a = installed orelse unreachable;
    const block = a.alignedAlloc(u8, .fromByteUnits(header), header + size) catch
        std.debug.panic("ztreesitter: the runtime cannot recover from a failed allocation of {d} bytes", .{size});
    std.mem.writeInt(usize, block[0..@sizeOf(usize)], size, .little);
    return block.ptr + header;
}

fn zigMalloc(size: usize) callconv(.c) ?*anyopaque {
    return allocate(size);
}

fn zigCalloc(count: usize, size: usize) callconv(.c) ?*anyopaque {
    const total = std.math.mul(usize, count, size) catch
        std.debug.panic("ztreesitter: calloc({d}, {d}) overflows", .{ count, size });
    const p = allocate(total);
    @memset(p[0..total], 0);
    return p;
}

fn zigRealloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const old = ptr orelse return allocate(size);
    const block = base(old);
    const old_size = sizeOf(block);
    const fresh = allocate(size);
    @memcpy(fresh[0..@min(old_size, size)], block[header..][0..@min(old_size, size)]);
    release(block);
    return fresh;
}

fn zigFree(ptr: ?*anyopaque) callconv(.c) void {
    release(base(ptr orelse return));
}

fn release(block: [*]align(header) u8) void {
    const a = installed orelse unreachable;
    a.free(block[0 .. header + sizeOf(block)]);
}

/// Free memory the runtime allocated and handed to its caller.
pub fn freeRuntime(ptr: *anyopaque) void {
    c.ts_current_free(ptr);
}
