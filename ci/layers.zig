//! Source layers, lowest first. Every source has one explicit place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "catalogue schema", .patterns = &.{
        "grammars/schema.zig",
    } },
    .{ .name = "catalogue", .patterns = &.{
        "grammars/catalogue.zig",
    } },
    .{ .name = "C boundary", .patterns = &.{
        "src/c.zig",
    } },
    .{ .name = "matchers", .patterns = &.{
        "src/lua_pattern.zig",
        "src/regex.zig",
    } },
    .{ .name = "values", .patterns = &.{
        "src/abi_check.zig",
        "src/language.zig",
        "src/memory.zig",
        "src/types.zig",
    } },
    .{ .name = "trees", .patterns = &.{
        "src/cursor.zig",
        "src/node.zig",
        "src/tree.zig",
    } },
    .{ .name = "parsing", .patterns = &.{
        "src/parser.zig",
    } },
    .{ .name = "predicates", .patterns = &.{
        "src/predicates.zig",
    } },
    .{ .name = "queries", .patterns = &.{
        "src/query.zig",
    } },
    .{ .name = "tags", .patterns = &.{
        "src/tags.zig",
    } },
    .{ .name = "public", .patterns = &.{
        "src/ztreesitter.zig",
    } },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{
    .{ .name = "ztreesitter", .path = "src/ztreesitter.zig", .from = "src/**" },
    .{ .name = "ztreesitter.catalogue", .path = "grammars/catalogue.zig", .from = "grammars/**" },
};

pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "builtin",
        "std",
        "ztreesitter_options",
        "api_h",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{ "src/**", "grammars/**" } },
    .{ .name = "options owner", .target = "ztreesitter_options", .except_from = &.{"src/ztreesitter.zig"} },
    .{ .name = "the header, for the ABI guard alone", .target = "api_h", .except_from = &.{"src/abi_check.zig"} },
};

pub const required = blk: {
    var count: usize = 0;
    for (layers) |layer| count += layer.patterns.len;
    var paths: [count][]const u8 = undefined;
    var i: usize = 0;
    for (layers) |layer| for (layer.patterns) |path| {
        paths[i] = path;
        i += 1;
    };
    break :blk paths;
};

pub const owned: []const gantry.rules.TokenRule = &.{};
