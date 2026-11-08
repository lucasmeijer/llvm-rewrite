; @source: tests/function/src/abi/varargs_callee.c
; @llc: -O2
; @driver: tests/function/src/abi/varargs_callee.driver.c
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/function/src/abi/varargs_callee.c'
source_filename = "tests/function/src/abi/varargs_callee.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.__va_list_tag = type { i32, i32, ptr, ptr }

; Function Attrs: nofree norecurse nosync nounwind uwtable
define dso_local double @vsum(ptr nofree noundef readonly captures(none) %0, ...) local_unnamed_addr #0 {
  %2 = alloca [1 x %struct.__va_list_tag], align 16
  call void @llvm.lifetime.start.p0(ptr nonnull %2) #5
  call void @llvm.va_start.p0(ptr nonnull %2)
  %3 = load i32, ptr %2, align 16
  %4 = getelementptr inbounds nuw i8, ptr %2, i64 8
  %5 = getelementptr inbounds nuw i8, ptr %2, i64 16
  %6 = load ptr, ptr %5, align 16
  %7 = getelementptr inbounds nuw i8, ptr %2, i64 4
  %8 = load ptr, ptr %4, align 8
  %9 = load i32, ptr %7, align 4
  br label %10

10:                                               ; preds = %78, %1
  %11 = phi i32 [ %9, %1 ], [ %79, %78 ]
  %12 = phi ptr [ %8, %1 ], [ %80, %78 ]
  %13 = phi i32 [ %3, %1 ], [ %81, %78 ]
  %14 = phi double [ 0.000000e+00, %1 ], [ %82, %78 ]
  %15 = phi ptr [ %0, %1 ], [ %83, %78 ]
  %16 = load i8, ptr %15, align 1, !tbaa !9
  switch i8 %16, label %78 [
    i8 0, label %17
    i8 105, label %18
    i8 108, label %33
    i8 100, label %48
    i8 112, label %62
  ]

17:                                               ; preds = %10
  call void @llvm.va_end.p0(ptr nonnull %2)
  call void @llvm.lifetime.end.p0(ptr nonnull %2) #5
  ret double %14

18:                                               ; preds = %10
  %19 = icmp ult i32 %13, 41
  br i1 %19, label %20, label %24

20:                                               ; preds = %18
  %21 = zext nneg i32 %13 to i64
  %22 = getelementptr i8, ptr %6, i64 %21
  %23 = add nuw nsw i32 %13, 8
  store i32 %23, ptr %2, align 16
  br label %26

24:                                               ; preds = %18
  %25 = getelementptr i8, ptr %12, i64 8
  store ptr %25, ptr %4, align 8
  br label %26

26:                                               ; preds = %24, %20
  %27 = phi ptr [ %12, %20 ], [ %25, %24 ]
  %28 = phi i32 [ %23, %20 ], [ %13, %24 ]
  %29 = phi ptr [ %22, %20 ], [ %12, %24 ]
  %30 = load i32, ptr %29, align 4, !tbaa !10
  %31 = sitofp i32 %30 to double
  %32 = fadd double %14, %31
  br label %78

33:                                               ; preds = %10
  %34 = icmp ult i32 %13, 41
  br i1 %34, label %35, label %39

35:                                               ; preds = %33
  %36 = zext nneg i32 %13 to i64
  %37 = getelementptr i8, ptr %6, i64 %36
  %38 = add nuw nsw i32 %13, 8
  store i32 %38, ptr %2, align 16
  br label %41

39:                                               ; preds = %33
  %40 = getelementptr i8, ptr %12, i64 8
  store ptr %40, ptr %4, align 8
  br label %41

41:                                               ; preds = %39, %35
  %42 = phi ptr [ %12, %35 ], [ %40, %39 ]
  %43 = phi i32 [ %38, %35 ], [ %13, %39 ]
  %44 = phi ptr [ %37, %35 ], [ %12, %39 ]
  %45 = load i64, ptr %44, align 8, !tbaa !11
  %46 = sitofp i64 %45 to double
  %47 = fadd double %14, %46
  br label %78

48:                                               ; preds = %10
  %49 = icmp ult i32 %11, 161
  br i1 %49, label %50, label %54

50:                                               ; preds = %48
  %51 = zext nneg i32 %11 to i64
  %52 = getelementptr i8, ptr %6, i64 %51
  %53 = add nuw nsw i32 %11, 16
  store i32 %53, ptr %7, align 4
  br label %56

