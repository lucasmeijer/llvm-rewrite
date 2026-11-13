; @origin: llvm/test/Linker/Inputs/pr21374.ll (llvmorg-23.1.5)
%foo = type { ptr }
define void @g(%foo %x) {
  ret void
}
