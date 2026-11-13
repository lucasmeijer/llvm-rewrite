# Skipped while importing llvm/test/Transforms/FixIrreducible (llvmorg-23.1.5)

8 of 9 files imported. Regenerate with `./harness/run import-llvm Transforms/FixIrreducible`.

- `unsupported-terminator.ll` RUN `not opt < %s -passes=fix-irreducible -S 2>&1 | FileCheck %s`: not an opt invocation
