; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/CoyoteBench/lpbench.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/CoyoteBench/lpbench.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/CoyoteBench/lpbench.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [4 x i8] c"-ga\00", align 1
@stdout = external local_unnamed_addr global ptr, align 8
@.str.1 = private unnamed_addr constant [3 x i8] c"%f\00", align 1
@.str.2 = private unnamed_addr constant [33 x i8] c"\0Alpbench (Std. C) run time: %f\0A\0A\00", align 1
@seed = internal unnamed_addr global i64 1325, align 8

; Function Attrs: nofree norecurse nosync nounwind memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @matgen(ptr nofree noundef readonly captures(none) %0, ptr nofree noundef captures(none) %1) local_unnamed_addr #0 {
  %3 = load i64, ptr @seed, align 8, !tbaa !9
  %4 = xor i64 %3, 123459876
  br label %5

5:                                                ; preds = %2, %30
  %6 = phi i64 [ 0, %2 ], [ %31, %30 ]
  %7 = phi i64 [ %4, %2 ], [ %22, %30 ]
  br label %11

8:                                                ; preds = %30
  %9 = xor i64 %22, 123459876
  store i64 %9, ptr @seed, align 8, !tbaa !9
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 8 dereferenceable(16000) %1, i8 0, i64 16000, i1 false), !tbaa !11
  %10 = getelementptr i8, ptr %1, i64 16000
  br label %33

11:                                               ; preds = %5, %11
  %12 = phi i64 [ 0, %5 ], [ %28, %11 ]
  %13 = phi i64 [ %7, %5 ], [ %22, %11 ]
  %14 = sdiv i64 %13, 127773
  %15 = mul nsw i64 %14, -127773
  %16 = add i64 %15, %13
  %17 = mul nsw i64 %16, 16807
  %18 = mul nsw i64 %14, -2836
  %19 = add i64 %17, %18
  %20 = icmp slt i64 %19, 0
  %21 = add nsw i64 %19, 2147483647
  %22 = select i1 %20, i64 %21, i64 %19
  %23 = sitofp i64 %22 to double
  %24 = fmul nnan double %23, f0x3E00000000200FE1
  %25 = getelementptr inbounds nuw [8 x i8], ptr %0, i64 %12
  %26 = load ptr, ptr %25, align 8, !tbaa !13
  %27 = getelementptr inbounds nuw [8 x i8], ptr %26, i64 %6
  store double %24, ptr %27, align 8, !tbaa !11
  %28 = add nuw nsw i64 %12, 1
  %29 = icmp eq i64 %28, 2000
  br i1 %29, label %30, label %11, !llvm.loop !16

30:                                               ; preds = %11
  %31 = add nuw nsw i64 %6, 1
  %32 = icmp eq i64 %31, 2000
  br i1 %32, label %8, label %5, !llvm.loop !18

33:                                               ; preds = %8, %93
  %34 = phi i64 [ 0, %8 ], [ %94, %93 ]
  %35 = getelementptr inbounds nuw [8 x i8], ptr %0, i64 %34
  %36 = load ptr, ptr %35, align 8, !tbaa !13
  %37 = getelementptr i8, ptr %36, i64 16000
  %38 = icmp ult ptr %1, %37
  %39 = icmp ult ptr %36, %10
  %40 = and i1 %38, %39
  br i1 %40, label %66, label %41

41:                                               ; preds = %33, %41
  %42 = phi i64 [ %64, %41 ], [ 0, %33 ]
  %43 = getelementptr inbounds nuw [8 x i8], ptr %36, i64 %42
  %44 = getelementptr inbounds nuw i8, ptr %43, i64 16
  %45 = load <2 x double>, ptr %43, align 8, !tbaa !11, !alias.scope !19
  %46 = load <2 x double>, ptr %44, align 8, !tbaa !11, !alias.scope !19
  %47 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %42
  %48 = getelementptr inbounds nuw i8, ptr %47, i64 16
  %49 = load <2 x double>, ptr %47, align 8, !tbaa !11, !alias.scope !22, !noalias !19
  %50 = load <2 x double>, ptr %48, align 8, !tbaa !11, !alias.scope !22, !noalias !19
  %51 = fadd <2 x double> %45, %49
  %52 = fadd <2 x double> %46, %50
  store <2 x double> %51, ptr %47, align 8, !tbaa !11, !alias.scope !22, !noalias !19
  store <2 x double> %52, ptr %48, align 8, !tbaa !11, !alias.scope !22, !noalias !19
  %53 = or disjoint i64 %42, 4
  %54 = getelementptr inbounds nuw [8 x i8], ptr %36, i64 %53
  %55 = getelementptr inbounds nuw i8, ptr %54, i64 16
  %56 = load <2 x double>, ptr %54, align 8, !tbaa !11, !alias.scope !19
  %57 = load <2 x double>, ptr %55, align 8, !tbaa !11, !alias.scope !19
  %58 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %53
  %59 = getelementptr inbounds nuw i8, ptr %58, i64 16
  %60 = load <2 x double>, ptr %58, align 8, !tbaa !11, !alias.scope !22, !noalias !19
  %61 = load <2 x double>, ptr %59, align 8, !tbaa !11, !alias.scope !22, !noalias !19
  %62 = fadd <2 x double> %56, %60
  %63 = fadd <2 x double> %57, %61
  store <2 x double> %62, ptr %58, align 8, !tbaa !11, !alias.scope !22, !noalias !19
  store <2 x double> %63, ptr %59, align 8, !tbaa !11, !alias.scope !22, !noalias !19
  %64 = add nuw nsw i64 %42, 8
  %65 = icmp eq i64 %64, 2000
  br i1 %65, label %93, label %41, !llvm.loop !24

66:                                               ; preds = %33, %66
  %67 = phi i64 [ %91, %66 ], [ 0, %33 ]
  %68 = getelementptr inbounds nuw [8 x i8], ptr %36, i64 %67
  %69 = load double, ptr %68, align 8, !tbaa !11
  %70 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %67
  %71 = load double, ptr %70, align 8, !tbaa !11
  %72 = fadd double %69, %71
  store double %72, ptr %70, align 8, !tbaa !11
  %73 = or disjoint i64 %67, 1
  %74 = getelementptr inbounds nuw [8 x i8], ptr %36, i64 %73
  %75 = load double, ptr %74, align 8, !tbaa !11
  %76 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %73
  %77 = load double, ptr %76, align 8, !tbaa !11
  %78 = fadd double %75, %77
  store double %78, ptr %76, align 8, !tbaa !11
  %79 = or disjoint i64 %67, 2
  %80 = getelementptr inbounds nuw [8 x i8], ptr %36, i64 %79
  %81 = load double, ptr %80, align 8, !tbaa !11
  %82 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %79
  %83 = load double, ptr %82, align 8, !tbaa !11
  %84 = fadd double %81, %83
  store double %84, ptr %82, align 8, !tbaa !11
  %85 = or disjoint i64 %67, 3
  %86 = getelementptr inbounds nuw [8 x i8], ptr %36, i64 %85
  %87 = load double, ptr %86, align 8, !tbaa !11
  %88 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %85
  %89 = load double, ptr %88, align 8, !tbaa !11
  %90 = fadd double %87, %89
  store double %90, ptr %88, align 8, !tbaa !11
  %91 = add nuw nsw i64 %67, 4
  %92 = icmp eq i64 %91, 2000
  br i1 %92, label %93, label %66, !llvm.loop !27

93:                                               ; preds = %41, %66
  %94 = add nuw nsw i64 %34, 1
  %95 = icmp eq i64 %94, 2000
  br i1 %95, label %96, label %33, !llvm.loop !28

96:                                               ; preds = %93
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: read) uwtable
define dso_local i32 @idamax(i32 noundef %0, ptr nofree noundef readonly captures(none) %1, i32 noundef %2, i32 noundef %3) local_unnamed_addr #1 {
  %5 = icmp slt i32 %0, 1
  br i1 %5, label %108, label %6

6:                                                ; preds = %4
  %7 = icmp eq i32 %0, 1
  br i1 %7, label %108, label %8

8:                                                ; preds = %6
  %9 = icmp eq i32 %3, 1
  %10 = sext i32 %2 to i64
  br i1 %9, label %48, label %11

11:                                               ; preds = %8
  %12 = add i32 %3, 1
  %13 = getelementptr inbounds [8 x i8], ptr %1, i64 %10
  %14 = load double, ptr %13, align 8, !tbaa !11
  %15 = tail call double @llvm.fabs.f64(double %14)
  %16 = sext i32 %12 to i64
  %17 = sext i32 %3 to i64
  %18 = getelementptr [8 x i8], ptr %1, i64 %10
  %19 = add nsw i32 %0, -1
  %20 = and i32 %19, 1
  %21 = icmp eq i32 %0, 2
  br i1 %21, label %97, label %22

22:                                               ; preds = %11
  %23 = and i32 %19, -2
  br label %24

