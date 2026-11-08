; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2008-04-20-LoopBug2.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2008-04-20-LoopBug2.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2008-04-20-LoopBug2.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [16 x i8] c"%d %d %d %d %d\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local void @foo(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  store i32 %0, ptr %3, align 4
  store ptr %1, ptr %4, align 8
  store i32 3, ptr %5, align 4
  br label %6

6:                                                ; preds = %19, %2
  %7 = load ptr, ptr %4, align 8
  %8 = load i32, ptr %5, align 4
  %9 = sub i32 %8, 1
  %10 = zext i32 %9 to i64
  %11 = getelementptr inbounds nuw i32, ptr %7, i64 %10
  %12 = load i32, ptr %11, align 4
  %13 = load ptr, ptr %4, align 8
  %14 = load i32, ptr %5, align 4
  %15 = zext i32 %14 to i64
  %16 = getelementptr inbounds nuw i32, ptr %13, i64 %15
  store i32 %12, ptr %16, align 4
  %17 = load i32, ptr %5, align 4
  %18 = add i32 %17, -1
  store i32 %18, ptr %5, align 4
  br label %19

19:                                               ; preds = %6
  %20 = load i32, ptr %5, align 4
  %21 = load i32, ptr %3, align 4
  %22 = icmp ugt i32 %20, %21
  br i1 %22, label %6, label %23, !llvm.loop !5

23:                                               ; preds = %19
  %24 = load i32, ptr %3, align 4
  %25 = load ptr, ptr %4, align 8
  %26 = getelementptr inbounds i32, ptr %25, i64 0
  %27 = load i32, ptr %26, align 4
  %28 = load ptr, ptr %4, align 8
  %29 = getelementptr inbounds i32, ptr %28, i64 1
  %30 = load i32, ptr %29, align 4
  %31 = load ptr, ptr %4, align 8
  %32 = getelementptr inbounds i32, ptr %31, i64 2
  %33 = load i32, ptr %32, align 4
  %34 = load ptr, ptr %4, align 8
  %35 = getelementptr inbounds i32, ptr %34, i64 3
  %36 = load i32, ptr %35, align 4
  %37 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %24, i32 noundef %27, i32 noundef %30, i32 noundef %33, i32 noundef %36)
  ret void
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [4 x i32], align 16
  %3 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store i32 0, ptr %3, align 4
  br label %4

4:                                                ; preds = %14, %0
  %5 = load i32, ptr %3, align 4
  %6 = icmp slt i32 %5, 5
  br i1 %6, label %7, label %17

7:                                                ; preds = %4
  %8 = getelementptr inbounds [4 x i32], ptr %2, i64 0, i64 0
  store i32 5, ptr %8, align 16
  %9 = getelementptr inbounds [4 x i32], ptr %2, i64 0, i64 1
  store i32 6, ptr %9, align 4
  %10 = getelementptr inbounds [4 x i32], ptr %2, i64 0, i64 2
  store i32 7, ptr %10, align 8
  %11 = getelementptr inbounds [4 x i32], ptr %2, i64 0, i64 3
  store i32 8, ptr %11, align 4
  %12 = load i32, ptr %3, align 4
  %13 = getelementptr inbounds [4 x i32], ptr %2, i64 0, i64 0
  call void @foo(i32 noundef %12, ptr noundef %13)
  br label %14

14:                                               ; preds = %7
  %15 = load i32, ptr %3, align 4
  %16 = add nsw i32 %15, 1
  store i32 %16, ptr %3, align 4
  br label %4, !llvm.loop !7

17:                                               ; preds = %4
  %18 = getelementptr inbounds [4 x i32], ptr %2, i64 0, i64 0
  store i32 5, ptr %18, align 16
  %19 = getelementptr inbounds [4 x i32], ptr %2, i64 0, i64 1
  store i32 6, ptr %19, align 4
  %20 = getelementptr inbounds [4 x i32], ptr %2, i64 0, i64 2
  store i32 7, ptr %20, align 8
  %21 = getelementptr inbounds [4 x i32], ptr %2, i64 0, i64 3
  store i32 8, ptr %21, align 4
  %22 = getelementptr inbounds [4 x i32], ptr %2, i64 0, i64 0
  call void @foo(i32 noundef -1, ptr noundef %22)
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
!7 = distinct !{!7, !6}
