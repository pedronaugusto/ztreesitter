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
    "regex",      "rust", "scss",    "swift",    "tsx",             "typescript",
    "zig",
};

/// What a project that depends on ztreesitter builds: the runtime, the
/// `ztreesitter` module over it and `ztreesitter.catalogue`. Grammars are the
/// application's, through `addGrammars`. The tests, checks, example and
/// benchmark are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Off by default and not tied to `optimize`: Zig's C sanitizer emits
    // calls into a runtime linked only into a sanitized compilation, so a
    // consumer that forgot to forward `optimize` would get a link failure
    // naming a __ubsan symbol. The suite turns it on explicitly. Grammars are
    // never sanitized: their C is third-party and unpatched.
    const sanitize_c = b.option(bool, "sanitize_c", "Compile the runtime's C with the undefined-behaviour sanitizer") orelse false;

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

    _ = b.addModule("ztreesitter.catalogue", .{ .root_source_file = b.path("grammars/catalogue.zig"), .target = target, .optimize = optimize });

    const module = b.addModule("ztreesitter", .{
        .root_source_file = b.path("src/ztreesitter.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ztreesitter_options", .module = optionsModule(b, sanitize_c, target, optimize) }},
    });
    module.linkLibrary(runtime);
}

/// What the sources read of the build: the version and whether the runtime
/// is sanitized.
fn optionsModule(b: *std.Build, sanitize_c: bool, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);
    options.addOption(bool, "sanitize_c", sanitize_c);
    return b.createModule(.{ .root_source_file = options.getOutput(), .target = target, .optimize = optimize });
}

/// ztreesitter's development: its tests, checks, example and benchmark under
/// preflight's gate, against the package as a consumer gets it, with its
/// grammars named through `addGrammars` as an application names them. Run
/// through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sanitize_c = b.option(bool, "sanitize_c", "Compile the runtime's C with the undefined-behaviour sanitizer") orelse false;
    const spec = b.option([]const u8, "grammars", "Grammars the tests compile: none, all, or a comma list (default: the representative set)");
    const test_filter = b.option([]const u8, "test-filter", "Run tests whose names contain this text");
    const filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};

    const package = b.dependency("ztreesitter", .{ .target = target, .optimize = optimize, .sanitize_c = sanitize_c });
    const p = package.builder;
    const module = package.module("ztreesitter");

    var names: std.ArrayList([]const u8) = .empty;
    if (spec) |list| {
        var it = std.mem.tokenizeScalar(u8, list, ',');
        while (it.next()) |name| names.append(b.allocator, name) catch @panic("OOM");
    } else {
        names.appendSlice(b.allocator, &representative) catch @panic("OOM");
    }
    // Null on the configure pass that fetches the named grammars.
    const grammars_module = addGrammars(b, package, names.items, .{}) orelse emptyGrammars(b, module, target, optimize);

    //=====================================================================
    // Tests. `unit` holds the tests beside the code; `tests` the ones that
    // need grammars, run against the module a consumer gets.
    //=====================================================================

    const unit = b.addTest(.{
        .name = "ztreesitter-unit",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/ztreesitter.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ztreesitter_options", .module = optionsModule(b, sanitize_c, target, optimize) }},
        }),
    });
    unit.root_module.linkLibrary(package.artifact("tree-sitter"));
    // The ABI guard reads the header through translate-c; wired on the test
    // module only, so the shipped module never translates C.
    const api_h = b.addTranslateC(.{ .root_source_file = p.path("libs/tree-sitter/lib/include/tree_sitter/api.h"), .target = target, .optimize = optimize });
    api_h.addIncludePath(p.path("libs/tree-sitter/lib/include"));
    unit.root_module.addImport("api_h", api_h.createModule());

    const tests = b.addTest(.{
        .name = "ztreesitter-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = p.path("tests/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ztreesitter", .module = module },
                .{ .name = "ztreesitter.catalogue", .module = b.createModule(.{ .root_source_file = p.path("grammars/catalogue.zig"), .target = target, .optimize = optimize }) },
                .{ .name = "grammars", .module = grammars_module },
            },
        }),
    });

    const test_step = b.step("test", "Run the tests and the example");
    test_step.dependOn(&b.addRunArtifact(unit).step);
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(p.path("."));
    test_step.dependOn(&run_tests.step);
    const check = b.step("check", "Compile the tests and the example without running them");
    check.dependOn(&unit.step);
    check.dependOn(&tests.step);

    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{
            .root_source_file = p.path("examples/usage.zig"),
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

    tools.preflight.addCi(b, p, .{
        .tests = test_step,
        .bench = .{
            .programs = &.{.{ .name = "throughput", .source = "bench/throughput.zig" }},
            .imports = benchImports,
            .target = target,
            .optimize = optimize,
        },
    });
}

/// The benchmark's imports: the module and the representative grammars.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const package = b.dependency("ztreesitter", .{ .target = target, .optimize = optimize });
    const module = package.module("ztreesitter");
    const grammars = addGrammars(b, package, &representative, .{}) orelse emptyGrammars(b, module, target, optimize);

    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "ztreesitter", .module = module },
        .{ .name = "grammars", .module = grammars },
        .{ .name = "samples", .module = b.createModule(.{ .root_source_file = package.builder.path("tests/samples.zig"), .target = target, .optimize = optimize }) },
    }) catch @panic("OOM");
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
    var wanted: std.array_hash_map.String(void) = .empty;
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
        dep.* = owner.dependencyLazy(b.fmt("grammar_{s}", .{g.name}), .{}) catch null;
        if (dep.* == null) missing = true;
        for (g.queries.tags) |q| {
            if (q.source == .helix) wants_helix = true;
        }
    }
    const nvim = if (selected.items.len != 0) owner.dependencyLazy("nvim_treesitter", .{}) catch null else null;
    if (selected.items.len != 0 and nvim == null) missing = true;
    const helix = if (wants_helix) owner.dependencyLazy("helix", .{}) catch null else null;
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
            appendFmt(b, &source, "    .language_fn = @extern(*const fn () callconv(.c) *const ts.c.Language, .{{ .name = \"{s}\" }}),\n", .{g.symbol});
        }
        appendFmt(b, &source, "    .licence = \"{s}\",\n    .url = \"{s}\",\n    .commit = \"{s}\",\n    .queries = .{{\n", .{ g.licence, g.url, g.commit });
        inline for (@typeInfo(schema.Queries).@"struct".field_names) |field_name| {
            const list = @field(g.queries, field_name);

            if (list.len != 0) {
                const dialect = if (list[0].source == .nvim) "neovim" else "tree_sitter";
                appendFmt(b, &source, "        .{s} = .{{ .dialect = .{s}, .text = ", .{ field_name, dialect });
                for (list, 0..) |q, i| {
                    const path: std.Build.LazyPath = switch (q.source) {
                        .nvim => nvim.?.path(q.path),
                        .helix => helix.?.path(q.path),
                        .grammar => dep.path(q.path),
                        .ztreesitter => owner.path(q.path),
                    };
                    const name = b.fmt("queries/{s}/{s}.{d}.scm", .{ g.name, field_name, i });
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
fn emptyGrammars(b: *std.Build, ts: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const files = b.addWriteFiles();
    return b.createModule(.{
        .root_source_file = files.add("grammars.zig", "const ts = @import(\"ztreesitter\");\npub const list = [_]*const ts.Grammar{};\n"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ztreesitter", .module = ts }},
    });
}
