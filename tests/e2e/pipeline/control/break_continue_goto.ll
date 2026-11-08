; @source: tests/e2e/src/control/break_continue_goto.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/control/break_continue_goto.c'
source_filename = "tests/e2e/src/control/break_continue_goto.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1
@.str.1 = private unnamed_addr constant [7 x i8] c"%d %d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  store i32 0, ptr %2, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #3
  store i32 0, ptr %3, align 4, !tbaa !9
  br label %7

7:                                                ; preds = %24, %0
  %8 = load i32, ptr %3, align 4, !tbaa !9
  %9 = icmp slt i32 %8, 100
  br i1 %9, label %11, label %10

10:                                               ; preds = %7
  store i32 2, ptr %4, align 4
  br label %27

11:                                               ; preds = %7
  %12 = load i32, ptr %3, align 4, !tbaa !9
  %13 = srem i32 %12, 3
  %14 = icmp eq i32 %13, 0
  br i1 %14, label %15, label %16

15:                                               ; preds = %11
  br label %24

16:                                               ; preds = %11
  %17 = load i32, ptr %3, align 4, !tbaa !9
  %18 = icmp sgt i32 %17, 50
  br i1 %18, label %19, label %20

19:                                               ; preds = %16
  store i32 2, ptr %4, align 4
  br label %27

20:                                               ; preds = %16
  %21 = load i32, ptr %3, align 4, !tbaa !9
  %22 = load i32, ptr %2, align 4, !tbaa !9
  %23 = add nsw i32 %22, %21
  store i32 %23, ptr %2, align 4, !tbaa !9
  br label %24

24:                                               ; preds = %20, %15
  %25 = load i32, ptr %3, align 4, !tbaa !9
  %26 = add nsw i32 %25, 1
  store i32 %26, ptr %3, align 4, !tbaa !9
  br label %7, !llvm.loop !10

27:                                               ; preds = %19, %10
  call void @llvm.lifetime.end.p0(ptr %3) #3
  br label %28

28:                                               ; preds = %27
  %29 = load i32, ptr %2, align 4, !tbaa !9
  %30 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %29)
  call void @llvm.lifetime.start.p0(ptr %5) #3
  store i32 0, ptr %5, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %6) #3
  store i32 0, ptr %5, align 4, !tbaa !9
  br label %31

31:                                               ; preds = %49, %28
  %32 = load i32, ptr %5, align 4, !tbaa !9
  %33 = icmp slt i32 %32, 10
  br i1 %33, label %34, label %52

34:                                               ; preds = %31
  store i32 0, ptr %6, align 4, !tbaa !9
  br label %35

35:                                               ; preds = %45, %34
  %36 = load i32, ptr %6, align 4, !tbaa !9
  %37 = icmp slt i32 %36, 10
  br i1 %37, label %38, label %48

38:                                               ; preds = %35
  %39 = load i32, ptr %5, align 4, !tbaa !9
  %40 = load i32, ptr %6, align 4, !tbaa !9
  %41 = mul nsw i32 %39, %40
  %42 = icmp eq i32 %41, 42
  br i1 %42, label %43, label %44

43:                                               ; preds = %38
  br label %53

44:                                               ; preds = %38
  br label %45

45:                                               ; preds = %44
  %46 = load i32, ptr %6, align 4, !tbaa !9
  %47 = add nsw i32 %46, 1
  store i32 %47, ptr %6, align 4, !tbaa !9
  br label %35, !llvm.loop !12

48:                                               ; preds = %35
  br label %49

49:                                               ; preds = %48
  %50 = load i32, ptr %5, align 4, !tbaa !9
  %51 = add nsw i32 %50, 1
  store i32 %51, ptr %5, align 4, !tbaa !9
  br label %31, !llvm.loop !13

52:                                               ; preds = %31
  store i32 1, ptr %1, align 4
  store i32 1, ptr %4, align 4
  br label %57

53:                                               ; preds = %43
  %54 = load i32, ptr %5, align 4, !tbaa !9
  %55 = load i32, ptr %6, align 4, !tbaa !9
  %56 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %54, i32 noundef %55)
  store i32 0, ptr %1, align 4
  store i32 1, ptr %4, align 4
  br label %57

57:                                               ; preds = %53, %52
  call void @llvm.lifetime.end.p0(ptr %6) #3
  call void @llvm.lifetime.end.p0(ptr %5) #3
  call void @llvm.lifetime.end.p0(ptr %2) #3
  %58 = load i32, ptr %1, align 4
  ret i32 %58
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

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
!12 = distinct !{!12, !11}
!13 = distinct !{!13, !11}
