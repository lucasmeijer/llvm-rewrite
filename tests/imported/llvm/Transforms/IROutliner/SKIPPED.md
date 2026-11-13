# Skipped while importing llvm/test/Transforms/IROutliner (llvmorg-23.1.5)

90 of 94 files imported. Regenerate with `./harness/run import-llvm Transforms/IROutliner`.

- `gvn-phi-debug.ll`: target triple thumbv7-none-linux-android19
- `nooutline-attribute.ll`: REQUIRES asserts
- `opt-remarks.ll` RUN `opt -S -passes=verify,iroutliner -o /dev/null -pass-remarks=iroutliner -pass-remarks-missed=iroutliner < %s 2>&1 | FileCheck -check-prefix=CHECK %s`: writes to a file
- `opt-remarks.ll` RUN `opt -S -passes=verify,iroutliner -o /dev/null -pass-remarks-output=%t < %s`: writes to a file
- `opt-remarks.ll` RUN `cat %t | FileCheck -check-prefix=YAML %s`: not an opt invocation
- `outlining-compatible-and-never-transfer-riscv.ll`: REQUIRES riscv-registered-target
