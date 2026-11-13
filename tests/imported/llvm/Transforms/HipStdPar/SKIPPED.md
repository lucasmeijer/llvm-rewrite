# Skipped while importing llvm/test/Transforms/HipStdPar (llvmorg-23.1.5)

3 of 15 files imported. Regenerate with `./harness/run import-llvm Transforms/HipStdPar`.

- `accelerator-code-selection.ll` RUN `opt -S -mtriple=amdgpu-amd-amdhsa -passes=hipstdpar-select-accelerator-code %s | FileCheck %s`: non-x86_64 target amdgpu-amd-amdhsa
- `global-var-indirection-wrong-table-member-0.ll`: REQUIRES amdgpu-registered-target
- `global-var-indirection-wrong-table-member-1.ll`: REQUIRES amdgpu-registered-target
- `global-var-indirection-wrong-table-member-2.ll`: REQUIRES amdgpu-registered-target
- `global-var-indirection-wrong-table-member-count.ll`: REQUIRES amdgpu-registered-target
- `global-var-indirection-wrong-table-type.ll`: REQUIRES amdgpu-registered-target
- `global-var-indirection.ll`: REQUIRES amdgpu-registered-target
- `global-var.ll`: REQUIRES amdgpu-registered-target
- `unsupported-asm.ll` RUN `not opt -S -mtriple=amdgpu-amd-amdhsa -passes=hipstdpar-select-accelerator-code %s 2>&1 | FileCheck %s`: not an opt invocation
- `unsupported-builtins.ll` RUN `not opt -S -mtriple=amdgpu-amd-amdhsa -passes=hipstdpar-select-accelerator-code %s 2>&1 | FileCheck %s`: not an opt invocation
- `unsupported-thread-local-direct-use.ll` RUN `not opt -S -mtriple=amdgpu-amd-amdhsa -passes=hipstdpar-select-accelerator-code %s 2>&1 | FileCheck %s`: not an opt invocation
- `unsupported-thread-local-indirect-use.ll`: XFAIL in LLVM
