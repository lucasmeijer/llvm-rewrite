# Skipped while importing llvm/test/Transforms/AggressiveInstCombine (llvmorg-23.1.5)

44 of 52 files imported. Regenerate with `./harness/run import-llvm Transforms/AggressiveInstCombine`.

- `combine_ignore_debug.ll`: in a AArch64 target directory
- `fptosisat.ll`: in a AArch64 target directory
- `lower-table-based-log2-basics.ll`: in a AArch64 target directory
- `or-load.ll`: in a AArch64 target directory
- `fold-consecutive-loads.ll`: in a AMDGPU target directory
- `fold-loads-multiple-uses.ll`: in a AMDGPU target directory
- `fptosisat.ll`: in a ARM target directory
- `dbgloc-memchr.ll` RUN `opt -S -p=aggressive-instcombine < %s | FileCheck %s`: no -passes / -O pipeline
