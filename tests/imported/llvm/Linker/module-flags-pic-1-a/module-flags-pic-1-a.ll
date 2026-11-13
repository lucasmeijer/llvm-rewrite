; @origin: llvm/test/Linker/module-flags-pic-1-a.ll (llvmorg-23.1.5)
; RUN: llvm-link %s %p/Inputs/module-flags-pic-1-b.ll -S -o - | FileCheck %s

; test linking modules with specified and default PIC levels

!0 = !{ i32 7, !"PIC Level", i32 1 }

!llvm.module.flags = !{!0}
; CHECK: !llvm.module.flags = !{!0}
; CHECK: !0 = !{i32 8, !"PIC Level", i32 1}
