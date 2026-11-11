# Skipped while importing llvm/test/Transforms/MergeICmps (llvmorg-23.1.5)

23 of 26 files imported. Regenerate with `./harness/run import-llvm Transforms/MergeICmps`.

- `int64-and-ptr.ll` RUN `opt < %s -mtriple=x86_64-unknown-unknown -passes=mergeicmps -verify-dom-info -S 2>&1 | FileCheck %s`: redirects or chains commands
- `pr41917.ll`: target triple i386-pc-windows-msvc19.11.0
- `tuple-four-int8.ll`: XFAIL in LLVM
