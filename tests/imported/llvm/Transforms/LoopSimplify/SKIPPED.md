# Skipped while importing llvm/test/Transforms/LoopSimplify (llvmorg-23.1.5)

38 of 41 files imported. Regenerate with `./harness/run import-llvm Transforms/LoopSimplify`.

- `2007-10-28-InvokeCrash.ll`: target triple i686-pc-mingw32
- `dup-preds.ll`: target triple powerpc64le-unknown-linux
- `preserve-scev.ll` RUN `opt -S < %s -passes='print<scalar-evolution>,loop-simplify,print<scalar-evolution>' 2>&1 | FileCheck %s`: analysis printer (stderr output) not supported yet
