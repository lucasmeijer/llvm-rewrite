; @source: tests/e2e/src/arith/shifts.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/arith/shifts.c'
source_filename = "tests/e2e/src/arith/shifts.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [13 x i8] c"%d %d %u %u\0A\00", align 1
@.str.1 = private unnamed_addr constant [16 x i8] c"%lld %llu %llu\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i64, align 8
  %5 = alloca i64, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store i32 -12345, ptr %2, align 4
  store i32 -559038737, ptr %3, align 4
  store i64 -9876543210, ptr %4, align 8
  store i64 -81985529216486896, ptr %5, align 8
  store i32 0, ptr %6, align 4
  br label %8

8:                                                ; preds = %27, %0
  %9 = load i32, ptr %6, align 4
  %10 = icmp slt i32 %9, 32
  br i1 %10, label %11, label %30

11:                                               ; preds = %8
  %12 = load i32, ptr %2, align 4
  %13 = load i32, ptr %6, align 4
  %14 = ashr i32 %12, %13
  %15 = load i32, ptr %2, align 4
  %16 = and i32 %15, 65535
  %17 = load i32, ptr %6, align 4
  %18 = srem i32 %17, 15
  %19 = shl i32 %16, %18
  %20 = load i32, ptr %3, align 4
  %21 = load i32, ptr %6, align 4
  %22 = lshr i32 %20, %21
  %23 = load i32, ptr %3, align 4
  %24 = load i32, ptr %6, align 4
  %25 = shl i32 %23, %24
  %26 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %14, i32 noundef %19, i32 noundef %22, i32 noundef %25)
  br label %27

27:                                               ; preds = %11
  %28 = load i32, ptr %6, align 4
  %29 = add nsw i32 %28, 3
  store i32 %29, ptr %6, align 4
  br label %8, !llvm.loop !5

30:                                               ; preds = %8
  store i32 0, ptr %7, align 4
  br label %31

31:                                               ; preds = %48, %30
  %32 = load i32, ptr %7, align 4
  %33 = icmp slt i32 %32, 64
  br i1 %33, label %34, label %51

34:                                               ; preds = %31
  %35 = load i64, ptr %4, align 8
  %36 = load i32, ptr %7, align 4
  %37 = zext i32 %36 to i64
  %38 = ashr i64 %35, %37
  %39 = load i64, ptr %5, align 8
  %40 = load i32, ptr %7, align 4
  %41 = zext i32 %40 to i64
  %42 = lshr i64 %39, %41
  %43 = load i64, ptr %5, align 8
  %44 = load i32, ptr %7, align 4
  %45 = zext i32 %44 to i64
  %46 = shl i64 %43, %45
  %47 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i64 noundef %38, i64 noundef %42, i64 noundef %46)
  br label %48

48:                                               ; preds = %34
  %49 = load i32, ptr %7, align 4
  %50 = add nsw i32 %49, 7
  store i32 %50, ptr %7, align 4
  br label %31, !llvm.loop !7

51:                                               ; preds = %31
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
