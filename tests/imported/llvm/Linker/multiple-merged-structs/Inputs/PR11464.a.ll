; @origin: llvm/test/Linker/Inputs/PR11464.a.ll (llvmorg-23.1.5)
%bug_type = type opaque
declare i32 @bug_a(ptr)
declare i32 @bug_b(ptr)
