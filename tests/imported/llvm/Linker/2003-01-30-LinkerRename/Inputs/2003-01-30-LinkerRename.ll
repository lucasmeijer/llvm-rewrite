; @origin: llvm/test/Linker/Inputs/2003-01-30-LinkerRename.ll (llvmorg-23.1.5)
@bar = global ptr @foo
define internal i32 @foo() {
  ret i32 7
}
