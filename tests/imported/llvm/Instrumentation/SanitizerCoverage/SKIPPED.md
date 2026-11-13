# Skipped while importing llvm/test/Instrumentation/SanitizerCoverage (llvmorg-23.1.5)

38 of 41 files imported. Regenerate with `./harness/run import-llvm Instrumentation/SanitizerCoverage`.

- `cmp-tracing-api-x86_32.ll`: target triple i386-unknown-linux-gnu
- `seh.ll`: target triple i686-pc-windows-msvc18.0.0
- `stack-depth-variable-declared-by-user.ll` RUN `not opt < %s -passes='module(sancov-module)' -sanitizer-coverage-level=1 -sanitizer-coverage-stack-depth -S 2>&1 | FileCheck %s`: not an opt invocation
- `trace-pc-guard.ll` RUN `opt < %s -passes='module(sancov-module)' -sanitizer-coverage-level=4 -sanitizer-coverage-trace-pc-guard -mtriple=aarch64-apple-darwin -S | FileCheck %s --check-prefixes=CHECK,CHECK-CTOR,MACHO`: non-x86_64 target aarch64-apple-darwin
