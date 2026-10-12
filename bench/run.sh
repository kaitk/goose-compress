#!/bin/sh
# Compresses each corpus file to gzip with goose-compress, zlib-ng, and
# libdeflate, at each level in LEVELS, and prints a Markdown table: the output's
# share of the input, and the median and best rate in MB/s of RUNS runs.
# bench/build.sh builds what it runs.
#
# LEVELS (default "0"): the levels, the same number for each library. RUNS
# (default 10). FILES (default: the Silesia files below) names files under
# build/bench/corpus/, or paths.
set -eu
# awk prints decimal commas under some locales.
export LC_ALL=C

root=$(cd "$(dirname "$0")/.." && pwd)
out=$root/build/bench
levels=${LEVELS:-0}
runs=${RUNS:-10}
files=${FILES:-"dickens webster xml nci mozilla samba x-ray"}

echo "| File | MB | Level | Library | Ratio | MB/s, median | MB/s, best |"
echo "|---|---:|---:|---|---:|---:|---:|"
for f in $files; do
    path=$f
    [ -f "$path" ] || path=$out/corpus/$f
    for level in $levels; do
        for cmd in "$out/bench $level" "$out/ref zlib-ng $level" \
            "$out/ref libdeflate $level"; do
            # shellcheck disable=SC2086
            $cmd "$path" "$runs" | awk -v f="$(basename "$path")" '{
                printf "| %s | %.1f | %s | %s | %.3f | %s | %s |\n",
                    f, $3 / 1e6, $2, $1, $4 / $3, $5, $6
            }'
        done
    done
done
