//! One short, valid text per grammar the suite knows, for the smoke test
//! that parses every selected grammar. Mirrors leave the grammars' own test
//! corpora out, so the samples live here.

pub const Sample = struct { name: []const u8, text: []const u8 };

pub const samples = [_]Sample{
    .{ .name = "bash", .text = "for f in *.zig; do\n  echo \"$f\" | wc -l\ndone\n" },
    .{ .name = "c", .text = "#include <stdio.h>\nstatic int add(int a, int b) { return a + b; }\nint main(void) { printf(\"%d\\n\", add(1, 2)); }\n" },
    .{ .name = "c_sharp", .text = "namespace App {\n  public record Point(int X, int Y);\n  class Program { static void Main() { var p = new Point(1, 2); System.Console.WriteLine(p.X); } }\n}\n" },
    .{ .name = "cpp", .text = "#include <vector>\ntemplate <typename T> T sum(const std::vector<T>& v) { T s{}; for (auto x : v) s += x; return s; }\n" },
    .{ .name = "css", .text = "a:hover { color: #fff; margin: 0 auto; }\n@media (max-width: 600px) { .x { display: none; } }\n" },
    .{ .name = "html", .text = "<!doctype html>\n<html><head><style>p { color: red; }</style></head>\n<body><p class=\"a\">hi</p><script>let x = 1 + 2;</script></body></html>\n" },
    .{ .name = "javascript", .text = "export function f(a, b = 2) { return `${a}-${b}`.split(/-/); }\nconst o = { k: [1, 2], async *g() { yield await 1; } };\n" },
    .{ .name = "json", .text = "{\"a\": [1, 2.5, true, null], \"b\": {\"c\": \"d\"}}\n" },
    .{ .name = "lua", .text = "local function f(t)\n  for k, v in pairs(t) do print(k, v) end\n  return #t\nend\n" },
    .{ .name = "markdown", .text = "# Title\n\nSome *text* with `code`.\n\n```zig\nconst x = 1;\n```\n\n- item\n" },
    .{ .name = "markdown_inline", .text = "Some *emphasis*, **strong**, `code` and a [link](https://example.com)." },
    .{ .name = "python", .text = "import os\n\nclass A(Base):\n    def f(self, x: int) -> int:\n        return [i * x for i in range(3)][0]\n" },
    .{ .name = "regex", .text = "^(?:[a-z]+|\\d{2,3})\\s*$" },
    .{ .name = "rust", .text = "use std::fmt;\npub struct P { x: i32 }\nimpl fmt::Display for P { fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result { write!(f, \"{}\", self.x) } }\n" },
    .{ .name = "swift", .text = "import Foundation\nstruct Point { var x: Int }\nclass Shape: CustomStringConvertible {\n  var description: String { \"shape\" }\n  func area() -> Double { return 0 }\n}\n" },
    .{ .name = "tsx", .text = "export const App = ({ n }: { n: number }) => <div className=\"a\">{n}</div>;\n" },
    .{ .name = "typescript", .text = "interface I { a: string }\nexport class C implements I { a = \"x\"; m<T>(t: T): T { return t; } }\n" },
    .{ .name = "zig", .text = "const std = @import(\"std\");\npub fn main() void {\n    std.debug.print(\"{d}\\n\", .{1 + 2});\n}\n" },
};

pub fn find(name: []const u8) ?[]const u8 {
    for (samples) |s| {
        if (eql(s.name, name)) return s.text;
    }
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
