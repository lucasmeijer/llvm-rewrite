; @origin: llvm/test/Linker/Inputs/type-unique-opaque.ll (llvmorg-23.1.5)
%t = type { i8 }
%t2 = type { %t, i16 }

@g = external global %t2
