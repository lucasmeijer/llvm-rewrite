; @origin: llvm/test/Transforms/InstSimplify/ConstProp/div-zero.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -S | grep "ret i32 0"
; PR4424
declare void @ext()

define i32 @foo(i32 %ptr) {
entry:
        %zero = sub i32 %ptr, %ptr              ; <i32> [#uses=1]
        %div_zero = sdiv i32 %zero, ptrtoint (ptr getelementptr (i32, ptr null,
i32 1) to i32)             ; <i32> [#uses=1]
        ret i32 %div_zero
}

