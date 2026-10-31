#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""jasmine: isolated offline AIR/a512 compilation; not a GPU correctness test.

Usage: jasmine-corpus.py --air2nir BIN --air2ir3 BIN --out DIR LIB...
Apple inputs, extracted slices, diagnostics and per-function tables belong in
ignored research storage. Function constants use the tool's zero defaults.
"""
import argparse
import collections
import csv
import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import subprocess

from corpus import mtlb_slices


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--air2nir', required=True)
    ap.add_argument('--air2ir3', required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--gpu', default='512')
    ap.add_argument('-j', type=int, default=2)
    ap.add_argument('libs', nargs='+')
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    tasks, rows = [], []
    for lib_index, lib in enumerate(args.libs):
        slices = list(mtlb_slices(lib))
        if not slices:
            rows.append(dict(lib=lib, function='(container)', nir='FAIL', ir3='SKIP',
                             reason='no MTLB slice'))
        for slice_index, cpu, data in slices:
            path = args.out / f'{lib_index}-{slice_index}.metallib'
            path.write_bytes(data)
            listed = subprocess.run([args.air2nir, '--list', str(path)],
                                    capture_output=True, text=True, timeout=30)
            if listed.returncode:
                rows.append(dict(lib=lib, function='(container)', nir='FAIL', ir3='SKIP',
                                 reason=listed.stderr.strip()))
                continue
            for line in listed.stdout.splitlines():
                fields = line.split()
                if fields:
                    tasks.append((lib, slice_index, path, fields[0]))

    def run(task):
        index, (lib, slice_index, path, name) = task
        row = dict(lib=lib, slice=slice_index, function=name, nir='FAIL', ir3='SKIP', reason='')
        try:
            proc = subprocess.run([args.air2ir3, str(path), name, args.gpu],
                                  capture_output=True, text=True, timeout=30)
            output = proc.stdout + proc.stderr
            (args.out / f'function-{index:05}.txt').write_text(output)
            row['nir'] = 'OK' if 'NIR OK:' in proc.stdout else 'FAIL'
            row['ir3'] = 'OK' if proc.returncode == 0 else ('FAIL' if row['nir'] == 'OK' else 'SKIP')
            if proc.returncode:
                lines = [s for s in output.splitlines() if s.strip()]
                useful = [s for s in lines if any(k in s.lower() for k in
                          ('assert', 'fail', 'error', 'unsupported', 'not support'))]
                row['reason'] = (useful or lines or ['no diagnostic'])[-1]
                if proc.returncode < 0:
                    row['reason'] = f'signal {-proc.returncode}: ' + row['reason']
        except subprocess.TimeoutExpired:
            row['reason'] = 'timeout (30 seconds)'
        return row

    with ThreadPoolExecutor(max_workers=args.j) as pool:
        rows.extend(pool.map(run, enumerate(tasks)))
    (args.out / 'functions.json').write_text(json.dumps(rows, indent=2) + '\n')
    with (args.out / 'functions.tsv').open('w', newline='') as fp:
        writer = csv.DictWriter(fp, ['lib', 'slice', 'function', 'nir', 'ir3', 'reason'],
                                delimiter='\t', restval='')
        writer.writeheader()
        writer.writerows(rows)
    summary = collections.Counter((r['nir'], r['ir3']) for r in rows)
    text = '\n'.join(f'NIR={n} ir3={i}: {count}' for (n, i), count in sorted(summary.items()))
    (args.out / 'summary.txt').write_text(text + '\n')
    print(text, flush=True)


if __name__ == '__main__':
    main()
