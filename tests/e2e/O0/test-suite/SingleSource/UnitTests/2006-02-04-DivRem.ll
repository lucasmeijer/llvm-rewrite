; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2006-02-04-DivRem.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2006-02-04-DivRem.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2006-02-04-DivRem.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [13 x i8] c"%u %u %u %u\0A\00", align 1
@i = dso_local global i32 0, align 4

; Function Attrs: noinline nounwind uwtable
define dso_local void @test(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 %0, ptr %3, align 4
  store i32 %1, ptr %4, align 4
  %5 = load i32, ptr %3, align 4
  %6 = load i32, ptr %4, align 4
  %7 = load i32, ptr %3, align 4
  %8 = load i32, ptr %4, align 4
  %9 = and i32 %8, 15
  %10 = shl i32 8, %9
  %11 = udiv i32 %7, %10
  %12 = load i32, ptr %3, align 4
  %13 = load i32, ptr %4, align 4
  %14 = and i32 %13, 15
  %15 = shl i32 8, %14
  %16 = urem i32 %12, %15
  %17 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %5, i32 noundef %6, i32 noundef %11, i32 noundef %16)
  ret void
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i64, align 8
  store i32 0, ptr %1, align 4
  store i32 10, ptr @i, align 4
  br label %3

3:                                                ; preds = %12, %0
  %4 = load i32, ptr @i, align 4
  %5 = icmp slt i32 %4, 139045193
  br i1 %5, label %6, label %15

6:                                                ; preds = %3
  %7 = load i32, ptr @i, align 4
  %8 = load i32, ptr @i, align 4
  %9 = xor i32 %8, 12345
  call void @test(i32 noundef %7, i32 noundef %9)
  %10 = load i32, ptr @i, align 4
  %11 = add nsw i32 %10, 1
  store i32 %11, ptr @i, align 4
  br label %12

12:                                               ; preds = %6
  %13 = load i32, ptr @i, align 4
  %14 = mul nsw i32 %13, -3
  store i32 %14, ptr @i, align 4
  br label %3, !llvm.loop !5

15:                                               ; preds = %3
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
!5 = distinct !{!5, !6}
!6 = !{!"llvm.loop.mustprogress"}
