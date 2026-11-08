# Skipped while importing llvm/test/Transforms/LoopIdiom (llvmorg-23.1.5)

63 of 85 files imported. Regenerate with `./harness/run import-llvm Transforms/LoopIdiom`.

- `byte-compare-index.ll`: in a AArch64 target directory
- `ctlz.ll`: in a AArch64 target directory
- `disable-vectorize.ll`: in a AArch64 target directory
- `find-first-byte.ll`: in a AArch64 target directory
- `popcnt.ll`: in a AMDGPU target directory
- `ctlz.ll`: in a ARM target directory
- `popcnt.ll`: in a LoongArch target directory
- `byte-compare-index.ll`: in a RISCV target directory
- `memset-pattern.ll`: in a RISCV target directory
- `popcnt.ll`: in a RISCV target directory
- `popcnt.ll` RUN `opt -passes=loop-idiom -mtriple=sparc -mattr=+v9,+popc -S < %s | FileCheck %s --check-prefixes=SPARC-CPOP,SPARC32-CPOP`: non-x86_64 target sparc
- `popcnt.ll` RUN `opt -passes=loop-idiom -mtriple=sparcv9 -mattr=+popc -S < %s | FileCheck %s --check-prefixes=SPARC-CPOP,SPARC64-CPOP`: non-x86_64 target sparcv9
- `popcnt.ll` RUN `opt -passes=loop-idiom -mtriple=sparc -S < %s | FileCheck %s --check-prefixes=SPARC-NOCPOP,SPARC32-NOCPOP`: non-x86_64 target sparc
- `popcnt.ll` RUN `opt -passes=loop-idiom -mtriple=sparcv9 -S < %s | FileCheck %s --check-prefixes=SPARC-NOCPOP,SPARC64-NOCPOP`: non-x86_64 target sparcv9
- `popcnt.ll`: in a SPIRV target directory
- `preserve-profile.ll` RUN `opt -passes="module(print<block-freq>),function(loop(loop-idiom)),module(print<block-freq>)" -mtriple=x86_64 -mcpu=core-avx2 %s -disable-output 2>&1 | FileCheck --check-prefix=PROFILE %s`: analysis printer (stderr output) not supported yet
- `add-nsw-zext-fold.ll` RUN `opt -p loop-idiom -S %s | FileCheck %s`: no -passes / -O pipeline
- `ctpop-multiple-users-crash.ll`: target triple arm64-apple-ios8.0.0
- `dbginfo-cost.ll` RUN `opt -S -passes=loop-idiom -mtriple=systemz-unknown -mcpu=z13 %s | FileCheck %s`: non-x86_64 target systemz-unknown
- `expand-scev-expand-simplifications.ll` RUN `opt -p loop-idiom -S %s | FileCheck %s`: no -passes / -O pipeline
- `introduce-memset-in-outerloop.ll` RUN `opt <%s -p "print<scalar-evolution>" -disable-output 2>&1 | FileCheck %s`: redirects or chains commands
- `introduce-memset-in-outerloop.ll` RUN `opt <%s -p "loop(loop-idiom),print<scalar-evolution>" -disable-output 2>&1 | FileCheck %s`: redirects or chains commands
- `memcpy-debugify-remarks.ll` RUN `opt -passes=debugify,loop-idiom,verify -pass-remarks=loop-idiom -pass-remarks-analysis=loop-idiom -pass-remarks-output=%t.yaml -verify-each -verify-dom-info -verify-loop-info  < %s -S 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks=loop-idiom
- `memcpy-debugify-remarks.ll` RUN `FileCheck --input-file=%t.yaml %s --check-prefixes=YAML`: not an opt invocation
- `memset-debugify-remarks.ll` RUN `opt -passes=debugify,loop-idiom,verify -pass-remarks=loop-idiom -pass-remarks-analysis=loop-idiom -pass-remarks-output=%t.yaml -verify-each -verify-dom-info -verify-loop-info  < %s -S 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks=loop-idiom
- `memset-debugify-remarks.ll` RUN `FileCheck --input-file=%t.yaml %s --check-prefixes=YAML`: not an opt invocation
- `memset-runtime-debug.ll`: REQUIRES asserts
- `reuse-lcssa-phi-scev-expansion.ll` RUN `opt -p loop-idiom -S %s | FileCheck %s`: no -passes / -O pipeline
