# Skipped while importing llvm/test/Transforms/MergeFunc (llvmorg-23.1.5)

71 of 85 files imported. Regenerate with `./harness/run import-llvm Transforms/MergeFunc`.

- `2011-02-08-RemoveEqual.ll`: target triple i386-pc-linux-gnu
- `crash.ll`: target triple i386-pc-linux-gnu
- `inttoptr.ll`: target triple i386-pc-linux-gnu
- `merge-linkonce-odr-used.ll` RUN `opt -p mergefunc -S %s | FileCheck %s`: no -passes / -O pipeline
- `merge-linkonce-odr-weak-odr-mixed-used.ll` RUN `opt -p mergefunc -S %s | FileCheck %s`: no -passes / -O pipeline
- `merge-linkonce-odr.ll` RUN `opt -p mergefunc -S %s | FileCheck --implicit-check-not=linkonce_odr_caller_of_foo_2 --implicit-check-not=linkonce_odr_caller_of_foo_1 %s`: no -passes / -O pipeline
- `merge-weak-odr-used.ll` RUN `opt -p mergefunc -S %s | FileCheck %s`: no -passes / -O pipeline
- `merge-weak-odr.ll` RUN `opt -p mergefunc -S %s | FileCheck %s`: no -passes / -O pipeline
- `metadata-call-arguments.ll` RUN `opt -p mergefunc -S %s | FileCheck %s`: no -passes / -O pipeline
- `phi-speculation1.ll`: REQUIRES asserts
- `phi-speculation2.ll`: REQUIRES asserts
- `ptrauth-const-compare.ll`: target triple arm64e-apple-ios14.0.0
- `vector.ll`: REQUIRES asserts
- `vectors-and-arrays.ll`: REQUIRES asserts
