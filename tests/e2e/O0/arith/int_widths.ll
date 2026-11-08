; @source: tests/e2e/src/arith/int_widths.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/arith/int_widths.c'
source_filename = "tests/e2e/src/arith/int_widths.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [13 x i8] c"%d %d %d %d\0A\00", align 1
@.str.1 = private unnamed_addr constant [7 x i8] c"%d %d\0A\00", align 1
@.str.2 = private unnamed_addr constant [12 x i8] c"%lld %d %u\0A\00", align 1
@.str.3 = private unnamed_addr constant [11 x i8] c"%lld %llu\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i8, align 1
  %3 = alloca i8, align 1
  %4 = alloca i16, align 2
  %5 = alloca i16, align 2
  %6 = alloca i64, align 8
  %7 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store i8 -100, ptr %2, align 1
  store i8 -56, ptr %3, align 1
  store i16 -30000, ptr %4, align 2
  store i16 -5536, ptr %5, align 2
  store i64 -5000000000, ptr %6, align 8
  %8 = load i8, ptr %2, align 1
  %9 = sext i8 %8 to i32
  %10 = load i8, ptr %3, align 1
  %11 = zext i8 %10 to i32
  %12 = load i16, ptr %4, align 2
  %13 = sext i16 %12 to i32
  %14 = load i16, ptr %5, align 2
  %15 = zext i16 %14 to i32
  %16 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %9, i32 noundef %11, i32 noundef %13, i32 noundef %15)
  %17 = load i8, ptr %2, align 1
  %18 = sext i8 %17 to i32
  %19 = sub nsw i32 %18, 100
  %20 = trunc i32 %19 to i8
  %21 = sext i8 %20 to i32
  %22 = load i8, ptr %3, align 1
  %23 = zext i8 %22 to i32
  %24 = add nsw i32 %23, 100
  %25 = trunc i32 %24 to i8
  %26 = zext i8 %25 to i32
  %27 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %21, i32 noundef %26)
  %28 = load i16, ptr %4, align 2
  %29 = sext i16 %28 to i32
  %30 = mul nsw i32 %29, 2
  %31 = trunc i32 %30 to i16
  %32 = sext i16 %31 to i32
  %33 = load i16, ptr %5, align 2
  %34 = zext i16 %33 to i32
  %35 = mul nsw i32 %34, 3
  %36 = trunc i32 %35 to i16
  %37 = zext i16 %36 to i32
  %38 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %32, i32 noundef %37)
  %39 = load i64, ptr %6, align 8
  %40 = load i64, ptr %6, align 8
  %41 = trunc i64 %40 to i32
  %42 = load i64, ptr %6, align 8
  %43 = trunc i64 %42 to i32
  %44 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i64 noundef %39, i32 noundef %41, i32 noundef %43)
  %45 = load i8, ptr %2, align 1
  %46 = sext i8 %45 to i64
  %47 = load i8, ptr %3, align 1
  %48 = zext i8 %47 to i64
  %49 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i64 noundef %46, i64 noundef %48)
  %50 = load i8, ptr %2, align 1
  %51 = sext i8 %50 to i32
  %52 = load i8, ptr %3, align 1
  %53 = zext i8 %52 to i32
  %54 = add nsw i32 %51, %53
  %55 = load i16, ptr %4, align 2
  %56 = sext i16 %55 to i32
  %57 = add nsw i32 %54, %56
  %58 = load i16, ptr %5, align 2
  %59 = zext i16 %58 to i32
  %60 = add nsw i32 %57, %59
  store i32 %60, ptr %7, align 4
  %61 = load i32, ptr %7, align 4
  %62 = and i32 %61, 255
  ret i32 %62
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
