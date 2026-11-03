# M7 closing probes: P24-P26

These are the display-on final M7 cases. Each new flag runs *only* its own probe
(the default P0-P23 suite is skipped) and ends with the usual
`== result: N checks passed, M failed`. The default display-on run is unchanged
at **47** checks; P23 is **49** (display-off) or **52** (with the wake sub-case).

The probe never toggles AppleCLCD power. The runner owns it and restores the
display state it found, including on failure.

## P24: `--cancelled-seal-wait=FILE`

```
bgmtl_render_probe KERNELS.metallib RENDER.metallib --cancelled-seal-wait=/private/var/tmp/bgmtl-p24
```

Display must be **on** at entry. The probe:

1. raw-BEGINs a scratch imported surface (display-on precondition), aborts it;
2. encodes a green ticketed clear on an imported target, then writes `FILE.encoded`;
3. waits for `FILE.off` (runner: `power0`, then create it), 60 s;
4. commits and waits: status must be Completed with no error (the display epoch
   cancelled the ticket; j0127 ACKs the proven submit as SEAL 0);
5. writes `FILE.committed`, then waits for `FILE.wake` (runner: `power1`, then
   create it), 60 s;
6. raw-BEGINs the scratch surface again, aborts it, and requires a different epoch;
7. encodes+commits a red clear on the **same** target and requires Completed plus
   exact red pixels (the cancelled backing was detached and is reusable).

Expected when the display was on at entry: **9/9 checks**. If the display is off
at entry the probe prints `SKIP` and reports 0 checks. A 60 s file timeout is a
FAIL.

Runner sequence: wait `.encoded` -> power0 -> create `.off`; wait `.committed` ->
power1 -> create `.wake`. Requires the j0127 kernel patch for the ACK.

## P25: `--pending-reuse`

```
BGMTL_ASYNC=1 bgmtl_render_probe KERNELS.metallib RENDER.metallib --pending-reuse --bb
bgmtl_render_probe KERNELS.metallib RENDER.metallib --pending-reuse
```

Display on. Twenty iterations: CB1 clears the imported target, commits without
waiting; CB2 immediately clears the same target red/green alternating, commits;
both are waited. Both must be Completed with no error, the final pixels must be
CB2's colour, and CB1's completion handler must run before CB2's. Then the
refusal variant: CB1 is encoded but not committed, CB2 is encoded on the same
target; CB2 must be Error with the "uncommitted" reason, and CB1 must still
complete with its own pixels (CB2 replayed nothing).

Expected: **3/3 checks**. Both async (`BGMTL_ASYNC=1 --bb`) and inline are valid.

## P26: `--submit-error`

```
bgmtl_render_probe KERNELS.metallib RENDER.metallib --submit-error
```

Display on, **without `--bb`**. The probe sets `BGMTL_TEST_SUBMIT_ERROR=1`; the
next Metal submit fails as the `-EIO` ioctl path does, before the kernel, once.
The CB must be Error with a non-nil error even though no GPU work ran, its ticket
must be ABORTed, and the next CB on the same imported target must complete with
exact red pixels. A CB on a plain (non-imported) texture must then succeed too.

Expected: **3/3 checks**. The hook is ignored when `BGMTL_BB` is set, so this
mode prints `SKIP` and reports 0 checks in the compositor.

## `bgmtl_ticket_probe --display-epochs`

Scenario 2 (post-submit display cancellation) now additionally calls SEAL twice
on the cancelled ticket: the same seqno must return 0 (idempotent ACK) and
`seqno+1` must return `kIOReturnAborted` (not Busy). The probe still prints one
`PASS`/`FAIL` line; the extra conditions are part of that result.

## Layout

- `README-display-off-admission.md`: P23 runner and the original display-off case.
- This file: P24 (cancelled ACK), P25 (pending reuse), P26 (submit failure).
