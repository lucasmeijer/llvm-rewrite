# Skipped while importing llvm/test/Transforms/LoopRotate (llvmorg-23.1.5)

34 of 42 files imported. Regenerate with `./harness/run import-llvm Transforms/LoopRotate`.

- `invalid-cost.ll`: in a RISCV target directory
- `convergent-controlled.ll`: uses non-x86 target intrinsic @llvm.dx.
- `loopexitinglatch.ll`: target triple thumbv8m.base-arm-none-eabi
- `minsize-disable.ll`: REQUIRES asserts
- `nosimplifylatch.ll`: target triple arm64-apple-ios8.0.0
- `oz-disable.ll`: REQUIRES asserts
- `pr35210.ll`: REQUIRES asserts
- `pr51981-scev-problem.ll` RUN `opt < %s -passes='print<scalar-evolution>,loop(loop-rotate),invalidate<scalar-evolution>,print<scalar-evolution>' -disable-output 2>&1 | FileCheck -check-prefixes CHECK-SCEV %s`: analysis printer (stderr output) not supported yet
- `pr51981-scev-problem.ll` RUN `opt < %s -passes='print<scalar-evolution>,loop(loop-rotate),print<scalar-evolution>' -disable-output 2>&1 | FileCheck -check-prefixes CHECK-SCEV %s`: analysis printer (stderr output) not supported yet
- `pr51981-scev-problem.ll` RUN `opt < %s -passes='loop(canon-freeze),loop(loop-rotate),print<scalar-evolution>' -disable-output`: analysis printer (stderr output) not supported yet
- `update-branch-weights.ll` RUN `opt < %s -passes='print<block-freq>' -disable-output 2>&1 | FileCheck %s --check-prefixes=BFI_BEFORE`: analysis printer (stderr output) not supported yet
- `update-branch-weights.ll` RUN `opt < %s -passes='loop(loop-rotate),print<block-freq>' -disable-output 2>&1 | FileCheck %s --check-prefixes=BFI_AFTER`: analysis printer (stderr output) not supported yet
