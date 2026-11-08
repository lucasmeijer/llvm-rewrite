; @origin: llvm/test/Transforms/GlobalOpt/2011-04-09-EmptyGlobalCtors.ll (llvmorg-23.1.5)
; @opt: -passes=globalopt
; RUN: opt < %s -passes=globalopt -disable-output

%0 = type { i32, ptr, ptr }
@llvm.global_ctors = appending global [0 x %0] zeroinitializer

