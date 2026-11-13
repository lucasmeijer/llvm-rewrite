; @origin: llvm/test/Linker/Inputs/alias-2.ll (llvmorg-23.1.5)
define void @B() {
  call void @A()
  ret void
}

declare void @A()

