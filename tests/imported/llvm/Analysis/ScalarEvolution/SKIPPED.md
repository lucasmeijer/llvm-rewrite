# Skipped while importing llvm/test/Analysis/ScalarEvolution (llvmorg-23.1.5)

264 of 278 files imported. Regenerate with `./harness/run import-llvm Analysis/ScalarEvolution`.

- `2008-06-12-BinomialInt64.ll` RUN `opt < %s -disable-output "-passes=print<scalar-evolution>" 2>/dev/null`: redirects or chains commands
- `2008-12-14-StrideAndSigned.ll`: XFAIL in LLVM
- `avoid-smax-1.ll`: target triple i386-apple-darwin9
- `cache_loop_exit_limit.ll` RUN `opt -scalar-evolution-max-arith-depth=4 -scalar-evolution-max-add-rec-size=4 -loop-reduce -S < %s | FileCheck %s`: no -passes / -O pipeline
- `invalidation.ll` RUN `opt < %s -passes='require<scalar-evolution>,invalidate<domtree>,print<scalar-evolution>' -debug-pass-manager -disable-output 2>&1 | FileCheck %s -check-prefixes=CHECK,CHECK-DT-INVALIDATE`: diagnostic output flag -debug-pass-manager
- `invalidation.ll` RUN `opt < %s -passes='require<scalar-evolution>,invalidate<loops>,print<scalar-evolution>' -debug-pass-manager -disable-output 2>&1 | FileCheck %s -check-prefixes=CHECK,CHECK-LI-INVALIDATE`: diagnostic output flag -debug-pass-manager
- `load.ll`: target triple i386-pc-linux-gnu
- `no-follow-alias.ll`: target triple aarch64-unknown-linux-gnu
- `pr22674.ll` RUN `opt -loop-reduce -S %s`: no -passes / -O pipeline
- `pr22856.ll` RUN `opt -loop-reduce -verify < %s`: no -passes / -O pipeline
- `pr40420.ll`: REQUIRES asserts
- `pr62430.ll` RUN `opt -loop-reduce -S < %s | FileCheck %s`: no -passes / -O pipeline
- `scev-expander-reuse-gep.ll`: target triple i386-apple-macosx10.12.0
- `sext-inreg.ll`: target triple i386-apple-darwin9.6
- `solve-quadratic.ll`: REQUIRES asserts
