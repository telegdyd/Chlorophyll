# Running P23 display-suspended deferred admission

P23 is in `bgmtl_render_probe.m`. It is the on-device companion to
`write_admission_test.m`: the host test stubs the ticket BEGIN results, while P23
uses the real kernel/display state.

The probe never toggles AppleCLCD power. The runner does that with the existing
`power0`/`power1` helper from `research/metal-m7-admission/validate.py` (or the
same `IOConnectCallScalarMethod` selector 12 on `AppleCLCD`). Keep the shared
phone lock for the whole run and restore the display state that existed before
it, including on failure.

## Sub-case 1: encode and commit while the display is off

1. Build the probe and shaders (one VM build at a time):

   ```sh
   tools/vm-mesa.sh mesa m7suspend
   ```

   The outputs are `xnu/out-mesa-m7suspend/bgmtl_render_probe`,
   `bg_kernels.metallib`, `bg_render.metallib`, `libbgair.dylib` and
   `libbgmtl.dylib`.

2. Copy them to an isolated device directory, as `validate.py` does, and leave
   the installed libraries/env files untouched.

3. Power the display off with the runner helper (`power0`), then run:

   ```sh
   python3 tools/sweet-sh.py --timeout 75 \
     /private/var/tmp/metal-m7-p23/exec \
     /private/var/tmp/metal-m7-p23 sysmem \
     /private/var/tmp/metal-m7-p23/bgmtl_render_probe \
     /private/var/tmp/metal-m7-p23/bg_kernels.metallib \
     /private/var/tmp/metal-m7-p23/bg_render.metallib \
     --display-off
   ```

   `exec` is the small `DYLD_LIBRARY_PATH`/`FD_MESA_DEBUG=sysmem` wrapper from
   `validate.py`; if your runner already sets those variables, run the probe
   directly. `--bb` is not needed here.

   P23 first probes ticket BEGIN on a scratch imported IOSurface. With the
   display off it must answer `-EAGAIN`; P23 then encodes a clear into an
   imported IOSurface, commits it, and checks:

   - status is `MTLCommandBufferStatusCompleted` (not Error);
   - every pixel is the expected red (`ff0000ff` in little-endian BGRA);
   - the diagnostics line (process log, `bgmtl.log`) is
     `render tickets: display suspended: N deferred, M ticketed at replay, K unticketed`.

   P22 also prints
   `SKIP: P22 needs the display on (covered by the display-on run)` and adds no
   checks: with the display off no kernel ticket can be begun, so P22's live
   pending-generation and refused-BEGIN preconditions cannot be created. The
   47-check display-on total contains P22's 10 checks, so the display-off base
   is 37. This sub-case adds 2 checks: **39 checks passed, 0 failed**.

4. Power the display back on (`power1`) or restore its previous state.

If the display is on and `--display-off` was not passed, P23 prints
`SKIP: display is on; run with the display powered off and pass --display-off`
and adds no checks, so the existing P20-P22 count is unchanged (`47 checks`).
If `--display-off` is passed but ticket BEGIN succeeds, P23 fails: the runner did
not actually leave the display off (or the build does not have the deferred
policy).

## Sub-case 2: encode while off, commit after the runner wakes the display

This is runner-driven because the probe must not touch AppleCLCD. Pass a signal
path under `/private/var/tmp`:

```sh
... bgmtl_render_probe ... --display-wake-wait=/private/var/tmp/bgmtl-p23.wake
```

`--display-wake-wait=` implies display-off mode. The probe:

1. removes any stale `.wake`/`.wake.encoded` files;
2. encodes a clear into a second imported IOSurface while the display is off;
3. creates `/private/var/tmp/bgmtl-p23.wake.encoded` and waits up to 30 s;
4. commits only after the runner creates `/private/var/tmp/bgmtl-p23.wake`.

The runner must, after seeing `.encoded`:

1. power the display on (`power1`);
2. create the wake file (e.g. copy an empty local file with
   `tools/sweet-fs.py put`, or any other runner-side file creation);
3. wait for the probe to finish, check status/pixels, then restore the original
   display state.

The probe probes ticket BEGIN again after the wake signal and expects success;
that check alone does not prove the CB's replayed ticket, only that the display
was up when the CB committed. P22 remains skipped and this sub-case adds 3
checks to the same 37-check display-off base: **42 checks passed, 0 failed**
when both P23 sub-cases run. Without `--display-wake-wait` it prints a SKIP and
only sub-case 1 runs.

If a runner asserts an exact check count, use 47 for the display-on run (P23
skipped, P22 run), 39 for display-off sub-case 1 (P22 and P23 sub-case 2
skipped), and 42 for display-off sub-case 2 (P22 skipped). The M7 suspend runner
in `research/metal-m7-suspend/validate.py` asserts those totals and requires the
P22 SKIP line for parts 2 and 3.
