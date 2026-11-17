// The runtime's strncmp: build.zig compiles libs/tree-sitter/lib/src/lib.c with
// -Dstrncmp=ztreesitter_strncmp, so every call the runtime makes reaches this one.
//
// Zig 0.17's own C library, which every musl target links, implements strncmp
// (lib/c/string.zig) through std.mem.boundedOrderZ, whose loop tests
// lhs[i] == rhs[i] before i < bound: it reads byte n of both strings, and byte 0
// when n is 0, where C reads at most n. The runtime calls strncmp on strings a
// length bounds and no NUL ends (a query's source, a node type or field name a
// caller passes), so that byte can lie past the caller's memory: the riscv64
// suite's fault in ts_language_symbol_for_name, under ts_query_new. This file
// goes when the pinned Zig's strncmp stops at n.

#include <stddef.h>

int ztreesitter_strncmp(const char *a, const char *b, size_t n) {
  for (size_t i = 0; i < n; i++) {
    const unsigned char x = (unsigned char)a[i];
    const unsigned char y = (unsigned char)b[i];
    if (x != y) return x < y ? -1 : 1;
    if (x == 0) return 0;
  }
  return 0;
}
