; @origin: llvm/test/Linker/Inputs/internalize-lazy.ll (llvmorg-23.1.5)
define linkonce_odr void @g() {
  ret void
}

define void @f() {
  call void @g()
  ret void
}
