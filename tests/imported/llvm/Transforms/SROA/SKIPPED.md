# Skipped while importing llvm/test/Transforms/SROA (llvmorg-23.1.5)

61 of 68 files imported. Regenerate with `./harness/run import-llvm Transforms/SROA`.

- `2009-02-20-InstCombine-SROA.ll`: target triple i386-apple-darwin9.6
- `dead-inst.ll`: target triple powerpc64le-grtev4-linux-gnu
- `phi-catchswitch.ll`: target triple wasm32-unknown-unknown
- `ppcf128-no-fold.ll`: target triple powerpc64-unknown-linux-gnu
- `pr37267.ll`: target triple sparcv9-sun-solaris
- `tbaa-struct3.ll` RUN `opt -p sroa -S %s | FileCheck %s`: no -passes / -O pipeline
- `vector-promotion-cannot-tree-structure-merge.ll`: REQUIRES asserts
