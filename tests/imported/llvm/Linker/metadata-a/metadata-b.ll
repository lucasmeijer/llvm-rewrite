; @origin: llvm/test/Linker/metadata-b.ll (llvmorg-23.1.5)
; This file is for use with metadata-a.ll
; RUN: true

define void @goo(i32 %b) nounwind {
entry:
  ret void, !attach !0
}

!0 = !{i32 524334, ptr @goo}
