; @origin: llvm/test/Linker/Inputs/fixed-vector-type-construction.ll (llvmorg-23.1.5)
%t = type {i32, float}
define void @foo(<4 x ptr> %x) {
  ret void
}
