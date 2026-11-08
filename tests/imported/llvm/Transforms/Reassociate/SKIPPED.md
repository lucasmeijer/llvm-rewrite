# Skipped while importing llvm/test/Transforms/Reassociate (llvmorg-23.1.5)

82 of 89 files imported. Regenerate with `./harness/run import-llvm Transforms/Reassociate`.

- `2011-01-26-UseAfterFree.ll`: target triple i386-gnu-linux
- `2012-05-08-UndefLeak.ll`: XFAIL in LLVM
- `canonicalize-made-change.ll` RUN `opt -passes="print<demanded-bits>,reassociate,bdce" -S < %s | FileCheck %s`: analysis printer (stderr output) not supported yet
- `debugloc-factoring-add.ll` RUN `opt < %s -p=reassociate -S | FileCheck %s`: no -passes / -O pipeline
- `debugloc-factoring-neg.ll` RUN `opt -S -p=reassociate < %s | FileCheck %s`: no -passes / -O pipeline
- `debugloc-reass-add.ll` RUN `opt -p=reassociate -S < %s | FileCheck %s`: no -passes / -O pipeline
- `long-chains.ll`: REQUIRES asserts
