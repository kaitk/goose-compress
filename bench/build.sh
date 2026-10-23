#!/bin/sh
# Builds what bench/run.sh runs, into build/bench/: libdeflate, zlib-ng, and
# libzstd at their pins, in release mode with their default options, which
# choose each CPU's fastest code at run time; bench/ref.c against all three;
# bench/klauspost with go build, which fetches klauspost/compress at the
# version its go.mod pins; bench/bench.goose and bench/json.goose with goose
# build; and the Silesia corpus, checked against its SHA-256.
#
# GOOSE or GOOSE_COMMIT names the compiler (default: the pinned release,
# scripts/goose.sh), CC the C compiler (default: cc, or clang on Windows), GO
# the Go toolchain (default: go on PATH). On Windows it runs under Git Bash,
# with CMake and Ninja on PATH.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/scripts/goose.sh"
goose=$GOOSE
cc=${CC:-cc}
go=${GO:-go}
generator=
exe=
case $(uname -s) in
MINGW* | MSYS*)
    cc=${CC:-clang}
    exe=.exe
    # Visual Studio's generator ignores CMAKE_C_COMPILER.
    generator="-G Ninja"
    ;;
esac
out=$root/build/bench
mkdir -p "$out/src" "$out/corpus"

LIBDEFLATE_TAG=v1.26
ZLIBNG_TAG=2.3.3
ZSTD_TAG=v1.5.7
SILESIA_SHA256=0626e25f45c0ffb5dc801f13b7c82a3b75743ba07e3a71835a41e3d9f63c77af

fetch() { # name url tag
    if [ ! -d "$out/src/$1" ]; then
        git -c advice.detachedHead=false clone -q --depth 1 --branch "$3" "$2" "$out/src/$1"
    fi
    [ "$(git -C "$out/src/$1" describe --tags)" = "$3" ] || {
        echo "$out/src/$1 isn't at $3; delete it and run again" >&2
        exit 1
    }
}

fetch libdeflate https://github.com/ebiggers/libdeflate.git $LIBDEFLATE_TAG
fetch zlib-ng https://github.com/zlib-ng/zlib-ng.git $ZLIBNG_TAG
fetch zstd https://github.com/facebook/zstd.git $ZSTD_TAG

# shellcheck disable=SC2086
cmake $generator -S "$out/src/libdeflate" -B "$out/libdeflate" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$cc" \
    -DLIBDEFLATE_BUILD_SHARED_LIB=OFF -DLIBDEFLATE_BUILD_GZIP=OFF >/dev/null
cmake --build "$out/libdeflate" -j >/dev/null
# shellcheck disable=SC2086
cmake $generator -S "$out/src/zlib-ng" -B "$out/zlib-ng" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$cc" -DZLIB_COMPAT=OFF -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF -DWITH_GTEST=OFF >/dev/null
cmake --build "$out/zlib-ng" -j >/dev/null
# shellcheck disable=SC2086
cmake $generator -S "$out/src/zstd/build/cmake" -B "$out/zstd" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$cc" \
    -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_PROGRAMS=OFF \
    -DZSTD_BUILD_TESTS=OFF >/dev/null
cmake --build "$out/zstd" -j >/dev/null

# Each platform names the static libraries its own way: libdeflate.a,
# libz-ng.a, and libzstd.a, or deflatestatic.lib, zlibstatic-ng.lib, and
# zstd_static.lib.
lib() {
    find "$1" -maxdepth 1 \( -name "$2*.a" -o -name "$2*.lib" \) | head -n 1
}
"$cc" -O2 -o "$out/ref$exe" "$root/bench/ref.c" \
    -I"$out/src/libdeflate" -I"$out/zlib-ng" -I"$out/src/zstd/lib" \
    "$(lib "$out/libdeflate" "*deflate")" "$(lib "$out/zlib-ng" "*z*-ng")" \
    "$(lib "$out/zstd/lib" "*zstd")"

"$go" build -C "$root/bench/klauspost" -o "$out/klauspost$exe" .

"$goose" build -o "$out/bench$exe" "$root/bench/bench.goose"
"$goose" build -o "$out/json$exe" "$root/bench/json.goose"

if [ ! -f "$out/corpus/dickens" ]; then
    curl -sSLf -o "$out/silesia.zip" https://sun.aei.polsl.pl/~sdeor/corpus/silesia.zip
    echo "$SILESIA_SHA256  $out/silesia.zip" | shasum -a 256 -c - >/dev/null
    unzip -q -o "$out/silesia.zip" -d "$out/corpus"
fi
echo "built $out with Goose $(goose_version)"
