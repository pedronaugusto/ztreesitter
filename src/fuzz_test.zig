//! Fuzz targets for the pattern languages predicates compile, as shakedown
//! properties: patterns drawn from the characters each syntax gives meaning
//! to, and subjects from a small alphabet so that patterns match them.

const std = @import("std");
const shakedown = @import("shakedown");
const regex = @import("regex.zig");
const lua = @import("lua_pattern.zig");
const testing = std.testing;

/// `len` at most `max` bytes, each from `alphabet`.
fn drawn(case: *shakedown.Case, alphabet: []const u8, max: usize) ![]u8 {
    const s = case.source;
    const out = try case.gpa.alloc(u8, shakedown.gen.intRange(s, usize, 0, max));
    for (out) |*b| b.* = alphabet[shakedown.gen.intRange(s, usize, 0, alphabet.len - 1)];
    return out;
}

const subject_alphabet = "aAb_1 .\n(é";

const regex_alphabets = [_][]const u8{
    // The regex crate's syntax.
    "ab.^$|()[]-*+?{},0123\\AzbBdDwWsS?:i-msxuUR",
    // Vim's very-magic syntax.
    "ab.^$|()[]-*+=@{},0123\\%<>cvVmM~&",
};

/// A pattern either compiles or is refused, and a compiled one gives one
/// answer however its subject is fed.
fn regexAnswersOnce(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const dialect: regex.Dialect = if (shakedown.gen.boolean(s)) .rust else .vim;
    const pattern = try drawn(case, regex_alphabets[@backingInt(dialect)], 24);
    const subject = try drawn(case, subject_alphabet, 64);
    case.note("{t} /{s}/ on \"{s}\"", .{ dialect, pattern, subject });
    var program = regex.compile(case.gpa, pattern, dialect) catch |err| switch (err) {
        error.InvalidPattern => return,
        error.OutOfMemory => |e| return e,
    };
    defer program.deinit(case.gpa);
    const whole = program.isMatch(subject);

    const m = try case.gpa.create(regex.Matcher);
    m.start(&program);
    var at: usize = 0;
    while (at < subject.len) {
        const n = shakedown.gen.intRange(s, usize, 1, subject.len - at);
        m.feed(subject[at..][0..n]);
        at += n;
    }
    try testing.expectEqual(whole, m.finish());
}

test "fuzz: a regular expression in either dialect compiles or is refused, and answers the same in pieces" {
    try shakedown.check(testing.allocator, {}, regexAnswersOnce, .{ .cases = 3000, .seed = 0x5e9e });
}

/// A pattern `Pattern.init` accepts is one matching never refuses: a
/// search ends with an answer, or stops at the step budget.
fn luaValidatedMatches(_: void, case: *shakedown.Case) !void {
    const pattern = try drawn(case, "^$ab.%()[]-*+?adlsuwxAbf1290", 20);
    const subject = try drawn(case, subject_alphabet, 64);
    case.note("/{s}/ on \"{s}\"", .{ pattern, subject });
    const compiled = lua.Pattern.init(pattern) catch return;
    _ = lua.findAt(case.io(), subject, compiled) catch |err| switch (err) {
        error.TooManySteps => {},
        error.Canceled => |e| return e,
    };
}

test "fuzz: a Lua pattern validation accepts is one matching never refuses" {
    try shakedown.check(testing.allocator, {}, luaValidatedMatches, .{ .cases = 3000, .seed = 0x1a5 });
}
