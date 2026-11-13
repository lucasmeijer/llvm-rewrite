# Skipped while importing llvm/test/Transforms/StackProtector (llvmorg-23.1.5)

2 of 3 files imported. Regenerate with `./harness/run import-llvm Transforms/StackProtector`.

- `missing-analysis.ll` RUN `not opt -mtriple=x86_64-- -passes=stack-protector -disable-output %s 2>&1 | FileCheck %s`: not an opt invocation
