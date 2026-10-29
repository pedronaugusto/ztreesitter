//! Lua patterns, for Neovim's `lua-match?` and `gsub!`.
//!
//! A port of the matcher in Lua 5.1's `lstrlib.c`, which is what Neovim's
//! `string.find` runs: classes (`%a %c %d %g %l %p %s %u %w %x` and their
//! complements), sets, `. * + - ?`, anchors, captures, back-references, `%b`
//! and `%f`. Byte-oriented, like Lua. It backtracks, so it needs the subject
//! contiguous; recursion is bounded as `lstrlib.c` bounds it.
//!
//! Backtracking can take time polynomial in the subject's length (`a*a*a*b`
//! on a run of `a`s), so a search is bounded: it is a cancellation point,
//! and it stops with `error.TooManySteps` after `step_budget` steps, as it
//! does past `lstrlib.c`'s recursion limit ("pattern too complex").

const std = @import("std");

pub const Error = error{InvalidPattern};

/// Why a search of a valid pattern stops without an answer.
pub const FindError = error{ Canceled, TooManySteps };

/// Steps one search may take: each pattern item tried at a position, and
/// each byte a repetition or `%b` scans. Linear patterns over a 16 KB node
/// take well under a million.
pub const step_budget = 1 << 24;
/// How often, in steps, a search checks for cancellation.
const cancel_interval = 4096;

const max_captures = 32;
const max_depth = 200;
const cap_unfinished = -1;
const cap_position = -2;

/// Steps counted across every start position of one search.
const Budget = struct {
    io: std.Io,
    steps: u32 = 0,

    fn step(b: *Budget) FindError!void {
        b.steps += 1;
        if (b.steps > step_budget) return error.TooManySteps;
        if (b.steps % cancel_interval == 0) try b.io.checkCancel();
    }
};

const State = struct {
    src: []const u8,
    pat: []const u8,
    budget: *Budget,
    level: usize = 0,
    depth: usize = 0,
    capture: [max_captures]struct { start: usize, len: isize } = undefined,
};

/// What matching a validated pattern can fail with: `InvalidPattern` only
/// for one `validate` would refuse.
const MatchError = Error || FindError;

fn classEnd(pat: []const u8, p0: usize) Error!usize {
    var p = p0;
    const ch = pat[p];
    p += 1;
    if (ch == '%') {
        if (p >= pat.len) return error.InvalidPattern;
        return p + 1;
    }
    if (ch == '[') {
        if (p < pat.len and pat[p] == '^') p += 1;
        // Look for a `]`; the first character of the set may be one.
        while (true) {
            if (p >= pat.len) return error.InvalidPattern;
            const cc = pat[p];
            p += 1;
            if (cc == '%') {
                if (p >= pat.len) return error.InvalidPattern;
                p += 1;
            }
            if (p < pat.len and pat[p] == ']') return p + 1;
            if (p >= pat.len) return error.InvalidPattern;
        }
    }
    return p;
}

fn singleClass(ch: u8, cl: u8) bool {
    const res = switch (std.ascii.toLower(cl)) {
        'a' => std.ascii.isAlphabetic(ch),
        'c' => std.ascii.isControl(ch),
        'd' => std.ascii.isDigit(ch),
        'g' => ch > 32 and ch < 127,
        'l' => std.ascii.isLower(ch),
        'p' => std.ascii.isPrint(ch) and !std.ascii.isAlphanumeric(ch) and ch != ' ',
        's' => std.ascii.isWhitespace(ch),
        'u' => std.ascii.isUpper(ch),
        'w' => std.ascii.isAlphanumeric(ch),
        'x' => std.ascii.isHex(ch),
        else => return cl == ch,
    };
    return if (std.ascii.isUpper(cl)) !res else res;
}

