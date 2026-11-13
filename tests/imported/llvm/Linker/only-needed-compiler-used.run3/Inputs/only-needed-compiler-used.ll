; @origin: llvm/test/Linker/Inputs/only-needed-compiler-used.ll (llvmorg-23.1.5)
@used1 = global i8 4
@used2 = global i32 123

@llvm.compiler.used = appending global [2 x ptr] [
   ptr @used1,
   ptr @used2
], section "llvm.metadata"
