# Skipped while importing llvm/test/Transforms/StripSymbols (llvmorg-23.1.5)

9 of 10 files imported. Regenerate with `./harness/run import-llvm Transforms/StripSymbols`.

- `2010-06-30-StripDebug.ll` RUN `opt -strip-debug < %s -S | FileCheck %s`: no -passes / -O pipeline
- `strip-cg-profile.ll` RUN `llvm-extract %s -func=a -S -o - | FileCheck %s --check-prefix=EXTRACT-A`: not an opt invocation
- `strip-cg-profile.ll` RUN `llvm-extract %s -func=a --func=b -S -o - | FileCheck %s --check-prefix=EXTRACT-AB`: not an opt invocation
- `strip-cg-profile.ll` RUN `llvm-extract %s -func=solo -S -o - | FileCheck %s --check-prefix=NOTHING-LEFT`: not an opt invocation
