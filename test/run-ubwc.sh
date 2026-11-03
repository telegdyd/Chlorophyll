#!/bin/sh
set -eu
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# MESA_STAGE may point at a local preflight checkout. On the VM use the
# production source after applying patches 0001-0032, even in /tmp/m8tl.
stage=${MESA_STAGE:-"$HOME/topaz-mesa/mesa-src"}
out=$(mktemp -d /tmp/bgmtl-ubwc-test.XXXXXX)
trap 'rm -rf "$out"' EXIT HUP INT TERM
${CC:-cc} -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
   -I"$stage/src/freedreno/fdl" -I"$stage/src/gallium/drivers/freedreno/a5xx" \
   "$dir/bg_ubwc_test.c" -o "$out/test"
ASAN_OPTIONS=detect_leaks=0 "$out/test"