24:                                               ; preds = %24, %22
  %25 = phi i64 [ %16, %22 ], [ %44, %24 ]
  %26 = phi i32 [ 0, %22 ], [ %43, %24 ]
  %27 = phi i32 [ 1, %22 ], [ %45, %24 ]
  %28 = phi double [ %15, %22 ], [ %42, %24 ]
  %29 = phi i32 [ 0, %22 ], [ %46, %24 ]
  %30 = getelementptr [8 x i8], ptr %18, i64 %25
  %31 = load double, ptr %30, align 8, !tbaa !11
  %32 = tail call double @llvm.fabs.f64(double %31)
  %33 = fcmp ogt double %32, %28
  %34 = select i1 %33, double %32, double %28
  %35 = select i1 %33, i32 %27, i32 %26
  %36 = add nsw i64 %25, %17
  %37 = add nuw nsw i32 %27, 1
  %38 = getelementptr [8 x i8], ptr %18, i64 %36
  %39 = load double, ptr %38, align 8, !tbaa !11
  %40 = tail call double @llvm.fabs.f64(double %39)
  %41 = fcmp ogt double %40, %34
  %42 = select i1 %41, double %40, double %34
  %43 = select i1 %41, i32 %37, i32 %35
  %44 = add nsw i64 %36, %17
  %45 = add nuw nsw i32 %27, 2
  %46 = add i32 %29, 2
  %47 = icmp eq i32 %46, %23
  br i1 %47, label %95, label %24, !llvm.loop !29

48:                                               ; preds = %8
  %49 = getelementptr inbounds [8 x i8], ptr %1, i64 %10
  %50 = load double, ptr %49, align 8, !tbaa !11
  %51 = tail call double @llvm.fabs.f64(double %50)
  %52 = zext nneg i32 %0 to i64
  %53 = getelementptr [8 x i8], ptr %1, i64 %10
  %54 = add nsw i64 %52, -1
  %55 = and i64 %54, 1
  %56 = icmp eq i32 %0, 2
  br i1 %56, label %84, label %57

57:                                               ; preds = %48
  %58 = and i64 %54, -2
  br label %59

59:                                               ; preds = %59, %57
  %60 = phi i64 [ 1, %57 ], [ %79, %59 ]
  %61 = phi i32 [ 0, %57 ], [ %78, %59 ]
  %62 = phi double [ %51, %57 ], [ %76, %59 ]
  %63 = phi i64 [ 0, %57 ], [ %80, %59 ]
  %64 = getelementptr [8 x i8], ptr %53, i64 %60
  %65 = load double, ptr %64, align 8, !tbaa !11
  %66 = tail call double @llvm.fabs.f64(double %65)
  %67 = fcmp ogt double %66, %62
  %68 = select i1 %67, double %66, double %62
  %69 = trunc nuw nsw i64 %60 to i32
  %70 = select i1 %67, i32 %69, i32 %61
  %71 = add nuw nsw i64 %60, 1
  %72 = getelementptr [8 x i8], ptr %53, i64 %71
  %73 = load double, ptr %72, align 8, !tbaa !11
  %74 = tail call double @llvm.fabs.f64(double %73)
  %75 = fcmp ogt double %74, %68
  %76 = select i1 %75, double %74, double %68
  %77 = trunc nuw nsw i64 %71 to i32
  %78 = select i1 %75, i32 %77, i32 %70
  %79 = add nuw nsw i64 %60, 2
  %80 = add nuw i64 %63, 2
  %81 = icmp eq i64 %80, %58
  br i1 %81, label %82, label %59, !llvm.loop !30

82:                                               ; preds = %59
  %83 = icmp eq i64 %55, 0
  br i1 %83, label %108, label %84

84:                                               ; preds = %82, %48
  %85 = phi i64 [ 1, %48 ], [ %79, %82 ]
  %86 = phi i32 [ 0, %48 ], [ %78, %82 ]
  %87 = phi double [ %51, %48 ], [ %76, %82 ]
  %88 = trunc i64 %54 to i1
  tail call void @llvm.assume(i1 %88)
  %89 = getelementptr [8 x i8], ptr %53, i64 %85
  %90 = load double, ptr %89, align 8, !tbaa !11
  %91 = tail call double @llvm.fabs.f64(double %90)
  %92 = fcmp ogt double %91, %87
  %93 = trunc nuw nsw i64 %85 to i32
  %94 = select i1 %92, i32 %93, i32 %86
  br label %108

95:                                               ; preds = %24
  %96 = icmp eq i32 %20, 0
  br i1 %96, label %108, label %97

97:                                               ; preds = %95, %11
  %98 = phi i64 [ %16, %11 ], [ %44, %95 ]
  %99 = phi i32 [ 0, %11 ], [ %43, %95 ]
  %100 = phi i32 [ 1, %11 ], [ %45, %95 ]
  %101 = phi double [ %15, %11 ], [ %42, %95 ]
  %102 = trunc i32 %19 to i1
  tail call void @llvm.assume(i1 %102)
  %103 = getelementptr [8 x i8], ptr %18, i64 %98
  %104 = load double, ptr %103, align 8, !tbaa !11
  %105 = tail call double @llvm.fabs.f64(double %104)
  %106 = fcmp ogt double %105, %101
  %107 = select i1 %106, i32 %100, i32 %99
  br label %108

108:                                              ; preds = %97, %95, %84, %82, %6, %4
  %109 = phi i32 [ 0, %6 ], [ -1, %4 ], [ %94, %84 ], [ %78, %82 ], [ %43, %95 ], [ %107, %97 ]
  ret i32 %109
}

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fabs.f64(double) #2

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @dscal(i32 noundef %0, double noundef %1, ptr nofree noundef captures(none) %2, i32 noundef %3, i32 noundef %4) local_unnamed_addr #3 {
  %6 = icmp sgt i32 %0, 0
  br i1 %6, label %7, label %54

7:                                                ; preds = %5
  %8 = icmp eq i32 %4, 1
  br i1 %8, label %9, label %32

9:                                                ; preds = %7
  %10 = sext i32 %3 to i64
  %11 = zext nneg i32 %0 to i64
  %12 = getelementptr [8 x i8], ptr %2, i64 %10
  %13 = icmp ult i32 %0, 4
  br i1 %13, label %30, label %14

14:                                               ; preds = %9
  %15 = and i64 %11, 2147483644
  %16 = insertelement <2 x double> poison, double %1, i64 0
  %17 = shufflevector <2 x double> %16, <2 x double> poison, <2 x i32> zeroinitializer
  br label %18

18:                                               ; preds = %18, %14
  %19 = phi i64 [ 0, %14 ], [ %26, %18 ]
  %20 = getelementptr [8 x i8], ptr %12, i64 %19
  %21 = getelementptr i8, ptr %20, i64 16
  %22 = load <2 x double>, ptr %20, align 8, !tbaa !11
  %23 = load <2 x double>, ptr %21, align 8, !tbaa !11
  %24 = fmul <2 x double> %17, %22
  %25 = fmul <2 x double> %17, %23
  store <2 x double> %24, ptr %20, align 8, !tbaa !11
  store <2 x double> %25, ptr %21, align 8, !tbaa !11
  %26 = add nuw i64 %19, 4
  %27 = icmp eq i64 %26, %15
  br i1 %27, label %28, label %18, !llvm.loop !31

28:                                               ; preds = %18
  %29 = icmp eq i64 %15, %11
  br i1 %29, label %54, label %30

30:                                               ; preds = %9, %28
  %31 = phi i64 [ 0, %9 ], [ %15, %28 ]
  br label %47

32:                                               ; preds = %7
  %33 = mul nsw i32 %4, %0
  %34 = icmp sgt i32 %33, 0
  br i1 %34, label %35, label %54

35:                                               ; preds = %32
  %36 = sext i32 %4 to i64
  %37 = sext i32 %3 to i64
  %38 = zext nneg i32 %33 to i64
  %39 = getelementptr [8 x i8], ptr %2, i64 %37
  br label %40

40:                                               ; preds = %35, %40
  %41 = phi i64 [ 0, %35 ], [ %45, %40 ]
  %42 = getelementptr [8 x i8], ptr %39, i64 %41
  %43 = load double, ptr %42, align 8, !tbaa !11
  %44 = fmul double %1, %43
  store double %44, ptr %42, align 8, !tbaa !11
  %45 = add nsw i64 %41, %36
  %46 = icmp slt i64 %45, %38
  br i1 %46, label %40, label %54, !llvm.loop !32

47:                                               ; preds = %30, %47
  %48 = phi i64 [ %52, %47 ], [ %31, %30 ]
  %49 = getelementptr [8 x i8], ptr %12, i64 %48
  %50 = load double, ptr %49, align 8, !tbaa !11
  %51 = fmul double %1, %50
  store double %51, ptr %49, align 8, !tbaa !11
  %52 = add nuw nsw i64 %48, 1
  %53 = icmp eq i64 %52, %11
  br i1 %53, label %54, label %47, !llvm.loop !33

54:                                               ; preds = %40, %47, %28, %32, %5
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @daxpy(i32 noundef %0, double noundef %1, ptr nofree noundef readonly captures(none) %2, i32 noundef %3, i32 noundef %4, ptr nofree noundef captures(none) %5, i32 noundef %6, i32 noundef %7) local_unnamed_addr #3 {
  %9 = icmp sgt i32 %0, 0
  %10 = fcmp une double %1, 0.000000e+00
  %11 = and i1 %9, %10
  br i1 %11, label %12, label %191

12:                                               ; preds = %8
  %13 = icmp ne i32 %4, 1
  %14 = icmp ne i32 %7, 1
  %15 = or i1 %13, %14
  br i1 %15, label %68, label %16

16:                                               ; preds = %12
  %17 = sext i32 %3 to i64
  %18 = sext i32 %6 to i64
  %19 = zext nneg i32 %0 to i64
  %20 = getelementptr [8 x i8], ptr %2, i64 %17
  %21 = getelementptr [8 x i8], ptr %5, i64 %18
  %22 = icmp ult i32 %0, 10
  br i1 %22, label %53, label %23

