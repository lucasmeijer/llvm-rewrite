; @source: tests/e2e/src/control/switch_dense.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/control/switch_dense.c'
source_filename = "tests/e2e/src/control/switch_dense.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [7 x i8] c"%d %s\0A\00", align 1
@.str.1 = private unnamed_addr constant [5 x i8] c"zero\00", align 1
@.str.2 = private unnamed_addr constant [4 x i8] c"one\00", align 1
@.str.3 = private unnamed_addr constant [4 x i8] c"two\00", align 1
@.str.4 = private unnamed_addr constant [6 x i8] c"three\00", align 1
@.str.5 = private unnamed_addr constant [5 x i8] c"four\00", align 1
@.str.6 = private unnamed_addr constant [5 x i8] c"five\00", align 1
@.str.7 = private unnamed_addr constant [4 x i8] c"six\00", align 1
@.str.8 = private unnamed_addr constant [6 x i8] c"seven\00", align 1
@.str.9 = private unnamed_addr constant [5 x i8] c"many\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store i32 -1, ptr %2, align 4
  br label %3

3:                                                ; preds = %11, %0
  %4 = load i32, ptr %2, align 4
  %5 = icmp slt i32 %4, 10
  br i1 %5, label %6, label %14

6:                                                ; preds = %3
  %7 = load i32, ptr %2, align 4
  %8 = load i32, ptr %2, align 4
  %9 = call ptr @name(i32 noundef %8)
  %10 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %7, ptr noundef %9)
  br label %11

11:                                               ; preds = %6
  %12 = load i32, ptr %2, align 4
  %13 = add nsw i32 %12, 1
  store i32 %13, ptr %2, align 4
  br label %3, !llvm.loop !5

14:                                               ; preds = %3
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: noinline nounwind uwtable
define internal ptr @name(i32 noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca i32, align 4
  store i32 %0, ptr %3, align 4
  %4 = load i32, ptr %3, align 4
  switch i32 %4, label %13 [
    i32 0, label %5
    i32 1, label %6
    i32 2, label %7
    i32 3, label %8
    i32 4, label %9
    i32 5, label %10
    i32 6, label %11
    i32 7, label %12
  ]

5:                                                ; preds = %1
  store ptr @.str.1, ptr %2, align 8
  br label %14

6:                                                ; preds = %1
  store ptr @.str.2, ptr %2, align 8
  br label %14

7:                                                ; preds = %1
  store ptr @.str.3, ptr %2, align 8
  br label %14

8:                                                ; preds = %1
  store ptr @.str.4, ptr %2, align 8
  br label %14

9:                                                ; preds = %1
  store ptr @.str.5, ptr %2, align 8
  br label %14

10:                                               ; preds = %1
  store ptr @.str.6, ptr %2, align 8
  br label %14

11:                                               ; preds = %1
  store ptr @.str.7, ptr %2, align 8
  br label %14

12:                                               ; preds = %1
  store ptr @.str.8, ptr %2, align 8
  br label %14

13:                                               ; preds = %1
  store ptr @.str.9, ptr %2, align 8
  br label %14

14:                                               ; preds = %13, %12, %11, %10, %9, %8, %7, %6, %5
  %15 = load ptr, ptr %2, align 8
  ret ptr %15
}

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
