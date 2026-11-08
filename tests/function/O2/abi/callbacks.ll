; @source: tests/function/src/abi/callbacks.c
; @llc: -O2
; @driver: tests/function/src/abi/callbacks.driver.c
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/function/src/abi/callbacks.c'
source_filename = "tests/function/src/abi/callbacks.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

; Function Attrs: nounwind uwtable
define dso_local i64 @fold(ptr nofree noundef readonly captures(none) %0, i32 noundef %1, i64 noundef %2, ptr nofree noundef readonly captures(none) %3) local_unnamed_addr #0 {
  %5 = icmp sgt i32 %1, 0
  br i1 %5, label %6, label %8

6:                                                ; preds = %4
  %7 = zext nneg i32 %1 to i64
  br label %10

8:                                                ; preds = %10, %4
  %9 = phi i64 [ %2, %4 ], [ %15, %10 ]
  ret i64 %9

10:                                               ; preds = %6, %10
  %11 = phi i64 [ 0, %6 ], [ %16, %10 ]
  %12 = phi i64 [ %2, %6 ], [ %15, %10 ]
  %13 = getelementptr inbounds nuw [8 x i8], ptr %0, i64 %11
  %14 = load i64, ptr %13, align 8, !tbaa !9
  %15 = tail call i64 %3(i64 noundef %12, i64 noundef %14) #1
  %16 = add nuw nsw i64 %11, 1
  %17 = icmp eq i64 %16, %7
  br i1 %17, label %8, label %10, !llvm.loop !11
}

; Function Attrs: nounwind uwtable
define dso_local double @map_sum(ptr nofree noundef readonly captures(none) %0, i32 noundef %1, ptr nofree noundef readonly captures(none) %2) local_unnamed_addr #0 {
  %4 = icmp sgt i32 %1, 0
  br i1 %4, label %5, label %7

5:                                                ; preds = %3
  %6 = zext nneg i32 %1 to i64
  br label %9

7:                                                ; preds = %9, %3
  %8 = phi double [ 0.000000e+00, %3 ], [ %15, %9 ]
  ret double %8

9:                                                ; preds = %5, %9
  %10 = phi i64 [ 0, %5 ], [ %16, %9 ]
  %11 = phi double [ 0.000000e+00, %5 ], [ %15, %9 ]
  %12 = getelementptr inbounds nuw [8 x i8], ptr %0, i64 %10
  %13 = load double, ptr %12, align 8, !tbaa !13
  %14 = tail call double %2(double noundef %13) #1
  %15 = fadd double %11, %14
  %16 = add nuw nsw i64 %10, 1
  %17 = icmp eq i64 %16, %6
  br i1 %17, label %7, label %9, !llvm.loop !15
}

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nounwind }

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
!9 = !{!10, !10, i64 0}
!10 = !{!"long", !7, i64 0}
!11 = distinct !{!11, !12}
!12 = !{!"llvm.loop.mustprogress"}
!13 = !{!14, !14, i64 0}
!14 = !{!"double", !7, i64 0}
!15 = distinct !{!15, !12}
