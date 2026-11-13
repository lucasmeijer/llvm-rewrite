# Skipped while importing llvm/test/Transforms/KCFI (llvmorg-23.1.5)

1 of 2 files imported. Regenerate with `./harness/run import-llvm Transforms/KCFI`.

- `kcfi-patchable-function-prefix.ll` RUN `not opt -S -passes=kcfi %s 2>&1 | FileCheck %s`: not an opt invocation
- `kcfi.ll` RUN `%if arm-registered-target %{ opt -S -passes=kcfi -mtriple=thumbv7m-unknown-linux-gnu %s | FileCheck --check-prefixes=CHECK,ARM %s %}`: not an opt invocation
