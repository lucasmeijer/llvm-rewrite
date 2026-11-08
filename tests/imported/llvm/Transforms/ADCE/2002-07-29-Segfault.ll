; @origin: llvm/test/Transforms/ADCE/2002-07-29-Segfault.ll (llvmorg-23.1.5)
; @opt: -passes=adce
; @opt: -passes=adce -adce-remove-loops
; RUN: opt < %s -passes=adce -disable-output
; RUN: opt < %s -passes=adce -disable-output -adce-remove-loops

define void @test() {
        br label %BB3

BB3:            ; preds = %BB3, %0
        br label %BB3
}

