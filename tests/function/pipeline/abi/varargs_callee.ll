; @source: tests/function/src/abi/varargs_callee.c
; @opt: -O2
; @llc: -O2
; @driver: tests/function/src/abi/varargs_callee.driver.c
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/function/src/abi/varargs_callee.c'
source_filename = "tests/function/src/abi/varargs_callee.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.__va_list_tag = type { i32, i32, ptr, ptr }

; Function Attrs: nounwind uwtable
define dso_local double @vsum(ptr noundef %0, ...) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca [1 x %struct.__va_list_tag], align 16
  %4 = alloca double, align 8
  %5 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #4
  %6 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_start.p0(ptr %6)
  call void @llvm.lifetime.start.p0(ptr %4) #4
  store double 0.000000e+00, ptr %4, align 8, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %5) #4
  %7 = load ptr, ptr %2, align 8, !tbaa !9
  store ptr %7, ptr %5, align 8, !tbaa !9
  br label %8

8:                                                ; preds = %98, %1
  %9 = load ptr, ptr %5, align 8, !tbaa !9
  %10 = load i8, ptr %9, align 1, !tbaa !14
  %11 = icmp ne i8 %10, 0
  br i1 %11, label %13, label %12

12:                                               ; preds = %8
  call void @llvm.lifetime.end.p0(ptr %5) #4
  br label %101

13:                                               ; preds = %8
  %14 = load ptr, ptr %5, align 8, !tbaa !9
  %15 = load i8, ptr %14, align 1, !tbaa !14
  %16 = sext i8 %15 to i32
  switch i32 %16, label %97 [
    i32 105, label %17
    i32 108, label %37
    i32 100, label %57
    i32 112, label %76
  ]

17:                                               ; preds = %13
  %18 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %19 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %18, i32 0, i32 0
  %20 = load i32, ptr %19, align 16
  %21 = icmp ule i32 %20, 40
  br i1 %21, label %22, label %27

22:                                               ; preds = %17
  %23 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %18, i32 0, i32 3
  %24 = load ptr, ptr %23, align 16
  %25 = getelementptr i8, ptr %24, i32 %20
  %26 = add i32 %20, 8
  store i32 %26, ptr %19, align 16
  br label %31

27:                                               ; preds = %17
  %28 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %18, i32 0, i32 2
  %29 = load ptr, ptr %28, align 8
  %30 = getelementptr i8, ptr %29, i32 8
  store ptr %30, ptr %28, align 8
  br label %31

31:                                               ; preds = %27, %22
  %32 = phi ptr [ %25, %22 ], [ %29, %27 ]
  %33 = load i32, ptr %32, align 4, !tbaa !15
  %34 = sitofp i32 %33 to double
  %35 = load double, ptr %4, align 8, !tbaa !12
  %36 = fadd double %35, %34
  store double %36, ptr %4, align 8, !tbaa !12
  br label %97

37:                                               ; preds = %13
  %38 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %39 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %38, i32 0, i32 0
  %40 = load i32, ptr %39, align 16
  %41 = icmp ule i32 %40, 40
  br i1 %41, label %42, label %47

42:                                               ; preds = %37
  %43 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %38, i32 0, i32 3
  %44 = load ptr, ptr %43, align 16
  %45 = getelementptr i8, ptr %44, i32 %40
  %46 = add i32 %40, 8
  store i32 %46, ptr %39, align 16
  br label %51

47:                                               ; preds = %37
  %48 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %38, i32 0, i32 2
  %49 = load ptr, ptr %48, align 8
  %50 = getelementptr i8, ptr %49, i32 8
  store ptr %50, ptr %48, align 8
  br label %51

51:                                               ; preds = %47, %42
  %52 = phi ptr [ %45, %42 ], [ %49, %47 ]
  %53 = load i64, ptr %52, align 8, !tbaa !16
  %54 = sitofp i64 %53 to double
  %55 = load double, ptr %4, align 8, !tbaa !12
  %56 = fadd double %55, %54
  store double %56, ptr %4, align 8, !tbaa !12
  br label %97

