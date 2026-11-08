; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/testcase-Expr-1.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/testcase-Expr-1.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/testcase-Expr-1.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@arr = dso_local global [3 x i32] [i32 0, i32 1, i32 2], align 4
@.str = private unnamed_addr constant [3 x i8] c"%d\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  %2 = load i32, ptr getelementptr inbounds nuw (i8, ptr @arr, i64 4), align 4
  %3 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %2)
  %4 = load i32, ptr getelementptr inbounds nuw (i8, ptr @arr, i64 4), align 4
  %5 = icmp ne i32 %4, -5
  br i1 %5, label %6, label %7

6:                                                ; preds = %0
  store i32 2, ptr %1, align 4
  br label %12

7:                                                ; preds = %0
  %8 = load i32, ptr getelementptr inbounds nuw (i8, ptr @arr, i64 8), align 4
  %9 = icmp ne i32 %8, 2
  br i1 %9, label %10, label %11

10:                                               ; preds = %7
  store i32 3, ptr %1, align 4
  br label %12

11:                                               ; preds = %7
  store i32 0, ptr %1, align 4
  br label %12

12:                                               ; preds = %11, %10, %6
  %13 = load i32, ptr %1, align 4
  ret i32 %13
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
