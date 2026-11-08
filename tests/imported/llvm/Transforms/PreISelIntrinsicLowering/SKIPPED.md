# Skipped while importing llvm/test/Transforms/PreISelIntrinsicLowering (llvmorg-23.1.5)

10 of 23 files imported. Regenerate with `./harness/run import-llvm Transforms/PreISelIntrinsicLowering`.

- `expand-exp.ll`: in a AArch64 target directory
- `expand-fp-math.ll`: in a AArch64 target directory
- `expand-log.ll`: in a AArch64 target directory
- `expand-mem-intrinsics.ll`: in a AMDGPU target directory
- `memset-pattern.ll`: in a AMDGPU target directory
- `memset-pattern.ll`: in a PowerPC target directory
- `expand-fp-math.ll`: in a RISCV target directory
- `memset-pattern.ll`: in a RISCV target directory
- `load-relative.ll` RUN `opt -mtriple=x86_64-pc-linux-gnu -pre-isel-intrinsic-lowering -S -o - %s | FileCheck %s`: no -passes / -O pipeline
- `objc-arc.ll` RUN `opt -mtriple=x86_64-pc-linux-gnu -pre-isel-intrinsic-lowering -S -o - %s | FileCheck %s`: no -passes / -O pipeline
- `cond-loop.ll`: REQUIRES mips-registered-target
- `emupac.ll` RUN `opt -passes=pre-isel-intrinsic-lowering -mtriple aarch64-unknown-linux -S < %s | FileCheck --check-prefix=NOPAUTH %s`: non-x86_64 target aarch64-unknown-linux
- `emupac.ll` RUN `opt -passes=pre-isel-intrinsic-lowering -mtriple aarch64-unknown-linux -mattr=+pauth -S < %s | FileCheck --check-prefix=PAUTH1 %s`: non-x86_64 target aarch64-unknown-linux
- `emupac.ll` RUN `opt -passes=pre-isel-intrinsic-lowering -mtriple arm64e-apple-darwin -S < %s | FileCheck --check-prefix=PAUTH2 %s`: non-x86_64 target arm64e-apple-darwin
- `looptrap.ll`: REQUIRES mips-registered-target
- `protected-field-pointer-addrspace1.ll`: target triple aarch64-unknown-linux-gnu
- `protected-field-pointer.ll`: target triple aarch64-unknown-linux-gnu
