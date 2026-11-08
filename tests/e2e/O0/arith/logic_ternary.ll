; @source: tests/e2e/src/arith/logic_ternary.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/arith/logic_ternary.c'
source_filename = "tests/e2e/src/arith/logic_ternary.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [13 x i8] c"%d %d %d %d\0A\00", align 1

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
  store i32 -5, ptr %3, align 4
  br label %7

7:                                                ; preds = %50, %0
  %8 = load i32, ptr %3, align 4
  %9 = icmp sle i32 %8, 5
  br i1 %9, label %10, label %53

10:                                               ; preds = %7
  %11 = load i32, ptr %3, align 4
  %12 = icmp sgt i32 %11, 0
  br i1 %12, label %13, label %17

13:                                               ; preds = %10
  %14 = load i32, ptr %3, align 4
  %15 = srem i32 %14, 2
  %16 = icmp eq i32 %15, 0
  br label %17

17:                                               ; preds = %13, %10
  %18 = phi i1 [ false, %10 ], [ %16, %13 ]
  %19 = zext i1 %18 to i32
  store i32 %19, ptr %4, align 4
  %20 = load i32, ptr %3, align 4
  %21 = icmp slt i32 %20, -2
  br i1 %21, label %25, label %22

22:                                               ; preds = %17
  %23 = load i32, ptr %3, align 4
  %24 = icmp eq i32 %23, 3
  br label %25

25:                                               ; preds = %22, %17
  %26 = phi i1 [ true, %17 ], [ %24, %22 ]
  %27 = zext i1 %26 to i32
  store i32 %27, ptr %5, align 4
  %28 = load i32, ptr %3, align 4
  %29 = icmp ne i32 %28, 0
  %30 = xor i1 %29, true
  %31 = zext i1 %30 to i32
  store i32 %31, ptr %6, align 4
  %32 = load i32, ptr %4, align 4
  %33 = mul nsw i32 %32, 100
  %34 = load i32, ptr %5, align 4
  %35 = mul nsw i32 %34, 10
  %36 = add nsw i32 %33, %35
  %37 = load i32, ptr %6, align 4
  %38 = add nsw i32 %36, %37
  %39 = load i32, ptr %3, align 4
  %40 = call i32 @pick(i32 noundef %39, i32 noundef 2)
  %41 = add nsw i32 %38, %40
  %42 = load i32, ptr %2, align 4
  %43 = add nsw i32 %42, %41
  store i32 %43, ptr %2, align 4
  %44 = load i32, ptr %4, align 4
  %45 = load i32, ptr %5, align 4
  %46 = load i32, ptr %6, align 4
  %47 = load i32, ptr %3, align 4
  %48 = call i32 @pick(i32 noundef %47, i32 noundef 2)
  %49 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %44, i32 noundef %45, i32 noundef %46, i32 noundef %48)
  br label %50

50:                                               ; preds = %25
  %51 = load i32, ptr %3, align 4
  %52 = add nsw i32 %51, 1
  store i32 %52, ptr %3, align 4
  br label %7, !llvm.loop !5

53:                                               ; preds = %7
  %54 = load i32, ptr %2, align 4
  %55 = and i32 %54, 127
  ret i32 %55
}

; Function Attrs: noinline nounwind uwtable
define internal i32 @pick(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 %0, ptr %3, align 4
  store i32 %1, ptr %4, align 4
  %5 = load i32, ptr %3, align 4
  %6 = load i32, ptr %4, align 4
  %7 = icmp sgt i32 %5, %6
  br i1 %7, label %8, label %12

8:                                                ; preds = %2
  %9 = load i32, ptr %3, align 4
  %10 = load i32, ptr %4, align 4
  %11 = sub nsw i32 %9, %10
  br label %16

12:                                               ; preds = %2
  %13 = load i32, ptr %4, align 4
  %14 = load i32, ptr %3, align 4
  %15 = sub nsw i32 %13, %14
  br label %16

16:                                               ; preds = %12, %8
  %17 = phi i32 [ %11, %8 ], [ %15, %12 ]
  ret i32 %17
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
