# Skipped while importing llvm/test/Transforms/SeparateConstOffsetFromGEP (llvmorg-23.1.5)

10 of 30 files imported. Regenerate with `./harness/run import-llvm Transforms/SeparateConstOffsetFromGEP`.

- `scalable-vector-geps.ll`: in a AArch64 target directory
- `split-gep.ll`: in a AArch64 target directory
- `amdgpu-large-lds-offset.ll`: in a AMDGPU target directory
- `lower-gep.ll`: in a AMDGPU target directory
- `preserve-inbounds.ll`: in a AMDGPU target directory
- `rebuild-trunc.ll`: in a AMDGPU target directory
- `reorder-gep-inbounds.ll`: in a AMDGPU target directory
- `reorder-gep.ll`: in a AMDGPU target directory
- `reunite-exts-source-types.ll`: in a AMDGPU target directory
- `reunite-exts.ll`: in a AMDGPU target directory
- `split-gep-and-gvn-addrspace-addressing-modes.ll`: in a AMDGPU target directory
- `split-gep-and-gvn.ll`: in a AMDGPU target directory
- `split-gep.ll`: in a AMDGPU target directory
- `xor-decompose.ll`: in a AMDGPU target directory
- `gep-chain.ll`: in a NVPTX target directory
- `lower-gep-reorder.ll`: in a NVPTX target directory
- `split-gep-and-gvn.ll`: in a NVPTX target directory
- `split-gep.ll`: in a NVPTX target directory
- `split-gep.ll`: in a RISCV target directory
- `crash-in-unreachable-code.ll` RUN `opt -mtriple=amdgpu-amd-amdhsa -passes=separate-const-offset-from-gep %s`: non-x86_64 target amdgpu-amd-amdhsa
