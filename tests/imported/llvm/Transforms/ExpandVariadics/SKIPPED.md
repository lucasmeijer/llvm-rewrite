# Skipped while importing llvm/test/Transforms/ExpandVariadics (llvmorg-23.1.5)

0 of 9 files imported. Regenerate with `./harness/run import-llvm Transforms/ExpandVariadics`.

- `expand-va-intrinsic-split-linkage.ll`: REQUIRES webassembly-registered-target
- `expand-va-intrinsic-split-simple.ll`: REQUIRES webassembly-registered-target
- `indirect-calls.ll`: REQUIRES webassembly-registered-target
- `intrinsics.ll`: REQUIRES webassembly-registered-target
- `invoke.ll`: REQUIRES webassembly-registered-target
- `pass-byval-byref.ll`: REQUIRES webassembly-registered-target
- `pass-indirect.ll`: REQUIRES webassembly-registered-target
- `pass-integers.ll`: REQUIRES webassembly-registered-target
- `spirv-printf.ll` RUN `opt -mtriple=spirv64-unknown-unknown -S --passes=expand-variadics --expand-variadics-override=lowering %s | FileCheck %s`: non-x86_64 target spirv64-unknown-unknown
