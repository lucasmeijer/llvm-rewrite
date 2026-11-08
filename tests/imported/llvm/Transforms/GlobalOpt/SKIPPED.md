# Skipped while importing llvm/test/Transforms/GlobalOpt (llvmorg-23.1.5)

180 of 205 files imported. Regenerate with `./harness/run import-llvm Transforms/GlobalOpt`.

- `2006-07-07-InlineAsmCrash.ll`: target triple i686-pc-linux-gnu
- `2007-04-05-Crash.ll`: target triple thumb-apple-darwin8
- `2007-05-13-Crash.ll`: target triple i686-apple-darwin8
- `2007-06-04-PackedStruct.ll`: target triple i686-pc-linux-gnu
- `2007-11-09-GEP-GEP-Crash.ll`: target triple powerpc-unknown-linux-gnu
- `2008-12-16-HeapSRACrash-2.ll`: target triple i386-apple-darwin7
- `2008-12-16-HeapSRACrash.ll`: target triple i386-apple-darwin7
- `2009-03-05-dbg.ll`: REQUIRES asserts
- `2009-03-07-PromotePtrToBool.ll`: target triple i386-apple-darwin7
- `coldcc_coldsites.ll`: in a PowerPC target directory
- `preserve-dbgloc-of-load-store-to-bool.ll` RUN `opt < %s -p=globalopt -S | FileCheck %s`: no -passes / -O pipeline
- `address_space_initializer.ll`: REQUIRES amdgpu-registered-target, nvptx-registered-target
- `analysis-invalidation.ll` RUN `opt -passes='function(require<no-op-function>),globalopt' %s -debug-pass-manager -S 2>&1 | FileCheck %s`: diagnostic output flag -debug-pass-manager
- `coldcc_stress_test.ll` RUN `opt < %s -passes=globalopt -S -enable-coldcc-stress-test -mtriple=powerpc64le-unknown-linux-gnu | FileCheck %s -check-prefix=COLDCC`: non-x86_64 target powerpc64le-unknown-linux-gnu
- `crash-2.ll` RUN `llvm-as < %s | opt -passes=globalopt -disable-output`: not an opt invocation
- `crash.ll`: target triple i386-apple-darwin9.8
- `dbg-intrinsic-loopanalysis.ll` RUN `opt -passes="globalopt" < %s -o /dev/null -debug-pass-manager 2>&1 | FileCheck %s`: writes to a file
- `dbg-intrinsic-loopanalysis.ll` RUN `opt -strip-debug -S < %s | opt -passes="globalopt" -o /dev/null -debug-pass-manager 2>&1 | FileCheck %s`: no -passes / -O pipeline
- `evaluate-call-errors.ll`: REQUIRES asserts
- `global-constructor-complex-constants.ll` RUN `opt -p globalopt -S %s | FileCheck %s`: no -passes / -O pipeline
- `issue62384.ll` RUN `opt -S -p=globalopt %s | FileCheck %s`: no -passes / -O pipeline
- `load-failed-to-evaluate-initializer.ll`: REQUIRES asserts
- `read-with-constexpr-users.ll` RUN `opt -p globalopt -S %s | FileCheck %s`: no -passes / -O pipeline
- `resolve-fmv-ifunc-noipa.ll`: REQUIRES aarch64-registered-target
- `resolve-fmv-ifunc.ll`: REQUIRES aarch64-registered-target
- `resolve-static-ifunc.ll`: target triple aarch64-unknown-linux-gnu
- `shrink-global-to-bool.ll`: REQUIRES amdgpu-registered-target
