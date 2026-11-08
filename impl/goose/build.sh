#!/usr/bin/env bash
# Builds bin/{opt,llc,llvm-link}. Called by the harness before every check; keep it incremental and quick.
#
# GOOSE_STACK_RESERVE (default 2G) is the address space reserved per data stack (`goose build --stack-reserve`).
# The program has ~490 data stacks (one per global resizable array), so the default reserves ~1 TB of address
# space, more than valgrind gives a client (~128 GB, of which it needs room for itself): under `perf --instr` every run would die with "cannot reserve
# data stack address space". `GOOSE_STACK_RESERVE=128M ./harness/run perf --impl goose --instr` works (NOTES.md).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
reserve="${GOOSE_STACK_RESERVE:-2G}"
stamp="bin/.stack-reserve"
if [ "$(cat "$stamp" 2>/dev/null || true)" != "$reserve" ]; then rm -f bin/opt bin/llc bin/llvm-link; fi
for tool in opt llc llvm-link; do
  # goose build is content-hashed under GOOSE_HOME, but skip it entirely when nothing changed.
  if [ ! -x "bin/$tool" ] || [ -n "$(find src -name "*.goose" -newer "bin/$tool" -print -quit)" ]; then
    goose build --stack-reserve "$reserve" --cc /opt/llvm-23.1.5/bin/clang -o "bin/$tool" "src/${tool}.goose" >/dev/null
  fi
done
echo "$reserve" > "$stamp"
