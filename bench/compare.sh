#!/bin/sh
# Compares builds of the package, one for each REV (a commit, a branch, or `.`
# for the working tree): checks that each gives the first one's output byte for
# byte, then times them in alternating rounds and prints a Markdown table. The
# programs that measure are this checkout's bench/json.goose, bench/bench.goose,
# and test/encode.goose, built against each REV's package.
#
#   bench/compare.sh REV...
#
# BODIES (default: the bodies in bench/json/) names small bodies, timed by
# bench/json.goose in 41 batches of 500 calls: a cell is the best round's
# median, in µs a call. FILES (default: none) names large files, such as the
# Silesia files under build/bench/corpus/, timed by bench/bench.goose over RUNS
# (default 5) runs: a cell is the best round's median, in MB/s. FORMAT (default
# gzip) is the files' format, as bench/bench.goose takes it; the bodies are
# always gzip. LEVELS (default 1), ROUNDS (default 3). The Load column is the 1-minute load average over the
# cell's rounds, where uptime gives one. GOOSE or GOOSE_COMMIT names the
# compiler and CC the C compiler, as in scripts/test.sh.
set -eu
export LC_ALL=C

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/scripts/goose.sh"
goose=$GOOSE
case $(uname -s) in
MINGW* | MSYS*) exe=.exe ;;
*) exe= ;;
esac
[ $# -gt 0 ] || { echo "usage: bench/compare.sh REV..." >&2; exit 2; }
bodies=${BODIES-"small100 json25 json40 json50"}
files=${FILES-}
levels=${LEVELS:-1}
rounds=${ROUNDS:-3}
runs=${RUNS:-5}
format=${FORMAT:-gzip}
work=$root/build/compare
mkdir -p "$work/out"

# Each REV's package, extracted under build/compare/, with this checkout's
# programs beside it.
dirs=
for rev in "$@"; do
    if [ "$rev" = . ]; then
        name=worktree
        src=$root
    else
        name=$(git -C "$root" rev-parse --short "$rev")
        src=$work/src-$name
        if [ ! -d "$src" ]; then
            mkdir -p "$src"
            git -C "$root" archive "$name" | tar -x -C "$src"
        fi
        cp "$root/bench/json.goose" "$root/bench/bench.goose" "$src/bench/"
        cp "$root/test/encode.goose" "$src/test/"
    fi
    echo "building $rev ($name)" >&2
    for p in bench/json bench/bench test/encode; do
        "$goose" build ${CC:+--cc "$CC"} -o "$work/$name-$(basename $p)" "$src/$p.goose" > "$work/build.log"
    done
    dirs="$dirs $name"
done

load() {
    uptime 2>/dev/null | awk -F'load averages?: ' 'NF > 1 { split($2, a, /[, ]+/); print a[1] }'
}

raw=$work/raw.txt
: > "$raw"
for kind in body file; do
    if [ $kind = body ]; then list=$bodies; else list=$files; fi
    for f in $list; do
        path=$f
        [ $kind = file ] || [ -f "$path" ] || path=$root/bench/json/$f.json
        input=$(basename "$path")
        for level in $levels; do
            first=
            for name in $dirs; do
                o=$work/out/$name.gz
                if [ $kind = body ]; then fmt=gzip; else fmt=$format; fi
                "$work/$name-encode$exe" $fmt "$level" "$path" "$o"
                if [ -z "$first" ]; then
                    first=$o
                elif ! cmp -s "$first" "$o"; then
                    echo "$input level $level: $name's output differs from the first's" >&2
                    exit 1
                fi
            done
            for r in $(seq "$rounds"); do
                for name in $dirs; do
                    l=$(load)
                    if [ $kind = body ]; then
                        line=$("$work/$name-json$exe" "$level" "$path" 41 500)
                    else
                        line=$("$work/$name-bench$exe" "$level" "$path" "$runs" $fmt)
                    fi
                    echo "$line" | awk -v k=$kind -v i="$input" -v n=$name -v r=$r -v l="${l:--}" '{
                        v = k == "body" ? $5 / 1000 : $5
                        print k, i, $2, n, r, $4, v, l
                    }' | tee -a "$raw" >&2
                done
            done
        done
    done
done

awk -v dirs="$dirs" '
BEGIN { n = split(dirs, d, " ") }
{
    key = $2 " " $3
    if (!(key in seen)) { seen[key] = 1; order[++cells] = key; kind[key] = $1; size[key] = $6 }
    c = key SUBSEP $4
    if (!(c in best) || ($1 == "body" ? $7 < best[c] : $7 > best[c])) best[c] = $7
    if ($8 != "-") {
        if (!(key in lo) || $8 + 0 < lo[key]) lo[key] = $8 + 0
        if (!(key in hi) || $8 + 0 > hi[key]) hi[key] = $8 + 0
    }
}
END {
    head = "| Input | Level | Bytes out | Unit |"; rule = "|---|---:|---:|---|"
    for (j = 1; j <= n; j++) { head = head " " d[j] " |"; rule = rule "---:|" }
    print head " Load |"; print rule "---|"
    for (i = 1; i <= cells; i++) {
        key = order[i]; split(key, kl, " ")
        row = "| " kl[1] " | " kl[2] " | " size[key] " | " (kind[key] == "body" ? "µs a call" : "MB/s") " |"
        for (j = 1; j <= n; j++) row = row " " sprintf(kind[key] == "body" ? "%.2f" : "%.1f", best[key SUBSEP d[j]]) " |"
        print row " " (key in lo ? lo[key] " to " hi[key] : "-") " |"
    }
}' "$raw"
