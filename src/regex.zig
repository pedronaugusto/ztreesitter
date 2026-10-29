//! Regular expressions for query predicates, in two dialects.
//!
//! - `.vim`: what Neovim's `match?` sees. Neovim prepends `\v` to every
//!   pattern that does not choose a mode itself, so this is Vim's very-magic
//!   syntax: `=` is `?`, `<` and `>` are word boundaries, `%(` opens a group,
//!   `\c` makes the whole pattern ignore case.
//! - `.rust`: what tree-sitter's own binding and Helix use, the `regex`
//!   crate's syntax: `(?i)`, `(?:`, `\A`, `\z`, `\b`.
//!
//! Both parse into one program for a Pike VM. Matching is a search (the
//! pattern may match anywhere), runs in time linear in the text, never
//! backtracks, reads the text in chunks of any size, and allocates nothing:
//! a `Matcher`'s thread lists are fixed arrays sized by `max_instructions`.
//!
//! What is not supported fails to compile with `error.InvalidPattern`:
//! lookaround (Vim's `@=`, `@!`), back-references, Vim's `\%` atoms and `~`,
//! and Unicode classes. `\w`, `\d` and `\s` are ASCII in both dialects, as
//! they are in Vim.

const std = @import("std");

pub const Dialect = enum { vim, rust };

pub const max_instructions = 4096;

pub const Error = error{ InvalidPattern, OutOfMemory };

const Assertion = enum {
    text_start,
    text_end,
    line_start,
    line_end,
    word_boundary,
    not_word_boundary,
    word_start,
    word_end,
};

const Inst = union(enum) {
    char: u21,
    any: void, // any code point but '\n'
    class: u16, // index into `classes`
    split: [2]u16,
    jump: u16,
    assert: Assertion,
    match: void,
};

const Class = struct {
    negated: bool,
    /// Inclusive code point ranges.
    ranges: []const [2]u21,
};

pub const Program = struct {
    insts: []const Inst,
    classes: []const Class,
    ignore_case: bool,

    pub fn deinit(p: *Program, gpa: std.mem.Allocator) void {
        for (p.classes) |cls| gpa.free(cls.ranges);
        gpa.free(p.classes);
        gpa.free(p.insts);
        p.* = undefined;
    }

    pub fn isMatch(p: *const Program, text: []const u8) bool {
        var m: Matcher = undefined;
        m.start(p);
        m.feed(text);
        return m.finish();
    }
};

// ---------------------------------------------------------------------------
// Parsing into a tree
// ---------------------------------------------------------------------------

const Node = union(enum) {
    empty,
    char: u21,
    any,
    class: u16,
    assert: Assertion,
    concat: []const u32,
    alt: []const u32,
    repeat: struct { node: u32, min: u32, max: ?u32 },
};

