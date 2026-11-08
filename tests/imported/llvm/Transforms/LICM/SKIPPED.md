# Skipped while importing llvm/test/Transforms/LICM (llvmorg-23.1.5)

134 of 157 files imported. Regenerate with `./harness/run import-llvm Transforms/LICM`.

- `2007-05-22-VolatileSink.ll`: target triple i686-apple-darwin8
- `2008-05-20-AliasSetVAArg.ll`: target triple i686-pc-linux-gnu
- `extract-element.ll`: in a AArch64 target directory
- `sme-fp8-hoist.ll`: in a AArch64 target directory
- `speculative-intrinsic-hoisting.ll`: in a AArch64 target directory
- `sve-load-hoist.ll`: in a AArch64 target directory
- `bitcast.ll`: in a AMDGPU target directory
- `buffer-rsrc-ptrs.ll`: in a AMDGPU target directory
- `funclet.ll`: target triple i386-pc-windows-msvc18.0.0
- `guards.ll`: REQUIRES asserts
- `hoist-invariant-load.ll`: REQUIRES asserts
- `hoist-mustexec.ll`: REQUIRES asserts
- `hoist-readonly-memory-def.ll` RUN `opt -S -passes="function(print<memoryssa>),cgscc(function-attrs),function(loop-mssa(licm))" < %s 2>/dev/null | FileCheck %s`: analysis printer (stderr output) not supported yet
- `lnicm.ll`: XFAIL in LLVM
- `opt-remarks-conditional-load.ll` RUN `opt < %s -passes=licm -pass-remarks-missed=licm -o /dev/null 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks-missed=licm
- `opt-remarks-conditional-load.ll` RUN `opt -aa-pipeline=basic-aa -passes='require<aa>,require<target-ir>,require<scalar-evolution>,require<opt-remark-emit>,loop-mssa(licm)' %s -o /dev/null -pass-remarks-missed=licm 2>&1 | FileCheck %s`: writes to a file
- `opt-remarks-intervening-store.ll` RUN `opt < %s -passes=licm -pass-remarks-missed=licm -o /dev/null 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks-missed=licm
- `opt-remarks-intervening-store.ll` RUN `opt -aa-pipeline=basic-aa -passes='require<aa>,require<target-ir>,require<scalar-evolution>,require<opt-remark-emit>,loop-mssa(licm)' %s -o /dev/null -pass-remarks-missed=licm 2>&1 | FileCheck %s`: writes to a file
- `opt-remarks.ll` RUN `opt < %s -passes=licm -pass-remarks=licm -o /dev/null 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks=licm
- `opt-remarks.ll` RUN `opt -aa-pipeline=basic-aa -passes='require<aa>,require<target-ir>,require<scalar-evolution>,require<opt-remark-emit>,loop-mssa(licm)' %s -o /dev/null -pass-remarks=licm 2>&1 | FileCheck %s`: writes to a file
- `pr26843.ll`: target triple i686-pc-windows-msvc18.0.0
- `pr27262.ll`: target triple i686-pc-windows-msvc18.0.0
- `pr38513.ll`: REQUIRES asserts
- `pr40317.ll`: target triple s390x-ibm-linux
- `sink-foldable.ll`: REQUIRES aarch64-registered-target
- `update-scev-after-hoist.ll` RUN `opt -S -passes='loop-unroll,loop-mssa(licm),print<scalar-evolution>' -unroll-count=4 -disable-output < %s 2>&1 | FileCheck %s --check-prefix=SCEV-EXPR`: analysis printer (stderr output) not supported yet
- `update-scev.ll` RUN `opt -passes='print<scalar-evolution>,loop-mssa(licm),print<scalar-evolution>' -disable-output < %s 2>&1 | FileCheck %s --check-prefix=SCEV-EXPRS`: analysis printer (stderr output) not supported yet
