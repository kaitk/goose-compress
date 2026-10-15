#!/bin/sh
# Runs every test this repository has, and fails on the first failure: the
# typecheck of each root file under test/ and bench/, the unit tests through TinyCC
# (scripts/test-unit.sh), then test/encode.goose built with goose build and
# its output checked against gzip and Python's zlib (scripts/roundtrip.py).
#
# GOOSE or GOOSE_COMMIT names the compiler (default: the pinned release,
# scripts/goose.sh), and CC the C compiler for goose build (default: the one
# goose build finds).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/scripts/goose.sh"
goose=$GOOSE
case $(uname -s) in
MINGW* | MSYS*) exe=.exe ;;
*) exe= ;;
esac

step() {
    echo
    echo "== $*"
}

for f in "$root"/test/*.goose "$root"/bench/*.goose; do
    step "check ${f#"$root"/}"
    "$goose" check "$f"
done

step "test-unit.sh"
"$root/scripts/test-unit.sh"

step "build test/encode.goose"
mkdir -p "$root/build"
"$goose" build ${CC:+--cc "$CC"} -o "$root/build/encode" "$root/test/encode.goose"

step "roundtrip.py"
python3 "$root/scripts/roundtrip.py" "$root/build/encode$exe"
