# Skipped while importing llvm/test/Transforms/DeadStoreElimination (llvmorg-23.1.5)

83 of 91 files imported. Regenerate with `./harness/run import-llvm Transforms/DeadStoreElimination`.

- `2011-03-25-DSEMiscompile.ll`: target triple i386-apple-darwin9.8
- `combined-partial-overwrites.ll`: target triple powerpc64le-unknown-linux
- `crash.ll`: target triple i386-apple-darwin10.0
- `debug-counter.ll` RUN `opt < %s -passes=dse -debug-counter=dse-memoryssa=0 -S | FileCheck --check-prefix=SKIP0-COUNT1 %s`: diagnostic output flag -debug-counter=dse-memoryssa=0
- `debug-counter.ll` RUN `opt < %s -passes=dse -debug-counter=dse-memoryssa=1 -S | FileCheck --check-prefix=SKIP1-COUNT1 %s`: diagnostic output flag -debug-counter=dse-memoryssa=1
- `debug-counter.ll` RUN `opt < %s -passes=dse -debug-counter=dse-memoryssa=0-1 -S | FileCheck --check-prefix=SKIP0-COUNT2 %s`: diagnostic output flag -debug-counter=dse-memoryssa=0-1
- `debug-counter.ll` RUN `opt < %s -passes=dse -debug-counter=dse-memoryssa=2 -S | FileCheck --check-prefix=SKIP2-COUNT1 %s`: diagnostic output flag -debug-counter=dse-memoryssa=2
- `malloc-earliest-escape-info-invalidation.ll` RUN `opt -p dse -S %s | FileCheck %s`: no -passes / -O pipeline
- `memcpy-complete-overwrite.ll`: XFAIL in LLVM
- `stats.ll`: REQUIRES asserts
- `tail-byval.ll`: target triple i386-unknown-linux-gnu
