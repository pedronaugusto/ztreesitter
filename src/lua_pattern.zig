//! Lua patterns, for Neovim's `lua-match?` and `gsub!`.
//!
//! A port of the matcher in Lua 5.1's `lstrlib.c`, which is what Neovim's
//! `string.find` runs: classes (`%a %c %d %g %l %p %s %u %w %x` and their
//! complements), sets, `. * + - ?`, anchors, captures, back-references, `%b`
//! and `%f`. Byte-oriented, like Lua. It backtracks, so it needs the subject
//! contiguous; recursion is bounded as `lstrlib.c` bounds it.

const std = @import("std");

pub const Error = error{InvalidPattern};

const max_captures = 32;
const max_depth = 200;
const cap_unfinished = -1;
const cap_position = -2;

const State = struct {
    src: []const u8,
    pat: []const u8,
    level: usize = 0,
    depth: usize = 0,
    capture: [max_captures]struct { start: usize, len: isize } = undefined,
};

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

fn doMatch(s: *State, start_i: usize, p0: usize) Error!?usize {
    var i = start_i;
    var p = p0;
    s.depth += 1;
    defer s.depth -= 1;
    if (s.depth > max_depth) return error.InvalidPattern;
    while (true) {
        if (p == s.pat.len) return i;
        switch (s.pat[p]) {
            '(' => {
                if (p + 1 < s.pat.len and s.pat[p + 1] == ')') return startCapture(s, i, p + 2, cap_position);
                return startCapture(s, i, p + 1, cap_unfinished);
            },
            ')' => return endCapture(s, i, p + 1),
            '%' => if (p + 1 < s.pat.len) switch (s.pat[p + 1]) {
                'b' => {
                    i = matchBalance(s, i, p + 2) orelse return null;
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

fn maxExpand(s: *State, i: usize, p: usize, ep: usize) Error!?usize {
    var n: usize = 0;
    while (singleMatch(s, i + n, p, ep)) n += 1;
    while (true) {
        if (try doMatch(s, i + n, ep + 1)) |r| return r;
        if (n == 0) return null;
        n -= 1;
    }
}

fn minExpand(s: *State, start_i: usize, p: usize, ep: usize) Error!?usize {
    var i = start_i;
    while (true) {
        if (try doMatch(s, i, ep + 1)) |r| return r;
        if (singleMatch(s, i, p, ep)) i += 1 else return null;
    }
}

fn startCapture(s: *State, i: usize, p: usize, what: isize) Error!?usize {
    if (s.level >= max_captures) return error.InvalidPattern;
    s.capture[s.level] = .{ .start = i, .len = what };
    s.level += 1;
    const r = try doMatch(s, i, p);
    if (r == null) s.level -= 1;
    return r;
}

fn endCapture(s: *State, i: usize, p: usize) Error!?usize {
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

fn matchBalance(s: *State, i: usize, p: usize) ?usize {
    if (p + 1 >= s.pat.len) return null;
    if (i >= s.src.len or s.src[i] != s.pat[p]) return null;
    const open = s.pat[p];
    const close = s.pat[p + 1];
    var cont: usize = 1;
    var j = i + 1;
    while (j < s.src.len) : (j += 1) {
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

/// Lua's `string.find(subject, pattern) ~= nil`.
pub fn find(subject: []const u8, pattern: []const u8) Error!bool {
    return (try findAt(subject, pattern)) != null;
}

pub const Found = struct { start: usize, end: usize };

pub fn findAt(subject: []const u8, pattern: []const u8) Error!?Found {
    var pat = pattern;
    const anchored = pat.len > 0 and pat[0] == '^';
    if (anchored) pat = pat[1..];
    var start: usize = 0;
    while (true) {
        var s: State = .{ .src = subject, .pat = pat };
        if (try doMatch(&s, start, 0)) |end| return .{ .start = start, .end = end };
        start += 1;
        if (anchored or start > subject.len) return null;
    }
}

/// Check that `pattern` is well formed, without a subject.
pub fn validate(pattern: []const u8) Error!void {
    var p: usize = if (pattern.len > 0 and pattern[0] == '^') 1 else 0;
    var open: usize = 0;
    while (p < pattern.len) {
        switch (pattern[p]) {
            '(' => {
                open += 1;
                p += 1;
                continue;
            },
            ')' => {
                if (open == 0) return error.InvalidPattern;
                open -= 1;
                p += 1;
                continue;
            },
            '%' => if (p + 1 < pattern.len and (pattern[p + 1] == 'b')) {
                if (p + 3 >= pattern.len) return error.InvalidPattern;
                p += 4;
                continue;
            },
            else => {},
        }
        p = try classEnd(pattern, p);
    }
    if (open != 0) return error.InvalidPattern;
}

test "Lua patterns as Neovim's lua-match? uses them" {
    const t = std.testing;
    try t.expect(try find("FOO_BAR", "^[A-Z][A-Z_0-9]*$"));
    try t.expect(!try find("Foo", "^[A-Z][A-Z_0-9]*$"));
    try t.expect(try find("  x", "^%s+"));
    try t.expect(try find("a.b", "%."));
    try t.expect(!try find("ab", "%."));
    try t.expect(try find("--- doc", "^%-%-%-"));
    try t.expect(try find("@param", "^@%a+$"));
    try t.expect(try find("f(a(b)c)", "%b()"));
    try t.expect(try find("THE (quick) fox", "%f[%a]%a+"));
    try t.expect(try find("hello hello", "(h%a+) %1"));
    try t.expect(try find("abc", "a.-c"));
    try t.expect(try find("ac", "ab?c"));
    try t.expect(!try find("abbc", "^ab?c$"));
    try t.expect(try find("", "^$"));
    try t.expect(try find("x]", "[]]"));
    try t.expectError(error.InvalidPattern, validate("[abc"));
    try t.expectError(error.InvalidPattern, validate("(abc"));
    try validate("^[A-Z][A-Z_0-9]*$");
}
