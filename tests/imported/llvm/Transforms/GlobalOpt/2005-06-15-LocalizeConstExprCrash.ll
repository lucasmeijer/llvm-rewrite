; @origin: llvm/test/Transforms/GlobalOpt/2005-06-15-LocalizeConstExprCrash.ll (llvmorg-23.1.5)
; @opt: -passes=globalopt
; RUN: opt < %s -passes=globalopt -disable-output
; PR579

@g_40507551 = internal global i16 31038         ; <ptr> [#uses=1]

define void @main() {
        %tmp.4.i.1 = load i8, ptr getelementptr (i8, ptr @g_40507551, i32 1)              ; <i8> [#uses=0]
        ret void
}

