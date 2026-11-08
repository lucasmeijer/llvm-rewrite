; @source: tests/e2e/src/calls/function_pointers.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/calls/function_pointers.c'
source_filename = "tests/e2e/src/calls/function_pointers.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  br label %3

1:                                                ; preds = %16
  %2 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %17)
  ret i32 0

3:                                                ; preds = %0, %16
  %4 = phi i32 [ 0, %0 ], [ %18, %16 ]
  %5 = phi i32 [ 1, %0 ], [ %17, %16 ]
  %6 = trunc nuw nsw i32 %4 to i8
  %7 = urem i8 %6, 3
  %8 = add nuw nsw i32 %4, 2
  switch i8 %7, label %9 [
    i8 0, label %10
    i8 1, label %12
    i8 2, label %14
  ], !prof !9

9:                                                ; preds = %3
  unreachable

10:                                               ; preds = %3
  %11 = tail call fastcc i32 @add(i32 noundef %5, i32 noundef range(i32 -2147483646, 14) %8) #3, !inline_history !10
  br label %16

12:                                               ; preds = %3
  %13 = tail call fastcc i32 @sub(i32 noundef %5, i32 noundef range(i32 -2147483646, 14) %8) #3, !inline_history !10
  br label %16

14:                                               ; preds = %3
  %15 = tail call fastcc i32 @mul(i32 noundef %5, i32 noundef range(i32 -2147483646, 14) %8) #3, !inline_history !10
  br label %16

16:                                               ; preds = %14, %12, %10
  %17 = phi i32 [ %11, %10 ], [ %13, %12 ], [ %15, %14 ]
  %18 = add nuw nsw i32 %4, 1
  %19 = icmp eq i32 %18, 12
  br i1 %19, label %1, label %3, !llvm.loop !11
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #1

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define internal fastcc i32 @add(i32 noundef %0, i32 noundef %1) unnamed_addr #2 {
  %3 = add nsw i32 %1, %0
  ret i32 %3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define internal fastcc i32 @sub(i32 noundef %0, i32 noundef %1) unnamed_addr #2 {
  %3 = sub nsw i32 %0, %1
  ret i32 %3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define internal fastcc i32 @mul(i32 noundef %0, i32 noundef %1) unnamed_addr #2 {
  %3 = mul nsw i32 %1, %0
  ret i32 %3
}

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind }

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
!9 = !{!"unknown", !"jump-table-to-switch"}
!10 = distinct !{null}
!11 = distinct !{!11, !12}
!12 = !{!"llvm.loop.mustprogress"}
