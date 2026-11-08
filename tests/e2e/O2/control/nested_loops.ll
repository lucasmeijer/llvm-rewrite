; @source: tests/e2e/src/control/nested_loops.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/control/nested_loops.c'
source_filename = "tests/e2e/src/control/nested_loops.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [5 x i8] c"%ld\0A\00", align 1
@.str.1 = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  br label %1

1:                                                ; preds = %0, %32
  %2 = phi i32 [ 0, %0 ], [ %36, %32 ]
  %3 = phi i32 [ 1, %0 ], [ %35, %32 ]
  %4 = phi i32 [ -1, %0 ], [ %34, %32 ]
  %5 = phi i32 [ 0, %0 ], [ %33, %32 ]
  %6 = phi i64 [ 0, %0 ], [ %39, %32 ]
  br label %10

7:                                                ; preds = %32
  %8 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i64 noundef %39)
  %9 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i32 noundef 102)
  ret i32 0

10:                                               ; preds = %1, %38
  %11 = phi i32 [ %2, %1 ], [ %42, %38 ]
  %12 = phi i32 [ %4, %1 ], [ %41, %38 ]
  %13 = phi i32 [ %5, %1 ], [ %40, %38 ]
  %14 = phi i64 [ %6, %1 ], [ %39, %38 ]
  %15 = icmp eq i32 %13, 0
  br i1 %15, label %38, label %16

16:                                               ; preds = %10
  %17 = lshr i32 %12, 1
  %18 = zext nneg i32 %17 to i64
  %19 = lshr i32 %12, 1
  %20 = add nsw i32 %19, -1
  %21 = zext i32 %20 to i64
  %22 = mul nuw nsw i64 %18, %21
  %23 = and i64 %22, 9223372036854775806
  %24 = lshr i32 %12, 1
  %25 = zext nneg i32 %24 to i64
  %26 = sext i32 %11 to i64
  %27 = add nsw i64 %26, -2
  %28 = mul nsw i64 %27, %25
  %29 = add i64 %14, %28
  %30 = add i64 %29, %26
  %31 = sub i64 %30, %23
  br label %38

32:                                               ; preds = %38
  %33 = add nuw nsw i32 %5, 1
  %34 = add nsw i32 %4, 1
  %35 = add nuw nsw i32 %3, 2
  %36 = add i32 %2, %3
  %37 = icmp eq i32 %33, 20
  br i1 %37, label %7, label %1, !llvm.loop !9

38:                                               ; preds = %16, %10
  %39 = phi i64 [ %14, %10 ], [ %31, %16 ]
  %40 = add nuw nsw i32 %13, 1
  %41 = add nsw i32 %12, 1
  %42 = add i32 %11, %5
  %43 = icmp eq i32 %41, 19
  br i1 %43, label %32, label %10, !llvm.loop !11
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
!11 = distinct !{!11, !10}