const Parser = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    dialect: Dialect,
    nodes: std.ArrayList(Node) = .empty,
    classes: std.ArrayList(Class) = .empty,
    ignore_case: bool = false,

    fn add(p: *Parser, n: Node) Error!u32 {
        try p.nodes.append(p.arena, n);
        return @intCast(p.nodes.items.len - 1);
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }

    fn eat(p: *Parser, ch: u8) bool {
        if (p.peek() == ch) {
            p.pos += 1;
            return true;
        }
        return false;
    }

    fn codepoint(p: *Parser) Error!u21 {
        const len = std.unicode.utf8ByteSequenceLength(p.src[p.pos]) catch return error.InvalidPattern;
        if (p.pos + len > p.src.len) return error.InvalidPattern;
        const cp = decodeUtf8(p.src[p.pos..][0..len]) catch return error.InvalidPattern;
        p.pos += len;
        return cp;
    }

    fn alternation(p: *Parser) Error!u32 {
        var branches: std.ArrayList(u32) = .empty;
        try branches.append(p.arena, try p.concatenation());
        while (p.eat('|')) try branches.append(p.arena, try p.concatenation());
        if (branches.items.len == 1) return branches.items[0];
        return p.add(.{ .alt = branches.items });
    }

    fn concatenation(p: *Parser) Error!u32 {
        var items: std.ArrayList(u32) = .empty;
        while (p.peek()) |ch| {
            if (ch == '|' or ch == ')') break;
            const unit = (try p.atom()) orelse continue;
            try items.append(p.arena, try p.quantified(unit));
        }
        if (items.items.len == 0) return p.add(.empty);
        if (items.items.len == 1) return items.items[0];
        return p.add(.{ .concat = items.items });
    }

    fn quantified(p: *Parser, unit: u32) Error!u32 {
        var node = unit;
        while (p.peek()) |ch| {
            const q: ?[2]?u32 = switch (ch) {
                '*' => .{ 0, null },
                '+' => .{ 1, null },
                '?' => .{ 0, 1 },
                '=' => if (p.dialect == .vim) .{ 0, 1 } else null,
                '{' => try p.braces(),
                else => null,
            };
            const bounds = q orelse break;
            if (ch != '{') p.pos += 1;
            // A lazy or possessive suffix changes which match is found, not
            // whether one is, so it is accepted and ignored.
            if (p.dialect == .rust) _ = p.eat('?') or p.eat('+');
            node = try p.add(.{ .repeat = .{ .node = node, .min = bounds[0].?, .max = bounds[1] } });
        }
        return node;
    }

    /// `{n}`, `{n,}`, `{,m}`, `{n,m}`; Vim also `{-...}` and `{}`.
    fn braces(p: *Parser) Error!?[2]?u32 {
        const start = p.pos;
        p.pos += 1;
        if (p.dialect == .vim) _ = p.eat('-');
        const lo = p.number();
        var hi: ?u32 = lo;
        if (p.eat(',')) hi = p.number();
        if (p.dialect == .vim) _ = p.eat('\\');
        if (!p.eat('}')) {
            if (p.dialect == .rust) {
                // The regex crate takes a `{` that opens no repetition literally.
                p.pos = start;
                return null;
            }
            return error.InvalidPattern;
        }
        const min = lo orelse 0;
        if (hi) |h| if (h < min) return error.InvalidPattern;
        if (lo == null and hi == null) return .{ 0, null };
        return .{ min, hi };
    }

    fn number(p: *Parser) ?u32 {
        var value: ?u32 = null;
        while (p.peek()) |ch| {
            if (ch < '0' or ch > '9') break;
            value = (value orelse 0) *| 10 +| (ch - '0');
            p.pos += 1;
        }
        return value;
    }

    fn atom(p: *Parser) Error!?u32 {
        const ch = p.peek().?;
        switch (ch) {
            '(' => {
                p.pos += 1;
                if (p.dialect == .rust and p.eat('?')) {
                    // Flags: `(?i)`, `(?i:...)`, `(?:...)`.
                    var negate = false;
                    while (p.peek()) |f| {
                        switch (f) {
                            'i' => p.ignore_case = !negate,
                            'm', 's', 'x', 'u', 'U', 'R' => {},
                            '-' => negate = true,
                            ':' => break,
                            ')' => {
                                p.pos += 1;
                                return null;
                            },
                            else => return error.InvalidPattern,
                        }
                        p.pos += 1;
                    }
                    if (!p.eat(':')) return error.InvalidPattern;
                }
                const inner = try p.alternation();
                if (!p.eat(')')) return error.InvalidPattern;
                return inner;
            },
            '[' => return try p.bracket(),
            '.' => {
                p.pos += 1;
                return try p.add(.any);
            },
            '^' => {
                p.pos += 1;
                return try p.add(.{ .assert = if (p.dialect == .vim) .line_start else .text_start });
            },
            '$' => {
                p.pos += 1;
                return try p.add(.{ .assert = if (p.dialect == .vim) .line_end else .text_end });
            },
            '\\' => return try p.escape(),
            '*', '+', '?' => return error.InvalidPattern,
            else => {},
        }
        if (p.dialect == .vim) switch (ch) {
            '<' => {
                p.pos += 1;
                return try p.add(.{ .assert = .word_start });
            },
            '>' => {
                p.pos += 1;
                return try p.add(.{ .assert = .word_end });
            },
            '%' => {
                p.pos += 1;
                if (!p.eat('(')) return error.InvalidPattern;
                const inner = try p.alternation();
                if (!p.eat(')')) return error.InvalidPattern;
                return inner;
            },
            '=', '{', '@', '~', '&' => return error.InvalidPattern,
            else => {},
        };
        return try p.add(.{ .char = try p.codepoint() });
    }

    fn escape(p: *Parser) Error!?u32 {
        p.pos += 1;
        const ch = p.peek() orelse return error.InvalidPattern;
        p.pos += 1;
        if (p.dialect == .vim) switch (ch) {
            'c' => {
                p.ignore_case = true;
                return null;
            },
            'C' => {
                p.ignore_case = false;
                return null;
            },
            'e' => return try p.add(.{ .char = 0x1b }),
            'a', 'A', 'l', 'L', 'u', 'U', 'x', 'X', 'h', 'H', 'o', 'O' => return try p.add(.{ .class = try p.named(ch) }),
            '%', 'z', '@' => if (ch != '@') return error.InvalidPattern,
            else => {},
        } else switch (ch) {
            'A' => return try p.add(.{ .assert = .text_start }),
            'z' => return try p.add(.{ .assert = .text_end }),
            'b' => return try p.add(.{ .assert = .word_boundary }),
            'B' => return try p.add(.{ .assert = .not_word_boundary }),
            'x', 'u', 'p', 'P' => return error.InvalidPattern,
            else => {},
        }
        switch (ch) {
            'w', 'W', 'd', 'D', 's', 'S' => return try p.add(.{ .class = try p.named(ch) }),
            'n' => return try p.add(.{ .char = '\n' }),
            't' => return try p.add(.{ .char = '\t' }),
            'r' => return try p.add(.{ .char = '\r' }),
            'f' => return try p.add(.{ .char = 0x0c }),
            'v' => return try p.add(.{ .char = 0x0b }),
            '0'...'9' => return error.InvalidPattern,
            else => {
                if (std.ascii.isAlphabetic(ch)) return error.InvalidPattern;
                p.pos -= 1;
                return try p.add(.{ .char = try p.codepoint() });
            },
        }
    }

    fn namedRanges(ch: u8) struct { []const [2]u21, bool } {
        const word = &[_][2]u21{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ '_', '_' }, .{ 'a', 'z' } };
        const digit = &[_][2]u21{.{ '0', '9' }};
        const space = &[_][2]u21{ .{ '\t', '\r' }, .{ ' ', ' ' } };
        const alpha = &[_][2]u21{ .{ 'A', 'Z' }, .{ 'a', 'z' } };
        const lower = &[_][2]u21{.{ 'a', 'z' }};
        const upper = &[_][2]u21{.{ 'A', 'Z' }};
        const hex = &[_][2]u21{ .{ '0', '9' }, .{ 'A', 'F' }, .{ 'a', 'f' } };
        const head = &[_][2]u21{ .{ 'A', 'Z' }, .{ '_', '_' }, .{ 'a', 'z' } };
        const octal = &[_][2]u21{.{ '0', '7' }};
        return switch (ch) {
            'w' => .{ word, false },
            'W' => .{ word, true },
            'd' => .{ digit, false },
            'D' => .{ digit, true },
            's' => .{ space, false },
            'S' => .{ space, true },
            'a' => .{ alpha, false },
            'A' => .{ alpha, true },
            'l' => .{ lower, false },
            'L' => .{ lower, true },
            'u' => .{ upper, false },
            'U' => .{ upper, true },
            'x' => .{ hex, false },
            'X' => .{ hex, true },
            'h' => .{ head, false },
            'H' => .{ head, true },
            'o' => .{ octal, false },
            'O' => .{ octal, true },
            else => unreachable,
        };
    }

    fn named(p: *Parser, ch: u8) Error!u16 {
        const ranges, const negated = namedRanges(ch);
        return p.addClass(negated, ranges);
    }

    fn addClass(p: *Parser, negated: bool, ranges: []const [2]u21) Error!u16 {
        if (p.classes.items.len >= std.math.maxInt(u16)) return error.InvalidPattern;
        const owned = try p.gpa.dupe([2]u21, ranges);
        errdefer p.gpa.free(owned);
        try p.classes.append(p.gpa, .{ .negated = negated, .ranges = owned });
        return @intCast(p.classes.items.len - 1);
    }

    fn bracket(p: *Parser) Error!u32 {
        p.pos += 1;
        const negated = p.eat('^');
        var ranges: std.ArrayList([2]u21) = .empty;
        var first = true;
        while (true) {
            const ch = p.peek() orelse return error.InvalidPattern;
            if (ch == ']' and !first) {
                p.pos += 1;
                break;
            }
            first = false;
            if (ch == '[' and p.pos + 1 < p.src.len and p.src[p.pos + 1] == ':') {
                try p.posixClass(&ranges);
                continue;
            }
            const lo = try p.bracketChar(&ranges) orelse continue;
            var hi = lo;
            if (p.peek() == '-' and p.pos + 1 < p.src.len and p.src[p.pos + 1] != ']') {
                p.pos += 1;
                hi = try p.bracketChar(&ranges) orelse return error.InvalidPattern;
                if (hi < lo) return error.InvalidPattern;
            }
            try ranges.append(p.arena, .{ lo, hi });
        }
        return p.add(.{ .class = try p.addClass(negated, ranges.items) });
    }

    /// One member of a bracket expression; a named class (`\d`) is added to
    /// `ranges` directly and yields null.
    fn bracketChar(p: *Parser, ranges: *std.ArrayList([2]u21)) Error!?u21 {
        if (p.peek() != '\\') return try p.codepoint();
        p.pos += 1;
        const ch = p.peek() orelse return error.InvalidPattern;
        p.pos += 1;
        switch (ch) {
            'n' => return '\n',
            't' => return '\t',
            'r' => return '\r',
            'e' => return 0x1b,
            'w', 'd', 's' => {
                const named_ranges, _ = namedRanges(ch);
                try ranges.appendSlice(p.arena, named_ranges);
                return null;
            },
            'W', 'D', 'S' => return error.InvalidPattern,
            else => {
                if (std.ascii.isAlphanumeric(ch)) return error.InvalidPattern;
                p.pos -= 1;
                return try p.codepoint();
            },
        }
    }

    fn posixClass(p: *Parser, ranges: *std.ArrayList([2]u21)) Error!void {
        const end = std.mem.findPos(u8, p.src, p.pos + 2, ":]") orelse return error.InvalidPattern;
        const name = p.src[p.pos + 2 .. end];
        p.pos = end + 2;
        const table = [_]struct { []const u8, []const [2]u21 }{
            .{ "alpha", &.{ .{ 'A', 'Z' }, .{ 'a', 'z' } } },
            .{ "digit", &.{.{ '0', '9' }} },
            .{ "alnum", &.{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ 'a', 'z' } } },
            .{ "upper", &.{.{ 'A', 'Z' }} },
            .{ "lower", &.{.{ 'a', 'z' }} },
            .{ "space", &.{ .{ '\t', '\r' }, .{ ' ', ' ' } } },
            .{ "blank", &.{ .{ '\t', '\t' }, .{ ' ', ' ' } } },
            .{ "xdigit", &.{ .{ '0', '9' }, .{ 'A', 'F' }, .{ 'a', 'f' } } },
            .{ "punct", &.{ .{ '!', '/' }, .{ ':', '@' }, .{ '[', '`' }, .{ '{', '~' } } },
            .{ "word", &.{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ '_', '_' }, .{ 'a', 'z' } } },
        };
        for (table) |entry| if (std.mem.eql(u8, entry[0], name)) {
            try ranges.appendSlice(p.arena, entry[1]);
            return;
        };
        return error.InvalidPattern;
    }
};

