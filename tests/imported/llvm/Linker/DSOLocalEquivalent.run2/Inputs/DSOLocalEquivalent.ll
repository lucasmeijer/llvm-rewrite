; @origin: llvm/test/Linker/Inputs/DSOLocalEquivalent.ll (llvmorg-23.1.5)
define void @defined_extern_func() {
  ret void
}

define hidden void @hidden_func() {
  ret void
}
