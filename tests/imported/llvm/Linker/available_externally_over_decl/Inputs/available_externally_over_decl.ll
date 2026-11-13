; @origin: llvm/test/Linker/Inputs/available_externally_over_decl.ll (llvmorg-23.1.5)
@h = global ptr @f
@h2 = global ptr @g

define available_externally void @f() {
  ret void
}

define available_externally void @g() {
  ret void
}
