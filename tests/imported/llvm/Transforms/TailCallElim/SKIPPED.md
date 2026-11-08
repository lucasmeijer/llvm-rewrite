# Skipped while importing llvm/test/Transforms/TailCallElim (llvmorg-23.1.5)

20 of 24 files imported. Regenerate with `./harness/run import-llvm Transforms/TailCallElim`.

- `EraseBB.ll` RUN `opt -passes=tailcallelim -verify-dom-info -S < %s 2>&1 | FileCheck %s`: redirects or chains commands
- `ackermann.ll`: REQUIRES asserts
- `dup_tail.ll`: REQUIRES asserts
- `opt-remarks-recursion.ll` RUN `opt %s -passes=tailcallelim -verify-dom-info -pass-remarks=tailcallelim -o /dev/null 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks=tailcallelim
- `opt-remarks-recursion.ll` RUN `opt %s -o /dev/null -passes='require<opt-remark-emit>,tailcallelim' -pass-remarks=tailcallelim 2>&1 | FileCheck %s`: writes to a file
