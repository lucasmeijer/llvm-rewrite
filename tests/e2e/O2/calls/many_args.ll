; @source: tests/e2e/src/calls/many_args.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/calls/many_args.c'
source_filename = "tests/e2e/src/calls/many_args.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [5 x i8] c"%ld\0A\00", align 1

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local i64 @f(i32 noundef %0, i64 noundef %1, i16 noundef signext %2, i8 noundef signext %3, i32 noundef %4, i64 noundef %5, i32 noundef %6, i64 noundef %7, i32 noundef %8, i8 noundef signext %9, i64 noundef %10) local_unnamed_addr #0 {
  %12 = sext i32 %0 to i64
  %13 = shl nsw i64 %1, 1
  %14 = add nsw i64 %13, %12
  %15 = sext i16 %2 to i64
  %16 = mul nsw i64 %15, 3
  %17 = add nsw i64 %14, %16
  %18 = sext i8 %3 to i32
  %19 = shl nsw i32 %18, 2
  %20 = sext i32 %19 to i64
  %21 = add nsw i64 %17, %20
  %22 = mul nsw i32 %4, 5
  %23 = sext i32 %22 to i64
  %24 = add nsw i64 %21, %23
  %25 = mul nsw i64 %5, 6
  %26 = add nsw i64 %24, %25
  %27 = mul nsw i32 %6, 7
  %28 = sext i32 %27 to i64
  %29 = add nsw i64 %26, %28
  %30 = shl nsw i64 %7, 3
  %31 = add nsw i64 %29, %30
  %32 = mul nsw i32 %8, 9
  %33 = sext i32 %32 to i64
  %34 = add nsw i64 %31, %33
  %35 = sext i8 %9 to i64
  %36 = mul nsw i64 %35, 10
  %37 = add nsw i64 %34, %36
  %38 = mul nsw i64 %10, 11
  %39 = add nsw i64 %37, %38
  ret i64 %39
}

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #1 {
  %1 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i64 noundef 506)
  %2 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i64 noundef -2641975319749)
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #2

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

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
