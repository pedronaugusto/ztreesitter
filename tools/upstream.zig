//! What this repository copies from upstream, compared with upstream.
//! Needs network; `zig build check-vendor` and `zig build verify-mirror`
//! run it.
//!
//!   upstream vendor ROOT CACHE ZIG
//!       libs/tree-sitter's LICENSE, lib/include and lib/src are the pinned
//!       tag's with libs/tree-sitter.patch applied, byte for byte, with
//!       nothing added or missing.
//!   upstream mirror CACHE ZIG (NAME URL COMMIT DIR)...
//!       Every file of each grammar mirror DIR is the grammar repository's at
//!       COMMIT, unmodified, but PROVENANCE and the generated parsers it
//!       names.

const std = @import("std");
const Io = std.Io;
const github = @import("github.zig");

/// The vendored runtime. UPSTREAM.md names the same tag and commit; the
/// re-vendor procedure there changes them together.
const runtime_url = "https://github.com/tree-sitter/tree-sitter";
const runtime_tag = "v0.27.0";
const runtime_commit = "6070dbfefd326bd735e5683eb128cc1b57dad0c0";
/// Paths copied, relative to upstream's root and to libs/tree-sitter.
const vendored = [_][]const u8{ "LICENSE", "lib/include", "lib/src" };
/// The changes to them, a unified diff against upstream's root that UPSTREAM.md
/// describes change by change.
const patch_path = "libs/tree-sitter.patch";

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) return usage();
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &buffer);
    const out = &stdout.interface;
    const mode = args[1];
    const status = if (std.mem.eql(u8, mode, "vendor") and args.len == 5) blk: {
        var ctx: github.Context = try .init(arena, init.gpa, init.io, init.environ_map, args[3], args[4]);
        defer ctx.deinit();
        break :blk try vendor(&ctx, out, args[2]);
    } else if (std.mem.eql(u8, mode, "mirror") and (args.len - 4) % 4 == 0) blk: {
        var ctx: github.Context = try .init(arena, init.gpa, init.io, init.environ_map, args[2], args[3]);
        defer ctx.deinit();
        break :blk try mirrors(&ctx, out, args[4..]);
    } else return usage();
    try out.flush();
    return status;
}

fn usage() u8 {
    std.log.err("usage: upstream vendor ROOT CACHE ZIG | upstream mirror CACHE ZIG (NAME URL COMMIT DIR)...", .{});
    return 2;
}

fn vendor(ctx: *github.Context, out: *Io.Writer, root: []const u8) !u8 {
    const upstream_md = try github.readFile(ctx, ctx.arena, ctx.path(&.{ root, "UPSTREAM.md" }));
    for ([_][]const u8{ runtime_tag, runtime_commit }) |name| {
        if (std.mem.find(u8, upstream_md, name) == null) {
            std.log.err("UPSTREAM.md does not name {s}", .{name});
            return 1;
        }
    }
    // A tag can move; the commit cannot.
    const tagged = try github.resolveCommit(ctx, runtime_url, runtime_tag);
    if (!std.mem.eql(u8, tagged, runtime_commit)) {
        std.log.err("tag {s} is {s}, expected {s}", .{ runtime_tag, tagged, runtime_commit });
        return 1;
    }
    const upstream = try github.download(ctx, runtime_url, runtime_commit);
    const patched = try applyPatch(ctx, upstream, ctx.path(&.{ root, patch_path }));
    defer github.remove(ctx, patched.root);
    const local = ctx.path(&.{ root, "libs", "tree-sitter" });

    var differ = false;
    for (vendored) |path| {
        const ours = ctx.path(&.{ local, path });
        const theirs = ctx.path(&.{ upstream, path });
        const same = if (github.isDir(ctx.io, theirs))
            try sameTree(ctx, out, &patched, upstream, path, ours)
        else
            try github.sameFile(ctx, patched.source(ctx, upstream, path), ours);
        try out.print("  {s} {s}\n", .{ path, if (same) "identical" else "DIFFERS" });
        if (!same) differ = true;
    }
    return @intFromBool(differ);
}

