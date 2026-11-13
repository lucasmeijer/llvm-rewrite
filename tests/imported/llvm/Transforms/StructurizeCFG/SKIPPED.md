# Skipped while importing llvm/test/Transforms/StructurizeCFG (llvmorg-23.1.5)

19 of 28 files imported. Regenerate with `./harness/run import-llvm Transforms/StructurizeCFG`.

- `backedge-id-bug.ll`: in a AMDGPU target directory
- `loop-subregion-misordered.ll`: in a AMDGPU target directory
- `uniform-regions.ll`: in a AMDGPU target directory
- `hoist-zerocost-nested.ll`: target triple amdgcn-amd-amdhsa
- `hoist-zerocost.ll`: uses non-x86 target intrinsic @llvm.amdgcn.
- `invert-constantexpr.ll`: uses non-x86 target intrinsic @llvm.amdgcn.
- `rebuild-ssa-infinite-loop-inseltpoison.ll`: uses non-x86 target intrinsic @llvm.amdgcn.
- `rebuild-ssa-infinite-loop.ll`: uses non-x86 target intrinsic @llvm.amdgcn.
- `structurizer-keep-perf-md.ll` RUN `opt -S -mtriple=amdgpu-- -passes=structurizecfg %s | FileCheck -check-prefix=OPT %s`: non-x86_64 target amdgpu--
