; @origin: llvm/test/Linker/Inputs/pr22807.ll (llvmorg-23.1.5)
%struct.A = type { %struct.B }
%struct.B = type opaque

@g = external global %struct.A
