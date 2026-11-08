; @source: tests/e2e/src/arith/mul_div_rem.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/arith/mul_div_rem.c'
source_filename = "tests/e2e/src/arith/mul_div_rem.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@__const.main.xs = private unnamed_addr constant [6 x i32] [i32 17, i32 -17, i32 1000003, i32 -5, i32 0, i32 2147483647], align 16
@.str = private unnamed_addr constant [19 x i8] c"%d %d: %lld %d %d\0A\00", align 1
@.str.1 = private unnamed_addr constant [10 x i8] c"%u %u %u\0A\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  br label %1

1:                                                ; preds = %0, %1
  %2 = phi i64 [ 0, %0 ], [ %30, %1 ]
  %3 = getelementptr inbounds nuw [4 x i8], ptr @__const.main.xs, i64 %2
  %4 = load i32, ptr %3, align 4, !tbaa !9
  %5 = sext i32 %4 to i64
  %6 = sdiv i32 %4, 3
  %7 = srem i32 %4, 3
  %8 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %4, i32 noundef 3, i64 noundef %5, i32 noundef %6, i32 noundef %7)
  %9 = sub nsw i64 0, %5
  %10 = sdiv i32 %4, -3
  %11 = srem i32 %4, 3
  %12 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %4, i32 noundef -3, i64 noundef %9, i32 noundef %10, i32 noundef %11)
  %13 = mul nsw i64 %5, 7
  %14 = sdiv i64 %13, 3
  %15 = sdiv i32 %4, 7
  %16 = srem i32 %4, 7
  %17 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %4, i32 noundef 7, i64 noundef %14, i32 noundef %15, i32 noundef %16)
  %18 = sdiv i32 %4, 3
  %19 = sext i32 %18 to i64
  %20 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %4, i32 noundef 1, i64 noundef %19, i32 noundef %4, i32 noundef 0)
  %21 = sdiv i32 %4, -3
  %22 = sext i32 %21 to i64
  %23 = sub nsw i32 0, %4
  %24 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %4, i32 noundef -1, i64 noundef %22, i32 noundef %23, i32 noundef 0)
  %25 = mul nsw i64 %5, 100
  %26 = sdiv i64 %25, 3
  %27 = sdiv i32 %4, 100
  %28 = srem i32 %4, 100
  %29 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %4, i32 noundef 100, i64 noundef %26, i32 noundef %27, i32 noundef %28)
  %30 = add nuw nsw i64 %2, 1
  %31 = icmp eq i64 %30, 6
  br i1 %31, label %32, label %1, !llvm.loop !10

32:                                               ; preds = %1
  %33 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i32 noundef 571428571, i32 noundef 3, i32 noundef -884901888)
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