23:                                               ; preds = %16
  %24 = add nsw i64 %18, %19
  %25 = shl nsw i64 %24, 3
  %26 = getelementptr i8, ptr %5, i64 %25
  %27 = add nsw i64 %17, %19
  %28 = shl nsw i64 %27, 3
  %29 = getelementptr i8, ptr %2, i64 %28
  %30 = icmp ult ptr %21, %29
  %31 = icmp ult ptr %20, %26
  %32 = and i1 %30, %31
  br i1 %32, label %53, label %33

33:                                               ; preds = %23
  %34 = and i64 %19, 2147483644
  %35 = insertelement <2 x double> poison, double %1, i64 0
  %36 = shufflevector <2 x double> %35, <2 x double> poison, <2 x i32> zeroinitializer
  br label %37

37:                                               ; preds = %37, %33
  %38 = phi i64 [ 0, %33 ], [ %49, %37 ]
  %39 = getelementptr [8 x i8], ptr %20, i64 %38
  %40 = getelementptr i8, ptr %39, i64 16
  %41 = load <2 x double>, ptr %39, align 8, !tbaa !11, !alias.scope !34
  %42 = load <2 x double>, ptr %40, align 8, !tbaa !11, !alias.scope !34
  %43 = getelementptr [8 x i8], ptr %21, i64 %38
  %44 = getelementptr i8, ptr %43, i64 16
  %45 = load <2 x double>, ptr %43, align 8, !tbaa !11, !alias.scope !37, !noalias !34
  %46 = load <2 x double>, ptr %44, align 8, !tbaa !11, !alias.scope !37, !noalias !34
  %47 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %36, <2 x double> %41, <2 x double> %45)
  %48 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %36, <2 x double> %42, <2 x double> %46)
  store <2 x double> %47, ptr %43, align 8, !tbaa !11, !alias.scope !37, !noalias !34
  store <2 x double> %48, ptr %44, align 8, !tbaa !11, !alias.scope !37, !noalias !34
  %49 = add nuw i64 %38, 4
  %50 = icmp eq i64 %49, %34
  br i1 %50, label %51, label %37, !llvm.loop !39

51:                                               ; preds = %37
  %52 = icmp eq i64 %34, %19
  br i1 %52, label %191, label %53

53:                                               ; preds = %23, %16, %51
  %54 = phi i64 [ 0, %23 ], [ 0, %16 ], [ %34, %51 ]
  %55 = and i64 %19, 1
  %56 = icmp eq i64 %55, 0
  br i1 %56, label %64, label %57

57:                                               ; preds = %53
  %58 = getelementptr [8 x i8], ptr %20, i64 %54
  %59 = load double, ptr %58, align 8, !tbaa !11
  %60 = getelementptr [8 x i8], ptr %21, i64 %54
  %61 = load double, ptr %60, align 8, !tbaa !11
  %62 = tail call double @llvm.fmuladd.f64(double %1, double %59, double %61)
  store double %62, ptr %60, align 8, !tbaa !11
  %63 = or disjoint i64 %54, 1
  br label %64

64:                                               ; preds = %57, %53
  %65 = phi i64 [ %54, %53 ], [ %63, %57 ]
  %66 = add nsw i64 %19, -1
  %67 = icmp eq i64 %54, %66
  br i1 %67, label %191, label %176

68:                                               ; preds = %12
  %69 = icmp slt i32 %7, 0
  %70 = sub nsw i32 1, %0
  %71 = mul nsw i32 %7, %70
  %72 = select i1 %69, i32 %71, i32 0
  %73 = icmp slt i32 %4, 0
  %74 = mul nsw i32 %4, %70
  %75 = select i1 %73, i32 %74, i32 0
  %76 = sext i32 %72 to i64
  %77 = sext i32 %7 to i64
  %78 = sext i32 %6 to i64
  %79 = sext i32 %75 to i64
  %80 = sext i32 %4 to i64
  %81 = sext i32 %3 to i64
  %82 = getelementptr [8 x i8], ptr %2, i64 %81
  %83 = getelementptr [8 x i8], ptr %5, i64 %78
  %84 = zext nneg i32 %0 to i64
  %85 = icmp ult i32 %0, 18
  br i1 %85, label %134, label %86

86:                                               ; preds = %68
  %87 = icmp ne i32 %7, 1
  %88 = icmp ne i32 %4, 1
  %89 = or i1 %87, %88
  br i1 %89, label %134, label %90

90:                                               ; preds = %86
  %91 = add nsw i64 %78, %76
  %92 = shl nsw i64 %91, 3
  %93 = getelementptr i8, ptr %5, i64 %92
  %94 = add nsw i32 %0, -1
  %95 = zext i32 %94 to i64
  %96 = shl nuw nsw i64 %95, 3
  %97 = getelementptr i8, ptr %5, i64 %92
  %98 = getelementptr i8, ptr %97, i64 %96
  %99 = getelementptr i8, ptr %98, i64 8
  %100 = add nsw i64 %81, %79
  %101 = shl nsw i64 %100, 3
  %102 = getelementptr i8, ptr %2, i64 %101
  %103 = getelementptr i8, ptr %2, i64 %101
  %104 = getelementptr i8, ptr %103, i64 %96
  %105 = getelementptr i8, ptr %104, i64 8
  %106 = icmp ult ptr %93, %105
  %107 = icmp ult ptr %102, %99
  %108 = and i1 %106, %107
  br i1 %108, label %134, label %109

109:                                              ; preds = %90
  %110 = and i64 %84, 2147483644
  %111 = add nsw i64 %110, %79
  %112 = add nsw i64 %110, %76
  %113 = trunc nuw nsw i64 %110 to i32
  %114 = insertelement <2 x double> poison, double %1, i64 0
  %115 = shufflevector <2 x double> %114, <2 x double> poison, <2 x i32> zeroinitializer
  %116 = getelementptr [8 x i8], ptr %82, i64 %79
  %117 = getelementptr [8 x i8], ptr %83, i64 %76
  br label %118

118:                                              ; preds = %118, %109
  %119 = phi i64 [ 0, %109 ], [ %130, %118 ]
  %120 = getelementptr [8 x i8], ptr %116, i64 %119
  %121 = getelementptr i8, ptr %120, i64 16
  %122 = load <2 x double>, ptr %120, align 8, !tbaa !11, !alias.scope !40
  %123 = load <2 x double>, ptr %121, align 8, !tbaa !11, !alias.scope !40
  %124 = getelementptr [8 x i8], ptr %117, i64 %119
  %125 = getelementptr i8, ptr %124, i64 16
  %126 = load <2 x double>, ptr %124, align 8, !tbaa !11, !alias.scope !43, !noalias !40
  %127 = load <2 x double>, ptr %125, align 8, !tbaa !11, !alias.scope !43, !noalias !40
  %128 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %115, <2 x double> %122, <2 x double> %126)
  %129 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %115, <2 x double> %123, <2 x double> %127)
  store <2 x double> %128, ptr %124, align 8, !tbaa !11, !alias.scope !43, !noalias !40
  store <2 x double> %129, ptr %125, align 8, !tbaa !11, !alias.scope !43, !noalias !40
  %130 = add nuw i64 %119, 4
  %131 = icmp eq i64 %130, %110
  br i1 %131, label %132, label %118, !llvm.loop !45

132:                                              ; preds = %118
  %133 = icmp eq i64 %110, %84
  br i1 %133, label %191, label %134

134:                                              ; preds = %90, %86, %68, %132
  %135 = phi i64 [ %79, %90 ], [ %79, %86 ], [ %79, %68 ], [ %111, %132 ]
  %136 = phi i64 [ %76, %90 ], [ %76, %86 ], [ %76, %68 ], [ %112, %132 ]
  %137 = phi i32 [ 0, %90 ], [ 0, %86 ], [ 0, %68 ], [ %113, %132 ]
  %138 = sub i32 %0, %137
  %139 = add i32 %137, 1
  %140 = and i32 %138, 1
  %141 = icmp eq i32 %140, 0
  br i1 %141, label %151, label %142

142:                                              ; preds = %134
  %143 = getelementptr [8 x i8], ptr %82, i64 %135
  %144 = load double, ptr %143, align 8, !tbaa !11
  %145 = getelementptr [8 x i8], ptr %83, i64 %136
  %146 = load double, ptr %145, align 8, !tbaa !11
  %147 = tail call double @llvm.fmuladd.f64(double %1, double %144, double %146)
  store double %147, ptr %145, align 8, !tbaa !11
  %148 = add nsw i64 %135, %80
  %149 = add nsw i64 %136, %77
  %150 = add nuw nsw i32 %137, 1
  br label %151

151:                                              ; preds = %142, %134
  %152 = phi i64 [ %135, %134 ], [ %148, %142 ]
  %153 = phi i64 [ %136, %134 ], [ %149, %142 ]
  %154 = phi i32 [ %137, %134 ], [ %150, %142 ]
  %155 = icmp eq i32 %0, %139
  br i1 %155, label %191, label %156

