//! What the catalogue tool and the upstream checks share: a GitHub
//! repository at a commit, unpacked into a cache; the commands they run
//! (git, zig, the tree-sitter CLI); and reading the trees they compare.

const std = @import("std");
const Io = std.Io;
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;

pub const Context = struct {
    /// Thread-safe; holds what outlives a task (paths, names, results).
    arena: Allocator,
    /// Thread-safe; for transient buffers, freed by their user.
    gpa: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    /// Downloads, temporary trees and zig's package cache for hashing.
    cache: []const u8,
    /// The zig that runs the build, for `zig fetch` and `zig fmt`.
    zig: []const u8,
    http: std.http.Client,
    locks: Locks = .{},
    temporaries: std.atomic.Value(u32) = .init(0),

    pub fn init(arena: Allocator, gpa: Allocator, io: Io, environ: *const std.process.Environ.Map, cache_arg: []const u8, zig: []const u8) !Context {
        try Io.Dir.cwd().createDirPath(io, cache_arg);
        // Absolute, so commands run in another directory find it.
        const cache = try Io.Dir.cwd().realPathFileAlloc(io, cache_arg, arena);
        // Temporary trees of an interrupted run.
        const tmp = try std.fs.path.join(arena, &.{ cache, "tmp" });
        try Io.Dir.cwd().deleteTree(io, tmp);
        try Io.Dir.cwd().createDirPath(io, tmp);
        return .{
            .arena = arena,
            .gpa = gpa,
            .io = io,
            .environ = environ,
            .cache = cache,
            .zig = zig,
            .http = .{ .allocator = gpa, .io = io },
        };
    }

    pub fn deinit(ctx: *Context) void {
        ctx.http.deinit();
    }

    pub fn path(ctx: *Context, parts: []const []const u8) []const u8 {
        return std.fs.path.join(ctx.arena, parts) catch @panic("OOM");
    }

    /// A new, empty directory under the cache, for the caller to delete.
    pub fn temporary(ctx: *Context) ![]const u8 {
        const n = ctx.temporaries.fetchAdd(1, .monotonic);
        const dir = ctx.path(&.{ ctx.cache, "tmp", try ctx.arena.print("{d}", .{n}) });
        try Io.Dir.cwd().createDirPath(ctx.io, dir);
        return dir;
    }
};

/// One lock per cache entry, so two grammars from one repository download it
/// once.
const Locks = struct {
    guard: Io.Mutex = .init,
    map: std.StringHashMapUnmanaged(*Io.Mutex) = .empty,

    fn get(locks: *Locks, ctx: *Context, key: []const u8) !*Io.Mutex {
        try locks.guard.lock(ctx.io);
        defer locks.guard.unlock(ctx.io);
        const slot = try locks.map.getOrPut(ctx.arena, key);
        if (!slot.found_existing) {
            slot.value_ptr.* = try ctx.arena.create(Io.Mutex);
            slot.value_ptr.*.* = .init;
        }
        return slot.value_ptr.*;
    }
};

pub const Repository = struct {
    owner: []const u8,
    name: []const u8,

    /// `https://github.com/<owner>/<name>`, with or without `.git` or a
    /// trailing slash.
    pub fn parse(url: []const u8) error{NotGitHub}!Repository {
        const prefix = "https://github.com/";
        if (!std.mem.startsWith(u8, url, prefix)) return error.NotGitHub;
        var rest = std.mem.trimEnd(u8, url[prefix.len..], "/");
        if (std.mem.endsWith(u8, rest, ".git")) rest = rest[0 .. rest.len - ".git".len];
        const slash = std.mem.findScalar(u8, rest, '/') orelse return error.NotGitHub;
        const owner = rest[0..slash];
        const name = rest[slash + 1 ..];
        if (owner.len == 0 or name.len == 0 or std.mem.findScalar(u8, name, '/') != null) return error.NotGitHub;
        return .{ .owner = owner, .name = name };
    }
};

pub fn tarballUrl(arena: Allocator, url: []const u8, commit: []const u8) ![]const u8 {
    const repo = try Repository.parse(url);
    return arena.print("https://github.com/{s}/{s}/archive/{s}.tar.gz", .{ repo.owner, repo.name, commit });
}

