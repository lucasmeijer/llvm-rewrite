# Skipped while importing llvm/test/Analysis/BasicAA (llvmorg-23.1.5)

105 of 128 files imported. Regenerate with `./harness/run import-llvm Analysis/BasicAA`.

- `2003-03-04-GEPCrash.ll` RUN `opt < %s -aa-pipeline=basic-aa -passes=aa-eval -disable-output 2>/dev/null`: redirects or chains commands
- `2003-04-25-GEPCrash.ll` RUN `opt < %s -aa-pipeline=basic-aa -passes=aa-eval -disable-output 2>/dev/null`: redirects or chains commands
- `2003-06-01-AliasCrash.ll` RUN `opt < %s -aa-pipeline=basic-aa -passes=aa-eval -disable-output 2>/dev/null`: redirects or chains commands
- `2003-07-03-BasicAACrash.ll` RUN `opt < %s -aa-pipeline=basic-aa -passes=aa-eval -disable-output 2>/dev/null`: redirects or chains commands
- `2006-11-03-BasicAAVectorCrash.ll`: target triple powerpc-unknown-linux-gnu
- `2007-01-13-BasePointerBadNoAlias.ll`: target triple i686-apple-darwin8
- `2008-04-15-Byval.ll`: target triple i386-apple-darwin8
- `2008-06-02-GEPTailCrash.ll`: target triple i686-pc-linux-gnu
- `byval.ll`: target triple i686-apple-darwin8
- `cs-cs-arm.ll`: REQUIRES arm-registered-target
- `cs-cs.ll`: target triple arm-apple-ios
- `gep-alias.ll` RUN `opt < %s -aa-pipeline=basic-aa -passes=gvn,instcombine -S 2>&1 | FileCheck %s`: redirects or chains commands
- `gep-and-alias.ll`: target triple i386-apple-macosx10.6.0
- `intrinsics-arm.ll`: REQUIRES arm-registered-target
- `invalidation.ll` RUN `opt -disable-output -disable-verify -debug-pass-manager %s 2>&1 -passes='require<aa>,invalidate<domtree>,aa-eval' -aa-pipeline='basic-aa' | FileCheck %s --check-prefix=CHECK-DT-INVALIDATE`: diagnostic output flag -debug-pass-manager
- `negoffset.ll`: target triple i386-unknown-linux-gnu
- `no-escape-call.ll`: target triple i386-apple-darwin8
- `noalias-wraparound-bug.ll`: target triple i386-apple-macosx10.6.0
- `phi-spec-order.ll`: target triple powerpc64le-unknown-linux
- `phi-values-usage.ll` RUN `opt -debug-pass-manager -aa-pipeline=basic-aa -passes='require<phi-values>,memcpyopt,instcombine' -disable-output < %s 2>&1 | FileCheck %s`: diagnostic output flag -debug-pass-manager
- `q.bad.ll`: target triple thumbv7--linux-gnueabi
- `separate_storage-alias-sets.ll` @analysis `-basic-aa-separate-storage '-passes=print<alias-sets>'`: nondeterministic output
- `separate_storage-alias-sets.ll`: no working RUN lines
- `unreachable-block.ll` RUN `opt -aa-pipeline=basic-aa -passes=aa-eval -disable-output < %s > /dev/null 2>&1`: redirects or chains commands
