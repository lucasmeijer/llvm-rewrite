# Skipped while importing llvm/test/Transforms/LoopUnrollAndJam (llvmorg-23.1.5)

14 of 18 files imported. Regenerate with `./harness/run import-llvm Transforms/LoopUnrollAndJam`.

- `disable.ll` RUN `opt -passes=loop-unroll-and-jam -allow-unroll-and-jam -unroll-and-jam-count=4 -pass-remarks=loop-unroll-and-jam < %s -S 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks=loop-unroll-and-jam
- `disable.ll` RUN `opt -passes='loop-unroll-and-jam' -allow-unroll-and-jam -unroll-and-jam-count=4 -pass-remarks=loop-unroll-and-jam < %s -S 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks=loop-unroll-and-jam
- `multiple_exit_blocks.ll`: REQUIRES asserts
- `pragma-disable-unroll.ll`: REQUIRES asserts
- `unprofitable.ll`: target triple thumbv8m.main-arm-none-eabi
