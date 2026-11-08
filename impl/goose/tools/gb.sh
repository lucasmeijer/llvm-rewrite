#!/usr/bin/env bash
# Build one root file, hiding warnings. Usage: tools/gb.sh src/opt.goose bin/opt [--debug]
src=$1; out=$2; shift 2
goose build --cc /opt/llvm-23.1.5/bin/clang --color never "$@" -o "$out" "$src" 2>&1 | python3 -c '
import sys
skip = False
for line in sys.stdin:
    if ": warning:" in line: skip = True; continue
    if ": error:" in line or line.startswith("built"): skip = False
    if not skip: sys.stdout.write(line)
'
