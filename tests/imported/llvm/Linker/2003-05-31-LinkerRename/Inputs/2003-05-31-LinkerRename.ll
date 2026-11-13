; @origin: llvm/test/Linker/Inputs/2003-05-31-LinkerRename.ll (llvmorg-23.1.5)
@bar = global ptr @foo

define internal i32 @foo() {
  ret i32 7
}