156:                                              ; preds = %151, %156
  %157 = phi i64 [ %172, %156 ], [ %152, %151 ]
  %158 = phi i64 [ %173, %156 ], [ %153, %151 ]
  %159 = phi i32 [ %174, %156 ], [ %154, %151 ]
  %160 = getelementptr [8 x i8], ptr %82, i64 %157
  %161 = load double, ptr %160, align 8, !tbaa !11
  %162 = getelementptr [8 x i8], ptr %83, i64 %158
  %163 = load double, ptr %162, align 8, !tbaa !11
  %164 = tail call double @llvm.fmuladd.f64(double %1, double %161, double %163)
  store double %164, ptr %162, align 8, !tbaa !11
  %165 = add nsw i64 %157, %80
  %166 = add nsw i64 %158, %77
  %167 = getelementptr [8 x i8], ptr %82, i64 %165
  %168 = load double, ptr %167, align 8, !tbaa !11
  %169 = getelementptr [8 x i8], ptr %83, i64 %166
  %170 = load double, ptr %169, align 8, !tbaa !11
  %171 = tail call double @llvm.fmuladd.f64(double %1, double %168, double %170)
  store double %171, ptr %169, align 8, !tbaa !11
  %172 = add nsw i64 %165, %80
  %173 = add nsw i64 %166, %77
  %174 = add nuw nsw i32 %159, 2
  %175 = icmp eq i32 %174, %0
  br i1 %175, label %191, label %156, !llvm.loop !46

176:                                              ; preds = %64, %176
  %177 = phi i64 [ %189, %176 ], [ %65, %64 ]
  %178 = getelementptr [8 x i8], ptr %20, i64 %177
  %179 = load double, ptr %178, align 8, !tbaa !11
  %180 = getelementptr [8 x i8], ptr %21, i64 %177
  %181 = load double, ptr %180, align 8, !tbaa !11
  %182 = tail call double @llvm.fmuladd.f64(double %1, double %179, double %181)
  store double %182, ptr %180, align 8, !tbaa !11
  %183 = add nuw nsw i64 %177, 1
  %184 = getelementptr [8 x i8], ptr %20, i64 %183
  %185 = load double, ptr %184, align 8, !tbaa !11
  %186 = getelementptr [8 x i8], ptr %21, i64 %183
  %187 = load double, ptr %186, align 8, !tbaa !11
  %188 = tail call double @llvm.fmuladd.f64(double %1, double %185, double %187)
  store double %188, ptr %186, align 8, !tbaa !11
  %189 = add nuw nsw i64 %177, 2
  %190 = icmp eq i64 %189, %19
  br i1 %190, label %191, label %176, !llvm.loop !47

191:                                              ; preds = %64, %176, %151, %156, %51, %132, %8
  ret void
}

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #2

; Function Attrs: nofree norecurse nosync nounwind memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @dgefa(ptr nofree noundef readonly captures(none) %0, ptr nofree noundef writeonly captures(none) %1) local_unnamed_addr #0 {
  br label %3

3:                                                ; preds = %2, %170
  %4 = phi i64 [ 0, %2 ], [ %54, %170 ]
  %5 = phi i64 [ 1, %2 ], [ %171, %170 ]
  %6 = sub nsw i64 1999, %4
  %7 = getelementptr inbounds nuw [8 x i8], ptr %0, i64 %4
  %8 = load ptr, ptr %7, align 8, !tbaa !13
  %9 = getelementptr inbounds nuw [8 x i8], ptr %8, i64 %4
  %10 = load double, ptr %9, align 8, !tbaa !11
  %11 = tail call double @llvm.fabs.f64(double %10)
  %12 = and i64 %6, 1
  %13 = icmp eq i64 %4, 1998
  br i1 %13, label %41, label %14

14:                                               ; preds = %3
  %15 = and i64 %6, -2
  br label %16

16:                                               ; preds = %16, %14
  %17 = phi i64 [ 1, %14 ], [ %36, %16 ]
  %18 = phi i32 [ 0, %14 ], [ %35, %16 ]
  %19 = phi double [ %11, %14 ], [ %33, %16 ]
  %20 = phi i64 [ 0, %14 ], [ %37, %16 ]
  %21 = getelementptr [8 x i8], ptr %9, i64 %17
  %22 = load double, ptr %21, align 8, !tbaa !11
  %23 = tail call double @llvm.fabs.f64(double %22)
  %24 = fcmp ogt double %23, %19
  %25 = select i1 %24, double %23, double %19
  %26 = trunc nuw nsw i64 %17 to i32
  %27 = select i1 %24, i32 %26, i32 %18
  %28 = add nuw nsw i64 %17, 1
  %29 = getelementptr [8 x i8], ptr %9, i64 %28
  %30 = load double, ptr %29, align 8, !tbaa !11
  %31 = tail call double @llvm.fabs.f64(double %30)
  %32 = fcmp ogt double %31, %25
  %33 = select i1 %32, double %31, double %25
  %34 = trunc nuw nsw i64 %28 to i32
  %35 = select i1 %32, i32 %34, i32 %27
  %36 = add nuw nsw i64 %17, 2
  %37 = add nuw i64 %20, 2
  %38 = icmp eq i64 %37, %15
  br i1 %38, label %39, label %16, !llvm.loop !30

39:                                               ; preds = %16
  %40 = icmp eq i64 %12, 0
  br i1 %40, label %52, label %41

41:                                               ; preds = %39, %3
  %42 = phi i64 [ 1, %3 ], [ %36, %39 ]
  %43 = phi i32 [ 0, %3 ], [ %35, %39 ]
  %44 = phi double [ %11, %3 ], [ %33, %39 ]
  %45 = trunc i64 %6 to i1
  tail call void @llvm.assume(i1 %45)
  %46 = getelementptr [8 x i8], ptr %9, i64 %42
  %47 = load double, ptr %46, align 8, !tbaa !11
  %48 = tail call double @llvm.fabs.f64(double %47)
  %49 = fcmp ogt double %48, %44
  %50 = trunc nuw nsw i64 %42 to i32
  %51 = select i1 %49, i32 %50, i32 %43
  br label %52

52:                                               ; preds = %39, %41
  %53 = phi i32 [ %35, %39 ], [ %51, %41 ]
  %54 = add nuw nsw i64 %4, 1
  %55 = trunc nuw nsw i64 %4 to i32
  %56 = add nsw i32 %53, %55
  %57 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %4
  store i32 %56, ptr %57, align 4, !tbaa !48
  %58 = sext i32 %56 to i64
  %59 = getelementptr inbounds [8 x i8], ptr %8, i64 %58
  %60 = load double, ptr %59, align 8, !tbaa !11
  %61 = fcmp une double %60, 0.000000e+00
  br i1 %61, label %62, label %170

62:                                               ; preds = %52
  %63 = icmp eq i32 %53, 0
  br i1 %63, label %65, label %64

64:                                               ; preds = %62
  store double %10, ptr %59, align 8, !tbaa !11
  store double %60, ptr %9, align 8, !tbaa !11
  br label %65

65:                                               ; preds = %64, %62
  %66 = phi double [ %60, %64 ], [ %10, %62 ]
  %67 = fdiv double -1.000000e+00, %66
  %68 = sub nuw nsw i64 1999, %4
  %69 = getelementptr [8 x i8], ptr %8, i64 %54
  %70 = icmp samesign ugt i64 %4, 1995
  br i1 %70, label %87, label %71

71:                                               ; preds = %65
  %72 = and i64 %68, 2044
  %73 = insertelement <2 x double> poison, double %67, i64 0
  %74 = shufflevector <2 x double> %73, <2 x double> poison, <2 x i32> zeroinitializer
  br label %75

75:                                               ; preds = %75, %71
  %76 = phi i64 [ 0, %71 ], [ %83, %75 ]
  %77 = getelementptr [8 x i8], ptr %69, i64 %76
  %78 = getelementptr i8, ptr %77, i64 16
  %79 = load <2 x double>, ptr %77, align 8, !tbaa !11
  %80 = load <2 x double>, ptr %78, align 8, !tbaa !11
  %81 = fmul <2 x double> %74, %79
  %82 = fmul <2 x double> %74, %80
  store <2 x double> %81, ptr %77, align 8, !tbaa !11
  store <2 x double> %82, ptr %78, align 8, !tbaa !11
  %83 = add nuw i64 %76, 4
  %84 = icmp eq i64 %83, %72
  br i1 %84, label %85, label %75, !llvm.loop !49

85:                                               ; preds = %75
  %86 = icmp eq i64 %68, %72
  br i1 %86, label %96, label %87

87:                                               ; preds = %65, %85
  %88 = phi i64 [ 0, %65 ], [ %72, %85 ]
  br label %89

89:                                               ; preds = %87, %89
  %90 = phi i64 [ %94, %89 ], [ %88, %87 ]
  %91 = getelementptr [8 x i8], ptr %69, i64 %90
  %92 = load double, ptr %91, align 8, !tbaa !11
  %93 = fmul double %67, %92
  store double %93, ptr %91, align 8, !tbaa !11
  %94 = add nuw nsw i64 %90, 1
  %95 = icmp eq i64 %94, %68
  br i1 %95, label %96, label %89, !llvm.loop !50

96:                                               ; preds = %89, %85
  %97 = getelementptr i8, ptr %8, i64 16000
  %98 = icmp samesign ugt i64 %4, 1995
  %99 = and i64 %68, 2044
  %100 = icmp eq i64 %68, %99
  %101 = and i64 %4, 1
  %102 = icmp eq i64 %101, 0
  br label %103

103:                                              ; preds = %96, %167
  %104 = phi i64 [ %168, %167 ], [ %5, %96 ]
  %105 = getelementptr inbounds nuw [8 x i8], ptr %0, i64 %104
  %106 = load ptr, ptr %105, align 8, !tbaa !13
  %107 = getelementptr inbounds [8 x i8], ptr %106, i64 %58
  %108 = load double, ptr %107, align 8, !tbaa !11
  br i1 %63, label %112, label %109

