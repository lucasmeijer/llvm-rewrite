# Skipped while importing llvm/test/Analysis/Lint (llvmorg-23.1.5)

13 of 14 files imported. Regenerate with `./harness/run import-llvm Analysis/Lint`.

- `abort-on-error.ll` RUN `not opt -passes='lint<abort-on-error>' -disable-output %s 2>&1 | FileCheck %s`: not an opt invocation
- `const-store.ll` RUN `not opt --mtriple=amdgcn --passes='lint<abort-on-error>' %s -disable-output 2>&1 | FileCheck %s`: not an opt invocation
- `const-store.ll` RUN `opt --mtriple=amdgcn --mcpu=gfx1030 --passes=lint %s -disable-output 2>&1 | FileCheck %s --check-prefixes=CHECK,CHECK0`: non-x86_64 target amdgcn
