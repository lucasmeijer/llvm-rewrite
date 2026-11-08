# Skipped while importing llvm/test/Transforms/LoopDeletion (llvmorg-23.1.5)

30 of 37 files imported. Regenerate with `./harness/run import-llvm Transforms/LoopDeletion`.

- `2008-05-06-Phi.ll`: target triple i386-apple-darwin9
- `2017-07-11-incremental-dt.ll` RUN `opt < %s -passes='loop(loop-deletion),print<domtree>' -verify-dom-info 2>&1 | FileCheck -check-prefix=DT %s`: analysis printer (stderr output) not supported yet
- `basic-remark.ll` RUN `opt -passes=loop-deletion %s -o /dev/null --pass-remarks-output=%t --pass-remarks-filter=loop-delete`: writes to a file
- `basic-remark.ll` RUN `cat %t | FileCheck %s`: not an opt invocation
- `crashbc.ll` RUN `opt < %s -passes=loop-deletion -o /dev/null`: writes to a file
- `invalidate-scev-after-hoisting.ll` RUN `opt -passes='loop(indvars,loop-deletion),verify<scalar-evolution>,print<scalar-evolution>' -S %s 2>&1| FileCheck %s`: analysis printer (stderr output) not supported yet
- `two-predecessors.ll`: target triple aarch64-unknown-linux-gnu
- `unreachable-loops.ll` RUN `opt < %s -passes=loop-deletion -verify-dom-info --pass-remarks-output=%t --pass-remarks-filter=loop-delete -S | FileCheck %s`: uses lit substitution --pass-remarks-output=%t
- `unreachable-loops.ll` RUN `cat %t | FileCheck %s --check-prefix=REMARKS`: not an opt invocation
- `update-scev.ll` RUN `opt -S -passes='print<scalar-evolution>,loop-deletion,print<scalar-evolution>' -verify-scev < %s 2>&1 | FileCheck %s --check-prefix=SCEV-EXPRS`: analysis printer (stderr output) not supported yet
