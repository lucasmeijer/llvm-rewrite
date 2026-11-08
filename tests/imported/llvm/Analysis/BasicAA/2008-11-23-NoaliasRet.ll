; @origin: llvm/test/Analysis/BasicAA/2008-11-23-NoaliasRet.ll (llvmorg-23.1.5)
; @analysis: -aa-pipeline=basic-aa -passes=aa-eval
; RUN: opt < %s -aa-pipeline=basic-aa -passes=aa-eval -disable-output 2>&1 | FileCheck %s

declare noalias ptr @_Znwj(i32 %x) nounwind

; CHECK: 1 no alias response

define i32 @foo() {
  %A = call ptr @_Znwj(i32 4)
  %B = call ptr @_Znwj(i32 4)
  store i32 1, ptr %A
  store i32 2, ptr %B
  %C = load i32, ptr %A
  ret i32 %C
}
