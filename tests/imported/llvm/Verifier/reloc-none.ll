; @origin: llvm/test/Verifier/reloc-none.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as -disable-output 2>&1 %s | FileCheck %s

; CHECK: llvm.reloc.none argument must be a metadata string
; CHECK-NEXT: call void @llvm.reloc.none(metadata !0)

define void @test_reloc_none_bad_arg() {
  call void @llvm.reloc.none(metadata !0)
  ret void
}

declare void @llvm.reloc.none(metadata)

!0 = !{}