57:                                               ; preds = %13
  %58 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %59 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %58, i32 0, i32 1
  %60 = load i32, ptr %59, align 4
  %61 = icmp ule i32 %60, 160
  br i1 %61, label %62, label %67

62:                                               ; preds = %57
  %63 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %58, i32 0, i32 3
  %64 = load ptr, ptr %63, align 16
  %65 = getelementptr i8, ptr %64, i32 %60
  %66 = add i32 %60, 16
  store i32 %66, ptr %59, align 4
  br label %71

67:                                               ; preds = %57
  %68 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %58, i32 0, i32 2
  %69 = load ptr, ptr %68, align 8
  %70 = getelementptr i8, ptr %69, i32 8
  store ptr %70, ptr %68, align 8
  br label %71

71:                                               ; preds = %67, %62
  %72 = phi ptr [ %65, %62 ], [ %69, %67 ]
  %73 = load double, ptr %72, align 8, !tbaa !12
  %74 = load double, ptr %4, align 8, !tbaa !12
  %75 = fadd double %74, %73
  store double %75, ptr %4, align 8, !tbaa !12
  br label %97

76:                                               ; preds = %13
  %77 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %78 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %77, i32 0, i32 0
  %79 = load i32, ptr %78, align 16
  %80 = icmp ule i32 %79, 40
  br i1 %80, label %81, label %86

81:                                               ; preds = %76
  %82 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %77, i32 0, i32 3
  %83 = load ptr, ptr %82, align 16
  %84 = getelementptr i8, ptr %83, i32 %79
  %85 = add i32 %79, 8
  store i32 %85, ptr %78, align 16
  br label %90

86:                                               ; preds = %76
  %87 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %77, i32 0, i32 2
  %88 = load ptr, ptr %87, align 8
  %89 = getelementptr i8, ptr %88, i32 8
  store ptr %89, ptr %87, align 8
  br label %90

90:                                               ; preds = %86, %81
  %91 = phi ptr [ %84, %81 ], [ %88, %86 ]
  %92 = load ptr, ptr %91, align 8, !tbaa !18
  %93 = load i32, ptr %92, align 4, !tbaa !15
  %94 = sitofp i32 %93 to double
  %95 = load double, ptr %4, align 8, !tbaa !12
  %96 = fadd double %95, %94
  store double %96, ptr %4, align 8, !tbaa !12
  br label %97

97:                                               ; preds = %13, %90, %71, %51, %31
  br label %98

98:                                               ; preds = %97
  %99 = load ptr, ptr %5, align 8, !tbaa !9
  %100 = getelementptr inbounds nuw i8, ptr %99, i32 1
  store ptr %100, ptr %5, align 8, !tbaa !9
  br label %8, !llvm.loop !20

101:                                              ; preds = %12
  %102 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_end.p0(ptr %102)
  %103 = load double, ptr %4, align 8, !tbaa !12
  call void @llvm.lifetime.end.p0(ptr %4) #4
  call void @llvm.lifetime.end.p0(ptr %3) #4
  ret double %103
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare void @llvm.va_start.p0(ptr) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare void @llvm.va_end.p0(ptr) #2

; Function Attrs: nounwind uwtable
define dso_local double @vforward(i32 noundef %0, ...) #0 {
  %2 = alloca i32, align 4
  %3 = alloca [1 x %struct.__va_list_tag], align 16
  %4 = alloca double, align 8
  store i32 %0, ptr %2, align 4, !tbaa !15
  call void @llvm.lifetime.start.p0(ptr %3) #4
  %5 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_start.p0(ptr %5)
  call void @llvm.lifetime.start.p0(ptr %4) #4
  %6 = load i32, ptr %2, align 4, !tbaa !15
  %7 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %8 = call double @vinner(i32 noundef %6, ptr noundef %7)
  store double %8, ptr %4, align 8, !tbaa !12
  %9 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_end.p0(ptr %9)
  %10 = load double, ptr %4, align 8, !tbaa !12
  call void @llvm.lifetime.end.p0(ptr %4) #4
  call void @llvm.lifetime.end.p0(ptr %3) #4
  ret double %10
}

