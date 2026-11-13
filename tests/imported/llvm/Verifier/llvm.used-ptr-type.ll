; @origin: llvm/test/Verifier/llvm.used-ptr-type.ll (llvmorg-23.1.5)
; @analysis: -passes=verify
; RUN: llvm-as < %s -o /dev/null

@a = global i32 42
@llvm.used = appending global [1 x ptr] [ptr @a], section "llvm.metadata"
