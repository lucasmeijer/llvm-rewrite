# Skipped while importing llvm/test/Analysis/LazyCallGraph (llvmorg-23.1.5)

6 of 7 files imported. Regenerate with `./harness/run import-llvm Analysis/LazyCallGraph`.

- `invalidate.ll` RUN `opt -passes='require<lcg>,function(instcombine)' -debug-pass-manager -disable-output < %s 2>&1 | FileCheck %s`: diagnostic output flag -debug-pass-manager