54:                                               ; preds = %48
  %55 = getelementptr i8, ptr %12, i64 8
  store ptr %55, ptr %4, align 8
  br label %56

56:                                               ; preds = %54, %50
  %57 = phi i32 [ %53, %50 ], [ %11, %54 ]
  %58 = phi ptr [ %12, %50 ], [ %55, %54 ]
  %59 = phi ptr [ %52, %50 ], [ %12, %54 ]
  %60 = load double, ptr %59, align 8, !tbaa !13
  %61 = fadd double %14, %60
  br label %78

62:                                               ; preds = %10
  %63 = icmp ult i32 %13, 41
  br i1 %63, label %64, label %68

64:                                               ; preds = %62
  %65 = zext nneg i32 %13 to i64
  %66 = getelementptr i8, ptr %6, i64 %65
  %67 = add nuw nsw i32 %13, 8
  store i32 %67, ptr %2, align 16
  br label %70

68:                                               ; preds = %62
  %69 = getelementptr i8, ptr %12, i64 8
  store ptr %69, ptr %4, align 8
  br label %70

70:                                               ; preds = %68, %64
  %71 = phi ptr [ %12, %64 ], [ %69, %68 ]
  %72 = phi i32 [ %67, %64 ], [ %13, %68 ]
  %73 = phi ptr [ %66, %64 ], [ %12, %68 ]
  %74 = load ptr, ptr %73, align 8, !tbaa !15
  %75 = load i32, ptr %74, align 4, !tbaa !10
  %76 = sitofp i32 %75 to double
  %77 = fadd double %14, %76
  br label %78

78:                                               ; preds = %10, %26, %41, %56, %70
  %79 = phi i32 [ %11, %10 ], [ %11, %26 ], [ %11, %41 ], [ %57, %56 ], [ %11, %70 ]
  %80 = phi ptr [ %12, %10 ], [ %27, %26 ], [ %42, %41 ], [ %58, %56 ], [ %71, %70 ]
  %81 = phi i32 [ %13, %10 ], [ %28, %26 ], [ %43, %41 ], [ %13, %56 ], [ %72, %70 ]
  %82 = phi double [ %14, %10 ], [ %32, %26 ], [ %47, %41 ], [ %61, %56 ], [ %77, %70 ]
  %83 = getelementptr inbounds nuw i8, ptr %15, i64 1
  br label %10, !llvm.loop !18
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn
declare void @llvm.va_start.p0(ptr) #2

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn
declare void @llvm.va_end.p0(ptr) #2

; Function Attrs: nofree norecurse nosync nounwind uwtable
define dso_local double @vforward(i32 noundef %0, ...) local_unnamed_addr #0 {
  %2 = alloca [1 x %struct.__va_list_tag], align 16
  call void @llvm.lifetime.start.p0(ptr nonnull %2) #5
  call void @llvm.va_start.p0(ptr nonnull %2)
  %3 = icmp sgt i32 %0, 0
  br i1 %3, label %4, label %74

4:                                                ; preds = %1
  %5 = getelementptr inbounds nuw i8, ptr %2, i64 4
  %6 = getelementptr inbounds nuw i8, ptr %2, i64 8
  %7 = getelementptr inbounds nuw i8, ptr %2, i64 16
  %8 = load i32, ptr %5, align 4
  %9 = load ptr, ptr %6, align 8
  %10 = load ptr, ptr %7, align 16
  %11 = and i32 %0, 1
  %12 = icmp eq i32 %0, 1
  br i1 %12, label %55, label %13

13:                                               ; preds = %4
  %14 = and i32 %0, 2147483646
  br label %15

15:                                               ; preds = %43, %13
  %16 = phi ptr [ %9, %13 ], [ %44, %43 ]
  %17 = phi i32 [ %8, %13 ], [ %45, %43 ]
  %18 = phi i32 [ 0, %13 ], [ %48, %43 ]
  %19 = phi double [ 0.000000e+00, %13 ], [ %50, %43 ]
  %20 = phi i32 [ 0, %13 ], [ %51, %43 ]
  %21 = icmp ult i32 %17, 161
  br i1 %21, label %22, label %26

22:                                               ; preds = %15
  %23 = zext nneg i32 %17 to i64
  %24 = getelementptr i8, ptr %10, i64 %23
  %25 = add nuw nsw i32 %17, 16
  store i32 %25, ptr %5, align 4
  br label %28

