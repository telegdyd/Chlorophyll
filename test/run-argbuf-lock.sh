#!/bin/sh
set -eu
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out=$(mktemp -d /tmp/bgmtl-argbuf-lock-test.XXXXXX)
trap 'rm -rf "$out"' EXIT HUP INT TERM
xcrun clang -O1 -g -Wall -Wextra -pthread -fsanitize=address,undefined \
    "$dir/bg_argbuf_lock_test.c" -o "$out/test"
ASAN_OPTIONS=detect_leaks=0 "$out/test"
