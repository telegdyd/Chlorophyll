#!/bin/sh
set -eu
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out=$(mktemp -d /tmp/bgmtl-admission-test.XXXXXX)
trap 'rm -rf "$out"' EXIT HUP INT TERM
xcrun clang -fblocks -fno-objc-arc -fsanitize=address,undefined \
    -framework Foundation "$dir/write_admission_test.m" -o "$out/test"
ASAN_OPTIONS=detect_leaks=0 "$out/test"
