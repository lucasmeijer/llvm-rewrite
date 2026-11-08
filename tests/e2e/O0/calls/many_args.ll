; @source: tests/e2e/src/calls/many_args.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/calls/many_args.c'
source_filename = "tests/e2e/src/calls/many_args.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [5 x i8] c"%ld\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i64 @f(i32 noundef %0, i64 noundef %1, i16 noundef signext %2, i8 noundef signext %3, i32 noundef %4, i64 noundef %5, i32 noundef %6, i64 noundef %7, i32 noundef %8, i8 noundef signext %9, i64 noundef %10) #0 {
  %12 = alloca i32, align 4
  %13 = alloca i64, align 8
  %14 = alloca i16, align 2
  %15 = alloca i8, align 1
  %16 = alloca i32, align 4
  %17 = alloca i64, align 8
  %18 = alloca i32, align 4
  %19 = alloca i64, align 8
  %20 = alloca i32, align 4
  %21 = alloca i8, align 1
  %22 = alloca i64, align 8
  store i32 %0, ptr %12, align 4
  store i64 %1, ptr %13, align 8
  store i16 %2, ptr %14, align 2
  store i8 %3, ptr %15, align 1
  store i32 %4, ptr %16, align 4
  store i64 %5, ptr %17, align 8
  store i32 %6, ptr %18, align 4
  store i64 %7, ptr %19, align 8
  store i32 %8, ptr %20, align 4
  store i8 %9, ptr %21, align 1
  store i64 %10, ptr %22, align 8
  %23 = load i32, ptr %12, align 4
  %24 = sext i32 %23 to i64
  %25 = load i64, ptr %13, align 8
  %26 = mul nsw i64 %25, 2
  %27 = add nsw i64 %24, %26
  %28 = load i16, ptr %14, align 2
  %29 = sext i16 %28 to i32
  %30 = mul nsw i32 %29, 3
  %31 = sext i32 %30 to i64
  %32 = add nsw i64 %27, %31
  %33 = load i8, ptr %15, align 1
  %34 = sext i8 %33 to i32
  %35 = mul nsw i32 %34, 4
  %36 = sext i32 %35 to i64
  %37 = add nsw i64 %32, %36
  %38 = load i32, ptr %16, align 4
  %39 = mul nsw i32 %38, 5
  %40 = sext i32 %39 to i64
  %41 = add nsw i64 %37, %40
  %42 = load i64, ptr %17, align 8
  %43 = mul nsw i64 %42, 6
  %44 = add nsw i64 %41, %43
  %45 = load i32, ptr %18, align 4
  %46 = mul nsw i32 %45, 7
  %47 = sext i32 %46 to i64
  %48 = add nsw i64 %44, %47
  %49 = load i64, ptr %19, align 8
  %50 = mul nsw i64 %49, 8
  %51 = add nsw i64 %48, %50
  %52 = load i32, ptr %20, align 4
  %53 = mul nsw i32 %52, 9
  %54 = sext i32 %53 to i64
  %55 = add nsw i64 %51, %54
  %56 = load i8, ptr %21, align 1
  %57 = sext i8 %56 to i32
  %58 = mul nsw i32 %57, 10
  %59 = sext i32 %58 to i64
  %60 = add nsw i64 %55, %59
  %61 = load i64, ptr %22, align 8
  %62 = mul nsw i64 %61, 11
  %63 = add nsw i64 %60, %62
  ret i64 %63
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  %2 = call i64 @f(i32 noundef 1, i64 noundef 2, i16 noundef signext 3, i8 noundef signext 4, i32 noundef 5, i64 noundef 6, i32 noundef 7, i64 noundef 8, i32 noundef 9, i8 noundef signext 10, i64 noundef 11)
  %3 = call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef %2)
  %4 = call i64 @f(i32 noundef -1, i64 noundef -2000000000000, i16 noundef signext -3, i8 noundef signext -4, i32 noundef -5, i64 noundef 6, i32 noundef -7, i64 noundef 8, i32 noundef -9, i8 noundef signext 120, i64 noundef 123456789012)
  %5 = call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef %4)
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
