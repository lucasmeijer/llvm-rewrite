; @origin: llvm/test/Transforms/ADCE/2002-07-17-AssertionFailure.ll (llvmorg-23.1.5)
; @opt: -passes=adce
; This testcase fails because ADCE does not correctly delete the chain of 
; three instructions that are dead here.  Ironically there were a dead basic
; block in this function, it would work fine, but that would be the part we 
; have to fix now, wouldn't it....
;
; RUN: opt < %s -passes=adce -S | FileCheck %s

define void @foo(ptr %reg5481) {
        %reg162 = load ptr, ptr %reg5481            ; <ptr> [#uses=1]
; CHECK-NOT: ptrtoint
        ptrtoint ptr %reg162 to i32             ; <i32>:1 [#uses=0]
        ret void
}
