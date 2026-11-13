target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

define i32 @fa(ptr %p) {
  %v = load i32, ptr %p, !tbaa !5, !range !9
  ret i32 %v
}

!llvm.ident = !{!0}
!llvm.module.flags = !{!1, !2, !3, !4}
!named = !{!0, !10}

!0 = !{!"clang version 23.1.5"}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 7, !"uwtable", i32 1}
!3 = !{i32 8, !"PIC Level", i32 2}
!4 = !{i32 7, !"frame-pointer", i32 2}
!5 = !{!6, !6, i64 0}
!6 = !{!"int", !7, i64 0}
!7 = !{!"omnipotent char", !8, i64 0}
!8 = !{!"Simple C/C++ TBAA"}
!9 = !{i32 0, i32 10}
!10 = distinct !{!"distinct"}
