; @origin: llvm/test/Verifier/byval-4.ll (llvmorg-23.1.5)
; @analysis: -passes=verify
; RUN: llvm-as %s -o /dev/null
%struct.foo = type { i64 }

declare void @h(ptr byval(%struct.foo) %num)
