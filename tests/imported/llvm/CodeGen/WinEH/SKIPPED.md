# Skipped while importing llvm/test/CodeGen/WinEH (llvmorg-23.1.5)

6 of 19 files imported. Regenerate with `./harness/run import-llvm CodeGen/WinEH`.

- `wineh-cloning.ll` RUN `opt -mtriple=x86_64-pc-windows-msvc -S -win-eh-prepare  < %s | FileCheck %s`: no -passes / -O pipeline
- `wineh-cloning.ll` RUN `%if aarch64-registered-target %{ opt -mtriple=aarch64-pc-windows-msvc -S -win-eh-prepare  < %s | FileCheck %s %}`: not an opt invocation
- `wineh-cloning.ll` RUN `%if aarch64-registered-target %{ opt -mtriple=aarch64-pc-windows-msvc -S -passes=win-eh-prepare  < %s | FileCheck %s %}`: not an opt invocation
- `wineh-comdat.ll` RUN `opt -mtriple=i686-unknown-windows-msvc -S -x86-winehstate < %s | FileCheck %s`: non-x86_64 target i686-unknown-windows-msvc
- `wineh-comdat.ll` RUN `opt -mtriple=i686-unknown-windows-msvc -S -passes=x86-winehstate < %s | FileCheck %s`: non-x86_64 target i686-unknown-windows-msvc
- `wineh-demotion.ll` RUN `opt -mtriple=x86_64-pc-windows-msvc -S -win-eh-prepare  < %s | FileCheck %s`: no -passes / -O pipeline
- `wineh-demotion.ll` RUN `%if aarch64-registered-target %{ opt -mtriple=aarch64-pc-windows-msvc -S -win-eh-prepare  < %s | FileCheck %s %}`: not an opt invocation
- `wineh-demotion.ll` RUN `%if aarch64-registered-target %{ opt -mtriple=aarch64-pc-windows-msvc -S -passes=win-eh-prepare  < %s | FileCheck %s %}`: not an opt invocation
- `wineh-dynamic-alloca.ll`: target triple i386-pc-windows-msvc
- `wineh-empty-seh-scope.ll` RUN `llc -mtriple=x86_64-pc-windows-msvc < %s | FileCheck %s --check-prefixes=CHECK,X64`: not an opt invocation
- `wineh-empty-seh-scope.ll` RUN `%if aarch64-registered-target %{ llc -mtriple=aarch64-pc-windows-msvc < %s | FileCheck %s --check-prefixes=CHECK,AARCH64 %}`: not an opt invocation
- `wineh-inlined-inalloca.ll`: target triple i386-pc-windows-msvc
- `wineh-intrinsics-invalid.ll` RUN `sed -e s/.T1:// %s | not opt -passes=lint -disable-output 2>&1 | FileCheck --check-prefix=CHECK1 %s`: not an opt invocation
- `wineh-intrinsics-invalid.ll` RUN `sed -e s/.T2:// %s | not opt -passes=lint -disable-output 2>&1 | FileCheck --check-prefix=CHECK2 %s`: not an opt invocation
- `wineh-musttail-call.ll`: target triple i386-pc-windows-msvc
- `wineh-nested-unwind.ll` RUN `llc -mtriple=x86_64-pc-windows-msvc < %s | FileCheck %s`: not an opt invocation
- `wineh-nested-unwind.ll` RUN `%if aarch64-registered-target %{ llc -mtriple=aarch64-pc-windows-msvc < %s | FileCheck %s %}`: not an opt invocation
- `wineh-no-demotion.ll` RUN `opt -mtriple=x86_64-pc-windows-msvc -S -win-eh-prepare -disable-demotion -disable-cleanups < %s | FileCheck %s`: no -passes / -O pipeline
- `wineh-no-demotion.ll` RUN `%if aarch64-registered-target %{ opt -mtriple=aarch64-pc-windows-msvc -S -win-eh-prepare -disable-demotion -disable-cleanups < %s | FileCheck %s %}`: not an opt invocation
- `wineh-no-demotion.ll` RUN `%if aarch64-registered-target %{ opt -mtriple=aarch64-pc-windows-msvc -S -passes=win-eh-prepare -disable-demotion -disable-cleanups < %s | FileCheck %s %}`: not an opt invocation
- `wineh-noret-cleanup.ll` RUN `sed -e s/.Cxx:// %s | llc -mtriple=x86_64-pc-windows-msvc | FileCheck %s --check-prefixes=CXX`: not an opt invocation
- `wineh-noret-cleanup.ll` RUN `sed -e s/.Seh:// %s | llc -mtriple=x86_64-pc-windows-msvc | FileCheck %s --check-prefixes=SEH`: not an opt invocation
- `wineh-noret-cleanup.ll` RUN `%if aarch64-registered-target %{ sed -e s/.Cxx:// %s | llc -mtriple=aarch64-pc-windows-msvc | FileCheck %s --check-prefix=CXX %}`: not an opt invocation
- `wineh-noret-cleanup.ll` RUN `%if aarch64-registered-target %{ sed -e s/.Seh:// %s | llc -mtriple=aarch64-pc-windows-msvc | FileCheck %s --check-prefix=SEH %}`: not an opt invocation
- `wineh-reuse-catch-alloca.ll` RUN `llc %s --mtriple=x86_64-pc-windows-msvc -o - | FileCheck %s --check-prefixes=CHECK,X64`: not an opt invocation
- `wineh-reuse-catch-alloca.ll` RUN `%if aarch64-registered-target %{ llc %s --mtriple=aarch64-pc-windows-msvc -o - | FileCheck %s --check-prefixes=CHECK,ARM64 %}`: not an opt invocation
- `wineh-scope-statenumbering.ll`: target triple i386-pc-windows-msvc19.42.34433
- `wineh-setjmp.ll`: target triple i686-pc-windows-msvc
- `wineh-statenumbering-cleanups.ll` RUN `sed -e s/.Cxx:// %s | opt -mtriple=i386-pc-windows-msvc -S -x86-winehstate | FileCheck %s`: not an opt invocation
- `wineh-statenumbering-cleanups.ll` RUN `sed -e s/.Cxx:// %s | opt -mtriple=i386-pc-windows-msvc -S -passes=x86-winehstate | FileCheck %s`: not an opt invocation
- `wineh-statenumbering-cleanups.ll` RUN `sed -e s/.SEH:// %s | opt -mtriple=i386-pc-windows-msvc -S -x86-winehstate | FileCheck %s`: not an opt invocation
- `wineh-statenumbering-cleanups.ll` RUN `sed -e s/.SEH:// %s | opt -mtriple=i386-pc-windows-msvc -S -passes=x86-winehstate | FileCheck %s`: not an opt invocation
- `wineh-statenumbering.ll`: target triple i686-pc-windows-msvc