fn matchBracket(ch: u8, pat: []const u8, p0: usize, ec: usize) bool {
    // pat[p0] is '[', pat[ec] is ']'.
    var p = p0 + 1;
    var sig = true;
    if (pat[p] == '^') {
        sig = false;
        p += 1;
    }
    while (p < ec) : (p += 1) {
        if (pat[p] == '%') {
            p += 1;
            if (singleClass(ch, pat[p])) return sig;
        } else if (p + 2 < ec and pat[p + 1] == '-') {
            if (pat[p] <= ch and ch <= pat[p + 2]) return sig;
            p += 2;
        } else if (pat[p] == ch) return sig;
    }
    return !sig;
}

fn singleMatch(s: *const State, i: usize, p: usize, ep: usize) bool {
    if (i >= s.src.len) return false;
    const ch = s.src[i];
    return switch (s.pat[p]) {
        '.' => true,
        '%' => singleClass(ch, s.pat[p + 1]),
        '[' => matchBracket(ch, s.pat, p, ep - 1),
        else => s.pat[p] == ch,
    };
}

fn doMatch(s: *State, start_i: usize, p0: usize) MatchError!?usize {
    var i = start_i;
    var p = p0;
    s.depth += 1;
    defer s.depth -= 1;
    if (s.depth > max_depth) return error.TooManySteps;
    while (true) {
        try s.budget.step();
        if (p == s.pat.len) return i;
        switch (s.pat[p]) {
            '(' => {
                if (p + 1 < s.pat.len and s.pat[p + 1] == ')') return startCapture(s, i, p + 2, cap_position);
                return startCapture(s, i, p + 1, cap_unfinished);
            },
            ')' => return endCapture(s, i, p + 1),
            '%' => if (p + 1 < s.pat.len) switch (s.pat[p + 1]) {
                'b' => {
                    i = try matchBalance(s, i, p + 2) orelse return null;
                    p += 4;
                    continue;
                },
                'f' => {
                    p += 2;
                    if (p >= s.pat.len or s.pat[p] != '[') return error.InvalidPattern;
                    const ep = try classEnd(s.pat, p);
                    const prev: u8 = if (i == 0) 0 else s.src[i - 1];
                    const cur: u8 = if (i < s.src.len) s.src[i] else 0;
                    if (!matchBracket(prev, s.pat, p, ep - 1) and matchBracket(cur, s.pat, p, ep - 1)) {
                        p = ep;
                        continue;
                    }
                    return null;
                },
                '0'...'9' => {
                    i = try matchCapture(s, i, s.pat[p + 1]) orelse return null;
                    p += 2;
                    continue;
                },
                else => {},
            },
            '$' => if (p + 1 == s.pat.len) return if (i == s.src.len) i else null,
            else => {},
        }
        const ep = try classEnd(s.pat, p);
        const m = singleMatch(s, i, p, ep);
        const op: u8 = if (ep < s.pat.len) s.pat[ep] else 0;
        switch (op) {
            '?' => {
                if (m) if (try doMatch(s, i + 1, ep + 1)) |r| return r;
                p = ep + 1;
                continue;
            },
            '*' => return maxExpand(s, i, p, ep),
            '+' => return if (m) maxExpand(s, i + 1, p, ep) else null,
            '-' => return minExpand(s, i, p, ep),
            else => {
                if (!m) return null;
                i += 1;
                p = ep;
            },
        }
    }
}

fn maxExpand(s: *State, i: usize, p: usize, ep: usize) MatchError!?usize {
    var n: usize = 0;
    while (singleMatch(s, i + n, p, ep)) {
        try s.budget.step();
        n += 1;
    }
    while (true) {
        if (try doMatch(s, i + n, ep + 1)) |r| return r;
        if (n == 0) return null;
        n -= 1;
    }
}

fn minExpand(s: *State, start_i: usize, p: usize, ep: usize) MatchError!?usize {
    var i = start_i;
    while (true) {
        if (try doMatch(s, i, ep + 1)) |r| return r;
        if (singleMatch(s, i, p, ep)) i += 1 else return null;
    }
}

