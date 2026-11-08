; @source: tests/e2e/src/control/short_circuit.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/control/short_circuit.c'
source_filename = "tests/e2e/src/control/short_circuit.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [7 x i8] c"%d %d\0A\00", align 1
@calls = internal global i32 0, align 4

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store i32 0, ptr %2, align 4
  store i32 0, ptr %3, align 4
  br label %7

7:                                                ; preds = %52, %0
  %8 = load i32, ptr %3, align 4
  %9 = icmp slt i32 %8, 8
  br i1 %9, label %10, label %55

10:                                               ; preds = %7
  %11 = load i32, ptr %3, align 4
  %12 = and i32 %11, 1
  store i32 %12, ptr %4, align 4
  %13 = load i32, ptr %3, align 4
  %14 = ashr i32 %13, 1
  %15 = and i32 %14, 1
  store i32 %15, ptr %5, align 4
  %16 = load i32, ptr %3, align 4
  %17 = ashr i32 %16, 2
  %18 = and i32 %17, 1
  store i32 %18, ptr %6, align 4
  %19 = load i32, ptr %4, align 4
  %20 = call i32 @t(i32 noundef %19)
  %21 = icmp ne i32 %20, 0
  br i1 %21, label %22, label %26

22:                                               ; preds = %10
  %23 = load i32, ptr %5, align 4
  %24 = call i32 @t(i32 noundef %23)
  %25 = icmp ne i32 %24, 0
  br i1 %25, label %30, label %26

26:                                               ; preds = %22, %10
  %27 = load i32, ptr %6, align 4
  %28 = call i32 @t(i32 noundef %27)
  %29 = icmp ne i32 %28, 0
  br label %30

30:                                               ; preds = %26, %22
  %31 = phi i1 [ true, %22 ], [ %29, %26 ]
  %32 = zext i1 %31 to i32
  %33 = load i32, ptr %2, align 4
  %34 = add nsw i32 %33, %32
  store i32 %34, ptr %2, align 4
  %35 = load i32, ptr %4, align 4
  %36 = call i32 @t(i32 noundef %35)
  %37 = icmp ne i32 %36, 0
  br i1 %37, label %42, label %38

38:                                               ; preds = %30
  %39 = load i32, ptr %5, align 4
  %40 = call i32 @t(i32 noundef %39)
  %41 = icmp ne i32 %40, 0
  br i1 %41, label %42, label %47

42:                                               ; preds = %38, %30
  %43 = load i32, ptr %6, align 4
  %44 = call i32 @t(i32 noundef %43)
  %45 = icmp ne i32 %44, 0
  %46 = xor i1 %45, true
  br label %47

47:                                               ; preds = %42, %38
  %48 = phi i1 [ false, %38 ], [ %46, %42 ]
  %49 = zext i1 %48 to i32
  %50 = load i32, ptr %2, align 4
  %51 = add nsw i32 %50, %49
  store i32 %51, ptr %2, align 4
  br label %52

52:                                               ; preds = %47
  %53 = load i32, ptr %3, align 4
  %54 = add nsw i32 %53, 1
  store i32 %54, ptr %3, align 4
  br label %7, !llvm.loop !5

55:                                               ; preds = %7
  %56 = load i32, ptr %2, align 4
  %57 = load i32, ptr @calls, align 4
  %58 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %56, i32 noundef %57)
  ret i32 0
}

; Function Attrs: noinline nounwind uwtable
define internal i32 @t(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4
  %3 = load i32, ptr @calls, align 4
  %4 = add nsw i32 %3, 1
  store i32 %4, ptr @calls, align 4
  %5 = load i32, ptr %2, align 4
  ret i32 %5
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
