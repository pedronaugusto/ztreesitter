const std = @import("std");
const manifest = @import("build.zig.zon");
const catalogue = @import("grammars/catalogue.zig");
const schema = @import("grammars/schema.zig");

/// The grammars `zig build test` compiles when ztreesitter is the root build
/// and `-Dgrammars` is not given: one of each mechanism the catalogue has.
/// README's Testing says which is which.
pub const representative = [_][]const u8{
    "bash",       "c",    "c_sharp", "cpp",      "css",             "html",
    "javascript", "json", "lua",     "markdown", "markdown_inline", "python",
    "regex",      "rust", "swift",   "tsx",      "typescript",      "zig",
};

pub fn build(b: *std.Build) void {
    importChecks(b);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Off by default and not tied to `optimize`: Zig's C sanitizer emits
    // calls into a runtime linked only into a sanitized compilation, so a
    // consumer that forgot to forward `optimize` would get a link failure
    // naming a __ubsan symbol. The suite turns it on explicitly. Grammars are
    // never sanitized: their C is third-party and unpatched.
    const sanitize_c = b.option(bool, "sanitize_c", "Compile the runtime's C with the undefined-behaviour sanitizer") orelse false;

    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);
    options.addOption(bool, "sanitize_c", sanitize_c);
    const options_module = options.createModule();

    //=====================================================================
    // The runtime: one translation unit, lib/src/lib.c, with the macros
    // upstream's own build defines.
    //=====================================================================

    const runtime = b.addLibrary(.{
        .name = "tree-sitter",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = if (sanitize_c) .full else .off,
        }),
    });
    runtime.root_module.addIncludePath(b.path("libs/tree-sitter/lib/include"));
    runtime.root_module.addIncludePath(b.path("libs/tree-sitter/lib/src"));
    for (runtime_macros) |macro| runtime.root_module.addCMacro(macro[0], macro[1]);
    // Under the sanitizer, one check is left out: query.c copies an empty
    // string with `memcpy(dst, NULL, 0)` (UPSTREAM.md, known upstream
    // behaviour), which glibc's headers declare non-null.
    const runtime_flags: []const []const u8 = if (sanitize_c) &.{ "-std=c11", "-fno-sanitize=nonnull-attribute" } else &.{"-std=c11"};
    runtime.root_module.addCSourceFile(.{ .file = b.path("libs/tree-sitter/lib/src/lib.c"), .flags = runtime_flags });
    runtime.installHeadersDirectory(b.path("libs/tree-sitter/lib/include"), ".", .{});
    b.installArtifact(runtime);

    //=====================================================================
    // Modules. `ztreesitter` is the Zig API over the runtime and holds no
    // grammar. `ztreesitter.catalogue` is every catalogue grammar as data:
    // no C, no fetch.
    //=====================================================================

    const catalogue_module = b.addModule("ztreesitter.catalogue", .{ .root_source_file = b.path("grammars/catalogue.zig") });

    const module = b.addModule("ztreesitter", .{
        .root_source_file = b.path("src/ztreesitter.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ztreesitter_options", .module = options_module }},
    });
    module.linkLibrary(runtime);

    //=====================================================================
    // Grammars, when this is the root build. As a dependency ztreesitter
    // declares no grammar option: an application names its grammars through
    // `addGrammars`, so every library in it shares one instance.
    //=====================================================================

    var grammars: ?*std.Build.Module = null;
    if (b.pkg_hash.len == 0) {
        const spec = b.option([]const u8, "grammars", "Grammars the tests compile: none, all, or a comma list (default: the representative set)");
        var names: std.ArrayList([]const u8) = .empty;
        if (spec) |list| {
            var it = std.mem.tokenizeScalar(u8, list, ',');
            while (it.next()) |name| names.append(b.allocator, name) catch @panic("OOM");
        } else {
            names.appendSlice(b.allocator, &representative) catch @panic("OOM");
        }
        grammars = addGrammarsTo(b, b, module, names.items, .{ .target = target, .optimize = optimize });
    }
    const grammars_module = grammars orelse emptyGrammars(b, module);

    //=====================================================================
    // Tests. `unit` holds the tests beside the code; `tests` the ones that
    // need grammars, run against the module a consumer gets.
    //=====================================================================

    const test_filter = b.option([]const u8, "test-filter", "Run tests whose names contain this text");
    const filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};

    const unit = b.addTest(.{
        .name = "ztreesitter-unit",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ztreesitter.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ztreesitter_options", .module = options_module }},
        }),
    });
    unit.root_module.linkLibrary(runtime);
    // The ABI guard @cImports the header; wired on the test module only, so
    // the shipped module never compiles C.
    unit.root_module.addIncludePath(b.path("libs/tree-sitter/lib/include"));

    const tests = b.addTest(.{
        .name = "ztreesitter-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ztreesitter", .module = module },
                .{ .name = "ztreesitter.catalogue", .module = catalogue_module },
                .{ .name = "grammars", .module = grammars_module },
            },
        }),
    });

    const test_step = b.step("test", "Run the tests and the example");
    test_step.dependOn(&b.addRunArtifact(unit).step);
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));
    test_step.dependOn(&run_tests.step);
    const check = b.step("check", "Compile the tests and the example without running them");
    check.dependOn(&unit.step);
    check.dependOn(&tests.step);

    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/usage.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ztreesitter", .module = module },
                .{ .name = "grammars", .module = grammars_module },
            },
        }),
    });
    check.dependOn(&example.step);
    const examples = b.step("examples", "Build and run the usage example");
    examples.dependOn(&b.addRunArtifact(example).step);
    test_step.dependOn(examples);

    // zig build bench -Doptimize=ReleaseFast -- LANGUAGE FILE...
    const bench = b.addExecutable(.{
        .name = "throughput",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/throughput.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ztreesitter", .module = module },
                .{ .name = "grammars", .module = grammars_module },
            },
        }),
    });
    check.dependOn(&bench.step);
    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| run_bench.addArgs(args);
    b.step("bench", "Measure parse and tags-query throughput on the given files").dependOn(&run_bench.step);
}

