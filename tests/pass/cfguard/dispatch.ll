; CFGuardPass on x86-64 Windows: the "cfguard" module flag Enabled (2) selects the dispatch mechanism (the
; indirect call goes through __guard_dispatch_icall_fptr with a "cfguardtarget" bundle and keeps its name and debug
; location but no other metadata); guard_nocf calls and direct calls are left alone.
; @opt: -passes=cfguard
target datalayout = "e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-pc-windows-msvc"

declare void @direct()
declare i32 @__CxxFrameHandler3(...)

define i32 @f(ptr %fp, ptr %gp) personality ptr @__CxxFrameHandler3 {
entry:
  %r = call i32 %fp(i32 1), !prof !0
  call void %gp() #0
  call void @direct()
  invoke void %gp() to label %cont unwind label %lp
cont:
  ret i32 %r
lp:
  %cs = catchswitch within none [label %h] unwind to caller
h:
  %c = catchpad within %cs [ptr null, i32 64, ptr null]
  catchret from %c to label %cont
}

attributes #0 = { "guard_nocf" }
!llvm.module.flags = !{!1}
!0 = !{!"branch_weights", i32 1}
!1 = !{i32 2, !"cfguard", i32 2}
