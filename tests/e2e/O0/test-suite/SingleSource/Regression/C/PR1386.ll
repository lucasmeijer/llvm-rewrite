; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/PR1386.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/PR1386.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/PR1386.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.X = type { i128 }

@.str = private unnamed_addr constant [16 x i8] c"bad bits: %llx\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca %struct.X, align 1
  %3 = alloca i64, align 8
  store i32 0, ptr %1, align 4
  %4 = load i128, ptr %2, align 1
  %5 = and i128 %4, -16
  %6 = or i128 %5, 15
  store i128 %6, ptr %2, align 1
  %7 = load i128, ptr %2, align 1
  %8 = and i128 %7, -295147905179352825841
  %9 = or i128 %8, 295147905179352825840
  store i128 %9, ptr %2, align 1
  %10 = load i128, ptr %2, align 1
  %11 = and i128 %10, 295147905179352825855
  %12 = or i128 %11, -295147905179352825856
  store i128 %12, ptr %2, align 1
  %13 = getelementptr inbounds i64, ptr %2, i64 1
  %14 = load i64, ptr %13, align 1
  %15 = xor i64 -1, %14
  store i64 %15, ptr %3, align 8
  %16 = load i64, ptr %3, align 8
  %17 = call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef %16)
  %18 = load i64, ptr %3, align 8
  %19 = icmp ne i64 %18, 0
  %20 = zext i1 %19 to i32
  ret i32 %20
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