// Build-only tooling belongs to a root invocation, never a consumer's
// dependency graph.
fn importChecks(b: *std.Build) void {
    const step = b.step("check-imports", "Check source layers and import boundaries");
    if (b.pkg_hash.len != 0) return;
    const dependency = if (b.lazyDependency("gantry", .{ .target = b.graph.host, .optimize = .Debug })) |dep| dep.module("gantry") else return;
    const checker = b.addExecutable(.{
        .name = "check-imports",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ci/imports.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "gantry", .module = dependency }},
        }),
    });
    const run = b.addRunArtifact(checker);
    run.setCwd(b.path("."));
    if (b.args) |args| run.addArgs(args);
    step.dependOn(&run.step);
}

const runtime_macros = [_][2][]const u8{
    .{ "_POSIX_C_SOURCE", "200112L" },
    .{ "_DEFAULT_SOURCE", "" },
    .{ "_BSD_SOURCE", "" },
    .{ "_DARWIN_C_SOURCE", "" },
};

/// The flags tree-sitter's own loader compiles a grammar with.
const grammar_flags = [_][]const u8{"-std=c11"};

pub const GrammarOptions = struct {
    /// Default to the target and optimize mode of ztreesitter's module.
    target: ?std.Build.ResolvedTarget = null,
    optimize: ?std.builtin.OptimizeMode = null,
    /// `.dynamic` builds one shared library per grammar and installs it; the
    /// module then carries each grammar's queries and symbol name but links
    /// no language, and the program loads each with `Language.load`.
    linkage: std.builtin.LinkMode = .static,
};

