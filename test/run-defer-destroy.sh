#!/bin/sh
set -eu
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out=$(mktemp -d /tmp/bgmtl-defer-test.XXXXXX)
trap 'rm -rf "$out"' EXIT HUP INT TERM
xcrun clang -O1 -g -Wall -Wextra -pthread -fsanitize=address,undefined \
    "$dir/bg_defer_test.c" -o "$out/test"
# ASan leak detection is not supported by the macOS ASan runtime used here;
# the queue frees every node in the drain, and the concurrent test checks counts.
ASAN_OPTIONS=detect_leaks=0 "$out/test"