109:                                              ; preds = %103
  %110 = getelementptr inbounds nuw [8 x i8], ptr %106, i64 %4
  %111 = load double, ptr %110, align 8, !tbaa !11
  store double %111, ptr %107, align 8, !tbaa !11
  store double %108, ptr %110, align 8, !tbaa !11
  br label %112

112:                                              ; preds = %109, %103
  %113 = fcmp une double %108, 0.000000e+00
  br i1 %113, label %114, label %167

114:                                              ; preds = %112
  %115 = getelementptr [8 x i8], ptr %106, i64 %54
  br i1 %98, label %139, label %116

116:                                              ; preds = %114
  %117 = getelementptr i8, ptr %106, i64 16000
  %118 = icmp ult ptr %115, %97
  %119 = icmp ult ptr %69, %117
  %120 = and i1 %118, %119
  br i1 %120, label %139, label %121

121:                                              ; preds = %116
  %122 = insertelement <2 x double> poison, double %108, i64 0
  %123 = shufflevector <2 x double> %122, <2 x double> poison, <2 x i32> zeroinitializer
  br label %124

124:                                              ; preds = %124, %121
  %125 = phi i64 [ 0, %121 ], [ %136, %124 ]
  %126 = getelementptr [8 x i8], ptr %69, i64 %125
  %127 = getelementptr i8, ptr %126, i64 16
  %128 = load <2 x double>, ptr %126, align 8, !tbaa !11, !alias.scope !51
  %129 = load <2 x double>, ptr %127, align 8, !tbaa !11, !alias.scope !51
  %130 = getelementptr [8 x i8], ptr %115, i64 %125
  %131 = getelementptr i8, ptr %130, i64 16
  %132 = load <2 x double>, ptr %130, align 8, !tbaa !11, !alias.scope !54, !noalias !51
  %133 = load <2 x double>, ptr %131, align 8, !tbaa !11, !alias.scope !54, !noalias !51
  %134 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %123, <2 x double> %128, <2 x double> %132)
  %135 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %123, <2 x double> %129, <2 x double> %133)
  store <2 x double> %134, ptr %130, align 8, !tbaa !11, !alias.scope !54, !noalias !51
  store <2 x double> %135, ptr %131, align 8, !tbaa !11, !alias.scope !54, !noalias !51
  %136 = add nuw i64 %125, 4
  %137 = icmp eq i64 %136, %99
  br i1 %137, label %138, label %124, !llvm.loop !56

138:                                              ; preds = %124
  br i1 %100, label %167, label %139

139:                                              ; preds = %116, %114, %138
  %140 = phi i64 [ 0, %116 ], [ 0, %114 ], [ %99, %138 ]
  %141 = add nuw i64 %4, %140
  br i1 %102, label %142, label %149

142:                                              ; preds = %139
  %143 = getelementptr [8 x i8], ptr %69, i64 %140
  %144 = load double, ptr %143, align 8, !tbaa !11
  %145 = getelementptr [8 x i8], ptr %115, i64 %140
  %146 = load double, ptr %145, align 8, !tbaa !11
  %147 = tail call double @llvm.fmuladd.f64(double %108, double %144, double %146)
  store double %147, ptr %145, align 8, !tbaa !11
  %148 = or disjoint i64 %140, 1
  br label %149

149:                                              ; preds = %142, %139
  %150 = phi i64 [ %140, %139 ], [ %148, %142 ]
  %151 = icmp eq i64 %141, 1998
  br i1 %151, label %167, label %152

152:                                              ; preds = %149, %152
  %153 = phi i64 [ %165, %152 ], [ %150, %149 ]
  %154 = getelementptr [8 x i8], ptr %69, i64 %153
  %155 = load double, ptr %154, align 8, !tbaa !11
  %156 = getelementptr [8 x i8], ptr %115, i64 %153
  %157 = load double, ptr %156, align 8, !tbaa !11
  %158 = tail call double @llvm.fmuladd.f64(double %108, double %155, double %157)
  store double %158, ptr %156, align 8, !tbaa !11
  %159 = add nuw nsw i64 %153, 1
  %160 = getelementptr [8 x i8], ptr %69, i64 %159
  %161 = load double, ptr %160, align 8, !tbaa !11
  %162 = getelementptr [8 x i8], ptr %115, i64 %159
  %163 = load double, ptr %162, align 8, !tbaa !11
  %164 = tail call double @llvm.fmuladd.f64(double %108, double %161, double %163)
  store double %164, ptr %162, align 8, !tbaa !11
  %165 = add nuw nsw i64 %153, 2
  %166 = icmp eq i64 %165, %68
  br i1 %166, label %167, label %152, !llvm.loop !57

167:                                              ; preds = %149, %152, %138, %112
  %168 = add nuw nsw i64 %104, 1
  %169 = icmp eq i64 %168, 2000
  br i1 %169, label %170, label %103, !llvm.loop !58

170:                                              ; preds = %167, %52
  %171 = add nuw nsw i64 %5, 1
  %172 = icmp eq i64 %54, 1999
  br i1 %172, label %173, label %3, !llvm.loop !59

173:                                              ; preds = %170
  %174 = getelementptr inbounds nuw i8, ptr %1, i64 7996
  store i32 1999, ptr %174, align 4, !tbaa !48
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(read, argmem: readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @dgesl(ptr nofree noundef readonly captures(none) %0, ptr nofree noundef readonly captures(none) %1, ptr nofree noundef captures(none) %2) local_unnamed_addr #4 {
  %4 = getelementptr i8, ptr %2, i64 16000
  br label %5

5:                                                ; preds = %3, %85
  %6 = phi i64 [ 0, %3 ], [ %21, %85 ]
  %7 = shl nuw nsw i64 %6, 3
  %8 = getelementptr i8, ptr %2, i64 %7
  %9 = getelementptr i8, ptr %8, i64 8
  %10 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %6
  %11 = load i32, ptr %10, align 4, !tbaa !48
  %12 = sext i32 %11 to i64
  %13 = getelementptr inbounds [8 x i8], ptr %2, i64 %12
  %14 = load double, ptr %13, align 8, !tbaa !11
  %15 = zext i32 %11 to i64
  %16 = icmp eq i64 %6, %15
  br i1 %16, label %20, label %17

17:                                               ; preds = %5
  %18 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %6
  %19 = load double, ptr %18, align 8, !tbaa !11
  store double %19, ptr %13, align 8, !tbaa !11
  store double %14, ptr %18, align 8, !tbaa !11
  br label %20

20:                                               ; preds = %17, %5
  %21 = add nuw nsw i64 %6, 1
  %22 = fcmp une double %14, 0.000000e+00
  br i1 %22, label %23, label %85

23:                                               ; preds = %20
  %24 = getelementptr inbounds nuw [8 x i8], ptr %0, i64 %6
  %25 = load ptr, ptr %24, align 8, !tbaa !13
  %26 = sub nuw nsw i64 1999, %6
  %27 = getelementptr [8 x i8], ptr %25, i64 %21
  %28 = getelementptr [8 x i8], ptr %2, i64 %21
  %29 = icmp samesign ugt i64 %6, 1995
  br i1 %29, label %55, label %30

30:                                               ; preds = %23
  %31 = getelementptr i8, ptr %25, i64 16000
  %32 = icmp ult ptr %9, %31
  %33 = icmp ult ptr %27, %4
  %34 = and i1 %32, %33
  br i1 %34, label %55, label %35

35:                                               ; preds = %30
  %36 = and i64 %26, 2044
  %37 = insertelement <2 x double> poison, double %14, i64 0
  %38 = shufflevector <2 x double> %37, <2 x double> poison, <2 x i32> zeroinitializer
  br label %39

39:                                               ; preds = %39, %35
  %40 = phi i64 [ 0, %35 ], [ %51, %39 ]
  %41 = getelementptr [8 x i8], ptr %27, i64 %40
  %42 = getelementptr i8, ptr %41, i64 16
  %43 = load <2 x double>, ptr %41, align 8, !tbaa !11, !alias.scope !60
  %44 = load <2 x double>, ptr %42, align 8, !tbaa !11, !alias.scope !60
  %45 = getelementptr [8 x i8], ptr %28, i64 %40
  %46 = getelementptr i8, ptr %45, i64 16
  %47 = load <2 x double>, ptr %45, align 8, !tbaa !11, !alias.scope !63, !noalias !60
  %48 = load <2 x double>, ptr %46, align 8, !tbaa !11, !alias.scope !63, !noalias !60
  %49 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %38, <2 x double> %43, <2 x double> %47)
  %50 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %38, <2 x double> %44, <2 x double> %48)
  store <2 x double> %49, ptr %45, align 8, !tbaa !11, !alias.scope !63, !noalias !60
  store <2 x double> %50, ptr %46, align 8, !tbaa !11, !alias.scope !63, !noalias !60
  %51 = add nuw i64 %40, 4
  %52 = icmp eq i64 %51, %36
  br i1 %52, label %53, label %39, !llvm.loop !65

53:                                               ; preds = %39
  %54 = icmp eq i64 %26, %36
  br i1 %54, label %85, label %55

