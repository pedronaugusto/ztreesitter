#!/usr/bin/env bash
#
# ztreesitter — README.md's Usage snippet, extracted from examples/usage.zig,
# which `zig build test` builds and runs. ci/check-readme.sh compares the two.
#
# Usage: ci/readme_usage.sh          # writes the fenced block to stdout

set -uo pipefail
cd "$(dirname "$0")/.."

exec python3 - <<'PY'
import pathlib
import sys

source = pathlib.Path("examples/usage.zig")
text = source.read_text(encoding="utf-8")
begin, end = "    // BEGIN README usage\n", "    // END README usage\n"
if text.count(begin) != 1 or text.count(end) != 1:
    sys.exit("%s: expected one BEGIN and one END README usage marker" % source)
body = text.split(begin)[1].split(end)[0]
lines = [line[4:] if line.startswith("    ") else line for line in body.splitlines()]
print("```zig")
print('const ts = @import("ztreesitter");')
print('const grammars = @import("grammars"); // made by addGrammars, see Install')
print()
print("\n".join(lines).strip("\n"))
print("```")
PY