// ---------------------------------------------------------------------------
// Compiling the tree into a program
// ---------------------------------------------------------------------------

const Compiler = struct {
    gpa: std.mem.Allocator,
    nodes: []const Node,
    insts: std.ArrayList(Inst) = .empty,

    fn emit(c: *Compiler, inst: Inst) Error!u16 {
        if (c.insts.items.len >= max_instructions) return error.InvalidPattern;
        try c.insts.append(c.gpa, inst);
        return @intCast(c.insts.items.len - 1);
    }

    fn here(c: *Compiler) u16 {
        return @intCast(c.insts.items.len);
    }

    fn compile(c: *Compiler, index: u32) Error!void {
        switch (c.nodes[index]) {
            .empty => {},
            .char => |ch| _ = try c.emit(.{ .char = ch }),
            .any => _ = try c.emit(.any),
            .class => |k| _ = try c.emit(.{ .class = k }),
            .assert => |a| _ = try c.emit(.{ .assert = a }),
            .concat => |items| for (items) |item| try c.compile(item),
            .alt => |branches| {
                // split L1, next; L1: branch; jump end; next: split ...
                var jumps: std.ArrayList(u16) = .empty;
                defer jumps.deinit(c.gpa);
                for (branches, 0..) |branch, i| {
                    if (i + 1 < branches.len) {
                        const split = try c.emit(.{ .split = .{ 0, 0 } });
                        c.insts.items[split].split[0] = c.here();
                        try c.compile(branch);
                        try jumps.append(c.gpa, try c.emit(.{ .jump = 0 }));
                        c.insts.items[split].split[1] = c.here();
                    } else {
                        try c.compile(branch);
                    }
                }
                for (jumps.items) |j| c.insts.items[j].jump = c.here();
            },
            .repeat => |r| {
                var i: u32 = 0;
                while (i < r.min) : (i += 1) try c.compile(r.node);
                if (r.max) |max| {
                    // Each optional copy: split body, end.
                    var splits: std.ArrayList(u16) = .empty;
                    defer splits.deinit(c.gpa);
                    while (i < max) : (i += 1) {
                        const split = try c.emit(.{ .split = .{ 0, 0 } });
                        c.insts.items[split].split[0] = c.here();
                        try c.compile(r.node);
                        try splits.append(c.gpa, split);
                    }
                    for (splits.items) |s| c.insts.items[s].split[1] = c.here();
                } else {
                    // loop: split body, end; body; jump loop
                    const loop = try c.emit(.{ .split = .{ 0, 0 } });
                    c.insts.items[loop].split[0] = c.here();
                    try c.compile(r.node);
                    _ = try c.emit(.{ .jump = loop });
                    c.insts.items[loop].split[1] = c.here();
                }
            },
        }
    }
};

