; @origin: llvm/test/Transforms/ADCE/2004-05-04-UnreachableBlock.ll (llvmorg-23.1.5)
; @opt: -passes=adce
; @opt: -passes=adce -adce-remove-loops
; RUN: opt < %s -passes=adce -disable-output
; RUN: opt < %s -passes=adce -adce-remove-loops -disable-output

define void @test() {
entry:
        br label %UnifiedReturnBlock

UnifiedReturnBlock:             ; preds = %invoke_catch.0, %entry
        ret void

invoke_catch.0:         ; No predecessors!
        br i1 false, label %UnifiedUnwindBlock, label %UnifiedReturnBlock

UnifiedUnwindBlock:             ; preds = %invoke_catch.0
        unreachable
}