fn startCapture(s: *State, i: usize, p: usize, what: isize) MatchError!?usize {
    if (s.level >= max_captures) return error.InvalidPattern;
    s.capture[s.level] = .{ .start = i, .len = what };
    s.level += 1;
    const r = try doMatch(s, i, p);
    if (r == null) s.level -= 1;
    return r;
}

fn endCapture(s: *State, i: usize, p: usize) MatchError!?usize {
    var l: isize = @as(isize, @intCast(s.level)) - 1;
    while (l >= 0) : (l -= 1) {
        if (s.capture[@intCast(l)].len == cap_unfinished) break;
    }
    if (l < 0) return error.InvalidPattern;
    const idx: usize = @intCast(l);
    s.capture[idx].len = @intCast(i - s.capture[idx].start);
    const r = try doMatch(s, i, p);
    if (r == null) s.capture[idx].len = cap_unfinished;
    return r;
}

fn matchBalance(s: *State, i: usize, p: usize) FindError!?usize {
    if (p + 1 >= s.pat.len) return null;
    if (i >= s.src.len or s.src[i] != s.pat[p]) return null;
    const open = s.pat[p];
    const close = s.pat[p + 1];
    var cont: usize = 1;
    var j = i + 1;
    while (j < s.src.len) : (j += 1) {
        try s.budget.step();
        if (s.src[j] == close) {
            cont -= 1;
            if (cont == 0) return j + 1;
        } else if (s.src[j] == open) cont += 1;
    }
    return null;
}

fn matchCapture(s: *State, i: usize, digit: u8) Error!?usize {
    const l = digit - '1';
    if (digit < '1' or l >= s.level or s.capture[l].len == cap_unfinished) return error.InvalidPattern;
    const cap = s.capture[l];
    const len: usize = @intCast(@max(cap.len, 0));
    if (s.src.len - i >= len and std.mem.eql(u8, s.src[cap.start..][0..len], s.src[i..][0..len])) return i + len;
    return null;
}

/// Lua's `string.find(subject, pattern) ~= nil`. A cancellation point on
/// `io`.
pub fn find(io: std.Io, subject: []const u8, pattern: Pattern) FindError!bool {
    return (try findAt(io, subject, pattern)) != null;
}

pub const Found = struct { start: usize, end: usize };

pub fn findAt(io: std.Io, subject: []const u8, pattern: Pattern) FindError!?Found {
    var pat = pattern.text;
    const anchored = pat.len > 0 and pat[0] == '^';
    if (anchored) pat = pat[1..];
    var budget: Budget = .{ .io = io };
    // Each start position, the end of the subject included; one if anchored.
    const starts = if (anchored) 1 else subject.len + 1;
    for (0..starts) |start| {
        var s: State = .{ .src = subject, .pat = pat, .budget = &budget };
        const end = doMatch(&s, start, 0) catch |err| switch (err) {
            error.InvalidPattern => unreachable, // unreachable: `Pattern.init` refused every pattern doMatch refuses
            else => |e| return e,
        };
        if (end) |e| return .{ .start = start, .end = e };
    }
    return null;
}

/// A pattern `validate` accepted, which matching cannot refuse.
pub const Pattern = struct {
    text: []const u8,

    pub fn init(text: []const u8) Error!Pattern {
        try validate(text);
        return .{ .text = text };
    }
};

