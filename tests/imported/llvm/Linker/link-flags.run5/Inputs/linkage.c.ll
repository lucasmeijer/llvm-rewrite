; @origin: llvm/test/Linker/Inputs/linkage.c.ll (llvmorg-23.1.5)
@X = global i32 5
@U = global i32 6
define i32 @foo() { ret i32 7 }
define i32 @unused() { ret i32 8 }
