# Skipped while importing llvm/test/Transforms/ExpandMemCmp (llvmorg-23.1.5)

3 of 5 files imported. Regenerate with `./harness/run import-llvm Transforms/ExpandMemCmp`.

- `memcmp.ll`: in a AArch64 target directory
- `memcmp-x32.ll` RUN `opt -S -passes=expand-memcmp -mtriple=i686-unknown-unknown -data-layout=e-m:o-p:32:32-f64:32:64-f80:128-n8:16:32-S128 < %s | FileCheck %s --check-prefix=X32`: non-x86_64 target i686-unknown-unknown
