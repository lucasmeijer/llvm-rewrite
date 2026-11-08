# Skipped while importing llvm/test/Transforms/MemCpyOpt (llvmorg-23.1.5)

56 of 68 files imported. Regenerate with `./harness/run import-llvm Transforms/MemCpyOpt`.

- `2008-02-24-MultipleUseofSRet.ll`: target triple i386-pc-linux-gnu
- `2011-06-02-CallSlotOverwritten.ll`: target triple i386-apple-darwin10
- `aa-recursion-assertion-failure.ll`: target triple aarch64-unknown-linux-android21
- `crash.ll`: target triple armv7-eabi
- `form-memset.ll`: target triple i386-apple-darwin8
- `invariant.start.ll`: target triple i686-apple-darwin9
- `memcpy.ll`: target triple i686-apple-darwin9
- `no-libcalls.ll`: REQUIRES amdgpu-registered-target
- `pr37967.ll` RUN `opt -passes='debugify,memcpyopt,check-debugify' -S < %s 2>&1 -verify-memoryssa | FileCheck %s`: redirects or chains commands
- `preserve-memssa.ll`: REQUIRES asserts
- `sret.ll`: target triple i686-apple-darwin9
- `stackrestore.ll`: target triple i686-unknown-windows-msvc19.14.26433
