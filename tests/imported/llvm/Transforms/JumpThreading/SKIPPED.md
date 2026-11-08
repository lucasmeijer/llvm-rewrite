# Skipped while importing llvm/test/Transforms/JumpThreading (llvmorg-23.1.5)

97 of 112 files imported. Regenerate with `./harness/run import-llvm Transforms/JumpThreading`.

- `combine-metadata.ll`: target triple i386-apple-darwin7
- `divergent-target-test.ll`: REQUIRES amdgpu-registered-target
- `domtree-updates.ll`: REQUIRES asserts
- `no-irreducible-loops.ll`: target triple i386-apple-darwin9.6
- `select.ll`: REQUIRES asserts
- `thread-loads.ll`: target triple i386-apple-darwin7
- `thread-prob-1.ll`: REQUIRES asserts
- `thread-prob-2.ll`: REQUIRES asserts
- `thread-prob-3.ll`: REQUIRES asserts
- `thread-prob-4.ll`: REQUIRES asserts
- `thread-prob-5.ll`: REQUIRES asserts
- `thread-prob-6.ll`: REQUIRES asserts
- `thread-prob-7.ll` RUN `opt -S -passes="jump-threading" < %s 2>&1 | FileCheck %s`: redirects or chains commands
- `thread-prob-8.ll`: REQUIRES asserts
- `thread-two-bbs-cuda.ll`: uses non-x86 target intrinsic @llvm.nvvm.
