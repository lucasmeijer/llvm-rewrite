; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/testcase-Value-1.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/testcase-Value-1.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/testcase-Value-1.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@b = dso_local local_unnamed_addr global i16 1, align 2
@d = dso_local local_unnamed_addr global i16 5, align 2
@h = dso_local local_unnamed_addr global i16 1, align 2
@e = dso_local local_unnamed_addr global i32 1, align 4
@f = dso_local local_unnamed_addr global i32 20, align 4
@g = dso_local local_unnamed_addr global i32 1, align 4
@j = dso_local local_unnamed_addr global i32 1, align 4
@c = dso_local local_unnamed_addr global [6 x i8] zeroinitializer, align 1
@a = dso_local local_unnamed_addr global i8 0, align 1
@.str = private unnamed_addr constant [3 x i8] c"%d\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = load i32, ptr @f, align 4, !tbaa !9
  %2 = load i32, ptr @j, align 4
  %3 = icmp eq i32 %2, 0
  %4 = load i8, ptr @a, align 1
  %5 = sext i8 %4 to i32
  %6 = icmp eq i32 %1, 0
  br i1 %6, label %20, label %7

7:                                                ; preds = %0, %7
  %8 = phi i32 [ %11, %7 ], [ 5, %0 ]
  %9 = icmp samesign ult i32 %8, 33
  %10 = select i1 %9, i1 %3, i1 false
  %11 = add nuw nsw i32 %8, 1
  br i1 %10, label %7, label %12, !llvm.loop !10

12:                                               ; preds = %7
  store i32 %8, ptr @g, align 4, !tbaa !9
  store i32 %5, ptr @f, align 4, !tbaa !9
  %13 = icmp eq i8 %4, 0
  br i1 %13, label %20, label %14

14:                                               ; preds = %12, %14
  %15 = phi i32 [ %19, %14 ], [ 5, %12 ]
  %16 = icmp samesign ult i32 %15, 33
  %17 = select i1 %16, i1 %3, i1 false
  %18 = add nuw nsw i32 %15, 1
  %19 = select i1 %17, i32 %18, i32 5
  br label %14, !llvm.loop !12

20:                                               ; preds = %12, %0
  store i32 0, ptr @e, align 4, !tbaa !9
  %21 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef 0)
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
!9 = !{!6, !6, i64 0}
!10 = distinct !{!10, !11}
!11 = !{!"llvm.loop.mustprogress"}
!12 = distinct !{!12, !11, !13}
!13 = !{!"llvm.loop.peeled.count", i32 1}
