; @source: tests/e2e/src/arith/compare.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/arith/compare.c'
source_filename = "tests/e2e/src/arith/compare.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@__const.main.vals = private unnamed_addr constant [6 x i32] [i32 -3, i32 -1, i32 0, i32 1, i32 2, i32 2147483647], align 16
@.str = private unnamed_addr constant [23 x i8] c"%d%d%d%d%d%d %d%d%d%d\0A\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  br label %1

1:                                                ; preds = %0, %6
  %2 = phi i64 [ 0, %0 ], [ %7, %6 ]
  %3 = getelementptr inbounds nuw [4 x i8], ptr @__const.main.vals, i64 %2
  %4 = load i32, ptr %3, align 4, !tbaa !9
  br label %9

5:                                                ; preds = %6
  ret i32 0

6:                                                ; preds = %9
  %7 = add nuw nsw i64 %2, 1
  %8 = icmp eq i64 %7, 6
  br i1 %8, label %5, label %1, !llvm.loop !10

9:                                                ; preds = %1, %9
  %10 = phi i64 [ 0, %1 ], [ %34, %9 ]
  %11 = getelementptr inbounds nuw [4 x i8], ptr @__const.main.vals, i64 %10
  %12 = load i32, ptr %11, align 4, !tbaa !9
  %13 = icmp slt i32 %4, %12
  %14 = zext i1 %13 to i32
  %15 = icmp sle i32 %4, %12
  %16 = zext i1 %15 to i32
  %17 = icmp sgt i32 %4, %12
  %18 = zext i1 %17 to i32
  %19 = icmp sge i32 %4, %12
  %20 = zext i1 %19 to i32
  %21 = icmp eq i32 %4, %12
  %22 = zext i1 %21 to i32
  %23 = icmp ne i32 %4, %12
  %24 = zext i1 %23 to i32
  %25 = icmp ult i32 %4, %12
  %26 = zext i1 %25 to i32
  %27 = icmp ule i32 %4, %12
  %28 = zext i1 %27 to i32
  %29 = icmp ugt i32 %4, %12
  %30 = zext i1 %29 to i32
  %31 = icmp uge i32 %4, %12
  %32 = zext i1 %31 to i32
  %33 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %14, i32 noundef %16, i32 noundef %18, i32 noundef %20, i32 noundef %22, i32 noundef %24, i32 noundef %26, i32 noundef %28, i32 noundef %30, i32 noundef %32)
  %34 = add nuw nsw i64 %10, 1
  %35 = icmp eq i64 %34, 6
  br i1 %35, label %6, label %9, !llvm.loop !12
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
!9 = !{!6, !6, i64 0}
!10 = distinct !{!10, !11}
!11 = !{!"llvm.loop.mustprogress"}
!12 = distinct !{!12, !11}
