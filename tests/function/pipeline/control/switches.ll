; @source: tests/function/src/control/switches.c
; @opt: -O2
; @llc: -O2
; @driver: tests/function/src/control/switches.driver.c
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/function/src/control/switches.c'
source_filename = "tests/function/src/control/switches.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [6 x i8] c"digit\00", align 1
@.str.1 = private unnamed_addr constant [6 x i8] c"lower\00", align 1
@.str.2 = private unnamed_addr constant [6 x i8] c"upper\00", align 1
@.str.3 = private unnamed_addr constant [6 x i8] c"space\00", align 1
@.str.4 = private unnamed_addr constant [6 x i8] c"other\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @dense(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !9
  %4 = load i32, ptr %3, align 4, !tbaa !9
  switch i32 %4, label %14 [
    i32 0, label %5
    i32 1, label %6
    i32 2, label %7
    i32 3, label %8
    i32 4, label %9
    i32 5, label %10
    i32 6, label %11
    i32 7, label %12
    i32 9, label %13
  ]

5:                                                ; preds = %1
  store i32 10, ptr %2, align 4
  br label %15

6:                                                ; preds = %1
  store i32 11, ptr %2, align 4
  br label %15

7:                                                ; preds = %1
  store i32 13, ptr %2, align 4
  br label %15

8:                                                ; preds = %1
  store i32 17, ptr %2, align 4
  br label %15

9:                                                ; preds = %1
  store i32 19, ptr %2, align 4
  br label %15

10:                                               ; preds = %1
  store i32 23, ptr %2, align 4
  br label %15

11:                                               ; preds = %1
  store i32 29, ptr %2, align 4
  br label %15

12:                                               ; preds = %1
  store i32 31, ptr %2, align 4
  br label %15

13:                                               ; preds = %1
  store i32 37, ptr %2, align 4
  br label %15

14:                                               ; preds = %1
  store i32 -1, ptr %2, align 4
  br label %15

15:                                               ; preds = %14, %13, %12, %11, %10, %9, %8, %7, %6, %5
  %16 = load i32, ptr %2, align 4
  ret i32 %16
}

; Function Attrs: nounwind uwtable
define dso_local i32 @sparse(i64 noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca i64, align 8
  store i64 %0, ptr %3, align 8, !tbaa !10
  %4 = load i64, ptr %3, align 8, !tbaa !10
  switch i64 %4, label %11 [
    i64 -5000000000, label %5
    i64 -1, label %6
    i64 100, label %7
    i64 101, label %8
    i64 4096, label %9
    i64 1099511627776, label %10
  ]

5:                                                ; preds = %1
  store i32 1, ptr %2, align 4
  br label %12

6:                                                ; preds = %1
  store i32 2, ptr %2, align 4
  br label %12

7:                                                ; preds = %1
  store i32 3, ptr %2, align 4
  br label %12

8:                                                ; preds = %1
  store i32 4, ptr %2, align 4
  br label %12

9:                                                ; preds = %1
  store i32 5, ptr %2, align 4
  br label %12

10:                                               ; preds = %1
  store i32 6, ptr %2, align 4
  br label %12

11:                                               ; preds = %1
  store i32 0, ptr %2, align 4
  br label %12

12:                                               ; preds = %11, %10, %9, %8, %7, %6, %5
  %13 = load i32, ptr %2, align 4
  ret i32 %13
}

; Function Attrs: nounwind uwtable
define dso_local ptr @ranges(i8 noundef zeroext %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca i8, align 1
  store i8 %0, ptr %3, align 1, !tbaa !12
  %4 = load i8, ptr %3, align 1, !tbaa !12
  %5 = zext i8 %4 to i32
  switch i32 %5, label %10 [
    i32 48, label %6
    i32 49, label %6
    i32 50, label %6
    i32 51, label %6
    i32 52, label %6
    i32 53, label %6
    i32 54, label %6
    i32 55, label %6
    i32 56, label %6
    i32 57, label %6
    i32 97, label %7
    i32 98, label %7
    i32 99, label %7
    i32 100, label %7
    i32 101, label %7
    i32 102, label %7
    i32 103, label %7
    i32 104, label %7
    i32 105, label %7
    i32 106, label %7
    i32 107, label %7
    i32 108, label %7
    i32 109, label %7
    i32 110, label %7
    i32 111, label %7
    i32 112, label %7
    i32 113, label %7
    i32 114, label %7
    i32 115, label %7
    i32 116, label %7
    i32 117, label %7
    i32 118, label %7
    i32 119, label %7
    i32 120, label %7
    i32 121, label %7
    i32 122, label %7
    i32 65, label %8
    i32 66, label %8
    i32 67, label %8
    i32 68, label %8
    i32 69, label %8
    i32 70, label %8
    i32 71, label %8
    i32 72, label %8
    i32 73, label %8
    i32 74, label %8
    i32 75, label %8
    i32 76, label %8
    i32 77, label %8
    i32 78, label %8
    i32 79, label %8
    i32 80, label %8
    i32 81, label %8
    i32 82, label %8
    i32 83, label %8
    i32 84, label %8
    i32 85, label %8
    i32 86, label %8
    i32 87, label %8
    i32 88, label %8
    i32 89, label %8
    i32 90, label %8
    i32 32, label %9
    i32 9, label %9
    i32 10, label %9
  ]

6:                                                ; preds = %1, %1, %1, %1, %1, %1, %1, %1, %1, %1
  store ptr @.str, ptr %2, align 8
  br label %11

7:                                                ; preds = %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1
  store ptr @.str.1, ptr %2, align 8
  br label %11

8:                                                ; preds = %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1, %1
  store ptr @.str.2, ptr %2, align 8
  br label %11

9:                                                ; preds = %1, %1, %1
  store ptr @.str.3, ptr %2, align 8
  br label %11

10:                                               ; preds = %1
  store ptr @.str.4, ptr %2, align 8
  br label %11

11:                                               ; preds = %10, %9, %8, %7, %6
  %12 = load ptr, ptr %2, align 8
  ret ptr %12
}

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

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
!10 = !{!11, !11, i64 0}
!11 = !{!"long", !7, i64 0}
!12 = !{!7, !7, i64 0}
