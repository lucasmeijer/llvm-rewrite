; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-005.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-005.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-005.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@b = dso_local global i64 0, align 8
@r = dso_local global ptr null, align 8
@s = dso_local global ptr null, align 8
@p = dso_local global ptr null, align 8
@e = dso_local global i16 0, align 2
@t = dso_local global ptr null, align 8
@q = dso_local global ptr null, align 8
@c = dso_local global i32 0, align 4
@d = dso_local global i32 0, align 4
@a = dso_local global i32 0, align 4
@.str = private unnamed_addr constant [8 x i8] c"a = %u\0A\00", align 1
@.str.1 = private unnamed_addr constant [9 x i8] c"b = %lu\0A\00", align 1
@.str.2 = private unnamed_addr constant [8 x i8] c"c = %u\0A\00", align 1
@.str.3 = private unnamed_addr constant [8 x i8] c"d = %u\0A\00", align 1
@.str.4 = private unnamed_addr constant [9 x i8] c"e = %hi\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local void @h() #0 {
  %1 = alloca ptr, align 8
  store ptr @b, ptr %1, align 8
  %2 = load ptr, ptr %1, align 8
  store ptr %2, ptr @r, align 8
  %3 = load ptr, ptr %1, align 8
  store i64 6, ptr %3, align 8
  call void @g()
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local void @g() #0 {
  %1 = alloca ptr, align 8
  %2 = alloca ptr, align 8
  br label %3

3:                                                ; preds = %22, %0
  store ptr @b, ptr %1, align 8
  %4 = load ptr, ptr %1, align 8
  store ptr %4, ptr @s, align 8
  %5 = load ptr, ptr %1, align 8
  store ptr %5, ptr @p, align 8
  store ptr @e, ptr %2, align 8
  %6 = load ptr, ptr %2, align 8
  store ptr %6, ptr @t, align 8
  %7 = load ptr, ptr %2, align 8
  store ptr %7, ptr @q, align 8
  %8 = load ptr, ptr %2, align 8
  %9 = load i16, ptr %8, align 2
  %10 = add i16 %9, -1
  store i16 %10, ptr %8, align 2
  %11 = load i32, ptr @c, align 4
  %12 = zext i32 %11 to i64
  %13 = load ptr, ptr %1, align 8
  %14 = load i64, ptr %13, align 8
  %15 = and i64 %14, %12
  store i64 %15, ptr %13, align 8
  br label %16

16:                                               ; preds = %24, %3
  %17 = load i32, ptr @d, align 4
  %18 = icmp ne i32 %17, 0
  br i1 %18, label %19, label %26

19:                                               ; preds = %16
  %20 = load i16, ptr @e, align 2
  %21 = icmp ne i16 %20, 0
  br i1 %21, label %22, label %23

22:                                               ; preds = %19
  br label %3

23:                                               ; preds = %19
  br label %24

24:                                               ; preds = %23
  %25 = load i32, ptr @d, align 4
  store i32 %25, ptr @a, align 4
  br label %16, !llvm.loop !5

26:                                               ; preds = %16
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i16, align 2
  %3 = alloca i16, align 2
  %4 = alloca i64, align 8
  %5 = alloca i64, align 8
  %6 = alloca i64, align 8
  %7 = alloca i64, align 8
  %8 = alloca i16, align 2
  %9 = alloca i16, align 2
  %10 = alloca i64, align 8
  %11 = alloca i64, align 8
  %12 = alloca i16, align 2
  %13 = alloca i64, align 8
  %14 = alloca i32, align 4
  %15 = alloca i32, align 4
  %16 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store i32 16777101, ptr %16, align 4
  store i32 -6, ptr %15, align 4
  store i32 0, ptr %14, align 4
  store i64 256, ptr %13, align 8
  store i16 -7, ptr %12, align 2
  store i64 -9223372032559808512, ptr %10, align 8
  store i16 0, ptr %8, align 2
  store i64 -72318388763361280, ptr %6, align 8
  store i64 0, ptr %4, align 8
  store i16 0, ptr %2, align 2
  %17 = load i64, ptr %10, align 8
  store i64 %17, ptr %11, align 8
  %18 = load i16, ptr %8, align 2
  store i16 %18, ptr %9, align 2
  %19 = load i64, ptr %6, align 8
  store i64 %19, ptr %7, align 8
  %20 = load i64, ptr %4, align 8
  store i64 %20, ptr %5, align 8
  %21 = load i16, ptr %2, align 2
  store i16 %21, ptr %3, align 2
  store ptr %3, ptr @t, align 8
  store ptr %5, ptr @s, align 8
  store ptr %7, ptr @r, align 8
  store ptr %9, ptr @q, align 8
  store ptr %11, ptr @p, align 8
  %22 = load i16, ptr %12, align 2
  store i16 %22, ptr @e, align 2
  %23 = load i64, ptr %13, align 8
  store i64 %23, ptr @b, align 8
  %24 = load i32, ptr %14, align 4
  store i32 %24, ptr @d, align 4
  %25 = load i32, ptr %15, align 4
  store i32 %25, ptr @c, align 4
  %26 = load i32, ptr %16, align 4
  store i32 %26, ptr @a, align 4
  call void @h()
  call void @g()
  %27 = load i32, ptr @a, align 4
  %28 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %27)
  %29 = load i64, ptr @b, align 8
  %30 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i64 noundef %29)
  %31 = load i32, ptr @c, align 4
  %32 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i32 noundef %31)
  %33 = load i32, ptr @d, align 4
  %34 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i32 noundef %33)
  %35 = load i16, ptr @e, align 2
  %36 = sext i16 %35 to i32
  %37 = call i32 (ptr, ...) @printf(ptr noundef @.str.4, i32 noundef %36)
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