55:                                               ; preds = %30, %23, %53
  %56 = phi i64 [ 0, %30 ], [ 0, %23 ], [ %36, %53 ]
  %57 = add nuw i64 %6, %56
  %58 = and i64 %6, 1
  %59 = icmp eq i64 %58, 0
  br i1 %59, label %60, label %67

60:                                               ; preds = %55
  %61 = getelementptr [8 x i8], ptr %27, i64 %56
  %62 = load double, ptr %61, align 8, !tbaa !11
  %63 = getelementptr [8 x i8], ptr %28, i64 %56
  %64 = load double, ptr %63, align 8, !tbaa !11
  %65 = tail call double @llvm.fmuladd.f64(double %14, double %62, double %64)
  store double %65, ptr %63, align 8, !tbaa !11
  %66 = or disjoint i64 %56, 1
  br label %67

67:                                               ; preds = %60, %55
  %68 = phi i64 [ %56, %55 ], [ %66, %60 ]
  %69 = icmp eq i64 %57, 1998
  br i1 %69, label %85, label %70

70:                                               ; preds = %67, %70
  %71 = phi i64 [ %83, %70 ], [ %68, %67 ]
  %72 = getelementptr [8 x i8], ptr %27, i64 %71
  %73 = load double, ptr %72, align 8, !tbaa !11
  %74 = getelementptr [8 x i8], ptr %28, i64 %71
  %75 = load double, ptr %74, align 8, !tbaa !11
  %76 = tail call double @llvm.fmuladd.f64(double %14, double %73, double %75)
  store double %76, ptr %74, align 8, !tbaa !11
  %77 = add nuw nsw i64 %71, 1
  %78 = getelementptr [8 x i8], ptr %27, i64 %77
  %79 = load double, ptr %78, align 8, !tbaa !11
  %80 = getelementptr [8 x i8], ptr %28, i64 %77
  %81 = load double, ptr %80, align 8, !tbaa !11
  %82 = tail call double @llvm.fmuladd.f64(double %14, double %79, double %81)
  store double %82, ptr %80, align 8, !tbaa !11
  %83 = add nuw nsw i64 %71, 2
  %84 = icmp eq i64 %83, %26
  br i1 %84, label %85, label %70, !llvm.loop !66

85:                                               ; preds = %67, %70, %53, %20
  %86 = icmp eq i64 %21, 1999
  br i1 %86, label %87, label %5, !llvm.loop !67

87:                                               ; preds = %85, %162
  %88 = phi i64 [ %92, %162 ], [ 0, %85 ]
  %89 = shl i64 %88, 3
  %90 = sub i64 15992, %89
  %91 = getelementptr i8, ptr %2, i64 %90
  %92 = add nuw nsw i64 %88, 1
  %93 = sub nuw nsw i64 1999, %88
  %94 = getelementptr inbounds nuw [8 x i8], ptr %0, i64 %93
  %95 = load ptr, ptr %94, align 8, !tbaa !13
  %96 = getelementptr inbounds nuw [8 x i8], ptr %95, i64 %93
  %97 = load double, ptr %96, align 8, !tbaa !11
  %98 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %93
  %99 = load double, ptr %98, align 8, !tbaa !11
  %100 = fdiv double %99, %97
  store double %100, ptr %98, align 8, !tbaa !11
  %101 = fneg double %100
  %102 = icmp ne i64 %88, 1999
  %103 = fcmp une double %100, 0.000000e+00
  %104 = and i1 %102, %103
  br i1 %104, label %105, label %162

105:                                              ; preds = %87
  %106 = icmp samesign ugt i64 %88, 1995
  br i1 %106, label %132, label %107

107:                                              ; preds = %105
  %108 = getelementptr i8, ptr %95, i64 %90
  %109 = icmp ult ptr %2, %108
  %110 = icmp ult ptr %95, %91
  %111 = and i1 %109, %110
  br i1 %111, label %132, label %112

112:                                              ; preds = %107
  %113 = and i64 %93, 2044
  %114 = insertelement <2 x double> poison, double %101, i64 0
  %115 = shufflevector <2 x double> %114, <2 x double> poison, <2 x i32> zeroinitializer
  br label %116

116:                                              ; preds = %116, %112
  %117 = phi i64 [ 0, %112 ], [ %128, %116 ]
  %118 = getelementptr [8 x i8], ptr %95, i64 %117
  %119 = getelementptr i8, ptr %118, i64 16
  %120 = load <2 x double>, ptr %118, align 8, !tbaa !11, !alias.scope !68
  %121 = load <2 x double>, ptr %119, align 8, !tbaa !11, !alias.scope !68
  %122 = getelementptr [8 x i8], ptr %2, i64 %117
  %123 = getelementptr i8, ptr %122, i64 16
  %124 = load <2 x double>, ptr %122, align 8, !tbaa !11, !alias.scope !71, !noalias !68
  %125 = load <2 x double>, ptr %123, align 8, !tbaa !11, !alias.scope !71, !noalias !68
  %126 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %115, <2 x double> %120, <2 x double> %124)
  %127 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %115, <2 x double> %121, <2 x double> %125)
  store <2 x double> %126, ptr %122, align 8, !tbaa !11, !alias.scope !71, !noalias !68
  store <2 x double> %127, ptr %123, align 8, !tbaa !11, !alias.scope !71, !noalias !68
  %128 = add nuw i64 %117, 4
  %129 = icmp eq i64 %128, %113
  br i1 %129, label %130, label %116, !llvm.loop !73

130:                                              ; preds = %116
  %131 = icmp eq i64 %93, %113
  br i1 %131, label %162, label %132

132:                                              ; preds = %107, %105, %130
  %133 = phi i64 [ 0, %107 ], [ 0, %105 ], [ %113, %130 ]
  %134 = add nuw i64 %88, %133
  %135 = and i64 %88, 1
  %136 = icmp eq i64 %135, 0
  br i1 %136, label %137, label %144

137:                                              ; preds = %132
  %138 = getelementptr [8 x i8], ptr %95, i64 %133
  %139 = load double, ptr %138, align 8, !tbaa !11
  %140 = getelementptr [8 x i8], ptr %2, i64 %133
  %141 = load double, ptr %140, align 8, !tbaa !11
  %142 = tail call double @llvm.fmuladd.f64(double %101, double %139, double %141)
  store double %142, ptr %140, align 8, !tbaa !11
  %143 = or disjoint i64 %133, 1
  br label %144

144:                                              ; preds = %137, %132
  %145 = phi i64 [ %133, %132 ], [ %143, %137 ]
  %146 = icmp eq i64 %134, 1998
  br i1 %146, label %162, label %147

147:                                              ; preds = %144, %147
  %148 = phi i64 [ %160, %147 ], [ %145, %144 ]
  %149 = getelementptr [8 x i8], ptr %95, i64 %148
  %150 = load double, ptr %149, align 8, !tbaa !11
  %151 = getelementptr [8 x i8], ptr %2, i64 %148
  %152 = load double, ptr %151, align 8, !tbaa !11
  %153 = tail call double @llvm.fmuladd.f64(double %101, double %150, double %152)
  store double %153, ptr %151, align 8, !tbaa !11
  %154 = add nuw nsw i64 %148, 1
  %155 = getelementptr [8 x i8], ptr %95, i64 %154
  %156 = load double, ptr %155, align 8, !tbaa !11
  %157 = getelementptr [8 x i8], ptr %2, i64 %154
  %158 = load double, ptr %157, align 8, !tbaa !11
  %159 = tail call double @llvm.fmuladd.f64(double %101, double %156, double %158)
  store double %159, ptr %157, align 8, !tbaa !11
  %160 = add nuw nsw i64 %148, 2
  %161 = icmp eq i64 %160, %93
  br i1 %161, label %162, label %147, !llvm.loop !74

162:                                              ; preds = %144, %147, %130, %87
  %163 = icmp eq i64 %92, 2000
  br i1 %163, label %164, label %87, !llvm.loop !75

164:                                              ; preds = %162
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local noundef i32 @main(i32 noundef %0, ptr nofree noundef readonly captures(none) %1) local_unnamed_addr #5 {
  %3 = icmp sgt i32 %0, 1
  br i1 %3, label %4, label %10

4:                                                ; preds = %2
  %5 = getelementptr inbounds nuw i8, ptr %1, i64 8
  %6 = load ptr, ptr %5, align 8, !tbaa !76
  %7 = tail call i32 @strcmp(ptr noundef nonnull dereferenceable(1) %6, ptr noundef nonnull dereferenceable(4) @.str) #13
  %8 = icmp eq i32 %7, 0
  %9 = select i1 %8, ptr @.str.1, ptr @.str.2
  br label %10

10:                                               ; preds = %4, %2
  %11 = phi ptr [ @.str.2, %2 ], [ %9, %4 ]
  %12 = tail call noalias dereferenceable_or_null(16000) ptr @malloc(i64 noundef 16000) #14
  br label %13

13:                                               ; preds = %10, %13
  %14 = phi i64 [ 0, %10 ], [ %17, %13 ]
  %15 = tail call noalias dereferenceable_or_null(16008) ptr @malloc(i64 noundef 16008) #14
  %16 = getelementptr inbounds nuw [8 x i8], ptr %12, i64 %14
  store ptr %15, ptr %16, align 8, !tbaa !13
  %17 = add nuw nsw i64 %14, 1
  %18 = icmp eq i64 %17, 2000
  br i1 %18, label %19, label %13, !llvm.loop !78

