#!/usr/bin/env bash
#
# ztreesitter — prove libs/tree-sitter is the pinned upstream, unmodified.
#
# UPSTREAM.md says libs/ is a copy of one tagged commit. This fetches that
# commit and diffs the vendored paths against it with no exclusions.
# Needs network, so it is a CI job of its own.
#
# Usage: ci/verify-vendor.sh

set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM_URL="https://github.com/tree-sitter/tree-sitter.git"
UPSTREAM_TAG="v0.27.0"
UPSTREAM_COMMIT="6070dbfefd326bd735e5683eb128cc1b57dad0c0"

# Paths copied verbatim, relative to the upstream root and to libs/tree-sitter.
VENDORED=(LICENSE lib/include lib/src)

grep -q "$UPSTREAM_COMMIT" UPSTREAM.md || { echo "UPSTREAM.md does not name $UPSTREAM_COMMIT" >&2; exit 1; }
grep -q "$UPSTREAM_TAG" UPSTREAM.md || { echo "UPSTREAM.md does not name $UPSTREAM_TAG" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git -c core.autocrlf=false -c core.eol=lf -c advice.detachedHead=false \
    clone --quiet --depth 1 --branch "$UPSTREAM_TAG" "$UPSTREAM_URL" "$work/upstream"

# A tag can move; the commit cannot.
actual=$(git -C "$work/upstream" rev-parse HEAD)
[ "$actual" = "$UPSTREAM_COMMIT" ] || { echo "tag $UPSTREAM_TAG is $actual, expected $UPSTREAM_COMMIT" >&2; exit 1; }

status=0
for path in "${VENDORED[@]}"; do
    if diff -r "$work/upstream/$path" "libs/tree-sitter/$path" > "$work/diff"; then
        echo "  $path identical"
    else
        echo "  $path DIFFERS"
        head -40 "$work/diff"
        status=1
    fi
done
exit $status
