; @origin: llvm/test/Transforms/CodeExtractor/2004-08-12-BlockExtractPHI.ll (llvmorg-23.1.5)
; @opt: -passes=extract-blocks
; RUN: opt < %s -passes=extract-blocks -disable-output

define void @test1() {
no_exit.0.i:
        br i1 false, label %yylex.entry, label %yylex.entry

yylex.entry:            ; preds = %no_exit.0.i, %no_exit.0.i
        %tmp.1027 = phi i32 [ 0, %no_exit.0.i ], [ 0, %no_exit.0.i ]            ; <i32> [#uses=0]
        ret void
}

define void @test2() {
no_exit.0.i:
        switch i32 0, label %yylex.entry [
                 i32 0, label %yylex.entry
                 i32 1, label %foo
        ]

yylex.entry:            ; preds = %no_exit.0.i, %no_exit.0.i
        %tmp.1027 = phi i32 [ 0, %no_exit.0.i ], [ 0, %no_exit.0.i ]            ; <i32> [#uses=0]
        ret void

foo:            ; preds = %no_exit.0.i
        ret void
}

