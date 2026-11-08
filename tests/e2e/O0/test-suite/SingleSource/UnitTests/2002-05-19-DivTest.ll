; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2002-05-19-DivTest.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2002-05-19-DivTest.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2002-05-19-DivTest.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local void @testL(i64 noundef %0) #0 {
  %2 = alloca i64, align 8
  store i64 %0, ptr %2, align 8
  %3 = load i64, ptr %2, align 8
  %4 = sdiv i64 %3, 16
  %5 = trunc i64 %4 to i32
  %6 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %5)
  %7 = load i64, ptr %2, align 8
  %8 = sdiv i64 %7, 70368744177664
  %9 = trunc i64 %8 to i32
  %10 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %9)
  ret void
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: noinline nounwind uwtable
define dso_local void @test(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4
  %3 = load i32, ptr %2, align 4
  %4 = sdiv i32 %3, 1
  %5 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %4)
  %6 = load i32, ptr %2, align 4
  %7 = sdiv i32 %6, 16
  %8 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %7)
  %9 = load i32, ptr %2, align 4
  %10 = sdiv i32 %9, 262144
  %11 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %10)
  %12 = load i32, ptr %2, align 4
  %13 = sdiv i32 %12, 1073741824
  %14 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %13)
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i64, align 8
  store i32 0, ptr %1, align 4
  store i32 -1048576, ptr %2, align 4
  store i64 -9007199254740992, ptr %3, align 8
  %4 = load i32, ptr %2, align 4
  %5 = add nsw i32 %4, 32
  call void @test(i32 noundef %5)
  %6 = load i32, ptr %2, align 4
  %7 = add nsw i32 %6, 33
  call void @test(i32 noundef %7)
  %8 = load i64, ptr %3, align 8
  %9 = add nsw i64 %8, 64
  call void @testL(i64 noundef %9)
  %10 = load i64, ptr %3, align 8
  %11 = add nsw i64 %10, 65
  call void @testL(i64 noundef %11)
  ret i32 0
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
