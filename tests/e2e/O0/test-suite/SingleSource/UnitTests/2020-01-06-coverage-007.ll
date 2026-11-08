; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-007.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-007.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-007.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@b = dso_local constant i32 -1, align 4
@a = dso_local global i32 0, align 4
@c = dso_local constant i32 0, align 4
@d = dso_local global i16 0, align 2
@.str = private unnamed_addr constant [8 x i8] c"a = %u\0A\00", align 1
@.str.1 = private unnamed_addr constant [8 x i8] c"b = %u\0A\00", align 1
@.str.2 = private unnamed_addr constant [8 x i8] c"c = %u\0A\00", align 1
@.str.3 = private unnamed_addr constant [9 x i8] c"d = %hi\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local void @e() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = load i32, ptr @a, align 4
  %4 = udiv i32 -1, %3
  store i32 %4, ptr %1, align 4
  %5 = load i32, ptr %1, align 4
  store i32 %5, ptr %2, align 4
  %6 = load i32, ptr %2, align 4
  %7 = load i32, ptr @c, align 4
  %8 = icmp ult i32 %6, %7
  %9 = zext i1 %8 to i32
  %10 = trunc i32 %9 to i16
  store i16 %10, ptr @d, align 2
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i16, align 2
  %3 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store i32 3, ptr %3, align 4
  store i16 -32767, ptr %2, align 2
  %4 = load i16, ptr %2, align 2
  store i16 %4, ptr @d, align 2
  %5 = load i32, ptr %3, align 4
  store i32 %5, ptr @a, align 4
  call void @e()
  %6 = load i32, ptr @a, align 4
  %7 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %6)
  %8 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef -1)
  %9 = load i32, ptr @c, align 4
  %10 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i32 noundef %9)
  %11 = load i16, ptr @d, align 2
  %12 = sext i16 %11 to i32
  %13 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i32 noundef %12)
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
