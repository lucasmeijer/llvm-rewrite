; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-001.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-001.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-001.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@b = dso_local global i8 7, align 1
@c = internal global ptr @a, align 8
@p = dso_local global ptr null, align 8
@a = dso_local global ptr null, align 8
@x = dso_local global i32 0, align 4
@.str = private unnamed_addr constant [10 x i8] c"b = %hhu\0A\00", align 1
@.str.1 = private unnamed_addr constant [8 x i8] c"x = %i\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local void @d() #0 {
  %1 = alloca ptr, align 8
  %2 = load ptr, ptr @c, align 8
  %3 = load ptr, ptr %2, align 8
  %4 = load i32, ptr %3, align 4
  %5 = and i32 %4, 8
  store i32 %5, ptr %3, align 4
  store ptr @b, ptr %1, align 8
  %6 = load ptr, ptr %1, align 8
  store ptr %6, ptr @p, align 8
  %7 = load ptr, ptr %1, align 8
  %8 = load i8, ptr %7, align 1
  %9 = zext i8 %8 to i32
  %10 = and i32 %9, 1
  %11 = trunc i32 %10 to i8
  store i8 %11, ptr %7, align 1
  %12 = zext i8 %11 to i32
  %13 = icmp ne i32 %12, 0
  br i1 %13, label %14, label %20

14:                                               ; preds = %0
  %15 = load ptr, ptr @a, align 8
  %16 = load i32, ptr %15, align 4
  %17 = icmp ne i32 %16, 0
  br i1 %17, label %18, label %20

18:                                               ; preds = %14
  %19 = load ptr, ptr %1, align 8
  store i8 0, ptr %19, align 1
  br label %20

20:                                               ; preds = %18, %14, %0
  %21 = phi i1 [ false, %14 ], [ false, %0 ], [ false, %18 ]
  %22 = zext i1 %21 to i32
  store i32 %22, ptr @x, align 4
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i8, align 1
  %4 = alloca i8, align 1
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store i32 1149798655, ptr %5, align 4
  store i8 -125, ptr %3, align 1
  store i32 -67108864, ptr %2, align 4
  %7 = load i32, ptr %5, align 4
  store i32 %7, ptr %6, align 4
  %8 = load i8, ptr %3, align 1
  store i8 %8, ptr %4, align 1
  %9 = load i32, ptr %2, align 4
  store i32 %9, ptr @x, align 4
  store ptr %4, ptr @p, align 8
  store ptr %6, ptr @a, align 8
  call void @d()
  %10 = load i8, ptr @b, align 1
  %11 = zext i8 %10 to i32
  %12 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %11)
  %13 = load i32, ptr @x, align 4
  %14 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %13)
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
