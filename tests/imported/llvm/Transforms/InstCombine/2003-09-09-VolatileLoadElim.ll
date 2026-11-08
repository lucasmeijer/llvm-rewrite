; @origin: llvm/test/Transforms/InstCombine/2003-09-09-VolatileLoadElim.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -S | grep load

define void @test(ptr %P) {
        ; Dead but not deletable!
        %X = load volatile i32, ptr %P              ; <i32> [#uses=0]
        ret void
}
