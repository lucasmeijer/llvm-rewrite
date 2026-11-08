; @source: tests/e2e/src/control/nested_loops.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/control/nested_loops.c'
source_filename = "tests/e2e/src/control/nested_loops.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [5 x i8] c"%ld\0A\00", align 1
@.str.1 = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i64, align 8
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store i64 0, ptr %2, align 8
  store i32 0, ptr %3, align 4
  br label %7

7:                                                ; preds = %37, %0
  %8 = load i32, ptr %3, align 4
  %9 = icmp slt i32 %8, 20
  br i1 %9, label %10, label %40

10:                                               ; preds = %7
  %11 = load i32, ptr %3, align 4
  store i32 %11, ptr %4, align 4
  br label %12

12:                                               ; preds = %33, %10
  %13 = load i32, ptr %4, align 4
  %14 = icmp slt i32 %13, 20
  br i1 %14, label %15, label %36

15:                                               ; preds = %12
  store i32 0, ptr %5, align 4
  br label %16

16:                                               ; preds = %29, %15
  %17 = load i32, ptr %5, align 4
  %18 = load i32, ptr %4, align 4
  %19 = icmp slt i32 %17, %18
  br i1 %19, label %20, label %32

20:                                               ; preds = %16
  %21 = load i32, ptr %3, align 4
  %22 = load i32, ptr %4, align 4
  %23 = mul nsw i32 %21, %22
  %24 = load i32, ptr %5, align 4
  %25 = sub nsw i32 %23, %24
  %26 = sext i32 %25 to i64
  %27 = load i64, ptr %2, align 8
  %28 = add nsw i64 %27, %26
  store i64 %28, ptr %2, align 8
  br label %29

29:                                               ; preds = %20
  %30 = load i32, ptr %5, align 4
  %31 = add nsw i32 %30, 2
  store i32 %31, ptr %5, align 4
  br label %16, !llvm.loop !5

32:                                               ; preds = %16
  br label %33

33:                                               ; preds = %32
  %34 = load i32, ptr %4, align 4
  %35 = add nsw i32 %34, 1
  store i32 %35, ptr %4, align 4
  br label %12, !llvm.loop !7

36:                                               ; preds = %12
  br label %37

37:                                               ; preds = %36
  %38 = load i32, ptr %3, align 4
  %39 = add nsw i32 %38, 1
  store i32 %39, ptr %3, align 4
  br label %7, !llvm.loop !8

40:                                               ; preds = %7
  %41 = load i64, ptr %2, align 8
  %42 = call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef %41)
  store i32 0, ptr %6, align 4
  br label %43

43:                                               ; preds = %46, %40
  %44 = load i32, ptr %6, align 4
  %45 = add nsw i32 %44, 3
  store i32 %45, ptr %6, align 4
  br label %46

46:                                               ; preds = %43
  %47 = load i32, ptr %6, align 4
  %48 = icmp slt i32 %47, 100
  br i1 %48, label %43, label %49, !llvm.loop !9

49:                                               ; preds = %46
  %50 = load i32, ptr %6, align 4
  %51 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %50)
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
!7 = distinct !{!7, !6}
!8 = distinct !{!8, !6}
!9 = distinct !{!9, !6}
