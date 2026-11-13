; @origin: llvm/test/Linker/Inputs/basiclink.a.ll (llvmorg-23.1.5)
define ptr @foo(i32 %x) { ret ptr @baz }
@baz = external global i32
