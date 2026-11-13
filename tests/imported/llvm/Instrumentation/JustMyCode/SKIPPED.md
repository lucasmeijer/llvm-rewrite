# Skipped while importing llvm/test/Instrumentation/JustMyCode (llvmorg-23.1.5)

2 of 3 files imported. Regenerate with `./harness/run import-llvm Instrumentation/JustMyCode`.

- `jmc-instrument-elf.ll` RUN `opt -jmc-instrumenter -mtriple=x86_64-unknown-linux-gnu  -S < %s | FileCheck %s`: no -passes / -O pipeline
- `jmc-instrument-x86.ll`: target triple i386-pc-windows-msvc
- `jmc-instrument.ll` RUN `opt -jmc-instrumenter -mtriple=x86_64-pc-windows-msvc  -S < %s | FileCheck %s`: no -passes / -O pipeline
- `jmc-instrument.ll` RUN `opt -jmc-instrumenter -mtriple=aarch64-pc-windows-msvc -S < %s | FileCheck %s`: non-x86_64 target aarch64-pc-windows-msvc
- `jmc-instrument.ll` RUN `opt -jmc-instrumenter -mtriple=arm-pc-windows-msvc     -S < %s | FileCheck %s`: non-x86_64 target arm-pc-windows-msvc
- `jmc-instrument.ll` RUN `opt -passes=jmc-instrumenter -mtriple=aarch64-pc-windows-msvc -S < %s | FileCheck %s`: non-x86_64 target aarch64-pc-windows-msvc
- `jmc-instrument.ll` RUN `opt -passes=jmc-instrumenter -mtriple=arm-pc-windows-msvc     -S < %s | FileCheck %s`: non-x86_64 target arm-pc-windows-msvc
