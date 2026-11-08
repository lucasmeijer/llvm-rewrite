; @origin: llvm/test/Transforms/ADCE/2003-09-15-InfLoopCrash.ll (llvmorg-23.1.5)
; @opt: -passes=adce
; @opt: -passes=adce -adce-remove-loops
; RUN: opt < %s -passes=adce -disable-output
; RUN: opt < %s -passes=adce -adce-remove-loops -disable-output

define i32 @main() {
        br label %loop

loop:           ; preds = %loop, %0
        br label %loop
}

