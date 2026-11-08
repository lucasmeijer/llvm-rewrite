; @origin: llvm/test/Transforms/InstCombine/2007-12-16-AsmNoUnwind.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -S | grep nounwind

define void @bar() {
entry:
        call void asm sideeffect "", "~{dirflag},~{fpsr},~{flags}"( )
        ret void
}
