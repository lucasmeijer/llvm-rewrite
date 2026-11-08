; @origin: llvm/test/Transforms/Inline/PR4909.ll (llvmorg-23.1.5)
; @opt: -passes=partial-inliner
; RUN: opt < %s -passes=partial-inliner -disable-output

define i32 @f() {
entry:
  br label %return

return:                                           ; preds = %entry
  ret i32 undef
}

define i32 @g() {
entry:
  %0 = call i32 @f()
  ret i32 %0
}