pub fn compile(gpa: std.mem.Allocator, pattern: []const u8, dialect: Dialect) Error!Program {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var parser: Parser = .{ .gpa = gpa, .arena = arena_state.allocator(), .src = pattern, .dialect = dialect };
    errdefer {
        for (parser.classes.items) |cls| gpa.free(cls.ranges);
        parser.classes.deinit(gpa);
    }
    // Neovim's own mode prefixes: `\v` is what it adds; others are refused
    // rather than silently read as very magic.
    if (dialect == .vim and pattern.len >= 2 and pattern[0] == '\\') switch (pattern[1]) {
        'v' => parser.pos = 2,
        'm', 'M', 'V' => return error.InvalidPattern,
        else => {},
    };
    const root = try parser.alternation();
    if (parser.pos != pattern.len) return error.InvalidPattern;

    var compiler: Compiler = .{ .gpa = gpa, .nodes = parser.nodes.items };
    errdefer compiler.insts.deinit(gpa);
    try compiler.compile(root);
    _ = try compiler.emit(.match);

    const classes = try parser.classes.toOwnedSlice(gpa);
    errdefer gpa.free(classes);
    return .{ .insts = try compiler.insts.toOwnedSlice(gpa), .classes = classes, .ignore_case = parser.ignore_case };
}

