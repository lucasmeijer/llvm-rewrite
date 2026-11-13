; @origin: llvm/test/Linker/Inputs/linkage.a.ll (llvmorg-23.1.5)
@X = linkonce global i32 5
define linkonce i32 @foo() { ret i32 7 }
