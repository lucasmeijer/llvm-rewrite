# Skipped while importing llvm/test/Transforms/CrossDSOCFI (llvmorg-23.1.5)

3 of 3 files imported. Regenerate with `./harness/run import-llvm Transforms/CrossDSOCFI`.

- `thumb.ll` RUN `opt -mtriple=armv7-linux-android -S -passes=cross-dso-cfi < %s | FileCheck --check-prefix=THUMB %s`: non-x86_64 target armv7-linux-android
- `thumb.ll` RUN `opt -mtriple=thumbv7-linux-android -S -passes=cross-dso-cfi < %s | FileCheck --check-prefix=THUMB %s`: non-x86_64 target thumbv7-linux-android
- `thumb.ll` RUN `opt -mtriple=i386-linux -S -passes=cross-dso-cfi < %s | FileCheck --check-prefix=NOTHUMB %s`: non-x86_64 target i386-linux
