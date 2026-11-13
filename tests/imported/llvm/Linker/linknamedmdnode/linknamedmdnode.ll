; @origin: llvm/test/Linker/linknamedmdnode.ll (llvmorg-23.1.5)
; RUN: llvm-as < %s > %t.bc
; RUN: llvm-as < %p/linknamedmdnode2.ll > %t2.bc
; RUN: llvm-link %t.bc %t2.bc -S | FileCheck %s
; CHECK: !llvm.stuff = !{!0, !1}

!0 = !{i32 42}
!llvm.stuff = !{!0}