/// Compile the named grammars and return a module listing them, or null on
/// the first configure pass while their lazy dependencies are fetched.
///
/// `names` are catalogue names, or `"all"` for every grammar that is not
/// excluded (each excluded one is printed with its reason). Each grammar's
/// `requires` are added. Call it once, from the application's build:
/// grammars are the application's choice, and every library in it shares
/// one ztreesitter.
pub fn addGrammars(b: *std.Build, ztreesitter: *std.Build.Dependency, names: []const []const u8, options: GrammarOptions) ?*std.Build.Module {
    return addGrammarsTo(b, ztreesitter.builder, ztreesitter.module("ztreesitter"), names, options);
}

fn find(name: []const u8) ?*const schema.Grammar {
    for (catalogue.grammars) |*g| if (std.mem.eql(u8, g.name, name)) return g;
    return null;
}

fn isQueryOnly(name: []const u8) bool {
    for (catalogue.query_only) |q| if (std.mem.eql(u8, q, name)) return true;
    return false;
}

fn addGrammarsTo(b: *std.Build, owner: *std.Build, ts: *std.Build.Module, names: []const []const u8, options: GrammarOptions) ?*std.Build.Module {
    const target = options.target orelse ts.resolved_target.?;
    const optimize = options.optimize orelse ts.optimize.?;
    const gpa = b.allocator;

    // The names, then their `requires`, kept in catalogue order.
    var wanted: std.StringArrayHashMapUnmanaged(void) = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    for (names) |name| {
        if (std.mem.eql(u8, name, "none")) continue;
        if (std.mem.eql(u8, name, "all")) {
            for (catalogue.grammars) |g| switch (g.status) {
                .excluded => std.log.warn("ztreesitter: {s} is excluded: {s}", .{ g.name, g.reason }),
                else => pending.append(gpa, g.name) catch @panic("OOM"),
            };
            continue;
        }
        const g = find(name) orelse std.debug.panic("ztreesitter: no grammar named '{s}' in the catalogue", .{name});
        if (g.status == .excluded) std.debug.panic("ztreesitter: grammar '{s}' is excluded: {s}", .{ name, g.reason });
        pending.append(gpa, name) catch @panic("OOM");
    }
    while (pending.pop()) |name| {
        if (wanted.contains(name)) continue;
        wanted.put(gpa, name, {}) catch @panic("OOM");
        for (find(name).?.requires) |r| {
            if (!isQueryOnly(r) and !wanted.contains(r)) pending.append(gpa, r) catch @panic("OOM");
        }
    }
    var selected: std.ArrayList(*const schema.Grammar) = .empty;
    for (catalogue.grammars) |*g| {
        if (wanted.contains(g.name)) selected.append(gpa, g) catch @panic("OOM");
    }

    // Ask for every lazy dependency before using any, so that one configure
    // pass fetches all of them.
    var missing = false;
    const deps = gpa.alloc(?*std.Build.Dependency, selected.items.len) catch @panic("OOM");
    var wants_helix = false;
    for (selected.items, deps) |g, *dep| {
        dep.* = owner.lazyDependency(b.fmt("grammar_{s}", .{g.name}), .{});
        if (dep.* == null) missing = true;
        for (g.queries.tags) |q| {
            if (q.source == .helix) wants_helix = true;
        }
    }
    const nvim = if (selected.items.len != 0) owner.lazyDependency("nvim_treesitter", .{}) else null;
    if (selected.items.len != 0 and nvim == null) missing = true;
    const helix = if (wants_helix) owner.lazyDependency("helix", .{}) else null;
    if (wants_helix and helix == null) missing = true;
    if (missing) return null;

    const files = b.addWriteFiles();
    var source: std.ArrayList(u8) = .empty;
    var libraries: std.ArrayList(*std.Build.Step.Compile) = .empty;
    appendFmt(b, &source, "//! Generated by ztreesitter's addGrammars.\nconst ts = @import(\"ztreesitter\");\n\n", .{});

    for (selected.items, deps) |g, dep_opt| {
        const dep = dep_opt.?;
        const src_dir = if (g.location.len == 0) "src" else b.fmt("{s}/src", .{g.location});
        const lib = b.addLibrary(.{
            .name = b.fmt("tree-sitter-{s}", .{g.name}),
            .linkage = options.linkage,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .sanitize_c = .off,
            }),
        });
        lib.root_module.addIncludePath(dep.path(src_dir));
        lib.root_module.addCSourceFile(.{ .file = dep.path(b.fmt("{s}/parser.c", .{src_dir})), .flags = &grammar_flags });
        if (g.scanner) lib.root_module.addCSourceFile(.{ .file = dep.path(b.fmt("{s}/scanner.c", .{src_dir})), .flags = &grammar_flags });
        switch (options.linkage) {
            .static => libraries.append(gpa, lib) catch @panic("OOM"),
            .dynamic => b.installArtifact(lib),
        }

        appendFmt(b, &source, "pub const @\"{s}\": ts.Grammar = .{{\n    .name = \"{s}\",\n    .symbol = \"{s}\",\n", .{ g.name, g.name, g.symbol });
        if (options.linkage == .static) {
            appendFmt(b, &source, "    .language_fn = @extern(*const fn () callconv(.c) *const ts.c.TSLanguage, .{{ .name = \"{s}\" }}),\n", .{g.symbol});
        }
        appendFmt(b, &source, "    .licence = \"{s}\",\n    .url = \"{s}\",\n    .commit = \"{s}\",\n    .queries = .{{\n", .{ g.licence, g.url, g.commit });
        inline for (@typeInfo(schema.Queries).@"struct".fields) |field| {
            const list = @field(g.queries, field.name);
            if (list.len != 0) {
                const dialect = if (list[0].source == .nvim) "neovim" else "tree_sitter";
                appendFmt(b, &source, "        .{s} = .{{ .dialect = .{s}, .text = ", .{ field.name, dialect });
                for (list, 0..) |q, i| {
                    const path: std.Build.LazyPath = switch (q.source) {
                        .nvim => nvim.?.path(q.path),
                        .helix => helix.?.path(q.path),
                        .grammar => dep.path(q.path),
                        .ztreesitter => owner.path(q.path),
                    };
                    const name = b.fmt("queries/{s}/{s}.{d}.scm", .{ g.name, field.name, i });
                    _ = files.addCopyFile(path, name);
                    appendFmt(b, &source, "{s}@embedFile(\"{s}\")", .{ if (i == 0) "" else " ++ \"\\n\" ++ ", name });
                }
                appendFmt(b, &source, " }},\n", .{});
            }
        }
        appendFmt(b, &source, "    }},\n}};\n\n", .{});
    }

    appendFmt(b, &source, "pub const list = [_]*const ts.Grammar{{", .{});
    for (selected.items) |g| appendFmt(b, &source, " &@\"{s}\",", .{g.name});
    appendFmt(b, &source, " }};\n", .{});

    const grammars = b.createModule(.{
        .root_source_file = files.add("grammars.zig", source.items),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ztreesitter", .module = ts }},
    });
    for (libraries.items) |lib| grammars.linkLibrary(lib);
    return grammars;
}

fn appendFmt(b: *std.Build, list: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) void {
    list.appendSlice(b.allocator, b.fmt(fmt, args)) catch @panic("OOM");
}

/// What the tests import when no grammar is selected.
fn emptyGrammars(b: *std.Build, ts: *std.Build.Module) *std.Build.Module {
    const files = b.addWriteFiles();
    return b.createModule(.{
        .root_source_file = files.add("grammars.zig", "const ts = @import(\"ztreesitter\");\npub const list = [_]*const ts.Grammar{};\n"),
        .imports = &.{.{ .name = "ztreesitter", .module = ts }},
    });
}