/// Upstream's files the patch changes, copied to `root` and patched there.
const Patched = struct {
    root: []const u8,
    /// Relative to upstream's root, with `/` separators.
    paths: []const []const u8,

    /// Where to read upstream's `rel` with the patch applied.
    fn source(p: *const Patched, ctx: *github.Context, upstream: []const u8, rel: []const u8) []const u8 {
        for (p.paths) |changed| {
            if (std.mem.eql(u8, changed, rel)) return ctx.path(&.{ p.root, rel });
        }
        return ctx.path(&.{ upstream, rel });
    }
};

/// Copies the files `patch` changes out of `upstream` and applies it to the
/// copies with `git apply`, outside any repository (the cache sits inside
/// this one), so it applies as a plain patch.
fn applyPatch(ctx: *github.Context, upstream: []const u8, patch: []const u8) !Patched {
    const text = try github.readFile(ctx, ctx.arena, patch);
    var paths: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const prefix = "+++ b/";
        if (std.mem.startsWith(u8, line, prefix)) try paths.append(ctx.arena, line[prefix.len..]);
    }
    const root = try ctx.temporary();
    for (paths.items) |rel| {
        const to = ctx.path(&.{ root, rel });
        try Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(to).?);
        try Io.Dir.copyFile(Io.Dir.cwd(), ctx.path(&.{ upstream, rel }), Io.Dir.cwd(), to, ctx.io, .{});
    }
    var env = try ctx.environ.clone(ctx.arena);
    try env.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(root).?);
    const absolute = try Io.Dir.cwd().realPathFileAlloc(ctx.io, patch, ctx.arena);
    _ = try github.runChecked(ctx, &.{ "git", "apply", absolute }, .{ .cwd = root, .environ = &env });
    return .{ .root = root, .paths = paths.items };
}

/// The two trees hold the same regular files with the same bytes, `theirs`
/// with the patch applied. Each difference is printed.
fn sameTree(ctx: *github.Context, out: *Io.Writer, patched: *const Patched, upstream: []const u8, prefix: []const u8, ours: []const u8) !bool {
    const a = try github.regularFiles(ctx, ctx.path(&.{ upstream, prefix }));
    const b = try github.regularFiles(ctx, ours);
    var same = true;
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len or j < b.len) {
        const order: std.math.Order = if (i == a.len) .gt else if (j == b.len) .lt else std.mem.order(u8, a[i], b[j]);
        switch (order) {
            .lt => {
                try out.print("    missing here: {s}\n", .{a[i]});
                i += 1;
                same = false;
            },
            .gt => {
                try out.print("    not upstream's: {s}\n", .{b[j]});
                j += 1;
                same = false;
            },
            .eq => {
                const rel = try std.mem.join(ctx.arena, "/", &.{ prefix, a[i] });
                if (!try github.sameFile(ctx, patched.source(ctx, upstream, rel), ctx.path(&.{ ours, b[j] }))) {
                    try out.print("    differs: {s}\n", .{a[i]});
                    same = false;
                }
                i += 1;
                j += 1;
            },
        }
    }
    return same;
}

const Mirror = struct {
    names: std.ArrayList([]const u8) = .empty,
    url: []const u8,
    commit: []const u8,
    dir: []const u8,
    failures: std.ArrayList([]const u8) = .empty,
    err: ?anyerror = null,
};

