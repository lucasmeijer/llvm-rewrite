# Skipped while importing llvm/test/Instrumentation/InstrProfiling (llvmorg-23.1.5)

19 of 34 files imported. Regenerate with `./harness/run import-llvm Instrumentation/InstrProfiling`.

- `alloc.ll` RUN `llc < %s -mtriple=x86_64-unknown-linux-gnu | FileCheck %s`: not an opt invocation
- `align32.ll`: target triple i386-unknown-linux-gnu
- `amdgpu-3d-grid.ll` RUN `opt %s -mtriple=amdgcn-amd-amdhsa -passes=instrprof -S | FileCheck %s`: non-x86_64 target amdgcn-amd-amdhsa
- `amdgpu-contiguous-counters.ll` RUN `opt -S -mtriple=amdgcn-amd-amdhsa -offload-pgo-sampling=0 -passes=instrprof < %s | FileCheck %s`: non-x86_64 target amdgcn-amd-amdhsa
- `amdgpu-instrumentation.ll` RUN `opt %s -mtriple=amdgcn-amd-amdhsa -passes=instrprof -offload-pgo-sampling=3 -S | FileCheck %s --check-prefix=SAMPLED`: non-x86_64 target amdgcn-amd-amdhsa
- `amdgpu-instrumentation.ll` RUN `opt %s -mtriple=amdgcn-amd-amdhsa -passes=instrprof -offload-pgo-sampling=0 -S | FileCheck %s --check-prefix=NOSAMPLE`: non-x86_64 target amdgcn-amd-amdhsa
- `amdgpu-uniform-counters.ll` RUN `opt %s -mtriple=amdgcn-amd-amdhsa -passes=instrprof -S | FileCheck %s`: non-x86_64 target amdgcn-amd-amdhsa
- `amdgpu-wave32.ll` RUN `opt %s -mtriple=amdgcn-amd-amdhsa -passes=instrprof -S | FileCheck %s`: non-x86_64 target amdgcn-amd-amdhsa
- `amdgpu-wave64.ll` RUN `opt %s -mtriple=amdgcn-amd-amdhsa -passes=instrprof -S | FileCheck %s`: non-x86_64 target amdgcn-amd-amdhsa
- `comdat.ll`: uses split-file
- `coverage.ll`: target triple aarch64-unknown-linux-gnu
- `debug-info-correlate-bitmap.ll`: REQUIRES object-emission, target={{.*-linux.*}}
- `debug-info-correlate.ll`: REQUIRES object-emission, target={{.*-linux.*}}
- `gpu-weak.ll`: target triple amdgcn-amd-amdhsa
- `icall-comdat.ll` RUN `opt < %s -mtriple=powerpc-unknown-linux -passes=instrprof -vp-static-alloc=true -S | FileCheck %s --check-prefix=STATIC`: non-x86_64 target powerpc-unknown-linux
- `icall-comdat.ll` RUN `opt < %s -mtriple=sparc-unknown-linux -passes=instrprof -vp-static-alloc=true -S | FileCheck %s --check-prefix=STATIC`: non-x86_64 target sparc-unknown-linux
- `icall-comdat.ll` RUN `opt < %s -mtriple=s390x-unknown-linux -passes=instrprof -vp-static-alloc=true -S | FileCheck %s --check-prefix=STATIC-EXT`: non-x86_64 target s390x-unknown-linux
- `icall-comdat.ll` RUN `opt < %s -mtriple=powerpc64-unknown-linux -passes=instrprof -vp-static-alloc=true -S | FileCheck %s --check-prefix=STATIC-EXT`: non-x86_64 target powerpc64-unknown-linux
- `icall-comdat.ll` RUN `opt < %s -mtriple=sparc64-unknown-linux -passes=instrprof -vp-static-alloc=true -S | FileCheck %s --check-prefix=STATIC-EXT`: non-x86_64 target sparc64-unknown-linux
- `icall-comdat.ll` RUN `opt < %s -mtriple=mips-unknown-linux -passes=instrprof -vp-static-alloc=true -S | FileCheck %s --check-prefix=STATIC-SEXT`: non-x86_64 target mips-unknown-linux
- `icall-comdat.ll` RUN `opt < %s -mtriple=mips64-unknown-linux -passes=instrprof -vp-static-alloc=true -S | FileCheck %s --check-prefix=STATIC-SEXT`: non-x86_64 target mips64-unknown-linux
- `icall-comdat.ll` RUN `opt %s -mtriple=powerpc64-unknown-linux -passes=instrprof -S | FileCheck %s --check-prefix=ALIGN`: non-x86_64 target powerpc64-unknown-linux
- `icall-comdat.ll` RUN `opt %s -mtriple=powerpc-ibm-aix -passes=instrprof -S | FileCheck %s --check-prefix=ALIGN`: non-x86_64 target powerpc-ibm-aix
- `icall-comdat.ll` RUN `opt %s -mtriple=powerpc64-ibm-aix -passes=instrprof -S | FileCheck %s --check-prefix=ALIGN`: non-x86_64 target powerpc64-ibm-aix
- `icall-nocomdat.ll` RUN `opt < %s -mtriple=powerpc-ibm-aix-xcoff -passes=instrprof -vp-static-alloc=false -S | FileCheck %s --check-prefix=DYN`: non-x86_64 target powerpc-ibm-aix-xcoff
- `icall-nocomdat.ll` RUN `opt < %s -mtriple=powerpc64-ibm-aix-xcoff -passes=instrprof -vp-static-alloc=false -S | FileCheck %s --check-prefix=DYN`: non-x86_64 target powerpc64-ibm-aix-xcoff
- `no-counters.ll` RUN `opt < %s -mtriple=powerpc64-ibm-aix-xcoff -passes=instrprof -S | FileCheck %s -check-prefixes=ALL,LINUX`: non-x86_64 target powerpc64-ibm-aix-xcoff
- `platform.ll` RUN `opt < %s -mtriple=powerpc64-ibm-aix-xcoff -passes=instrprof -S | FileCheck %s -check-prefix=AIX`: non-x86_64 target powerpc64-ibm-aix-xcoff
- `platform.ll` RUN `opt < %s -mtriple=arm-elf -passes=instrprof -S | FileCheck %s -check-prefix=BAREMETAL`: non-x86_64 target arm-elf
- `platform.ll` RUN `opt < %s -mtriple=amdgcn-amd-amdhsa -passes=instrprof -S | FileCheck %s -check-prefix=AMDGPU`: non-x86_64 target amdgcn-amd-amdhsa
- `profiling.ll` RUN `opt < %s -mtriple=powerpc64-ibm-aix-xcoff -passes=instrprof -S | FileCheck %s --check-prefixes=XCOFF`: non-x86_64 target powerpc64-ibm-aix-xcoff
- `profiling.ll` RUN `opt < %s -mtriple=wasm32-unknown-unknown -passes=instrprof -S | FileCheck %s --check-prefix=WASM`: non-x86_64 target wasm32-unknown-unknown
- `section-code-model-medium.ll` RUN `opt %s -mtriple=ppc64-unknown-linux -passes=instrprof -S | FileCheck %s --check-prefixes=CHECK,PPC`: non-x86_64 target ppc64-unknown-linux
- `timestamp-coverage.ll`: target triple aarch64-unknown-linux-gnu
- `timestamp.ll`: target triple aarch64-unknown-linux-gnu
