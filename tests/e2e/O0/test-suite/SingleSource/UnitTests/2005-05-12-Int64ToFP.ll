; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2005-05-12-Int64ToFP.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2005-05-12-Int64ToFP.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2005-05-12-Int64ToFP.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [22 x i8] c"%llu = %f  %lld = %f\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i64, align 8
  %3 = alloca i64, align 8
  store i32 0, ptr %1, align 4
  store i64 124, ptr %2, align 8
  br label %4

4:                                                ; preds = %15, %0
  %5 = load i64, ptr %2, align 8
  store i64 %5, ptr %3, align 8
  %6 = load i64, ptr %3, align 8
  %7 = load i64, ptr %3, align 8
  %8 = uitofp i64 %7 to double
  %9 = load i64, ptr %3, align 8
  %10 = load i64, ptr %3, align 8
  %11 = sitofp i64 %10 to double
  %12 = call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef %6, double noundef %8, i64 noundef %9, double noundef %11)
  %13 = load i64, ptr %2, align 8
  %14 = add i64 %13, 1152921504606846976
  store i64 %14, ptr %2, align 8
  br label %15

15:                                               ; preds = %4
  %16 = load i64, ptr %3, align 8
  %17 = load i64, ptr %2, align 8
  %18 = icmp ult i64 %16, %17
  br i1 %18, label %4, label %19, !llvm.loop !5

19:                                               ; preds = %15
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #1

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{i32 7, !"frame-pointer", i32 2}
!4 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
!5 = distinct !{!5, !6}
!6 = !{!"llvm.loop.mustprogress"}
