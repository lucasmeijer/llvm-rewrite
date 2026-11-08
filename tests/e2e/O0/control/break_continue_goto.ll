; @source: tests/e2e/src/control/break_continue_goto.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/control/break_continue_goto.c'
source_filename = "tests/e2e/src/control/break_continue_goto.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1
@.str.1 = private unnamed_addr constant [7 x i8] c"%d %d\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store i32 0, ptr %2, align 4
  store i32 0, ptr %3, align 4
  br label %6

6:                                                ; preds = %22, %0
  %7 = load i32, ptr %3, align 4
  %8 = icmp slt i32 %7, 100
  br i1 %8, label %9, label %25

9:                                                ; preds = %6
  %10 = load i32, ptr %3, align 4
  %11 = srem i32 %10, 3
  %12 = icmp eq i32 %11, 0
  br i1 %12, label %13, label %14

13:                                               ; preds = %9
  br label %22

14:                                               ; preds = %9
  %15 = load i32, ptr %3, align 4
  %16 = icmp sgt i32 %15, 50
  br i1 %16, label %17, label %18

17:                                               ; preds = %14
  br label %25

18:                                               ; preds = %14
  %19 = load i32, ptr %3, align 4
  %20 = load i32, ptr %2, align 4
  %21 = add nsw i32 %20, %19
  store i32 %21, ptr %2, align 4
  br label %22

22:                                               ; preds = %18, %13
  %23 = load i32, ptr %3, align 4
  %24 = add nsw i32 %23, 1
  store i32 %24, ptr %3, align 4
  br label %6, !llvm.loop !5

25:                                               ; preds = %17, %6
  %26 = load i32, ptr %2, align 4
  %27 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %26)
  store i32 0, ptr %4, align 4
  store i32 0, ptr %4, align 4
  br label %28

28:                                               ; preds = %46, %25
  %29 = load i32, ptr %4, align 4
  %30 = icmp slt i32 %29, 10
  br i1 %30, label %31, label %49

31:                                               ; preds = %28
  store i32 0, ptr %5, align 4
  br label %32

32:                                               ; preds = %42, %31
  %33 = load i32, ptr %5, align 4
  %34 = icmp slt i32 %33, 10
  br i1 %34, label %35, label %45

35:                                               ; preds = %32
  %36 = load i32, ptr %4, align 4
  %37 = load i32, ptr %5, align 4
  %38 = mul nsw i32 %36, %37
  %39 = icmp eq i32 %38, 42
  br i1 %39, label %40, label %41

40:                                               ; preds = %35
  br label %50

41:                                               ; preds = %35
  br label %42

42:                                               ; preds = %41
  %43 = load i32, ptr %5, align 4
  %44 = add nsw i32 %43, 1
  store i32 %44, ptr %5, align 4
  br label %32, !llvm.loop !7

45:                                               ; preds = %32
  br label %46

46:                                               ; preds = %45
  %47 = load i32, ptr %4, align 4
  %48 = add nsw i32 %47, 1
  store i32 %48, ptr %4, align 4
  br label %28, !llvm.loop !8

49:                                               ; preds = %28
  store i32 1, ptr %1, align 4
  br label %54

50:                                               ; preds = %40
  %51 = load i32, ptr %4, align 4
  %52 = load i32, ptr %5, align 4
  %53 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %51, i32 noundef %52)
  store i32 0, ptr %1, align 4
  br label %54

54:                                               ; preds = %50, %49
  %55 = load i32, ptr %1, align 4
  ret i32 %55
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
