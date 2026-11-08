; @origin: llvm/test/Transforms/IndVarSimplify/2005-11-18-Crash.ll (llvmorg-23.1.5)
; @opt: -passes=indvars
; RUN: opt < %s -passes=indvars -disable-output

@fixtab = external global [29 x [29 x [2 x i32]]]               ; <ptr> [#uses=1]

define void @init_optabs(i1 %arg) {
entry:
        br label %no_exit.0

no_exit.0:              ; preds = %no_exit.0, %entry
        %p.0.0 = phi ptr [ @fixtab, %entry ], [ %inc.0, %no_exit.0 ]               ; <ptr> [#uses=1]
        %inc.0 = getelementptr i32, ptr %p.0.0, i32 1               ; <ptr> [#uses=1]
        br i1 %arg, label %no_exit.0, label %no_exit.1

no_exit.1:              ; preds = %no_exit.0
        ret void
}

