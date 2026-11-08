# Skipped while importing llvm/test/Transforms/InferFunctionAttrs (llvmorg-23.1.5)

8 of 10 files imported. Regenerate with `./harness/run import-llvm Transforms/InferFunctionAttrs`.

- `annotate.ll` RUN `opt < %s -mtriple=nvptx -passes=inferattrs -S | FileCheck --match-full-lines --check-prefixes=CHECK-NOLINUX,CHECK-NVPTX %s`: non-x86_64 target nvptx
- `annotate.ll` RUN `opt < %s -mtriple=powerpc64-ibm-aix-xcoff -passes=inferattrs -S | FileCheck --match-full-lines --check-prefixes=CHECK-NOLINUX,CHECK-AIX %s`: non-x86_64 target powerpc64-ibm-aix-xcoff
- `enable-builtin.ll` RUN `opt -S -mtriple=amdgpu-- -passes=inferattrs %s | FileCheck -check-prefix=NOBUILTIN %s`: non-x86_64 target amdgpu--
- `enable-builtin.ll` RUN `opt -S -enable-builtin=malloc -mtriple=amdgpu-- -passes=inferattrs %s | FileCheck -check-prefix=WITHBUILTIN %s`: non-x86_64 target amdgpu--
- `norecurse_debug.ll`: target triple armv4t-none-unknown-eabi
