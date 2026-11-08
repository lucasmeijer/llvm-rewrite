; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2003-05-02-DependentPHI.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2003-05-02-DependentPHI.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2003-05-02-DependentPHI.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.List = type { ptr, i32 }

@Node0 = dso_local global { ptr, i32, [4 x i8] } { ptr null, i32 5, [4 x i8] zeroinitializer }, align 8
@Node1 = dso_local global { ptr, i32, [4 x i8] } { ptr @Node0, i32 4, [4 x i8] zeroinitializer }, align 8
@Node2 = dso_local global { ptr, i32, [4 x i8] } { ptr @Node1, i32 3, [4 x i8] zeroinitializer }, align 8
@Node3 = dso_local global { ptr, i32, [4 x i8] } { ptr @Node2, i32 2, [4 x i8] zeroinitializer }, align 8
@Node4 = dso_local global { ptr, i32, [4 x i8] } { ptr @Node3, i32 1, [4 x i8] zeroinitializer }, align 8
@Node5 = dso_local global { ptr, i32, [4 x i8] } { ptr @Node4, i32 0, [4 x i8] zeroinitializer }, align 8
@.str = private unnamed_addr constant [7 x i8] c"%d %d\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca ptr, align 8
  %3 = alloca ptr, align 8
  store i32 0, ptr %1, align 4
  store ptr null, ptr %2, align 8
  store ptr @Node5, ptr %3, align 8
  br label %4

4:                                                ; preds = %21, %0
  %5 = load ptr, ptr %3, align 8
  %6 = icmp ne ptr %5, null
  br i1 %6, label %7, label %26

7:                                                ; preds = %4
  %8 = load ptr, ptr %3, align 8
  %9 = getelementptr inbounds nuw %struct.List, ptr %8, i32 0, i32 1
  %10 = load i32, ptr %9, align 8
  %11 = load ptr, ptr %2, align 8
  %12 = icmp ne ptr %11, null
  br i1 %12, label %13, label %17

13:                                               ; preds = %7
  %14 = load ptr, ptr %2, align 8
  %15 = getelementptr inbounds nuw %struct.List, ptr %14, i32 0, i32 1
  %16 = load i32, ptr %15, align 8
  br label %18

17:                                               ; preds = %7
  br label %18

18:                                               ; preds = %17, %13
  %19 = phi i32 [ %16, %13 ], [ -1, %17 ]
  %20 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %10, i32 noundef %19)
  br label %21

21:                                               ; preds = %18
  %22 = load ptr, ptr %3, align 8
  store ptr %22, ptr %2, align 8
  %23 = load ptr, ptr %3, align 8
  %24 = getelementptr inbounds nuw %struct.List, ptr %23, i32 0, i32 0
  %25 = load ptr, ptr %24, align 8
  store ptr %25, ptr %3, align 8
  br label %4, !llvm.loop !5

26:                                               ; preds = %4
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
