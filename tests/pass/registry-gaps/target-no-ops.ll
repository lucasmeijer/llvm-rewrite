; Passes that change nothing for x86 targets: loop-data-prefetch (cache line size 0), loop-idiom-vectorize
; (no scalable vectors), complex-deinterleaving (not supported by X86TargetLowering), x86-lower-amx-intrinsics
; (-enable-x86-scalar-amx off), rewrite-symbols (no -rewrite-map-file), static-data-annotator (no profile
; summary), cfguard (no "cfguard" module flag), x86-winehstate (no funclet personality).
; @opt: '-passes=function(loop-data-prefetch,loop(loop-idiom-vectorize),complex-deinterleaving,x86-lower-amx-intrinsics,cfguard)'
; @opt: '-passes=rewrite-symbols,static-data-annotator,x86-winehstate,function(x86-partial-reduction)'
; @opt: '-passes=function(loop(require<ddg>)),require<static-data-profile-info>'
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"
define void @f(ptr %a, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %p = getelementptr i8, ptr %a, i64 %i
  %v = load i8, ptr %p
  %c0 = icmp eq i8 %v, 0
  %i.next = add i64 %i, 1
  %c = icmp slt i64 %i.next, %n
  %cc = and i1 %c, %c0
  br i1 %cc, label %loop, label %exit
exit:
  ret void
}