; Function Attrs: nounwind uwtable
define internal double @vinner(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca ptr, align 8
  %5 = alloca double, align 8
  %6 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !15
  store ptr %1, ptr %4, align 8, !tbaa !22
  call void @llvm.lifetime.start.p0(ptr %5) #4
  store double 0.000000e+00, ptr %5, align 8, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %6) #4
  store i32 0, ptr %6, align 4, !tbaa !15
  br label %7

7:                                                ; preds = %34, %2
  %8 = load i32, ptr %6, align 4, !tbaa !15
  %9 = load i32, ptr %3, align 4, !tbaa !15
  %10 = icmp slt i32 %8, %9
  br i1 %10, label %12, label %11

11:                                               ; preds = %7
  call void @llvm.lifetime.end.p0(ptr %6) #4
  br label %37

12:                                               ; preds = %7
  %13 = load ptr, ptr %4, align 8, !tbaa !22
  %14 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %13, i32 0, i32 1
  %15 = load i32, ptr %14, align 4
  %16 = icmp ule i32 %15, 160
  br i1 %16, label %17, label %22

17:                                               ; preds = %12
  %18 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %13, i32 0, i32 3
  %19 = load ptr, ptr %18, align 8
  %20 = getelementptr i8, ptr %19, i32 %15
  %21 = add i32 %15, 16
  store i32 %21, ptr %14, align 4
  br label %26

22:                                               ; preds = %12
  %23 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %13, i32 0, i32 2
  %24 = load ptr, ptr %23, align 8
  %25 = getelementptr i8, ptr %24, i32 8
  store ptr %25, ptr %23, align 8
  br label %26

26:                                               ; preds = %22, %17
  %27 = phi ptr [ %20, %17 ], [ %24, %22 ]
  %28 = load double, ptr %27, align 8, !tbaa !12
  %29 = load i32, ptr %6, align 4, !tbaa !15
  %30 = add nsw i32 %29, 1
  %31 = sitofp i32 %30 to double
  %32 = load double, ptr %5, align 8, !tbaa !12
  %33 = call double @llvm.fmuladd.f64(double %28, double %31, double %32)
  store double %33, ptr %5, align 8, !tbaa !12
  br label %34

34:                                               ; preds = %26
  %35 = load i32, ptr %6, align 4, !tbaa !15
  %36 = add nsw i32 %35, 1
  store i32 %36, ptr %6, align 4, !tbaa !15
  br label %7, !llvm.loop !24

37:                                               ; preds = %11
  %38 = load double, ptr %5, align 8, !tbaa !12
  call void @llvm.lifetime.end.p0(ptr %5) #4
  ret double %38
}

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #3

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nocallback nofree nosync nounwind willreturn }
attributes #3 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
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
!9 = !{!10, !10, i64 0}
!10 = !{!"p1 omnipotent char", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!13, !13, i64 0}
!13 = !{!"double", !7, i64 0}
!14 = !{!7, !7, i64 0}
!15 = !{!6, !6, i64 0}
!16 = !{!17, !17, i64 0}
!17 = !{!"long", !7, i64 0}
!18 = !{!19, !19, i64 0}
!19 = !{!"p1 int", !11, i64 0}
!20 = distinct !{!20, !21}
!21 = !{!"llvm.loop.mustprogress"}
!22 = !{!23, !23, i64 0}
!23 = !{!"p1 _ZTS13__va_list_tag", !11, i64 0}
!24 = distinct !{!24, !21}