// ---------------------------------------------------------------------------
// The Pike VM
// ---------------------------------------------------------------------------

const Set = struct {
    dense: [max_instructions]u16,
    sparse: [max_instructions]u16,
    len: u16,

    fn clear(s: *Set) void {
        s.len = 0;
    }

    fn contains(s: *const Set, pc: u16) bool {
        const i = s.sparse[pc];
        return i < s.len and s.dense[i] == pc;
    }

    fn insert(s: *Set, pc: u16) void {
        s.sparse[pc] = s.len;
        s.dense[s.len] = pc;
        s.len += 1;
    }
};

const eof: u21 = std.math.maxInt(u21);

/// One UTF-8 sequence of one to four bytes, its length read from its first.
fn decodeUtf8(bytes: []const u8) error{InvalidUtf8}!u21 {
    return switch (bytes.len) {
        1 => bytes[0],
        2 => std.unicode.utf8Decode2(bytes[0..2].*) catch error.InvalidUtf8,
        3 => std.unicode.utf8Decode3(bytes[0..3].*) catch error.InvalidUtf8,
        4 => std.unicode.utf8Decode4(bytes[0..4].*) catch error.InvalidUtf8,
        else => error.InvalidUtf8,
    };
}

fn isWord(cp: u21) bool {
    return cp != eof and cp < 128 and (std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_');
}

fn fold(cp: u21) u21 {
    return if (cp < 128) std.ascii.toLower(@intCast(cp)) else cp;
}

/// One search, fed in chunks. About 40 KB; keep one per cursor and reuse it.
pub const Matcher = struct {
    program: *const Program,
    lists: [2]Set,
    current: u1,
    stack: [max_instructions]u16,
    matched: bool,
    /// The code point before the one waiting to be stepped, and that one.
    prev: u21,
    pending: ?u21,
    carry: [4]u8,
    carry_len: u3,

    pub fn start(m: *Matcher, program: *const Program) void {
        m.program = program;
        m.lists[0].clear();
        m.lists[1].clear();
        m.current = 0;
        m.matched = false;
        m.prev = eof;
        m.pending = null;
        m.carry_len = 0;
    }

    fn holds(m: *const Matcher, a: Assertion, prev: u21, cur: u21) bool {
        _ = m;
        return switch (a) {
            .text_start => prev == eof,
            .text_end => cur == eof,
            .line_start => prev == eof or prev == '\n',
            .line_end => cur == eof or cur == '\n',
            .word_boundary => isWord(prev) != isWord(cur),
            .not_word_boundary => isWord(prev) == isWord(cur),
            .word_start => !isWord(prev) and isWord(cur),
            .word_end => isWord(prev) and !isWord(cur),
        };
    }

    /// Add `pc` and everything reachable from it without consuming input.
    fn add(m: *Matcher, list: *Set, pc0: u16, prev: u21, cur: u21) void {
        var top: usize = 0;
        m.stack[top] = pc0;
        top += 1;
        while (top > 0) {
            top -= 1;
            const pc = m.stack[top];
            if (list.contains(pc)) continue;
            list.insert(pc);
            switch (m.program.insts[pc]) {
                .jump => |to| {
                    m.stack[top] = to;
                    top += 1;
                },
                .split => |to| {
                    m.stack[top] = to[1];
                    m.stack[top + 1] = to[0];
                    top += 2;
                },
                .assert => |a| if (m.holds(a, prev, cur)) {
                    m.stack[top] = pc + 1;
                    top += 1;
                },
                .match => m.matched = true,
                else => {},
            }
        }
    }

    fn accepts(m: *const Matcher, inst: Inst, cp: u21) bool {
        if (cp == eof) return false;
        const ic = m.program.ignore_case;
        return switch (inst) {
            .char => |ch| ch == cp or (ic and fold(ch) == fold(cp)),
            .any => cp != '\n',
            .class => |k| blk: {
                const cls = m.program.classes[k];
                var hit = false;
                for (cls.ranges) |r| {
                    if (cp >= r[0] and cp <= r[1]) hit = true;
                    if (ic and !hit) {
                        const f = fold(cp);
                        const up: u21 = if (cp < 128) std.ascii.toUpper(@intCast(cp)) else cp;
                        if ((f >= r[0] and f <= r[1]) or (up >= r[0] and up <= r[1])) hit = true;
                    }
                }
                break :blk hit != cls.negated;
            },
            else => false,
        };
    }

    /// Advance over `cp` (the code point at the current position), knowing
    /// the one after it, `next`.
    fn step(m: *Matcher, cp: u21, next: u21) void {
        const clist = &m.lists[m.current];
        // A new thread may start here: the search is unanchored.
        m.add(clist, 0, m.prev, cp);
        if (m.matched) return;
        const nlist = &m.lists[m.current +% 1];
        nlist.clear();
        var i: u16 = 0;
        while (i < clist.len) : (i += 1) {
            const pc = clist.dense[i];
            if (m.accepts(m.program.insts[pc], cp)) m.add(nlist, pc + 1, cp, next);
            if (m.matched) return;
        }
        clist.clear();
        m.current +%= 1;
        m.prev = cp;
    }

    fn push(m: *Matcher, cp: u21) void {
        if (m.pending) |p| m.step(p, cp);
        m.pending = cp;
    }

    /// Feed the next chunk of text. Chunks may split a code point.
    pub fn feed(m: *Matcher, chunk: []const u8) void {
        var i: usize = 0;
        while (i < chunk.len and !m.matched) {
            if (m.carry_len == 0) {
                const b = chunk[i];
                if (b < 0x80) {
                    m.push(b);
                    i += 1;
                    continue;
                }
            }
            m.carry[m.carry_len] = chunk[i];
            m.carry_len += 1;
            i += 1;
            const want = std.unicode.utf8ByteSequenceLength(m.carry[0]) catch {
                // Not UTF-8: take the byte as a code point of its own.
                m.push(m.carry[0]);
                m.carry_len = 0;
                continue;
            };
            if (m.carry_len < want) continue;
            const cp = decodeUtf8(m.carry[0..want]) catch m.carry[0];
            m.carry_len = 0;
            m.push(cp);
        }
    }

    /// End of text: true when the pattern matched somewhere.
    pub fn finish(m: *Matcher) bool {
        if (m.matched) return true;
        if (m.pending) |p| m.step(p, eof);
        if (m.matched) return true;
        // Threads waiting at the end, and one starting there.
        m.add(&m.lists[m.current], 0, m.prev, eof);
        return m.matched;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn expectMatch(dialect: Dialect, pattern: []const u8, text: []const u8, want: bool) !void {
    const gpa = std.testing.allocator;
    var p = try compile(gpa, pattern, dialect);
    defer p.deinit(gpa);
    if (p.isMatch(text) != want) {
        std.log.err("{s} /{s}/ on \"{s}\": expected {}", .{ @tagName(dialect), pattern, text, want });
        return error.TestUnexpectedResult;
    }
    // The same answer fed one byte at a time.
    const m = try gpa.create(Matcher);
    defer gpa.destroy(m);
    m.start(&p);
    for (0..text.len) |i| m.feed(text[i..][0..1]);
    try std.testing.expectEqual(want, m.finish());
}

test "rust dialect: what tags and grammar queries use" {
    try expectMatch(.rust, "^[A-Z]", "Foo", true);
    try expectMatch(.rust, "^[A-Z]", "foo", false);
    try expectMatch(.rust, "(?i)^(cl:)?defclass$", "CL:DEFCLASS", true);
    try expectMatch(.rust, "(?:^|\\.)[A-Z][^.]*$", "a.b.Cdef", true);
    try expectMatch(.rust, "(?:^|\\.)[A-Z][^.]*$", "a.Cd.ef", false);
    try expectMatch(.rust, "^#region\\b", "#region foo", true);
    try expectMatch(.rust, "^#region\\b", "#regional", false);
    try expectMatch(.rust, "^(\\+|-|\\*|/|=|>|<|>=|<=)$", ">=", true);
    try expectMatch(.rust, "^(\\+|-|\\*|/|=|>|<|>=|<=)$", "=>", false);
    try expectMatch(.rust, "^[%/][a-zA-Z][a-zA-Z0-9.]*$", "%foo.1", true);
    try expectMatch(.rust, "\\A[^\\n\\r]*\\{[\\t ]*(\\n|\\r)", "fn x {\n}", true);
    try expectMatch(.rust, "^-.", "-x", true);
    try expectMatch(.rust, "^-.", "-", false);
    try expectMatch(.rust, "a{2,3}$", "baa", true);
    try expectMatch(.rust, "^a{2,3}$", "aaaa", false);
    try expectMatch(.rust, "^((ENV|ARGV)|[_ab]|\\W|\\d+|\\^.*)$", "123", true);
    try expectMatch(.rust, "^((ENV|ARGV)|[_ab]|\\W|\\d+|\\^.*)$", "^x", true);
    try expectMatch(.rust, "^((ENV|ARGV)|[_ab]|\\W|\\d+|\\^.*)$", "xy", false);
    try expectMatch(.rust, "^(lambda|λ)$", "λ", true);
}

test "vim dialect: what nvim-treesitter's match? patterns mean" {
    // `=` is `?` in very magic mode, `\=` a literal `=`.
    try expectMatch(.vim, "^(!?\\=|-[a-zA-Z]+)$", "!=", true);
    try expectMatch(.vim, "^(!?\\=|-[a-zA-Z]+)$", "=", true);
    try expectMatch(.vim, "^(!?\\=|-[a-zA-Z]+)$", "-eq", true);
    try expectMatch(.vim, "^(!?\\=|-[a-zA-Z]+)$", "!", false);
    // `<` is a word start: "<=" outside a bracket is "word start, optional".
    try expectMatch(.vim, "^([+*-+=<>]|<=|>=|/=)$", "+", true);
    try expectMatch(.vim, "^([+*-+=<>]|<=|>=|/=)$", "/", true);
    try expectMatch(.vim, "^(:|v-bind|v-|\\@)", "@click", true);
    try expectMatch(.vim, "^(:|v-bind|v-|\\@)", "v-if", true);
    try expectMatch(.vim, "^(:|v-bind|v-|\\@)", "class", false);
    // `\c` anywhere makes the whole pattern ignore case.
    try expectMatch(.vim, "\\c^(continue|break)$", "CONTINUE", true);
    try expectMatch(.vim, "\\c^list$", "List", true);
    try expectMatch(.vim, "^list$", "List", false);
    try expectMatch(.vim, "^\\w+_(min|max|sdd|adev|median|sum(sq)?|(lo|up)_quartile)(_x|_y)?$", "foo_sumsq_y", true);
    try expectMatch(.vim, "^[A-Z][A-Z0-9_]+$|^[a-z]{2,3}[A-Z].+$", "abcDef", true);
    try expectMatch(.vim, "^[A-Z][A-Z0-9_]+$|^[a-z]{2,3}[A-Z].+$", "abcdef", false);
    try expectMatch(.vim, "^[-+]?[0-9]+(.[0-9]+)?$", "-12.5", true);
    try expectMatch(.vim, "/\\*!([a-zA-Z]+:)?re2c", "/*!re2c", true);
    try expectMatch(.vim, "^assert[A-Za-z_0-9]*|error|info$", "an error here", true);
    try expectMatch(.vim, "%(ab)+$", "xabab", true);
    try expectMatch(.vim, "<foo>", "a foo b", true);
    try expectMatch(.vim, "<foo>", "afoob", false);
}

test "patterns outside the supported set are refused" {
    const gpa = std.testing.allocator;
    for ([_]struct { Dialect, []const u8 }{
        .{ .vim, "foo@!bar" },
        .{ .vim, "\\%[abc]" },
        .{ .rust, "(?=x)" },
        .{ .rust, "\\p{L}" },
        .{ .rust, "(a" },
        .{ .rust, "[a" },
        .{ .vim, "\\mfoo" },
    }) |case| {
        try std.testing.expectError(error.InvalidPattern, compile(gpa, case[1], case[0]));
    }
}