fn mirrors(ctx: *github.Context, out: *Io.Writer, args: []const []const u8) !u8 {
    // Grammars from one repository share its mirror; each is checked once.
    var list: std.ArrayList(Mirror) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 4) {
        const name, const url, const commit, const dir = args[i..][0..4].*;
        for (list.items) |*m| {
            if (std.mem.eql(u8, m.dir, dir)) {
                try m.names.append(ctx.arena, name);
                break;
            }
        } else {
            try list.append(ctx.arena, .{ .url = url, .commit = commit, .dir = dir });
            try list.items[list.items.len - 1].names.append(ctx.arena, name);
        }
    }

    var group: Io.Group = .init;
    for (list.items) |*m| group.async(ctx.io, checkTask, .{ ctx, m });
    try group.await(ctx.io);

    var bad: usize = 0;
    for (list.items) |m| {
        const label = try std.mem.join(ctx.arena, ", ", m.names.items);
        if (m.err) |err| {
            try out.print("  {s}: {t}\n", .{ label, err });
            bad += 1;
        } else if (m.failures.items.len != 0) {
            try out.print("  {s}: {d} files differ from {s} at {s}\n", .{ label, m.failures.items.len, m.url, m.commit });
            for (m.failures.items) |f| try out.print("    {s}\n", .{f});
            bad += 1;
        } else {
            try out.print("  {s}: upstream's at {s}\n", .{ label, m.commit[0..12] });
        }
    }
    try out.print("verify-mirror: {d} mirrors, {d} differ\n", .{ list.items.len, bad });
    return @intFromBool(bad != 0);
}

fn checkTask(ctx: *github.Context, m: *Mirror) void {
    check(ctx, m) catch |err| {
        m.err = err;
    };
}

fn check(ctx: *github.Context, m: *Mirror) !void {
    const provenance = try github.readFile(ctx, ctx.arena, ctx.path(&.{ m.dir, "PROVENANCE" }));
    const first = try ctx.arena.print("Mirrored from {s} at {s} ", .{ m.url, m.commit });
    if (!std.mem.startsWith(u8, provenance, first)) {
        try m.failures.append(ctx.arena, "PROVENANCE names another repository or commit");
        return;
    }
    // "Generated: <dir>/parser.c and the tree_sitter/ headers beside it, ..."
    var generated: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, provenance, '\n');
    while (lines.next()) |line| {
        const prefix = "Generated: ";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const end = std.mem.findScalar(u8, line[prefix.len..], ' ') orelse return error.BadProvenance;
        const parser = line[prefix.len..][0..end];
        if (!std.mem.endsWith(u8, parser, "parser.c")) return error.BadProvenance;
        try generated.append(ctx.arena, parser[0 .. parser.len - "parser.c".len]);
    }

    const upstream = try github.download(ctx, m.url, m.commit);
    var dir = try Io.Dir.cwd().openDir(ctx.io, m.dir, .{ .iterate = true });
    defer dir.close(ctx.io);
    var walker = try dir.walk(ctx.gpa);
    defer walker.deinit();
    while (try walker.next(ctx.io)) |entry| {
        const rel = try ctx.arena.dupe(u8, entry.path);
        if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
        switch (entry.kind) {
            .directory => continue,
            .file => {},
            else => {
                try m.failures.append(ctx.arena, try ctx.arena.print("not a regular file: {s}", .{rel}));
                continue;
            },
        }
        if (std.mem.eql(u8, rel, "PROVENANCE") or isGenerated(generated.items, rel)) continue;
        if (!try github.sameFile(ctx, ctx.path(&.{ m.dir, rel }), ctx.path(&.{ upstream, rel }))) {
            try m.failures.append(ctx.arena, rel);
        }
    }
}

/// A generated parser's directory holds parser.c and tree_sitter/*.h.
fn isGenerated(dirs: []const []const u8, rel: []const u8) bool {
    for (dirs) |d| {
        if (!std.mem.startsWith(u8, rel, d)) continue;
        const rest = rel[d.len..];
        if (std.mem.eql(u8, rest, "parser.c")) return true;
        if (std.mem.startsWith(u8, rest, "tree_sitter/") and std.mem.findScalar(u8, rest["tree_sitter/".len..], '/') == null) return true;
    }
    return false;
}