26:                                               ; preds = %15
  %27 = getelementptr i8, ptr %16, i64 8
  store ptr %27, ptr %6, align 8
  br label %28

28:                                               ; preds = %26, %22
  %29 = phi ptr [ %16, %22 ], [ %27, %26 ]
  %30 = phi i32 [ %25, %22 ], [ %17, %26 ]
  %31 = phi ptr [ %24, %22 ], [ %16, %26 ]
  %32 = load double, ptr %31, align 8, !tbaa !13
  %33 = or disjoint i32 %18, 1
  %34 = uitofp nneg i32 %33 to double
  %35 = call double @llvm.fmuladd.f64(double %32, double %34, double %19)
  %36 = icmp ult i32 %30, 161
  br i1 %36, label %39, label %37

37:                                               ; preds = %28
  %38 = getelementptr i8, ptr %29, i64 8
  store ptr %38, ptr %6, align 8
  br label %43

39:                                               ; preds = %28
  %40 = zext nneg i32 %30 to i64
  %41 = getelementptr i8, ptr %10, i64 %40
  %42 = add nuw nsw i32 %30, 16
  store i32 %42, ptr %5, align 4
  br label %43

43:                                               ; preds = %39, %37
  %44 = phi ptr [ %29, %39 ], [ %38, %37 ]
  %45 = phi i32 [ %42, %39 ], [ %30, %37 ]
  %46 = phi ptr [ %41, %39 ], [ %29, %37 ]
  %47 = load double, ptr %46, align 8, !tbaa !13
  %48 = add nuw nsw i32 %18, 2
  %49 = uitofp nneg i32 %48 to double
  %50 = call double @llvm.fmuladd.f64(double %47, double %49, double %35)
  %51 = add i32 %20, 2
  %52 = icmp eq i32 %51, %14
  br i1 %52, label %53, label %15, !llvm.loop !20

53:                                               ; preds = %43
  %54 = icmp eq i32 %11, 0
  br i1 %54, label %74, label %55

55:                                               ; preds = %53, %4
  %56 = phi ptr [ %9, %4 ], [ %44, %53 ]
  %57 = phi i32 [ %8, %4 ], [ %45, %53 ]
  %58 = phi i32 [ 0, %4 ], [ %48, %53 ]
  %59 = phi double [ 0.000000e+00, %4 ], [ %50, %53 ]
  %60 = trunc i32 %0 to i1
  call void @llvm.assume(i1 %60)
  %61 = icmp ult i32 %57, 161
  br i1 %61, label %64, label %62

62:                                               ; preds = %55
  %63 = getelementptr i8, ptr %56, i64 8
  store ptr %63, ptr %6, align 8
  br label %68

64:                                               ; preds = %55
  %65 = zext nneg i32 %57 to i64
  %66 = getelementptr i8, ptr %10, i64 %65
  %67 = add nuw nsw i32 %57, 16
  store i32 %67, ptr %5, align 4
  br label %68

68:                                               ; preds = %64, %62
  %69 = phi ptr [ %66, %64 ], [ %56, %62 ]
  %70 = load double, ptr %69, align 8, !tbaa !13
  %71 = add nuw nsw i32 %58, 1
  %72 = uitofp nneg i32 %71 to double
  %73 = call double @llvm.fmuladd.f64(double %70, double %72, double %59)
  br label %74

74:                                               ; preds = %68, %53, %1
  %75 = phi double [ 0.000000e+00, %1 ], [ %50, %53 ], [ %73, %68 ]
  call void @llvm.va_end.p0(ptr nonnull %2)
  call void @llvm.lifetime.end.p0(ptr nonnull %2) #5
  ret double %75
}

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write)
declare void @llvm.assume(i1 noundef) #4

attributes #0 = { nofree norecurse nosync nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { mustprogress nocallback nofree nosync nounwind willreturn }
attributes #3 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #4 = { nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write) }
attributes #5 = { nounwind }

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
!9 = !{!7, !7, i64 0}
!10 = !{!6, !6, i64 0}
!11 = !{!12, !12, i64 0}
!12 = !{!"long", !7, i64 0}
!13 = !{!14, !14, i64 0}
!14 = !{!"double", !7, i64 0}
!15 = !{!16, !16, i64 0}
!16 = !{!"p1 int", !17, i64 0}
!17 = !{!"any pointer", !7, i64 0}
!18 = distinct !{!18, !19}
!19 = !{!"llvm.loop.mustprogress"}
!20 = distinct !{!20, !19}
