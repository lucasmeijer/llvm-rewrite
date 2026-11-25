#!/bin/bash
# Cross-check lower-matrix-intrinsics beyond the imported tests: every LLVM test file of
# llvm/test/Transforms/LowerMatrixIntrinsics (including the aarch64-only ones the importer skips), with its triple
# replaced by none / x86_64 (+avx2, +avx512f), under several argument sets; LLVM vs impl/jai, canonicalized text.
# Usage: impl/jai/tools/lower_matrix_xcheck.sh [scratch dir]   (prints OK / DIFF / FAIL / LLVMFAIL per run)
LLVM=/opt/llvm-23.1.5/bin
JAI=$(cd "$(dirname "$0")/.." && pwd)/bin/opt
SRC=/opt/llvm-project-23.1.5/llvm/test/Transforms/LowerMatrixIntrinsics
W=${1:-/tmp/lower_matrix_xcheck}; mkdir -p "$W"; cd "$W" || exit 1
for f in $SRC/*.ll; do
  b=$(basename $f)
  sed -e 's/^target triple = .*//' $f > base.ll
  for variant in "x86|" "x86|-mattr=+avx512f" "x86|-mattr=+avx2" "none|"; do
    tr=${variant%%|*}; extra=${variant#*|}
    if [ $tr = x86 ]; then (echo 'target triple = "x86_64-unknown-linux-gnu"'; cat base.ll) > in.ll; else cp base.ll in.ll; fi
    for args in "-passes=lower-matrix-intrinsics" "-passes=lower-matrix-intrinsics -matrix-default-layout=row-major" \
                "-passes=lower-matrix-intrinsics -force-fuse-matrix" \
                "-passes=lower-matrix-intrinsics -fuse-matrix-loops-threshold=0 -fuse-matrix-tile-size=2 -force-fuse-matrix" \
                "-O2 -enable-matrix" "-O0 -enable-matrix" "-passes=lower-matrix-intrinsics<minimal>"; do
      $LLVM/opt $args $extra -S in.ll -o exp.ll 2>exp.err; e1=$?
      $JAI $args $extra -S in.ll -o act.ll 2>act.err; e2=$?
      if [ $e1 -ne 0 ]; then echo "LLVMFAIL $b [$variant] $args"; continue; fi
      if [ $e2 -ne 0 ]; then echo "FAIL $b [$variant] $args: $(head -1 act.err)"; continue; fi
      $LLVM/llvm-as < act.ll 2>/dev/null | $LLVM/llvm-dis -o act.c.ll 2>/dev/null; $LLVM/llvm-as < exp.ll | $LLVM/llvm-dis -o exp.c.ll
      if diff -q exp.c.ll act.c.ll >/dev/null; then echo "OK $b [$variant] $args"; else echo "DIFF $b [$variant] $args"; fi
    done
  done
done
