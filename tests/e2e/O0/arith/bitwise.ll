; @source: tests/e2e/src/arith/bitwise.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/arith/bitwise.c'
source_filename = "tests/e2e/src/arith/bitwise.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [21 x i8] c"%08x %08x %08x %08x\0A\00", align 1
@.str.1 = private unnamed_addr constant [17 x i8] c"%016llx %016llx\0A\00", align 1
@.str.2 = private unnamed_addr constant [7 x i8] c"%d %d\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i64, align 8
  %5 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store i32 -252664411, ptr %2, align 4
  store i32 267391540, ptr %3, align 4
  %6 = load i32, ptr %2, align 4
  %7 = load i32, ptr %3, align 4
  %8 = and i32 %6, %7
  %9 = load i32, ptr %2, align 4
  %10 = load i32, ptr %3, align 4
  %11 = or i32 %9, %10
  %12 = load i32, ptr %2, align 4
  %13 = load i32, ptr %3, align 4
  %14 = xor i32 %12, %13
  %15 = load i32, ptr %2, align 4
  %16 = xor i32 %15, -1
  %17 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %8, i32 noundef %11, i32 noundef %14, i32 noundef %16)
  store i64 1311768467463790320, ptr %4, align 8
  %18 = load i64, ptr %4, align 8
  %19 = and i64 %18, -256
  %20 = load i64, ptr %4, align 8
  %21 = load i64, ptr %4, align 8
  %22 = lshr i64 %21, 17
  %23 = xor i64 %20, %22
  %24 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i64 noundef %19, i64 noundef %23)
  store i32 -1, ptr %5, align 4
  %25 = load i32, ptr %5, align 4
  %26 = and i32 %25, 127
  %27 = load i32, ptr %5, align 4
  %28 = xor i32 %27, 85
  %29 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i32 noundef %26, i32 noundef %28)
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