/// The repository at `commit`, unpacked under the cache once; its path.
pub fn download(ctx: *Context, url: []const u8, commit: []const u8) ![]const u8 {
    const repo = try Repository.parse(url);
    const dest = ctx.path(&.{ ctx.cache, "src", try ctx.arena.print("{s}--{s}--{s}", .{ repo.owner, repo.name, commit }) });
    const lock = try ctx.locks.get(ctx, dest);
    try lock.lock(ctx.io);
    defer lock.unlock(ctx.io);

    if (isDir(ctx.io, dest)) return dest;

    var body: Io.Writer.Allocating = .init(ctx.gpa);
    defer body.deinit();
    const result = try ctx.http.fetch(.{
        .location = .{ .url = try tarballUrl(ctx.arena, url, commit) },
        .response_writer = &body.writer,
    });
    if (result.status != .ok) {
        std.log.err("{s} at {s}: HTTP {d}", .{ url, commit, @backingInt(result.status) });
        return error.DownloadFailed;
    }

    const tmp = try ctx.temporary();
    {
        var dir = try Io.Dir.cwd().openDir(ctx.io, tmp, .{});
        defer dir.close(ctx.io);
        var input: Io.Reader = .fixed(body.written());
        const window = try ctx.gpa.alloc(u8, std.compress.flate.max_window_len);
        defer ctx.gpa.free(window);
        var gzip: std.compress.flate.Decompress = .init(&input, .gzip, window);
        // GitHub's archives hold one directory, `<name>-<commit>/`.
        try std.tar.extract(ctx.io, dir, &gzip.reader, .{ .strip_components = 1 });
    }
    try Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(dest).?);
    try Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), dest, ctx.io);
    return dest;
}

pub const Output = struct {
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,

    pub fn ok(o: Output) bool {
        return o.term.success();
    }

    /// stderr's last line, for a note.
    pub fn lastLine(o: Output) []const u8 {
        var lines = std.mem.splitBackwardsScalar(u8, std.mem.trim(u8, o.stderr, " \t\r\n"), '\n');
        return lines.first();
    }
};

pub const RunOptions = struct {
    cwd: ?[]const u8 = null,
    environ: ?*const std.process.Environ.Map = null,
};

/// Runs a command to its end, keeping its output in the arena.
pub fn run(ctx: *Context, argv: []const []const u8, options: RunOptions) !Output {
    const result = try std.process.run(ctx.arena, ctx.io, .{
        .argv = argv,
        .cwd = if (options.cwd) |dir| .{ .path = dir } else .inherit,
        .environ_map = options.environ,
    });
    return .{ .term = result.term, .stdout = result.stdout, .stderr = result.stderr };
}

/// Runs a command that must succeed; its standard output, trimmed.
pub fn runChecked(ctx: *Context, argv: []const []const u8, options: RunOptions) ![]const u8 {
    const out = try run(ctx, argv, options);
    if (!out.ok()) {
        std.log.err("{s} failed: {s}", .{ argv[0], out.lastLine() });
        return error.CommandFailed;
    }
    return std.mem.trim(u8, out.stdout, " \t\r\n");
}

