M9 UBWC validation
==================

`BGMTL_UBWC=1` requests compressed allocations only for own-memory 2D
RGBA8/BGRA8 UNORM render targets: one mip, layer and sample, no shader writes.
IOSurface imports and drawable shadows do not opt in. The default is off.
CPU access decompresses to a linear resource; it does not recompress later.

The coordinator builds/tests on macOS. No build or device run was performed
by the local implementation task. Build outputs must include:
`bgmtl_ubwc_probe`, `bgmtl_ubwc_exec`, `bg_ubwc.metallib`, `libbgmtl.dylib`,
`libbgair.dylib`. Both `tools/mesa-local.sh mesa` and `build-probe.sh` wire the
new sources; the repository's VM wrapper uses `tools/mesa-local.sh`.

Host tests (run on the coordinator's Mac):

```sh
# After applying 0001-0032 to MESA_STAGE:
MESA_STAGE="$HOME/topaz-mesa/stage" sh mesa/metal/test/run-ubwc.sh
# For an isolated /tmp/m8tl src+air+test copy:
for test in /tmp/m8tl/test/run-*.sh; do
  MESA_STAGE="$HOME/topaz-mesa/stage" sh "$test" || exit 1
done
# With Mesa's native host test build, default FLAG_ALIGN=4096:
meson test -C HOST_MESA_BUILD fd5_layout --print-errorlogs
python -m unittest discover -s tools/g2 -p 'test_*.py' -q
```

`bg_ubwc_test.c` tests the exact metadata/policy helpers used by the patch,
including boundaries, the 100x2000 blob example and rejected eligibility
conditions. Mesa's `fd5_layout` test additionally calls the real layout
function and checks flags/color offsets, pitch, total size and layer size.

Coordinator device run (the implementation task does not execute this):

```sh
python research/metal-m9-fbc/ubwc_probe.py --dry-run
python research/metal-m9-fbc/ubwc_probe.py \
  --binary-dir xnu/out-mesa-m9ubwc1 --out research/metal-m9-fbc/probe1
```

The runner is included in the root commit artifact. It takes the existing phone lock, uses
a fresh `/private/var/tmp/metal-m9ubwc-*` directory, snapshots the installed
libraries/env files and verifies them byte-exactly in `finally`. It neither
installs nor powers/restarts anything. It saves initial/final GPU/DDR state,
per-combination logs and `results.json`, and empties the temporary directory.
It needs the display on, idle bench/profiler and sweetd/netfs already running.

The wrapper runs each combination in a fresh process, controlling all knobs.
The first process is UBWC-off and writes reference pixels. The sweep then
tests defaults and one-at-a-time MRTS2=0, SYSMEM=0, TEXBASE=color, TILEALL=0.
Each process covers BGRA8 and RGBA8 at 100x2000, 127x65 and 828x1792,
six patterns per format/size:
solid, gradient, noise, partial GPU update, clear+draw, blend over loaded
contents. Each case checks actual UBWC allocation, sample-to-linear,
UBWC-to-linear blit, direct getBytes, sampling through a surviving view after
getBytes, and a partial CPU write followed by sampling. The off run requires
498 checks; each on run requires 534 (including 12 analytic reference
checks). Pixel mismatches report x/y/channel.

Knob defaults:

| Variable | Default | Alternative |
| --- | --- | --- |
| BGMTL_UBWC | 0 | 1 opts in eligible allocations |
| FD5_UBWC_MRTS2 | 1 | 0 emits only FLAG_MRTS |
| FD5_UBWC_SYSMEM | 1 | 0 forces GMEM for UBWC attachments |
| FD5_UBWC_TEXBASE | flags | color |
| FD5_UBWC_TILEALL | 1 | 0 clears descriptor TILE_ALL only |
| FD5_UBWC_FLAG_ALIGN | 4096 | page-sized powers of two through 1048576 |

Invalid flag alignment falls back to 4096. Every variable is read once per
process (Mesa getters cache per translation unit). Runtime hardware behavior
is unvalidated: the coordinator must build generated register headers, run
all host tests, and establish the working knob combination on the phone.
Keep compositor UBWC disabled until those checks pass. The kernel is unchanged;
the follow-up spec directs matching RB/TPL1 reset bank configuration, as used
by already-working fd5 tiled allocations.