/// Check that `pattern` is well formed, without a subject: everything
/// matching would otherwise refuse. Captures are balanced and at most
/// `max_captures`, `%b` has its two characters, `%f` its set, and a
/// back-reference names a capture closed before it.
pub fn validate(pattern: []const u8) Error!void {
    var p: usize = if (pattern.len > 0 and pattern[0] == '^') 1 else 0;
    var count: usize = 0;
    // The captures still open, by number.
    var open: [max_captures]usize = undefined;
    var open_len: usize = 0;
    while (p < pattern.len) {
        switch (pattern[p]) {
            '(' => {
                if (count == max_captures) return error.InvalidPattern;
                if (p + 1 < pattern.len and pattern[p + 1] == ')') {
                    // A position capture: closed as it opens.
                    p += 2;
                } else {
                    open[open_len] = count;
                    open_len += 1;
                    p += 1;
                }
                count += 1;
                continue;
            },
            ')' => {
                if (open_len == 0) return error.InvalidPattern;
                open_len -= 1;
                p += 1;
                continue;
            },
            '%' => if (p + 1 < pattern.len) switch (pattern[p + 1]) {
                'b' => {
                    if (p + 3 >= pattern.len) return error.InvalidPattern;
                    p += 4;
                    continue;
                },
                'f' => {
                    if (p + 2 >= pattern.len or pattern[p + 2] != '[') return error.InvalidPattern;
                    p += 2;
                    continue;
                },
                '0'...'9' => |digit| {
                    if (digit == '0') return error.InvalidPattern;
                    const l: usize = digit - '1';
                    if (l >= count) return error.InvalidPattern;
                    for (open[0..open_len]) |o| if (o == l) return error.InvalidPattern;
                },
                else => {},
            },
            else => {},
        }
        p = try classEnd(pattern, p);
    }
    if (open_len != 0) return error.InvalidPattern;
}

test "Lua patterns as Neovim's lua-match? uses them" {
    const t = std.testing;
    try t.expect(try finds("FOO_BAR", "^[A-Z][A-Z_0-9]*$"));
    try t.expect(!try finds("Foo", "^[A-Z][A-Z_0-9]*$"));
    try t.expect(try finds("  x", "^%s+"));
    try t.expect(try finds("a.b", "%."));
    try t.expect(!try finds("ab", "%."));
    try t.expect(try finds("--- doc", "^%-%-%-"));
    try t.expect(try finds("@param", "^@%a+$"));
    try t.expect(try finds("f(a(b)c)", "%b()"));
    try t.expect(try finds("THE (quick) fox", "%f[%a]%a+"));
    try t.expect(try finds("hello hello", "(h%a+) %1"));
    try t.expect(try finds("abc", "a.-c"));
    try t.expect(try finds("ac", "ab?c"));
    try t.expect(!try finds("abbc", "^ab?c$"));
    try t.expect(try finds("", "^$"));
    try t.expect(try finds("x]", "[]]"));
    try t.expectError(error.InvalidPattern, validate("[abc"));
    try t.expectError(error.InvalidPattern, validate("(abc"));
    try validate("^[A-Z][A-Z_0-9]*$");
}

fn finds(subject: []const u8, pattern: []const u8) !bool {
    return find(std.testing.io, subject, try .init(pattern));
}

test "validation refuses what matching would" {
    const t = std.testing;
    for ([_][]const u8{ "%1", "(a%1)", "%0", "(a)%2", "%f", "%fa", "%b(", ")" }) |pattern| {
        try t.expectError(error.InvalidPattern, validate(pattern));
    }
    try validate("(a)%1");
    try validate("()a%1");
    try validate("%f[%w]");
    var buffer: [2 * (max_captures + 1)]u8 = undefined;
    try t.expectError(error.InvalidPattern, validate(repeat(&buffer, "()", max_captures + 1)));
    try validate(repeat(&buffer, "()", max_captures));
}

test "a search past its step budget stops" {
    const t = std.testing;
    // Five nested repetitions over a run that never ends in `b`: polynomial
    // backtracking, far past the budget.
    const run: [4096]u8 = @splat('a');
    try t.expectError(error.TooManySteps, finds(&run, "a*a*a*a*a*b"));
    // The same pattern where it matches is quick.
    try t.expect(try finds("aaab", "a*a*a*a*a*b"));
    // Deep recursion is the same refusal, as in Lua ("pattern too complex").
    var buffer: [600]u8 = undefined;
    try t.expectError(error.TooManySteps, finds(&run, repeat(&buffer, "a?", 300)));
}

fn repeat(buffer: []u8, item: []const u8, n: usize) []const u8 {
    for (0..n) |k| @memcpy(buffer[k * item.len ..][0..item.len], item);
    return buffer[0 .. n * item.len];
}
