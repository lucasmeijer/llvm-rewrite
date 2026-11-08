; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-003.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-003.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-003.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@a = dso_local global i8 0, align 1
@x = dso_local global i32 0, align 4
@.str = private unnamed_addr constant [10 x i8] c"a = %hhi\0A\00", align 1
@.str.1 = private unnamed_addr constant [8 x i8] c"x = %i\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local void @b() #0 {
  %1 = load i8, ptr @a, align 1
  %2 = sext i8 %1 to i64
  %3 = icmp ugt i64 4073709551607, %2
  br i1 %3, label %8, label %4

4:                                                ; preds = %0
  %5 = load i8, ptr @a, align 1
  %6 = sext i8 %5 to i32
  %7 = icmp ne i32 %6, 0
  br label %8

8:                                                ; preds = %4, %0
  %9 = phi i1 [ true, %0 ], [ %7, %4 ]
  %10 = zext i1 %9 to i32
  store i32 %10, ptr @x, align 4
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i8, align 1
  store i32 0, ptr %1, align 4
  store i8 -7, ptr %3, align 1
  store i32 1695154176, ptr %2, align 4
  %4 = load i32, ptr %2, align 4
  store i32 %4, ptr @x, align 4
  %5 = load i8, ptr %3, align 1
  store i8 %5, ptr @a, align 1
  call void @b()
  %6 = load i8, ptr @a, align 1
  %7 = sext i8 %6 to i32
  %8 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %7)
  %9 = load i32, ptr @x, align 4
  %10 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %9)
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
