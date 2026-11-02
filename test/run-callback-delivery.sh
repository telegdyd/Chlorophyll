#!/bin/sh
# macOS Foundation host regression, using the same methods as libbgmtl.
set -eu
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out=$(mktemp -d /tmp/bgmtl-callback-test.XXXXXX)
trap 'rm -rf "$out"' EXIT HUP INT TERM
xcrun clang -fblocks -fno-objc-arc -fsanitize=address,undefined \
    -framework Foundation "$dir/callback_delivery_test.m" -o "$out/test"
# Foundation/libdispatch keep process-global allocations; check memory/UB, not
# process-exit framework leak accounting.
ASAN_OPTIONS=detect_leaks=0 "$out/test"