19:                                               ; preds = %13
  %20 = tail call noalias dereferenceable_or_null(16000) ptr @malloc(i64 noundef 16000) #14
  %21 = tail call noalias dereferenceable_or_null(8000) ptr @malloc(i64 noundef 8000) #14
  %22 = load i64, ptr @seed, align 8, !tbaa !9
  %23 = xor i64 %22, 123459876
  br label %24

24:                                               ; preds = %48, %19
  %25 = phi i64 [ 0, %19 ], [ %49, %48 ]
  %26 = phi i64 [ %23, %19 ], [ %40, %48 ]
  br label %29

27:                                               ; preds = %48
  %28 = xor i64 %40, 123459876
  store i64 %28, ptr @seed, align 8, !tbaa !9
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 8 dereferenceable(16000) %20, i8 0, i64 16000, i1 false), !tbaa !11
  br label %51

29:                                               ; preds = %29, %24
  %30 = phi i64 [ 0, %24 ], [ %46, %29 ]
  %31 = phi i64 [ %26, %24 ], [ %40, %29 ]
  %32 = sdiv i64 %31, 127773
  %33 = mul nsw i64 %32, -127773
  %34 = add i64 %33, %31
  %35 = mul nsw i64 %34, 16807
  %36 = mul nsw i64 %32, -2836
  %37 = add i64 %35, %36
  %38 = icmp slt i64 %37, 0
  %39 = add nsw i64 %37, 2147483647
  %40 = select i1 %38, i64 %39, i64 %37
  %41 = sitofp i64 %40 to double
  %42 = fmul nnan double %41, f0x3E00000000200FE1
  %43 = getelementptr inbounds nuw [8 x i8], ptr %12, i64 %30
  %44 = load ptr, ptr %43, align 8, !tbaa !13
  %45 = getelementptr inbounds nuw [8 x i8], ptr %44, i64 %25
  store double %42, ptr %45, align 8, !tbaa !11
  %46 = add nuw nsw i64 %30, 1
  %47 = icmp eq i64 %46, 2000
  br i1 %47, label %48, label %29, !llvm.loop !16

48:                                               ; preds = %29
  %49 = add nuw nsw i64 %25, 1
  %50 = icmp eq i64 %49, 2000
  br i1 %50, label %27, label %24, !llvm.loop !18

51:                                               ; preds = %80, %27
  %52 = phi i64 [ 0, %27 ], [ %81, %80 ]
  %53 = getelementptr inbounds nuw [8 x i8], ptr %12, i64 %52
  %54 = load ptr, ptr %53, align 8, !tbaa !13
  br label %55

55:                                               ; preds = %55, %51
  %56 = phi i64 [ 0, %51 ], [ %78, %55 ]
  %57 = getelementptr inbounds nuw [8 x i8], ptr %54, i64 %56
  %58 = getelementptr inbounds nuw i8, ptr %57, i64 16
  %59 = load <2 x double>, ptr %57, align 8, !tbaa !11
  %60 = load <2 x double>, ptr %58, align 8, !tbaa !11
  %61 = getelementptr inbounds nuw [8 x i8], ptr %20, i64 %56
  %62 = getelementptr inbounds nuw i8, ptr %61, i64 16
  %63 = load <2 x double>, ptr %61, align 8, !tbaa !11
  %64 = load <2 x double>, ptr %62, align 8, !tbaa !11
  %65 = fadd <2 x double> %59, %63
  %66 = fadd <2 x double> %60, %64
  store <2 x double> %65, ptr %61, align 8, !tbaa !11
  store <2 x double> %66, ptr %62, align 8, !tbaa !11
  %67 = or disjoint i64 %56, 4
  %68 = getelementptr inbounds nuw [8 x i8], ptr %54, i64 %67
  %69 = getelementptr inbounds nuw i8, ptr %68, i64 16
  %70 = load <2 x double>, ptr %68, align 8, !tbaa !11
  %71 = load <2 x double>, ptr %69, align 8, !tbaa !11
  %72 = getelementptr inbounds nuw [8 x i8], ptr %20, i64 %67
  %73 = getelementptr inbounds nuw i8, ptr %72, i64 16
  %74 = load <2 x double>, ptr %72, align 8, !tbaa !11
  %75 = load <2 x double>, ptr %73, align 8, !tbaa !11
  %76 = fadd <2 x double> %70, %74
  %77 = fadd <2 x double> %71, %75
  store <2 x double> %76, ptr %72, align 8, !tbaa !11
  store <2 x double> %77, ptr %73, align 8, !tbaa !11
  %78 = add nuw nsw i64 %56, 8
  %79 = icmp eq i64 %78, 2000
  br i1 %79, label %80, label %55, !llvm.loop !79

80:                                               ; preds = %55
  %81 = add nuw nsw i64 %52, 1
  %82 = icmp eq i64 %81, 2000
  br i1 %82, label %83, label %51, !llvm.loop !28

83:                                               ; preds = %80
  tail call void @dgefa(ptr noundef nonnull %12, ptr noundef %21)
  br label %84

84:                                               ; preds = %137, %83
  %85 = phi i64 [ 0, %83 ], [ %97, %137 ]
  %86 = getelementptr inbounds nuw [4 x i8], ptr %21, i64 %85
  %87 = load i32, ptr %86, align 4, !tbaa !48
  %88 = sext i32 %87 to i64
  %89 = getelementptr inbounds [8 x i8], ptr %20, i64 %88
  %90 = load double, ptr %89, align 8, !tbaa !11
  %91 = zext i32 %87 to i64
  %92 = icmp eq i64 %85, %91
  br i1 %92, label %96, label %93

93:                                               ; preds = %84
  %94 = getelementptr inbounds nuw [8 x i8], ptr %20, i64 %85
  %95 = load double, ptr %94, align 8, !tbaa !11
  store double %95, ptr %89, align 8, !tbaa !11
  store double %90, ptr %94, align 8, !tbaa !11
  br label %96

96:                                               ; preds = %93, %84
  %97 = add nuw nsw i64 %85, 1
  %98 = fcmp une double %90, 0.000000e+00
  br i1 %98, label %99, label %137

99:                                               ; preds = %96
  %100 = getelementptr inbounds nuw [8 x i8], ptr %12, i64 %85
  %101 = load ptr, ptr %100, align 8, !tbaa !13
  %102 = sub nuw nsw i64 1999, %85
  %103 = getelementptr [8 x i8], ptr %101, i64 %97
  %104 = getelementptr [8 x i8], ptr %20, i64 %97
  %105 = icmp samesign ugt i64 %85, 1995
  br i1 %105, label %126, label %106

106:                                              ; preds = %99
  %107 = and i64 %102, 2044
  %108 = insertelement <2 x double> poison, double %90, i64 0
  %109 = shufflevector <2 x double> %108, <2 x double> poison, <2 x i32> zeroinitializer
  br label %110

110:                                              ; preds = %110, %106
  %111 = phi i64 [ 0, %106 ], [ %122, %110 ]
  %112 = getelementptr [8 x i8], ptr %103, i64 %111
  %113 = getelementptr i8, ptr %112, i64 16
  %114 = load <2 x double>, ptr %112, align 8, !tbaa !11
  %115 = load <2 x double>, ptr %113, align 8, !tbaa !11
  %116 = getelementptr [8 x i8], ptr %104, i64 %111
  %117 = getelementptr i8, ptr %116, i64 16
  %118 = load <2 x double>, ptr %116, align 8, !tbaa !11
  %119 = load <2 x double>, ptr %117, align 8, !tbaa !11
  %120 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %109, <2 x double> %114, <2 x double> %118)
  %121 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %109, <2 x double> %115, <2 x double> %119)
  store <2 x double> %120, ptr %116, align 8, !tbaa !11
  store <2 x double> %121, ptr %117, align 8, !tbaa !11
  %122 = add nuw i64 %111, 4
  %123 = icmp eq i64 %122, %107
  br i1 %123, label %124, label %110, !llvm.loop !80

124:                                              ; preds = %110
  %125 = icmp eq i64 %102, %107
  br i1 %125, label %137, label %126

126:                                              ; preds = %99, %124
  %127 = phi i64 [ 0, %99 ], [ %107, %124 ]
  br label %128

128:                                              ; preds = %126, %128
  %129 = phi i64 [ %135, %128 ], [ %127, %126 ]
  %130 = getelementptr [8 x i8], ptr %103, i64 %129
  %131 = load double, ptr %130, align 8, !tbaa !11
  %132 = getelementptr [8 x i8], ptr %104, i64 %129
  %133 = load double, ptr %132, align 8, !tbaa !11
  %134 = tail call double @llvm.fmuladd.f64(double %90, double %131, double %133)
  store double %134, ptr %132, align 8, !tbaa !11
  %135 = add nuw nsw i64 %129, 1
  %136 = icmp eq i64 %135, %102
  br i1 %136, label %137, label %128, !llvm.loop !81

137:                                              ; preds = %128, %124, %96
  %138 = icmp eq i64 %97, 1999
  br i1 %138, label %139, label %84, !llvm.loop !67

139:                                              ; preds = %137, %187
  %140 = phi i64 [ %141, %187 ], [ 0, %137 ]
  %141 = add nuw nsw i64 %140, 1
  %142 = sub nuw nsw i64 1999, %140
  %143 = getelementptr inbounds nuw [8 x i8], ptr %12, i64 %142
  %144 = load ptr, ptr %143, align 8, !tbaa !13
  %145 = getelementptr inbounds nuw [8 x i8], ptr %144, i64 %142
  %146 = load double, ptr %145, align 8, !tbaa !11
  %147 = getelementptr inbounds nuw [8 x i8], ptr %20, i64 %142
  %148 = load double, ptr %147, align 8, !tbaa !11
  %149 = fdiv double %148, %146
  store double %149, ptr %147, align 8, !tbaa !11
  %150 = fneg double %149
  %151 = icmp ne i64 %140, 1999
  %152 = fcmp une double %149, 0.000000e+00
  %153 = and i1 %151, %152
  br i1 %153, label %154, label %187

