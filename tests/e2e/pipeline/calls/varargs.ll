; @source: tests/e2e/src/calls/varargs.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/calls/varargs.c'
source_filename = "tests/e2e/src/calls/varargs.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.__va_list_tag = type { i32, i32, ptr, ptr }

@.str = private unnamed_addr constant [5 x i8] c"%ld\0A\00", align 1
@.str.1 = private unnamed_addr constant [6 x i8] c"%.3f\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  %2 = call i64 (i32, ...) @sum(i32 noundef 10, i32 noundef 1, i32 noundef 2, i32 noundef 3, i32 noundef 4, i32 noundef 5, i32 noundef 6, i32 noundef 7, i32 noundef 8, i32 noundef 9, i32 noundef 10)
  %3 = call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef %2)
  %4 = call double (i32, ...) @mixed(i32 noundef 8, i64 noundef 1, double noundef 5.000000e-01, i64 noundef 2, double noundef 2.500000e-01, i64 noundef 3, double noundef 1.250000e-01, i64 noundef 4, double noundef 1.000000e+10)
  %5 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, double noundef %4)
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: nounwind uwtable
define internal i64 @sum(i32 noundef %0, ...) #0 {
  %2 = alloca i32, align 4
  %3 = alloca [1 x %struct.__va_list_tag], align 16
  %4 = alloca i64, align 8
  %5 = alloca i32, align 4
  store i32 %0, ptr %2, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #4
  %6 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_start.p0(ptr %6)
  call void @llvm.lifetime.start.p0(ptr %4) #4
  store i64 0, ptr %4, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %5) #4
  store i32 0, ptr %5, align 4, !tbaa !9
  br label %7

7:                                                ; preds = %32, %1
  %8 = load i32, ptr %5, align 4, !tbaa !9
  %9 = load i32, ptr %2, align 4, !tbaa !9
  %10 = icmp slt i32 %8, %9
  br i1 %10, label %12, label %11

11:                                               ; preds = %7
  call void @llvm.lifetime.end.p0(ptr %5) #4
  br label %35

12:                                               ; preds = %7
  %13 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %14 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %13, i32 0, i32 0
  %15 = load i32, ptr %14, align 16
  %16 = icmp ule i32 %15, 40
  br i1 %16, label %17, label %22

17:                                               ; preds = %12
  %18 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %13, i32 0, i32 3
  %19 = load ptr, ptr %18, align 16
  %20 = getelementptr i8, ptr %19, i32 %15
  %21 = add i32 %15, 8
  store i32 %21, ptr %14, align 16
  br label %26

22:                                               ; preds = %12
  %23 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %13, i32 0, i32 2
  %24 = load ptr, ptr %23, align 8
  %25 = getelementptr i8, ptr %24, i32 8
  store ptr %25, ptr %23, align 8
  br label %26

26:                                               ; preds = %22, %17
  %27 = phi ptr [ %20, %17 ], [ %24, %22 ]
  %28 = load i32, ptr %27, align 4, !tbaa !9
  %29 = sext i32 %28 to i64
  %30 = load i64, ptr %4, align 8, !tbaa !10
  %31 = add nsw i64 %30, %29
  store i64 %31, ptr %4, align 8, !tbaa !10
  br label %32

32:                                               ; preds = %26
  %33 = load i32, ptr %5, align 4, !tbaa !9
  %34 = add nsw i32 %33, 1
  store i32 %34, ptr %5, align 4, !tbaa !9
  br label %7, !llvm.loop !12

35:                                               ; preds = %11
  %36 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_end.p0(ptr %36)
  %37 = load i64, ptr %4, align 8, !tbaa !10
  call void @llvm.lifetime.end.p0(ptr %4) #4
  call void @llvm.lifetime.end.p0(ptr %3) #4
  ret i64 %37
}

; Function Attrs: nounwind uwtable
define internal double @mixed(i32 noundef %0, ...) #0 {
  %2 = alloca i32, align 4
  %3 = alloca [1 x %struct.__va_list_tag], align 16
  %4 = alloca double, align 8
  %5 = alloca i32, align 4
  store i32 %0, ptr %2, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #4
  %6 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_start.p0(ptr %6)
  call void @llvm.lifetime.start.p0(ptr %4) #4
  store double 0.000000e+00, ptr %4, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %5) #4
  store i32 0, ptr %5, align 4, !tbaa !9
  br label %7

