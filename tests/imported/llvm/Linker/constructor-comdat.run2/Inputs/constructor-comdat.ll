; @origin: llvm/test/Linker/Inputs/constructor-comdat.ll (llvmorg-23.1.5)
define weak_odr void @_ZN3fooIiEC2Ev() {
  ret void
}

define weak_odr void @_ZN3fooIiEC1Ev() {
  ret void
}
