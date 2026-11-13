; @origin: llvm/test/Linker/Inputs/syncscope-1.ll (llvmorg-23.1.5)
define void @syncscope_1() {
  fence syncscope("agent") seq_cst
  fence syncscope("workgroup") seq_cst
  fence syncscope("wavefront") seq_cst
  ret void
}
