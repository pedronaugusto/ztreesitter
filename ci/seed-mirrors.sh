#!/bin/sh
# Put grammar mirrors into Zig's package cache from this repository's own
# refs, for as long as the repository is private: Zig's fetcher cannot
# authenticate, so it cannot download them from GitHub. A mirror's archive
# hashes the same as the tree `git archive` writes, so the build finds it.
#
# Usage: ci/seed-mirrors.sh GRAMMAR...   (catalogue names; "all" for every one)
# Fetches each mirror commit it lacks from origin.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
if [ "$#" -eq 0 ]; then echo "usage: $0 GRAMMAR..." >&2; exit 2; fi
names="$*"
if [ "$names" = all ]; then
    names=$(sed -n 's/^        \.name = "\(.*\)",$/\1/p' grammars/catalogue.zig)
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for name in $names; do
    # The mirror commit is the `.mirror` line after the grammar's `.name`.
    sha=$(awk -v n="        .name = \"$name\"," '$0 == n { found = 1 } found && /\.mirror = / { gsub(/.*= "|",$/, ""); print; exit }' grammars/catalogue.zig)
    if [ -z "$sha" ]; then echo "seed: no grammar named $name" >&2; exit 1; fi
    [ -d "$work/$sha" ] && continue
    # Fetch the mirror commit by name when this clone lacks it; GitHub serves
    # any commit reachable from a ref, hidden refs included.
    git cat-file -e "$sha^{commit}" 2>/dev/null || git fetch --quiet --depth=1 origin "$sha"
    mkdir "$work/$sha"
    git archive "$sha" | tar -x -C "$work/$sha"
    hash=$(zig fetch "$work/$sha")
    echo "seed: $name $hash"
done
