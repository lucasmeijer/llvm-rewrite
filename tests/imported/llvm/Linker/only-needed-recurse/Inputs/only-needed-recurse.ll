; @origin: llvm/test/Linker/Inputs/only-needed-recurse.ll (llvmorg-23.1.5)
define void @f2() {
  call void @f3()
  ret void
}

define void @f3() {
  ret void
}
