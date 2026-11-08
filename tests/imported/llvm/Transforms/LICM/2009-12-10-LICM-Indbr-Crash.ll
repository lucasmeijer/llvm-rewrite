; @origin: llvm/test/Transforms/LICM/2009-12-10-LICM-Indbr-Crash.ll (llvmorg-23.1.5)
; @opt: -passes=licm
; Test for rdar://7452967
; RUN: opt < %s -passes=licm -disable-output
define void @foo (ptr %arg)
{
  entry:
    br i1 false, label %preheader, label %return

  preheader:
    br i1 false, label %loop, label %return

  loop:
    indirectbr ptr %arg, [label %preheader, label %stuff]

  stuff:
    %0 = load i8, ptr %arg, align 1
    br label %loop

  return:
    ret void

}
