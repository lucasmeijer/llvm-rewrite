# Skipped while importing llvm/test/Transforms/JumpTableToSwitch (llvmorg-23.1.5)

7 of 9 files imported. Regenerate with `./harness/run import-llvm Transforms/JumpTableToSwitch`.

- `remarks.ll` RUN `opt < %s -passes=jump-table-to-switch -pass-remarks=jump-table-to-switch -S -o /dev/null 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks=jump-table-to-switch
- `stats.ll`: REQUIRES asserts
