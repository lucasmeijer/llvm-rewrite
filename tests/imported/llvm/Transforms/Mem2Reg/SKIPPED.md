# Skipped while importing llvm/test/Transforms/Mem2Reg (llvmorg-23.1.5)

30 of 32 files imported. Regenerate with `./harness/run import-llvm Transforms/Mem2Reg`.

- `2007-08-27-VolatileLoadsStores.ll`: target triple i686-pc-linux-gnu
- `PromoteMemToRegister.ll` RUN `opt < %s -passes='debugify,mem2reg,check-debugify' -S 2>&1 | FileCheck %s`: redirects or chains commands
