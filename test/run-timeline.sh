#!/bin/sh
set -eu
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out=$(mktemp -d /tmp/bgmtl-timeline-test.XXXXXX)
trap 'rm -rf "$out"' EXIT HUP INT TERM
xcrun clang -fblocks -Wall -Wextra "$dir/timeline_test.c" -o "$out/test"
"$out/test"
"$out/test" armed
