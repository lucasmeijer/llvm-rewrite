# Skipped while importing llvm/test/Transforms/EntryExitInstrumenter (llvmorg-23.1.5)

2 of 5 files imported. Regenerate with `./harness/run import-llvm Transforms/EntryExitInstrumenter`.

- `mcount-aix.ll`: target triple powerpc-ibm-aix7.2.0.0
- `mcount-with-frompc.ll` RUN `opt -mtriple=riscv64 -passes="ee-instrument<post-inline>" -S < %s | FileCheck %s --check-prefixes=CHECK,RISCV64`: non-x86_64 target riscv64
- `mcount-with-frompc.ll` RUN `opt -mtriple=riscv32 -passes="ee-instrument<post-inline>" -S < %s | FileCheck %s --check-prefixes=CHECK,RISCV32`: non-x86_64 target riscv32
- `mcount-with-frompc.ll` RUN `opt -mtriple=loongarch64 -passes="ee-instrument<post-inline>" -S < %s | FileCheck %s --check-prefixes=CHECK,LOONGARCH64`: non-x86_64 target loongarch64
- `mcount-with-frompc.ll` RUN `opt -mtriple=loongarch32 -passes="ee-instrument<post-inline>" -S < %s | FileCheck %s --check-prefixes=CHECK,LOONGARCH32`: non-x86_64 target loongarch32
- `mcount-with-frompc.ll` RUN `opt -mtriple=aarch64 -passes="ee-instrument<post-inline>" -S < %s | FileCheck %s --check-prefixes=CHECK,AARCH64`: non-x86_64 target aarch64
- `mcount-with-frompc.ll` RUN `opt -mtriple=aarch64_be -passes="ee-instrument<post-inline>" -S < %s | FileCheck %s --check-prefixes=CHECK,AARCH64_BE`: non-x86_64 target aarch64_be
- `mcount-with-frompc.ll` RUN `opt -mtriple=aarch64_32 -passes="ee-instrument<post-inline>" -S < %s | FileCheck %s --check-prefixes=CHECK,AARCH64_32`: non-x86_64 target aarch64_32
- `mcount.ll`: uses non-x86 target intrinsic @llvm.arm.
