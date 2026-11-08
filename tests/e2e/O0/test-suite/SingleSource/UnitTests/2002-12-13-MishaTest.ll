; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2002-12-13-MishaTest.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2002-12-13-MishaTest.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2002-12-13-MishaTest.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [11 x i8] c"Sum is %d\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @sum(ptr noundef %0, ptr noundef %1, i32 noundef %2) #0 {
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca i16, align 2
  %8 = alloca i32, align 4
  %9 = trunc i32 %2 to i16
  store ptr %0, ptr %5, align 8
  store ptr %1, ptr %6, align 8
  store i16 %9, ptr %7, align 2
  store i32 0, ptr %8, align 4
  br label %10

10:                                               ; preds = %25, %3
  %11 = load i32, ptr %8, align 4
  %12 = load i16, ptr %7, align 2
  %13 = sext i16 %12 to i32
  %14 = icmp ne i32 %11, %13
  br i1 %14, label %15, label %28

15:                                               ; preds = %10
  %16 = load ptr, ptr %6, align 8
  %17 = getelementptr inbounds nuw i16, ptr %16, i32 1
  store ptr %17, ptr %6, align 8
  %18 = load i16, ptr %16, align 2
  %19 = sext i16 %18 to i32
  %20 = load ptr, ptr %5, align 8
  %21 = load i16, ptr %20, align 2
  %22 = sext i16 %21 to i32
  %23 = add nsw i32 %22, %19
  %24 = trunc i32 %23 to i16
  store i16 %24, ptr %20, align 2
  br label %25

25:                                               ; preds = %15
  %26 = load i32, ptr %8, align 4
  %27 = add nsw i32 %26, 1
  store i32 %27, ptr %8, align 4
  br label %10, !llvm.loop !5

28:                                               ; preds = %10
  %29 = load i32, ptr %4, align 4
  ret i32 %29
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [2 x i16], align 2
  %3 = alloca i16, align 2
  %4 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store i16 0, ptr %3, align 2
  store i32 0, ptr %4, align 4
  br label %5

5:                                                ; preds = %14, %0
  %6 = load i32, ptr %4, align 4
  %7 = icmp ne i32 %6, 2
  br i1 %7, label %8, label %17

8:                                                ; preds = %5
  %9 = load i32, ptr %4, align 4
  %10 = trunc i32 %9 to i16
  %11 = load i32, ptr %4, align 4
  %12 = sext i32 %11 to i64
  %13 = getelementptr inbounds [2 x i16], ptr %2, i64 0, i64 %12
  store i16 %10, ptr %13, align 2
  br label %14

14:                                               ; preds = %8
  %15 = load i32, ptr %4, align 4
  %16 = add nsw i32 %15, 1
  store i32 %16, ptr %4, align 4
  br label %5, !llvm.loop !7

17:                                               ; preds = %5
  %18 = getelementptr inbounds [2 x i16], ptr %2, i64 0, i64 0
  %19 = call i32 @sum(ptr noundef %3, ptr noundef %18, i32 noundef 2)
  %20 = load i16, ptr %3, align 2
  %21 = sext i16 %20 to i32
  %22 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %21)
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
!7 = distinct !{!7, !6}
