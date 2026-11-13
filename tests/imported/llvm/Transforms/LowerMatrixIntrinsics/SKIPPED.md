# Skipped while importing llvm/test/Transforms/LowerMatrixIntrinsics (llvmorg-23.1.5)

49 of 71 files imported. Regenerate with `./harness/run import-llvm Transforms/LowerMatrixIntrinsics`.

- `after-transpose-opts.ll`: REQUIRES aarch64-registered-target
- `data-layout-multiply-fused.ll`: REQUIRES aarch64-registered-target
- `dot-product-float.ll`: REQUIRES aarch64-registered-target
- `dot-product-int-row-major.ll`: REQUIRES aarch64-registered-target
- `dot-product-int.ll`: REQUIRES aarch64-registered-target
- `dot-product-transpose-int.ll`: REQUIRES aarch64-registered-target
- `flatten.ll`: REQUIRES asserts
- `multiply-fused-dominance.ll`: REQUIRES aarch64-registered-target
- `multiply-fused-loops-large-matrixes.ll`: REQUIRES aarch64-registered-target
- `multiply-fused-loops.ll`: REQUIRES aarch64-registered-target
- `multiply-fused-multiple-blocks.ll`: REQUIRES aarch64-registered-target
- `multiply-fused-tile-size-0.ll`: REQUIRES aarch64-registered-target
- `multiply-fused-volatile.ll`: REQUIRES aarch64-registered-target
- `multiply-fused.ll`: REQUIRES aarch64-registered-target
- `multiply-minimal.ll`: REQUIRES aarch64-registered-target
- `multiply-remainder-rm.ll`: REQUIRES aarch64-registered-target
- `multiply-remainder.ll`: REQUIRES aarch64-registered-target
- `remarks-inlining.ll`: REQUIRES aarch64-registered-target
- `remarks-shared-subtrees.ll`: REQUIRES aarch64-registered-target
- `remarks.ll`: REQUIRES aarch64-registered-target
- `shape-verification.ll` RUN `not --crash opt -passes='lower-matrix-intrinsics' -verify-matrix-shapes=true -S %s 2>&1 | FileCheck --check-prefix=VERIFY %s`: not an opt invocation
- `transpose-opts-lifting.ll`: REQUIRES asserts
- `transpose-opts.ll`: REQUIRES aarch64-registered-target
