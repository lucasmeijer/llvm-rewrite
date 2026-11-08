; @source: tests/e2e/src/control/switch_dense.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/control/switch_dense.c'
source_filename = "tests/e2e/src/control/switch_dense.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [7 x i8] c"%d %s\0A\00", align 1
@.str.1 = private unnamed_addr constant [5 x i8] c"zero\00", align 1
@.str.2 = private unnamed_addr constant [4 x i8] c"one\00", align 1
@.str.3 = private unnamed_addr constant [4 x i8] c"two\00", align 1
@.str.4 = private unnamed_addr constant [6 x i8] c"three\00", align 1
@.str.5 = private unnamed_addr constant [5 x i8] c"four\00", align 1
@.str.6 = private unnamed_addr constant [5 x i8] c"five\00", align 1
@.str.7 = private unnamed_addr constant [4 x i8] c"six\00", align 1
@.str.8 = private unnamed_addr constant [6 x i8] c"seven\00", align 1
@.str.9 = private unnamed_addr constant [5 x i8] c"many\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  store i32 -1, ptr %2, align 4, !tbaa !9
  br label %3

3:                                                ; preds = %12, %0
  %4 = load i32, ptr %2, align 4, !tbaa !9
  %5 = icmp slt i32 %4, 10
  br i1 %5, label %7, label %6

6:                                                ; preds = %3
  call void @llvm.lifetime.end.p0(ptr %2) #3
  br label %15

7:                                                ; preds = %3
  %8 = load i32, ptr %2, align 4, !tbaa !9
  %9 = load i32, ptr %2, align 4, !tbaa !9
  %10 = call ptr @name(i32 noundef %9)
  %11 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %8, ptr noundef %10)
  br label %12

12:                                               ; preds = %7
  %13 = load i32, ptr %2, align 4, !tbaa !9
  %14 = add nsw i32 %13, 1
  store i32 %14, ptr %2, align 4, !tbaa !9
  br label %3, !llvm.loop !10

15:                                               ; preds = %6
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nounwind uwtable
define internal ptr @name(i32 noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !9
  %4 = load i32, ptr %3, align 4, !tbaa !9
  switch i32 %4, label %13 [
    i32 0, label %5
    i32 1, label %6
    i32 2, label %7
    i32 3, label %8
    i32 4, label %9
    i32 5, label %10
    i32 6, label %11
    i32 7, label %12
  ]

5:                                                ; preds = %1
  store ptr @.str.1, ptr %2, align 8
  br label %14

6:                                                ; preds = %1
  store ptr @.str.2, ptr %2, align 8
  br label %14

7:                                                ; preds = %1
  store ptr @.str.3, ptr %2, align 8
  br label %14

8:                                                ; preds = %1
  store ptr @.str.4, ptr %2, align 8
  br label %14

9:                                                ; preds = %1
  store ptr @.str.5, ptr %2, align 8
  br label %14

10:                                               ; preds = %1
  store ptr @.str.6, ptr %2, align 8
  br label %14

11:                                               ; preds = %1
  store ptr @.str.7, ptr %2, align 8
  br label %14

12:                                               ; preds = %1
  store ptr @.str.8, ptr %2, align 8
  br label %14

13:                                               ; preds = %1
  store ptr @.str.9, ptr %2, align 8
  br label %14

14:                                               ; preds = %13, %12, %11, %10, %9, %8, %7, %6, %5
  %15 = load ptr, ptr %2, align 8
  ret ptr %15
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind }

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
!10 = distinct !{!10, !11}
!11 = !{!"llvm.loop.mustprogress"}
