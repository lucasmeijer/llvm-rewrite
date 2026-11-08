; @source: tests/e2e/src/control/break_continue_goto.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/control/break_continue_goto.c'
source_filename = "tests/e2e/src/control/break_continue_goto.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1
@.str.1 = private unnamed_addr constant [7 x i8] c"%d %d\0A\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef range(i32 0, 2) i32 @main() local_unnamed_addr #0 {
  br label %1

1:                                                ; preds = %21, %0
  %2 = phi i32 [ 0, %0 ], [ %23, %21 ]
  %3 = phi i32 [ 0, %0 ], [ %22, %21 ]
  %4 = trunc nuw i32 %2 to i8
  %5 = urem i8 %4, 3
  %6 = icmp eq i8 %5, 0
  br i1 %6, label %11, label %7

7:                                                ; preds = %1
  %8 = icmp samesign ugt i32 %2, 50
  br i1 %8, label %25, label %9

9:                                                ; preds = %7
  %10 = add nsw i32 %2, %3
  br label %11

11:                                               ; preds = %1, %9
  %12 = phi i32 [ %3, %1 ], [ %10, %9 ]
  %13 = or disjoint i32 %2, 1
  %14 = trunc nuw i32 %13 to i8
  %15 = urem i8 %14, 3
  %16 = icmp eq i8 %15, 0
  br i1 %16, label %21, label %17

17:                                               ; preds = %11
  %18 = icmp samesign ugt i32 %2, 49
  br i1 %18, label %25, label %19

19:                                               ; preds = %17
  %20 = add nsw i32 %13, %12
  br label %21

21:                                               ; preds = %19, %11
  %22 = phi i32 [ %12, %11 ], [ %20, %19 ]
  %23 = add nuw nsw i32 %2, 2
  %24 = icmp eq i32 %23, 100
  br i1 %24, label %25, label %1, !llvm.loop !9

25:                                               ; preds = %21, %17, %7
  %26 = phi i32 [ %3, %7 ], [ %22, %21 ], [ %12, %17 ]
  %27 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %26)
  %28 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i32 noundef 6, i32 noundef 7)
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #1

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

!llvm.module.flags = !{!0, !1, !2}
!llvm.ident = !{!3}
!llvm.errno.tbaa = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
!4 = !{!5, !6, i64 0}
!5 = !{!"__libc_errno", !6, i64 0}
!6 = !{!"int", !7, i64 0}
!7 = !{!"omnipotent char", !8, i64 0}
!8 = !{!"Simple C/C++ TBAA"}
!9 = distinct !{!9, !10}
!10 = !{!"llvm.loop.mustprogress"}
