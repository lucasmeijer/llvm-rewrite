# Skipped while importing llvm/test/Transforms/IRNormalizer (llvmorg-23.1.5)

10 of 11 files imported. Regenerate with `./harness/run import-llvm Transforms/IRNormalizer`.

- `pass-parameters.ll` RUN `not opt -S -passes='normalize<invalid>' %s 2>&1 | FileCheck -check-prefix=ERR %s`: not an opt invocation
- `regression-convergence-tokens.ll`: uses non-x86 target intrinsic @llvm.amdgcn.
