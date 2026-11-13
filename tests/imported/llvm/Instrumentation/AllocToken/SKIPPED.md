# Skipped while importing llvm/test/Instrumentation/AllocToken (llvmorg-23.1.5)

11 of 13 files imported. Regenerate with `./harness/run import-llvm Instrumentation/AllocToken`.

- `intrinsic32.ll`: target triple i386-pc-linux-gnu
- `remark.ll` RUN `opt < %s -passes=inferattrs,alloc-token -pass-remarks=alloc-token -S 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks=alloc-token
