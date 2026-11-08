# Skipped while importing llvm/test/Transforms/LoopSimplifyCFG (llvmorg-23.1.5)

9 of 18 files imported. Regenerate with `./harness/run import-llvm Transforms/LoopSimplifyCFG`.

- `constant-fold-branch.ll`: REQUIRES asserts
- `invalidate-scev-dispositions-2.ll` RUN `opt -verify-scev -passes="print<scalar-evolution>,loop-simplifycfg" -S %s 2>&1 | FileCheck %s`: analysis printer (stderr output) not supported yet
- `irreducible_cfg.ll`: REQUIRES asserts
- `live_block_marking.ll`: REQUIRES asserts
- `mssa_update.ll`: REQUIRES asserts
- `phi_with_duplicating_inputs.ll`: REQUIRES asserts
- `pr117537.ll` RUN `opt -S -passes='print<scalar-evolution>,loop-mssa(licm,loop-simplifycfg,loop-predication)' -verify-scev < %s | FileCheck %s`: analysis printer (stderr output) not supported yet
- `pr39783.ll`: REQUIRES asserts
- `update_parents.ll`: REQUIRES asserts