7:                                                ; preds = %56, %1
  %8 = load i32, ptr %5, align 4, !tbaa !9
  %9 = load i32, ptr %2, align 4, !tbaa !9
  %10 = icmp slt i32 %8, %9
  br i1 %10, label %12, label %11

11:                                               ; preds = %7
  call void @llvm.lifetime.end.p0(ptr %5) #4
  br label %59

12:                                               ; preds = %7
  %13 = load i32, ptr %5, align 4, !tbaa !9
  %14 = srem i32 %13, 2
  %15 = icmp ne i32 %14, 0
  br i1 %15, label %16, label %35

16:                                               ; preds = %12
  %17 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %18 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %17, i32 0, i32 1
  %19 = load i32, ptr %18, align 4
  %20 = icmp ule i32 %19, 160
  br i1 %20, label %21, label %26

21:                                               ; preds = %16
  %22 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %17, i32 0, i32 3
  %23 = load ptr, ptr %22, align 16
  %24 = getelementptr i8, ptr %23, i32 %19
  %25 = add i32 %19, 16
  store i32 %25, ptr %18, align 4
  br label %30

26:                                               ; preds = %16
  %27 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %17, i32 0, i32 2
  %28 = load ptr, ptr %27, align 8
  %29 = getelementptr i8, ptr %28, i32 8
  store ptr %29, ptr %27, align 8
  br label %30

30:                                               ; preds = %26, %21
  %31 = phi ptr [ %24, %21 ], [ %28, %26 ]
  %32 = load double, ptr %31, align 8, !tbaa !14
  %33 = load double, ptr %4, align 8, !tbaa !14
  %34 = fadd double %33, %32
  store double %34, ptr %4, align 8, !tbaa !14
  br label %55

35:                                               ; preds = %12
  %36 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %37 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %36, i32 0, i32 0
  %38 = load i32, ptr %37, align 16
  %39 = icmp ule i32 %38, 40
  br i1 %39, label %40, label %45

40:                                               ; preds = %35
  %41 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %36, i32 0, i32 3
  %42 = load ptr, ptr %41, align 16
  %43 = getelementptr i8, ptr %42, i32 %38
  %44 = add i32 %38, 8
  store i32 %44, ptr %37, align 16
  br label %49

45:                                               ; preds = %35
  %46 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %36, i32 0, i32 2
  %47 = load ptr, ptr %46, align 8
  %48 = getelementptr i8, ptr %47, i32 8
  store ptr %48, ptr %46, align 8
  br label %49

49:                                               ; preds = %45, %40
  %50 = phi ptr [ %43, %40 ], [ %47, %45 ]
  %51 = load i64, ptr %50, align 8, !tbaa !10
  %52 = sitofp i64 %51 to double
  %53 = load double, ptr %4, align 8, !tbaa !14
  %54 = fadd double %53, %52
  store double %54, ptr %4, align 8, !tbaa !14
  br label %55

55:                                               ; preds = %49, %30
  br label %56

56:                                               ; preds = %55
  %57 = load i32, ptr %5, align 4, !tbaa !9
  %58 = add nsw i32 %57, 1
  store i32 %58, ptr %5, align 4, !tbaa !9
  br label %7, !llvm.loop !16

59:                                               ; preds = %11
  %60 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_end.p0(ptr %60)
  %61 = load double, ptr %4, align 8, !tbaa !14
  call void @llvm.lifetime.end.p0(ptr %4) #4
  call void @llvm.lifetime.end.p0(ptr %3) #4
  ret double %61
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare void @llvm.va_start.p0(ptr) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare void @llvm.va_end.p0(ptr) #3

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #3 = { nocallback nofree nosync nounwind willreturn }
attributes #4 = { nounwind }

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
!12 = distinct !{!12, !13}
!13 = !{!"llvm.loop.mustprogress"}
!14 = !{!15, !15, i64 0}
!15 = !{!"double", !7, i64 0}
!16 = distinct !{!16, !13}
