; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/AtomicOps.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/AtomicOps.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/AtomicOps.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@x = dso_local global i32 0, align 4
@.str = private unnamed_addr constant [8 x i8] c"%d, %d\0A\00", align 1
@.str.1 = private unnamed_addr constant [11 x i8] c"test = %d\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @foo(ptr noundef %0, i32 noundef %1, i32 noundef %2) #0 {
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  store ptr %0, ptr %4, align 8
  store i32 %1, ptr %5, align 4
  store i32 %2, ptr %6, align 4
  %8 = load ptr, ptr %4, align 8
  %9 = load i32, ptr %5, align 4
  %10 = atomicrmw add ptr %8, i32 %9 seq_cst, align 4
  store i32 %10, ptr %7, align 4
  %11 = load i32, ptr %7, align 4
  %12 = load i32, ptr %6, align 4
  %13 = add nsw i32 %11, %12
  ret i32 %13
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i64, align 8
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store i64 0, ptr %2, align 8
  %5 = call i32 @foo(ptr noundef @x, i32 noundef 1, i32 noundef 2)
  store i32 %5, ptr %4, align 4
  %6 = load i32, ptr %4, align 4
  %7 = load volatile i32, ptr @x, align 4
  %8 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %6, i32 noundef %7)
  %9 = cmpxchg ptr @x, i32 1, i32 2 seq_cst seq_cst, align 4
  %10 = extractvalue { i32, i1 } %9, 0
  store i32 %10, ptr %4, align 4
  %11 = load i32, ptr %4, align 4
  %12 = load volatile i32, ptr @x, align 4
  %13 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %11, i32 noundef %12)
  %14 = atomicrmw xchg ptr @x, i32 1 seq_cst, align 4
  store i32 %14, ptr %4, align 4
  %15 = load i32, ptr %4, align 4
  %16 = load volatile i32, ptr @x, align 4
  %17 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %15, i32 noundef %16)
  store i32 0, ptr %3, align 4
  br label %18

18:                                               ; preds = %27, %0
  %19 = load i32, ptr %3, align 4
  %20 = icmp slt i32 %19, 5
  br i1 %20, label %21, label %30

21:                                               ; preds = %18
  %22 = atomicrmw add ptr %2, i64 1 seq_cst, align 8
  %23 = add i64 %22, 1
  %24 = load i64, ptr %2, align 8
  %25 = trunc i64 %24 to i32
  %26 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %25)
  br label %27

27:                                               ; preds = %21
  %28 = load i32, ptr %3, align 4
  %29 = add nsw i32 %28, 1
  store i32 %29, ptr %3, align 4
  br label %18, !llvm.loop !5

30:                                               ; preds = %18
  store i32 0, ptr %3, align 4
  br label %31

31:                                               ; preds = %39, %30
  %32 = load i32, ptr %3, align 4
  %33 = icmp slt i32 %32, 5
  br i1 %33, label %34, label %42

34:                                               ; preds = %31
  %35 = atomicrmw sub ptr %2, i64 1 seq_cst, align 8
  %36 = load i64, ptr %2, align 8
  %37 = trunc i64 %36 to i32
  %38 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %37)
  br label %39

39:                                               ; preds = %34
  %40 = load i32, ptr %3, align 4
  %41 = add nsw i32 %40, 1
  store i32 %41, ptr %3, align 4
  br label %31, !llvm.loop !7

42:                                               ; preds = %31
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
