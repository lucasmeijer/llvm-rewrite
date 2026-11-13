; @origin: llvm/test/Linker/module-flags-2-b.ll (llvmorg-23.1.5)
; This file is used with module-flags-2-a.ll
; RUN: true

!0 = !{ i32 4, !"foo", i32 37 } ; Override the "foo" value.

!llvm.module.flags = !{ !0 }
