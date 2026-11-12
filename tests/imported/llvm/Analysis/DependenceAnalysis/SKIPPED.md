# Skipped while importing llvm/test/Analysis/DependenceAnalysis (llvmorg-23.1.5)

72 of 76 files imported. Regenerate with `./harness/run import-llvm Analysis/DependenceAnalysis`.

- `DADelin.ll`: target triple thumbv8m.main-arm-none-eabi
- `Invariant.ll`: XFAIL in LLVM
- `NonAffineExpr.ll`: target triple thumbv7--linux-gnueabi
- `new-pm-invalidation.ll` RUN `opt < %s -passes='require<da>,invalidate<scalar-evolution>,print<da>' -disable-output -debug-pass-manager 2>&1 | FileCheck %s`: diagnostic output flag -debug-pass-manager
