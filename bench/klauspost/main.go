// Compresses a file with klauspost/compress's zstd encoder, the Go one
// goose-compress is measured against, the way bench/ref.c does with libzstd:
// one-shot with EncodeAll, the whole file in memory, RUNS times, with the
// content checksum on. LEVEL is zstd's, mapped to the encoder's own levels by
// zstd.EncoderLevelFromZstd: 1 and 2 are SpeedFastest, 3 to 5 SpeedDefault.
//
//	klauspost LEVEL FILE RUNS [zstd]
//
// Prints the same line as bench/ref.c, under the name klauspost.
package main

import (
	"fmt"
	"os"
	"sort"
	"strconv"
	"time"

	"github.com/klauspost/compress/zstd"
)

func main() {
	if len(os.Args) != 4 && (len(os.Args) != 5 || os.Args[4] != "zstd") {
		fmt.Fprintln(os.Stderr, "usage: klauspost LEVEL FILE RUNS [zstd]")
		os.Exit(2)
	}
	level, err1 := strconv.Atoi(os.Args[1])
	runs, err2 := strconv.Atoi(os.Args[3])
	if err1 != nil || err2 != nil || level < 1 || runs < 1 {
		fmt.Fprintln(os.Stderr, "bad arguments")
		os.Exit(2)
	}
	in, err := os.ReadFile(os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	enc, err := zstd.NewWriter(nil, zstd.WithEncoderLevel(zstd.EncoderLevelFromZstd(level)),
		zstd.WithEncoderCRC(true))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	out := make([]byte, 0, len(in)+len(in)/8+1024)
	rate := make([]float64, runs)
	for i := range rate {
		t := time.Now()
		out = enc.EncodeAll(in, out[:0])
		rate[i] = float64(len(in)) / time.Since(t).Seconds() / 1e6
	}
	sort.Float64s(rate)
	fmt.Printf("klauspost %d %d %d %.1f %.1f\n", level, len(in), len(out), rate[runs/2],
		rate[runs-1])
}
