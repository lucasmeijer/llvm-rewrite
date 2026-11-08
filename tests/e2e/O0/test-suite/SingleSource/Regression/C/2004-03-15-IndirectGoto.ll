; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/2004-03-15-IndirectGoto.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/2004-03-15-IndirectGoto.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/2004-03-15-IndirectGoto.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@main.L = internal global [5 x ptr] [ptr blockaddress(@main, %4), ptr blockaddress(@main, %6), ptr blockaddress(@main, %8), ptr blockaddress(@main, %15), ptr null], align 16
@.str = private unnamed_addr constant [3 x i8] c"A\0A\00", align 1
@.str.1 = private unnamed_addr constant [3 x i8] c"B\0A\00", align 1
@.str.2 = private unnamed_addr constant [3 x i8] c"C\0A\00", align 1
@.str.3 = private unnamed_addr constant [3 x i8] c"D\0A\00", align 1
@.str.4 = private unnamed_addr constant [3 x i8] c"E\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store i32 0, ptr %2, align 4
  %3 = call i32 (ptr, ...) @printf(ptr noundef @.str)
  br label %4

4:                                                ; preds = %0, %17
  %5 = call i32 (ptr, ...) @printf(ptr noundef @.str.1)
  br label %6

6:                                                ; preds = %4, %17
  %7 = call i32 (ptr, ...) @printf(ptr noundef @.str.2)
  br label %8

8:                                                ; preds = %6, %17
  %9 = call i32 (ptr, ...) @printf(ptr noundef @.str.3)
  %10 = load i32, ptr %2, align 4
  %11 = add i32 %10, 1
  store i32 %11, ptr %2, align 4
  %12 = zext i32 %10 to i64
  %13 = getelementptr inbounds nuw [5 x ptr], ptr @main.L, i64 0, i64 %12
  %14 = load ptr, ptr %13, align 8
  br label %17

15:                                               ; preds = %17
  %16 = call i32 (ptr, ...) @printf(ptr noundef @.str.4)
  ret i32 0

17:                                               ; preds = %8
  %18 = phi ptr [ %14, %8 ]
  indirectbr ptr %18, [label %4, label %6, label %8, label %15]
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