pub fn isCommit(revision: []const u8) bool {
    if (revision.len != 40) return false;
    for (revision) |ch| switch (ch) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// A tag (peeled) or branch name as the commit it names.
pub fn resolveCommit(ctx: *Context, url: []const u8, revision: []const u8) ![]const u8 {
    if (isCommit(revision)) return revision;
    const peeled = try ctx.arena.print("refs/tags/{s}^{{}}", .{revision});
    const tag = try ctx.arena.print("refs/tags/{s}", .{revision});
    const head = try ctx.arena.print("refs/heads/{s}", .{revision});
    const out = try runChecked(ctx, &.{ "git", "ls-remote", url, tag, peeled, head }, .{});
    for ([_][]const u8{ peeled, tag, head }) |want| {
        var lines = std.mem.tokenizeScalar(u8, out, '\n');
        while (lines.next()) |line| {
            const tab = std.mem.findScalar(u8, line, '\t') orelse continue;
            if (std.mem.eql(u8, std.mem.trimEnd(u8, line[tab + 1 ..], "\r"), want)) return line[0..tab];
        }
    }
    std.log.err("{s}: cannot resolve {s}", .{ url, revision });
    return error.UnknownRevision;
}

/// `zig fetch` in a cache of its own, so a run never fills the maintainer's
/// global cache with every grammar. `target` is a directory or a URL.
pub fn zigHash(ctx: *Context, target: []const u8) ![]const u8 {
    const project = ctx.path(&.{ ctx.cache, "project" });
    {
        const lock = try ctx.locks.get(ctx, project);
        try lock.lock(ctx.io);
        defer lock.unlock(ctx.io);
        try Io.Dir.cwd().createDirPath(ctx.io, project);
        try Io.Dir.cwd().writeFile(ctx.io, .{
            .sub_path = ctx.path(&.{ project, "build.zig" }),
            .data = "pub fn build(_: *@import(\"std\").Build) void {}\n",
        });
    }
    const absolute = if (std.mem.find(u8, target, "://") == null) try Io.Dir.cwd().realPathFileAlloc(ctx.io, target, ctx.arena) else target;
    var env = try ctx.environ.clone(ctx.arena);
    try env.put("ZIG_GLOBAL_CACHE_DIR", ctx.path(&.{ ctx.cache, "zig", "global" }));
    const packages = ctx.path(&.{ ctx.cache, "zig", "packages" });
    const hash = try runChecked(ctx, &.{
        ctx.zig,       "fetch",
        "--cache-dir", ctx.path(&.{ ctx.cache, "zig", "local" }),
        "--pkg-dir",   packages,
        absolute,
    }, .{ .cwd = project, .environ = &env });
    // The unpacked copy is not needed once hashed.
    remove(ctx, ctx.path(&.{ packages, hash }));
    return hash;
}

pub const Kind = enum { file, directory, sym_link, other };

/// What is at `path`, without following a symbolic link; null if nothing.
pub fn kindOf(io: Io, path: []const u8) ?Kind {
    const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return null;
    return switch (st.kind) {
        .file => .file,
        .directory => .directory,
        .sym_link => .sym_link,
        else => .other,
    };
}

/// A regular file at `path`, following a symbolic link, as Python's
/// `Path.is_file` reads it.
pub fn isFile(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

pub fn isDir(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// The largest file read: a grammar's generated parser.c runs to tens of
/// MiB.
const max_file_bytes = 1 << 30;

pub fn readFile(ctx: *Context, allocator: Allocator, path: []const u8) ![]u8 {
    return aegis.own.readFile(ctx.io, Io.Dir.cwd(), path, allocator, .fromRaw(max_file_bytes));
}

/// Deletes a tree the run made. One left behind takes disk space and
/// nothing else, so a failure is reported and the run goes on.
pub fn remove(ctx: *Context, path: []const u8) void {
    Io.Dir.cwd().deleteTree(ctx.io, path) catch |err| std.log.warn("cannot remove {s}: {t}", .{ path, err });
}

/// Every regular file under `root`, as paths relative to it with `/`
/// separators, sorted. Symbolic links are neither followed nor listed.
pub fn regularFiles(ctx: *Context, root: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var dir = Io.Dir.cwd().openDir(ctx.io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return &.{},
        else => |e| return e,
    };
    defer dir.close(ctx.io);
    var walker = try dir.walk(ctx.gpa);
    defer walker.deinit();
    while (try walker.next(ctx.io)) |entry| {
        if (entry.kind != .file) continue;
        const rel = try ctx.arena.dupe(u8, entry.path);
        if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
        try out.append(ctx.arena, rel);
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.items;
}

pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The bytes at `a` and `b` are the same; a missing file is not.
pub fn sameFile(ctx: *Context, a: []const u8, b: []const u8) !bool {
    const left = readFile(ctx, ctx.gpa, a) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    defer ctx.gpa.free(left);
    const right = readFile(ctx, ctx.gpa, b) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    defer ctx.gpa.free(right);
    return std.mem.eql(u8, left, right);
}
