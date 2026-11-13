# Skipped while importing llvm/test/Transforms/ObjCARC (llvmorg-23.1.5)

52 of 58 files imported. Regenerate with `./harness/run import-llvm Transforms/ObjCARC`.

- `contract-catchswitch.ll`: target triple i686--windows-msvc19.11.0
- `contract-marker-funclet.ll` RUN `opt -mtriple=i686-unknown-windows-msvc -passes=objc-arc-contract -S -o - %s | FileCheck %s`: non-x86_64 target i686-unknown-windows-msvc
- `contract-storestrong-funclet.ll` RUN `opt -mtriple=i686-unknown-windows-msvc -passes=objc-arc-contract -S -o - %s | FileCheck %s`: non-x86_64 target i686-unknown-windows-msvc
- `opt-catchswitch.ll`: target triple i686--windows-msvc
- `path-overflow.ll`: target triple thumbv7-apple-ios5.0.0
- `related-check.ll` RUN `mkdir -p %t`: not an opt invocation
- `related-check.ll` RUN `opt -passes=objc-arc %s -S -o %t/out1.ll`: writes to a file
- `related-check.ll` RUN `opt -passes=objc-arc %s -S -o %t/out2.ll`: writes to a file
- `related-check.ll` RUN `diff -u %t/out1.ll %t/out2.ll`: not an opt invocation