154:                                              ; preds = %139
  %155 = icmp samesign ugt i64 %140, 1995
  br i1 %155, label %176, label %156

156:                                              ; preds = %154
  %157 = and i64 %142, 2044
  %158 = insertelement <2 x double> poison, double %150, i64 0
  %159 = shufflevector <2 x double> %158, <2 x double> poison, <2 x i32> zeroinitializer
  br label %160

160:                                              ; preds = %160, %156
  %161 = phi i64 [ 0, %156 ], [ %172, %160 ]
  %162 = getelementptr [8 x i8], ptr %144, i64 %161
  %163 = getelementptr i8, ptr %162, i64 16
  %164 = load <2 x double>, ptr %162, align 8, !tbaa !11
  %165 = load <2 x double>, ptr %163, align 8, !tbaa !11
  %166 = getelementptr [8 x i8], ptr %20, i64 %161
  %167 = getelementptr i8, ptr %166, i64 16
  %168 = load <2 x double>, ptr %166, align 8, !tbaa !11
  %169 = load <2 x double>, ptr %167, align 8, !tbaa !11
  %170 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %159, <2 x double> %164, <2 x double> %168)
  %171 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %159, <2 x double> %165, <2 x double> %169)
  store <2 x double> %170, ptr %166, align 8, !tbaa !11
  store <2 x double> %171, ptr %167, align 8, !tbaa !11
  %172 = add nuw i64 %161, 4
  %173 = icmp eq i64 %172, %157
  br i1 %173, label %174, label %160, !llvm.loop !82

174:                                              ; preds = %160
  %175 = icmp eq i64 %142, %157
  br i1 %175, label %187, label %176

176:                                              ; preds = %154, %174
  %177 = phi i64 [ 0, %154 ], [ %157, %174 ]
  br label %178

178:                                              ; preds = %176, %178
  %179 = phi i64 [ %185, %178 ], [ %177, %176 ]
  %180 = getelementptr [8 x i8], ptr %144, i64 %179
  %181 = load double, ptr %180, align 8, !tbaa !11
  %182 = getelementptr [8 x i8], ptr %20, i64 %179
  %183 = load double, ptr %182, align 8, !tbaa !11
  %184 = tail call double @llvm.fmuladd.f64(double %150, double %181, double %183)
  store double %184, ptr %182, align 8, !tbaa !11
  %185 = add nuw nsw i64 %179, 1
  %186 = icmp eq i64 %185, %142
  br i1 %186, label %187, label %178, !llvm.loop !83

187:                                              ; preds = %178, %174, %139
  %188 = icmp eq i64 %141, 2000
  br i1 %188, label %189, label %139, !llvm.loop !75

189:                                              ; preds = %187
  tail call void @free(ptr noundef %21) #15
  tail call void @free(ptr noundef nonnull %20) #15
  br label %190

190:                                              ; preds = %189, %190
  %191 = phi i64 [ 0, %189 ], [ %194, %190 ]
  %192 = getelementptr inbounds nuw [8 x i8], ptr %12, i64 %191
  %193 = load ptr, ptr %192, align 8, !tbaa !13
  tail call void @free(ptr noundef %193) #15
  %194 = add nuw nsw i64 %191, 1
  %195 = icmp eq i64 %194, 2000
  br i1 %195, label %196, label %190, !llvm.loop !84

196:                                              ; preds = %190
  tail call void @free(ptr noundef nonnull %12) #15
  %197 = load ptr, ptr @stdout, align 8, !tbaa !85
  %198 = tail call i32 (ptr, ptr, ...) @fprintf(ptr noundef %197, ptr noundef nonnull %11, double noundef 0.000000e+00) #15
  %199 = load ptr, ptr @stdout, align 8, !tbaa !85
  %200 = tail call i32 @fflush(ptr noundef %199)
  ret i32 0
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: read)
declare i32 @strcmp(ptr noundef captures(none), ptr noundef captures(none)) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nounwind willreturn allockind("alloc,uninitialized") allocsize(0) memory(inaccessiblemem: readwrite, errnomem: write)
declare noalias noundef ptr @malloc(i64 noundef) local_unnamed_addr #7

; Function Attrs: mustprogress nounwind willreturn allockind("free") memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @free(ptr allocptr noundef captures(none)) local_unnamed_addr #8

; Function Attrs: nofree nounwind
declare noundef i32 @fprintf(ptr noundef captures(none), ptr noundef readonly captures(none), ...) local_unnamed_addr #9

; Function Attrs: nofree nounwind
declare noundef i32 @fflush(ptr noundef captures(none)) local_unnamed_addr #9

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #10

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write)
declare void @llvm.assume(i1 noundef) #11

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare <2 x double> @llvm.fmuladd.v2f64(<2 x double>, <2 x double>, <2 x double>) #12

attributes #0 = { nofree norecurse nosync nounwind memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree norecurse nosync nounwind memory(argmem: read) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #3 = { nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nofree norecurse nosync nounwind memory(read, argmem: readwrite, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: read) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #7 = { mustprogress nofree nounwind willreturn allockind("alloc,uninitialized") allocsize(0) memory(inaccessiblemem: readwrite, errnomem: write) "alloc-family"="malloc" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #8 = { mustprogress nounwind willreturn allockind("free") memory(argmem: readwrite, inaccessiblemem: readwrite) "alloc-family"="malloc" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #9 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #10 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #11 = { nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write) }
attributes #12 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #13 = { nounwind willreturn memory(read) }
attributes #14 = { nounwind allocsize(0) }
attributes #15 = { nounwind }

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
!10 = !{!"long", !7, i64 0}
!11 = !{!12, !12, i64 0}
!12 = !{!"double", !7, i64 0}
!13 = !{!14, !14, i64 0}
!14 = !{!"p1 double", !15, i64 0}
!15 = !{!"any pointer", !7, i64 0}
!16 = distinct !{!16, !17}
!17 = !{!"llvm.loop.mustprogress"}
!18 = distinct !{!18, !17}
!19 = !{!20}
!20 = distinct !{!20, !21}
!21 = distinct !{!21, !"LVerDomain"}
!22 = !{!23}
!23 = distinct !{!23, !21}
!24 = distinct !{!24, !17, !25, !26}
!25 = !{!"llvm.loop.isvectorized", i32 1}
!26 = !{!"llvm.loop.unroll.runtime.disable"}
!27 = distinct !{!27, !17, !25}
!28 = distinct !{!28, !17}
!29 = distinct !{!29, !17}
!30 = distinct !{!30, !17}
!31 = distinct !{!31, !17, !25, !26}
!32 = distinct !{!32, !17, !25}
!33 = distinct !{!33, !17, !26, !25}
!34 = !{!35}
!35 = distinct !{!35, !36}
!36 = distinct !{!36, !"LVerDomain"}
!37 = !{!38}
!38 = distinct !{!38, !36}
!39 = distinct !{!39, !17, !25, !26}
!40 = !{!41}
!41 = distinct !{!41, !42}
!42 = distinct !{!42, !"LVerDomain"}
!43 = !{!44}
!44 = distinct !{!44, !42}
!45 = distinct !{!45, !17, !25, !26}
!46 = distinct !{!46, !17, !25}
!47 = distinct !{!47, !17, !25}
!48 = !{!6, !6, i64 0}
!49 = distinct !{!49, !17, !25, !26}
!50 = distinct !{!50, !17, !26, !25}
!51 = !{!52}
!52 = distinct !{!52, !53}
!53 = distinct !{!53, !"LVerDomain"}
!54 = !{!55}
!55 = distinct !{!55, !53}
!56 = distinct !{!56, !17, !25, !26}
!57 = distinct !{!57, !17, !25}
!58 = distinct !{!58, !17}
!59 = distinct !{!59, !17}
!60 = !{!61}
!61 = distinct !{!61, !62}
!62 = distinct !{!62, !"LVerDomain"}
!63 = !{!64}
!64 = distinct !{!64, !62}
!65 = distinct !{!65, !17, !25, !26}
!66 = distinct !{!66, !17, !25}
!67 = distinct !{!67, !17}
!68 = !{!69}
!69 = distinct !{!69, !70}
!70 = distinct !{!70, !"LVerDomain"}
!71 = !{!72}
!72 = distinct !{!72, !70}
!73 = distinct !{!73, !17, !25, !26}
!74 = distinct !{!74, !17, !25}
!75 = distinct !{!75, !17}
!76 = !{!77, !77, i64 0}
!77 = !{!"p1 omnipotent char", !15, i64 0}
!78 = distinct !{!78, !17}
!79 = distinct !{!79, !17, !25, !26}
!80 = distinct !{!80, !17, !25, !26}
!81 = distinct !{!81, !17, !26, !25}
!82 = distinct !{!82, !17, !25, !26}
!83 = distinct !{!83, !17, !26, !25}
!84 = distinct !{!84, !17}
!85 = !{!86, !86, i64 0}
!86 = !{!"p1 _ZTS8_IO_FILE", !15, i64 0}
