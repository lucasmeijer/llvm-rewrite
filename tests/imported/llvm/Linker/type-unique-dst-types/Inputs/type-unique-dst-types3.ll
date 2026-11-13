; @origin: llvm/test/Linker/Inputs/type-unique-dst-types3.ll (llvmorg-23.1.5)
%A.11 = type opaque
@g2 = external global %A.11

define ptr @use_g2() {
  ret ptr @g2
}
