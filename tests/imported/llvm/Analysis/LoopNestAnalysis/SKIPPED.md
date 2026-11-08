# Skipped while importing llvm/test/Analysis/LoopNestAnalysis (llvmorg-23.1.5)

4 of 5 files imported. Regenerate with `./harness/run import-llvm Analysis/LoopNestAnalysis`.

- `nests-with-lcssa.ll` RUN `opt -S -passes='print<loopnest>' < %s 2>&1 > /dev/null | FileCheck %s`: redirects or chains commands
