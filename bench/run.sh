#!/bin/sh
# Compresses each corpus file with goose-compress and the libraries it's
# measured against, at each level in LEVELS, and prints a Markdown table: the
# output's share of the input, and the median and best rate in MB/s of RUNS
# runs. bench/build.sh builds what it runs.
#
# FORMAT (default gzip): gzip, zlib, or raw, against zlib-ng and libdeflate;
# or zstd, against libzstd, libzstd with the package's 128 KB window
# (libzstd-w17), and klauspost/compress, whose levels 1 and 3 are its
# SpeedFastest and SpeedDefault. LEVELS (default "0", or "1 3" for zstd): the
# levels, the same number for each library. RUNS (default 10). FILES (default:
# the Silesia files below) names files under build/bench/corpus/, or paths.
set -eu
# awk prints decimal commas under some locales.
export LC_ALL=C

root=$(cd "$(dirname "$0")/.." && pwd)
out=$root/build/bench
format=${FORMAT:-gzip}
runs=${RUNS:-10}
files=${FILES:-"dickens webster xml nci mozilla samba x-ray"}
if [ "$format" = zstd ]; then
    levels=${LEVELS:-"1 3"}
    libs="ref:libzstd ref:libzstd-w17 klauspost"
else
    levels=${LEVELS:-0}
    libs="ref:zlib-ng ref:libdeflate"
fi

echo "| File | MB | Level | Library | Ratio | MB/s, median | MB/s, best |"
echo "|---|---:|---:|---|---:|---:|---:|"
for f in $files; do
    path=$f
    [ -f "$path" ] || path=$out/corpus/$f
    for level in $levels; do
        for lib in bench $libs; do
            cmd="$out/$(echo "$lib" | tr : ' ')"
            # shellcheck disable=SC2086
            $cmd "$level" "$path" "$runs" "$format" | awk -v f="$(basename "$path")" '{
                printf "| %s | %.1f | %s | %s | %.3f | %s | %s |\n",
                    f, $3 / 1e6, $2, $1, $4 / $3, $5, $6
            }'
        done
    done
done
