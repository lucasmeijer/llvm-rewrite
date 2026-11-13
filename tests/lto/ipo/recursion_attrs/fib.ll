; @source: tests/lto/src/ipo/recursion_attrs/fib.c
; @opt: -passes='lto-pre-link<O2>'
; @generated: clang -O2 -flto -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/lto/src/ipo/recursion_attrs/fib.c'
source_filename = "tests/lto/src/ipo/recursion_attrs/fib.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

; Function Attrs: nounwind uwtable
define dso_local i64 @fib(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4, !tbaa !9
  %3 = load i32, ptr %2, align 4, !tbaa !9
  %4 = icmp slt i32 %3, 2
  br i1 %4, label %5, label %8

5:                                                ; preds = %1
  %6 = load i32, ptr %2, align 4, !tbaa !9
  %7 = sext i32 %6 to i64
  br label %16

8:                                                ; preds = %1
  %9 = load i32, ptr %2, align 4, !tbaa !9
  %10 = sub nsw i32 %9, 1
  %11 = call i64 @fib(i32 noundef %10)
  %12 = load i32, ptr %2, align 4, !tbaa !9
  %13 = sub nsw i32 %12, 2
  %14 = call i64 @fib(i32 noundef %13)
  %15 = add nsw i64 %11, %14
  br label %16

16:                                               ; preds = %8, %5
  %17 = phi i64 [ %7, %5 ], [ %15, %8 ]
  ret i64 %17
}

; Function Attrs: nounwind uwtable
define dso_local i64 @fact(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4, !tbaa !9
  %3 = load i32, ptr %2, align 4, !tbaa !9
  %4 = icmp sle i32 %3, 1
  br i1 %4, label %5, label %6

5:                                                ; preds = %1
  br label %13

6:                                                ; preds = %1
  %7 = load i32, ptr %2, align 4, !tbaa !9
  %8 = sext i32 %7 to i64
  %9 = load i32, ptr %2, align 4, !tbaa !9
  %10 = sub nsw i32 %9, 1
  %11 = call i64 @fact(i32 noundef %10)
  %12 = mul nsw i64 %8, %11
  br label %13

13:                                               ; preds = %6, %5
  %14 = phi i64 [ 1, %5 ], [ %12, %6 ]
  ret i64 %14
}

; Function Attrs: nounwind uwtable
define dso_local i32 @is_odd(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4, !tbaa !9
  %3 = load i32, ptr %2, align 4, !tbaa !9
  %4 = icmp eq i32 %3, 0
  br i1 %4, label %5, label %6

5:                                                ; preds = %1
  br label %10

6:                                                ; preds = %1
  %7 = load i32, ptr %2, align 4, !tbaa !9
  %8 = sub nsw i32 %7, 1
  %9 = call i32 @is_even(i32 noundef %8)
  br label %10

10:                                               ; preds = %6, %5
  %11 = phi i32 [ 0, %5 ], [ %9, %6 ]
  ret i32 %11
}

declare i32 @is_even(i32 noundef) #1

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

!llvm.module.flags = !{!0, !1, !2}
!llvm.ident = !{!3}
!llvm.errno.tbaa = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
!4 = !{!5, !6, i64 0}
!5 = !{!"__libc_errno", !6, i64 0}
!6 = !{!"int", !7, i64 0}
!7 = !{!"omnipotent char", !8, i64 0}
!8 = !{!"Simple C/C++ TBAA"}
!9 = !{!6, !6, i64 0}
