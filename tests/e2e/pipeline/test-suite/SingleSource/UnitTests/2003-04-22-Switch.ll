; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2003-04-22-Switch.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2003-04-22-Switch.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2003-04-22-Switch.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [3 x i8] c"C\0A\00", align 1
@.str.1 = private unnamed_addr constant [3 x i8] c"A\0A\00", align 1
@.str.2 = private unnamed_addr constant [3 x i8] c"B\0A\00", align 1
@.str.3 = private unnamed_addr constant [3 x i8] c"D\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  store i32 0, ptr %2, align 4, !tbaa !9
  br label %3

3:                                                ; preds = %9, %0
  %4 = load i32, ptr %2, align 4, !tbaa !9
  %5 = icmp ult i32 %4, 10
  br i1 %5, label %6, label %12

6:                                                ; preds = %3
  %7 = load i32, ptr %2, align 4, !tbaa !9
  %8 = call i32 @func(i32 noundef %7)
  br label %9

9:                                                ; preds = %6
  %10 = load i32, ptr %2, align 4, !tbaa !9
  %11 = add i32 %10, 1
  store i32 %11, ptr %2, align 4, !tbaa !9
  br label %3, !llvm.loop !10

12:                                               ; preds = %3
  call void @llvm.lifetime.end.p0(ptr %2) #3
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define internal i32 @func(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  store i32 %0, ptr %2, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #3
  store i32 4, ptr %3, align 4, !tbaa !9
  %4 = load i32, ptr %2, align 4, !tbaa !9
  switch i32 %4, label %12 [
    i32 8, label %5
    i32 0, label %7
    i32 3, label %7
    i32 2, label %7
    i32 1, label %9
    i32 7, label %9
    i32 9, label %10
  ]

5:                                                ; preds = %1
  %6 = call i32 (ptr, ...) @printf(ptr noundef @.str)
  store i32 6, ptr %3, align 4, !tbaa !9
  br label %7

7:                                                ; preds = %1, %1, %1, %5
  %8 = call i32 (ptr, ...) @printf(ptr noundef @.str.1)
  br label %14

9:                                                ; preds = %1, %1
  store i32 7, ptr %3, align 4, !tbaa !9
  br label %10

10:                                               ; preds = %1, %9
  %11 = call i32 (ptr, ...) @printf(ptr noundef @.str.2)
  br label %14

12:                                               ; preds = %1
  %13 = call i32 (ptr, ...) @printf(ptr noundef @.str.3)
  store i32 1, ptr %3, align 4, !tbaa !9
  br label %14

14:                                               ; preds = %12, %10, %7
  %15 = load i32, ptr %3, align 4, !tbaa !9
  call void @llvm.lifetime.end.p0(ptr %3) #3
  ret i32 %15
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #2

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
