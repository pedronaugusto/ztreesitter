//! The hand-written declarations in `c.zig` against the vendored `api.h`,
//! translated by the test build only (`api_h`), compared by reflection. A
//! re-vendor that changes a signature, a struct layout or an enumerator fails
//! to compile; the reverse sweep fails if the header declares a function this
//! file neither binds nor excludes by name.

const std = @import("std");
const c = @import("c.zig");

const h = @import("api_h");

/// Declared by the header, compiled only with WebAssembly support, which
/// this build leaves out.
const excluded = [_][]const u8{
    "ts_wasm_store_new",
    "ts_wasm_store_load_language",
    "ts_wasm_store_language_count",
    "ts_parser_set_wasm_store",
    "ts_parser_take_wasm_store",
};

fn fail(comptime msg: []const u8) noreturn {
    @compileError("ztreesitter ABI drift: " ++ msg);
}

/// Size and alignment of what a C type and its Zig counterpart describe,
/// looking through pointers (which compare by pointer size only).
fn sameShape(comptime Z: type, comptime C: type, comptime where: []const u8) void {
    const zi = @typeInfo(Z);
    const ci = @typeInfo(C);
    switch (zi) {
        .pointer, .optional => {
            if (@sizeOf(Z) != @sizeOf(C)) fail(where ++ ": pointer size");
            return;
        },
        .void => if (C != void and C != anyopaque) fail(where ++ ": void"),
        else => {},
    }
    if (zi == .@"enum") {
        if (@sizeOf(Z) != @sizeOf(C)) fail(where ++ ": enum size");
        return;
    }
    if (zi == .@"struct" and ci == .@"struct") {
        if (@sizeOf(Z) != @sizeOf(C)) fail(where ++ ": struct size " ++ @typeName(Z));
        if (@alignOf(Z) != @alignOf(C)) fail(where ++ ": struct alignment " ++ @typeName(Z));
        const zs = zi.@"struct";
        const cs = ci.@"struct";
        if (zs.field_names.len != cs.field_names.len) fail(where ++ ": field count of " ++ @typeName(Z));
        inline for (zs.field_names, cs.field_names, zs.field_types, cs.field_types) |a, b, at, bt| {
            if (!std.mem.eql(u8, a, b)) fail(where ++ ": field " ++ a ++ " vs " ++ b);
            if (@offsetOf(Z, a) != @offsetOf(C, b)) fail(where ++ ": offset of " ++ a);
            sameShape(at, bt, where ++ "." ++ a);
        }
        return;
    }
    if (@sizeOf(Z) != @sizeOf(C)) fail(where ++ ": size of " ++ @typeName(Z) ++ " vs " ++ @typeName(C));
}

fn checkFunction(comptime name: []const u8) void {
    const Z = @TypeOf(@field(c, name));
    const C = @TypeOf(@field(h, name));
    const zf = @typeInfo(Z).@"fn";
    const cf = @typeInfo(C).@"fn";
    if (zf.param_types.len != cf.param_types.len) fail(name ++ ": parameter count");
    inline for (zf.param_types, cf.param_types, 0..) |a, b, i| {
        sameShape(a.?, b.?, name ++ " parameter " ++ std.fmt.comptimePrint("{d}", .{i}));
    }
    sameShape(zf.return_type.?, cf.return_type.?, name ++ " result");
}

fn checkEnum(comptime E: type, comptime prefix: []const u8) void {
    const e = @typeInfo(E).@"enum";
    inline for (e.field_names, e.field_values) |field_name, value| {
        const cname = prefix ++ field_name;
        if (!@hasDecl(h, cname)) fail(cname ++ " is not in the header");
        if (@field(h, cname) != value) fail(cname ++ " changed value");
    }
}

test "ABI: c.zig agrees with api.h, and binds all of it" {
    comptime {
        @setEvalBranchQuota(200_000);
        // Forward: every extern here matches the header.
        for (@typeInfo(c).@"struct".decl_names) |name| {
            if (std.mem.startsWith(u8, name, "ts_") and @typeInfo(@TypeOf(@field(c, name))) == .@"fn") {
                if (!@hasDecl(h, name)) fail(name ++ " is not in the header");
                checkFunction(name);
            }
        }
        // Reverse: every header function is bound or excluded by name.
        // Excluded names are skipped before they are touched: referring to an
        // extern the library does not define is an undefined symbol on ELF.
        for (@typeInfo(h).@"struct".decl_names) |name| {
            if (!std.mem.startsWith(u8, name, "ts_")) continue;
            const skip = for (excluded) |e| {
                if (std.mem.eql(u8, e, name)) break true;
            } else false;
            if (skip) continue;
            if (@typeInfo(@TypeOf(@field(h, name))) != .@"fn") continue;
            if (!@hasDecl(c, name)) fail(name ++ " is in the header but not bound");
        }
        sameShape(c.TSPoint, h.TSPoint, "TSPoint");
        sameShape(c.TSRange, h.TSRange, "TSRange");
        sameShape(c.TSInput, h.TSInput, "TSInput");
        sameShape(c.TSParseState, h.TSParseState, "TSParseState");
        sameShape(c.TSParseOptions, h.TSParseOptions, "TSParseOptions");
        sameShape(c.TSLogger, h.TSLogger, "TSLogger");
        sameShape(c.TSInputEdit, h.TSInputEdit, "TSInputEdit");
        sameShape(c.TSNode, h.TSNode, "TSNode");
        sameShape(c.TSTreeCursor, h.TSTreeCursor, "TSTreeCursor");
        sameShape(c.TSQueryCapture, h.TSQueryCapture, "TSQueryCapture");
        sameShape(c.TSQueryMatch, h.TSQueryMatch, "TSQueryMatch");
        sameShape(c.TSQueryPredicateStep, h.TSQueryPredicateStep, "TSQueryPredicateStep");
        sameShape(c.TSQueryCursorState, h.TSQueryCursorState, "TSQueryCursorState");
        sameShape(c.TSQueryCursorOptions, h.TSQueryCursorOptions, "TSQueryCursorOptions");
        sameShape(c.TSLanguageMetadata, h.TSLanguageMetadata, "TSLanguageMetadata");
        checkEnum(c.TSInputEncoding, "TSInputEncoding");
        checkEnum(c.TSSymbolType, "TSSymbolType");
        checkEnum(c.TSLogType, "TSLogType");
        checkEnum(c.TSQuantifier, "TSQuantifier");
        checkEnum(c.TSQueryPredicateStepType, "TSQueryPredicateStepType");
        checkEnum(c.TSQueryError, "TSQueryError");
        if (h.TREE_SITTER_LANGUAGE_VERSION != c.LANGUAGE_VERSION) fail("LANGUAGE_VERSION");
        if (h.TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION != c.MIN_COMPATIBLE_LANGUAGE_VERSION) fail("MIN_COMPATIBLE_LANGUAGE_VERSION");
    }
}
