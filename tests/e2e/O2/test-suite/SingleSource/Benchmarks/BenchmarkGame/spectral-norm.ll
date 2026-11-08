; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/BenchmarkGame/spectral-norm.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/BenchmarkGame/spectral-norm.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/BenchmarkGame/spectral-norm.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [7 x i8] c"%0.9f\0A\00", align 1

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local double @eval_A(i32 noundef %0, i32 noundef %1) local_unnamed_addr #0 {
  %3 = add nsw i32 %1, %0
  %4 = add nsw i32 %3, 1
  %5 = mul nsw i32 %4, %3
  %6 = sdiv i32 %5, 2
  %7 = add i32 %0, 1
  %8 = add i32 %7, %6
  %9 = sitofp i32 %8 to double
  %10 = fdiv double 1.000000e+00, %9
  ret double %10
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @eval_A_times_u(i32 noundef %0, ptr nofree noundef readonly captures(none) %1, ptr nofree noundef writeonly captures(none) %2) local_unnamed_addr #1 {
  %4 = icmp sgt i32 %0, 0
  br i1 %4, label %5, label %65

5:                                                ; preds = %3
  %6 = zext nneg i32 %0 to i64
  %7 = and i64 %6, 1
  %8 = icmp eq i32 %0, 1
  %9 = and i64 %6, 2147483646
  %10 = icmp eq i64 %7, 0
  %11 = trunc i32 %0 to i1
  br label %12

12:                                               ; preds = %63, %5
  %13 = phi i64 [ 0, %5 ], [ %15, %63 ]
  %14 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %13
  store double 0.000000e+00, ptr %14, align 8, !tbaa !9
  %15 = add nuw nsw i64 %13, 1
  %16 = add nuw i64 %13, 1
  %17 = trunc nuw nsw i64 %15 to i32
  br i1 %8, label %49, label %18

18:                                               ; preds = %12, %18
  %19 = phi i64 [ %45, %18 ], [ 0, %12 ]
  %20 = phi double [ %44, %18 ], [ 0.000000e+00, %12 ]
  %21 = phi i64 [ %46, %18 ], [ 0, %12 ]
  %22 = add nuw nsw i64 %19, %13
  %23 = add i64 %19, %16
  %24 = mul i64 %23, %22
  %25 = trunc i64 %24 to i32
  %26 = lshr i32 %25, 1
  %27 = add i32 %26, %17
  %28 = sitofp i32 %27 to double
  %29 = fdiv double 1.000000e+00, %28
  %30 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %19
  %31 = load double, ptr %30, align 8, !tbaa !9
  %32 = tail call double @llvm.fmuladd.f64(double %29, double %31, double %20)
  store double %32, ptr %14, align 8, !tbaa !9
  %33 = or disjoint i64 %19, 1
  %34 = add nuw nsw i64 %33, %13
  %35 = add i64 %33, %16
  %36 = mul i64 %35, %34
  %37 = trunc i64 %36 to i32
  %38 = lshr i32 %37, 1
  %39 = add i32 %38, %17
  %40 = sitofp i32 %39 to double
  %41 = fdiv double 1.000000e+00, %40
  %42 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %33
  %43 = load double, ptr %42, align 8, !tbaa !9
  %44 = tail call double @llvm.fmuladd.f64(double %41, double %43, double %32)
  store double %44, ptr %14, align 8, !tbaa !9
  %45 = add nuw nsw i64 %19, 2
  %46 = add i64 %21, 2
  %47 = icmp eq i64 %46, %9
  br i1 %47, label %48, label %18, !llvm.loop !11

48:                                               ; preds = %18
  br i1 %10, label %63, label %49

49:                                               ; preds = %48, %12
  %50 = phi i64 [ 0, %12 ], [ %45, %48 ]
  %51 = phi double [ 0.000000e+00, %12 ], [ %44, %48 ]
  tail call void @llvm.assume(i1 %11)
  %52 = add nuw nsw i64 %50, %13
  %53 = add i64 %50, %16
  %54 = mul i64 %53, %52
  %55 = trunc i64 %54 to i32
  %56 = lshr i32 %55, 1
  %57 = add i32 %56, %17
  %58 = sitofp i32 %57 to double
  %59 = fdiv double 1.000000e+00, %58
  %60 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %50
  %61 = load double, ptr %60, align 8, !tbaa !9
  %62 = tail call double @llvm.fmuladd.f64(double %59, double %61, double %51)
  store double %62, ptr %14, align 8, !tbaa !9
  br label %63

63:                                               ; preds = %48, %49
  %64 = icmp eq i64 %15, %6
  br i1 %64, label %65, label %12, !llvm.loop !13

65:                                               ; preds = %63, %3
  ret void
}

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #2

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @eval_At_times_u(i32 noundef %0, ptr nofree noundef readonly captures(none) %1, ptr nofree noundef writeonly captures(none) %2) local_unnamed_addr #1 {
  %4 = icmp sgt i32 %0, 0
  br i1 %4, label %5, label %68

5:                                                ; preds = %3
  %6 = zext nneg i32 %0 to i64
  %7 = and i64 %6, 1
  %8 = icmp eq i32 %0, 1
  %9 = and i64 %6, 2147483646
  %10 = icmp eq i64 %7, 0
  %11 = trunc i32 %0 to i1
  br label %12

12:                                               ; preds = %65, %5
  %13 = phi i64 [ 0, %5 ], [ %66, %65 ]
  %14 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %13
  store double 0.000000e+00, ptr %14, align 8, !tbaa !9
  %15 = add nuw i64 %13, 1
  br i1 %8, label %49, label %16

16:                                               ; preds = %12, %16
  %17 = phi i64 [ %38, %16 ], [ 0, %12 ]
  %18 = phi double [ %45, %16 ], [ 0.000000e+00, %12 ]
  %19 = phi i64 [ %46, %16 ], [ 0, %12 ]
  %20 = add nuw nsw i64 %17, %13
  %21 = add i64 %17, %15
  %22 = mul i64 %21, %20
  %23 = trunc i64 %22 to i32
  %24 = lshr i32 %23, 1
  %25 = or disjoint i64 %17, 1
  %26 = trunc nuw nsw i64 %25 to i32
  %27 = add nuw i32 %24, %26
  %28 = sitofp i32 %27 to double
  %29 = fdiv double 1.000000e+00, %28
  %30 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %17
  %31 = load double, ptr %30, align 8, !tbaa !9
  %32 = tail call double @llvm.fmuladd.f64(double %29, double %31, double %18)
  store double %32, ptr %14, align 8, !tbaa !9
  %33 = add nuw nsw i64 %25, %13
  %34 = add i64 %25, %15
  %35 = mul i64 %34, %33
  %36 = trunc i64 %35 to i32
  %37 = lshr i32 %36, 1
  %38 = add nuw nsw i64 %17, 2
  %39 = trunc nuw nsw i64 %38 to i32
  %40 = add nuw i32 %37, %39
  %41 = sitofp i32 %40 to double
  %42 = fdiv double 1.000000e+00, %41
  %43 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %25
  %44 = load double, ptr %43, align 8, !tbaa !9
  %45 = tail call double @llvm.fmuladd.f64(double %42, double %44, double %32)
  store double %45, ptr %14, align 8, !tbaa !9
  %46 = add i64 %19, 2
  %47 = icmp eq i64 %46, %9
  br i1 %47, label %48, label %16, !llvm.loop !14

48:                                               ; preds = %16
  br i1 %10, label %65, label %49

49:                                               ; preds = %48, %12
  %50 = phi i64 [ 0, %12 ], [ %38, %48 ]
  %51 = phi double [ 0.000000e+00, %12 ], [ %45, %48 ]
  tail call void @llvm.assume(i1 %11)
  %52 = add nuw nsw i64 %50, %13
  %53 = add i64 %50, %15
  %54 = mul i64 %53, %52
  %55 = trunc i64 %54 to i32
  %56 = lshr i32 %55, 1
  %57 = trunc i64 %50 to i32
  %58 = add i32 %57, 1
  %59 = add nuw i32 %56, %58
  %60 = sitofp i32 %59 to double
  %61 = fdiv double 1.000000e+00, %60
  %62 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %50
  %63 = load double, ptr %62, align 8, !tbaa !9
  %64 = tail call double @llvm.fmuladd.f64(double %61, double %63, double %51)
  store double %64, ptr %14, align 8, !tbaa !9
  br label %65

65:                                               ; preds = %48, %49
  %66 = add nuw nsw i64 %13, 1
  %67 = icmp eq i64 %66, %6
  br i1 %67, label %68, label %12, !llvm.loop !15

68:                                               ; preds = %65, %3
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @eval_AtA_times_u(i32 noundef %0, ptr nofree noundef readonly captures(none) %1, ptr nofree noundef writeonly captures(none) %2) local_unnamed_addr #1 {
  %4 = zext i32 %0 to i64
  %5 = alloca double, i64 %4, align 16
  %6 = icmp sgt i32 %0, 0
  br i1 %6, label %7, label %129

7:                                                ; preds = %3
  %8 = add nsw i64 %4, -1
  %9 = and i64 %4, 1
  %10 = icmp eq i64 %8, 0
  %11 = and i64 %4, 2147483646
  %12 = icmp eq i64 %9, 0
  %13 = trunc i32 %0 to i1
  br label %14

14:                                               ; preds = %7, %64
  %15 = phi i64 [ %17, %64 ], [ 0, %7 ]
  %16 = getelementptr inbounds nuw [8 x i8], ptr %5, i64 %15
  %17 = add nuw nsw i64 %15, 1
  %18 = trunc nuw nsw i64 %17 to i32
  br i1 %10, label %50, label %19

19:                                               ; preds = %14, %19
  %20 = phi i64 [ %46, %19 ], [ 0, %14 ]
  %21 = phi double [ %45, %19 ], [ 0.000000e+00, %14 ]
  %22 = phi i64 [ %47, %19 ], [ 0, %14 ]
  %23 = add nuw nsw i64 %20, %15
  %24 = add nuw nsw i64 %20, %17
  %25 = mul i64 %24, %23
  %26 = trunc i64 %25 to i32
  %27 = lshr i32 %26, 1
  %28 = add i32 %27, %18
  %29 = sitofp i32 %28 to double
  %30 = fdiv double 1.000000e+00, %29
  %31 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %20
  %32 = load double, ptr %31, align 8, !tbaa !9
  %33 = tail call double @llvm.fmuladd.f64(double %30, double %32, double %21)
  %34 = or disjoint i64 %20, 1
  %35 = add nuw nsw i64 %34, %15
  %36 = add nuw nsw i64 %34, %17
  %37 = mul i64 %36, %35
  %38 = trunc i64 %37 to i32
  %39 = lshr i32 %38, 1
  %40 = add i32 %39, %18
  %41 = sitofp i32 %40 to double
  %42 = fdiv double 1.000000e+00, %41
  %43 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %34
  %44 = load double, ptr %43, align 8, !tbaa !9
  %45 = tail call double @llvm.fmuladd.f64(double %42, double %44, double %33)
  %46 = add nuw nsw i64 %20, 2
  %47 = add i64 %22, 2
  %48 = icmp eq i64 %47, %11
  br i1 %48, label %49, label %19, !llvm.loop !11

49:                                               ; preds = %19
  br i1 %12, label %64, label %50

50:                                               ; preds = %49, %14
  %51 = phi i64 [ 0, %14 ], [ %46, %49 ]
  %52 = phi double [ 0.000000e+00, %14 ], [ %45, %49 ]
  tail call void @llvm.assume(i1 %13)
  %53 = add nuw nsw i64 %51, %15
  %54 = add nuw nsw i64 %51, %17
  %55 = mul i64 %54, %53
  %56 = trunc i64 %55 to i32
  %57 = lshr i32 %56, 1
  %58 = add i32 %57, %18
  %59 = sitofp i32 %58 to double
  %60 = fdiv double 1.000000e+00, %59
  %61 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %51
  %62 = load double, ptr %61, align 8, !tbaa !9
  %63 = tail call double @llvm.fmuladd.f64(double %60, double %62, double %52)
  br label %64

64:                                               ; preds = %49, %50
  %65 = phi double [ %45, %49 ], [ %63, %50 ]
  store double %65, ptr %16, align 8, !tbaa !9
  %66 = icmp eq i64 %17, %4
  br i1 %66, label %67, label %14, !llvm.loop !13

67:                                               ; preds = %64
  %68 = and i64 %4, 1
  %69 = icmp eq i64 %8, 0
  %70 = and i64 %4, 2147483646
  %71 = icmp eq i64 %68, 0
  %72 = trunc i32 %0 to i1
  br label %73

73:                                               ; preds = %67, %126
  %74 = phi i64 [ %76, %126 ], [ 0, %67 ]
  %75 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %74
  %76 = add nuw nsw i64 %74, 1
  br i1 %69, label %110, label %77

77:                                               ; preds = %73, %77
  %78 = phi i64 [ %99, %77 ], [ 0, %73 ]
  %79 = phi double [ %106, %77 ], [ 0.000000e+00, %73 ]
  %80 = phi i64 [ %107, %77 ], [ 0, %73 ]
  %81 = add nuw nsw i64 %78, %74
  %82 = add nuw nsw i64 %78, %76
  %83 = mul i64 %82, %81
  %84 = trunc i64 %83 to i32
  %85 = lshr i32 %84, 1
  %86 = or disjoint i64 %78, 1
  %87 = trunc nuw nsw i64 %86 to i32
  %88 = add nuw i32 %85, %87
  %89 = sitofp i32 %88 to double
  %90 = fdiv double 1.000000e+00, %89
  %91 = getelementptr inbounds nuw [8 x i8], ptr %5, i64 %78
  %92 = load double, ptr %91, align 16, !tbaa !9
  %93 = tail call double @llvm.fmuladd.f64(double %90, double %92, double %79)
  %94 = add nuw nsw i64 %86, %74
  %95 = add nuw nsw i64 %86, %76
  %96 = mul i64 %95, %94
  %97 = trunc i64 %96 to i32
  %98 = lshr i32 %97, 1
  %99 = add nuw nsw i64 %78, 2
  %100 = trunc nuw nsw i64 %99 to i32
  %101 = add nuw i32 %98, %100
  %102 = sitofp i32 %101 to double
  %103 = fdiv double 1.000000e+00, %102
  %104 = getelementptr inbounds nuw [8 x i8], ptr %5, i64 %86
  %105 = load double, ptr %104, align 8, !tbaa !9
  %106 = tail call double @llvm.fmuladd.f64(double %103, double %105, double %93)
  %107 = add i64 %80, 2
  %108 = icmp eq i64 %107, %70
  br i1 %108, label %109, label %77, !llvm.loop !14

109:                                              ; preds = %77
  br i1 %71, label %126, label %110

110:                                              ; preds = %109, %73
  %111 = phi i64 [ 0, %73 ], [ %99, %109 ]
  %112 = phi double [ 0.000000e+00, %73 ], [ %106, %109 ]
  tail call void @llvm.assume(i1 %72)
  %113 = add nuw nsw i64 %111, %74
  %114 = add nuw nsw i64 %111, %76
  %115 = mul i64 %114, %113
  %116 = trunc i64 %115 to i32
  %117 = lshr i32 %116, 1
  %118 = trunc i64 %111 to i32
  %119 = add i32 %118, 1
  %120 = add nuw i32 %117, %119
  %121 = sitofp i32 %120 to double
  %122 = fdiv double 1.000000e+00, %121
  %123 = getelementptr inbounds nuw [8 x i8], ptr %5, i64 %111
  %124 = load double, ptr %123, align 8, !tbaa !9
  %125 = tail call double @llvm.fmuladd.f64(double %122, double %124, double %112)
  br label %126

126:                                              ; preds = %109, %110
  %127 = phi double [ %106, %109 ], [ %125, %110 ]
  store double %127, ptr %75, align 8, !tbaa !9
  %128 = icmp eq i64 %76, %4
  br i1 %128, label %129, label %73, !llvm.loop !15

129:                                              ; preds = %126, %3
  ret void
}

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main(i32 noundef %0, ptr nofree noundef readonly captures(none) %1) local_unnamed_addr #3 {
  %3 = icmp eq i32 %0, 2
  br i1 %3, label %7, label %4

4:                                                ; preds = %2
  %5 = alloca [2000 x double], align 16
  %6 = alloca [2000 x double], align 16
  br label %16

7:                                                ; preds = %2
  %8 = getelementptr inbounds nuw i8, ptr %1, i64 8
  %9 = load ptr, ptr %8, align 8, !tbaa !16
  %10 = tail call i64 @strtol(ptr noundef nonnull captures(none) %9, ptr noundef null, i32 noundef 10) #9, !inline_history !19
  %11 = trunc i64 %10 to i32
  %12 = and i64 %10, 4294967295
  %13 = alloca double, i64 %12, align 16
  %14 = alloca double, i64 %12, align 16
  %15 = icmp sgt i32 %11, 0
  br i1 %15, label %16, label %34

16:                                               ; preds = %4, %7
  %17 = phi ptr [ %6, %4 ], [ %14, %7 ]
  %18 = phi ptr [ %5, %4 ], [ %13, %7 ]
  %19 = phi i64 [ 2000, %4 ], [ %12, %7 ]
  %20 = phi i32 [ 2000, %4 ], [ %11, %7 ]
  %21 = icmp samesign ult i64 %19, 4
  br i1 %21, label %32, label %22

22:                                               ; preds = %16
  %23 = and i64 %19, 4294967292
  br label %24

24:                                               ; preds = %24, %22
  %25 = phi i64 [ 0, %22 ], [ %28, %24 ]
  %26 = getelementptr inbounds nuw [8 x i8], ptr %18, i64 %25
  %27 = getelementptr inbounds nuw i8, ptr %26, i64 16
  store <2 x double> splat (double 1.000000e+00), ptr %26, align 16, !tbaa !9
  store <2 x double> splat (double 1.000000e+00), ptr %27, align 16, !tbaa !9
  %28 = add nuw i64 %25, 4
  %29 = icmp eq i64 %28, %23
  br i1 %29, label %30, label %24, !llvm.loop !20

30:                                               ; preds = %24
  %31 = icmp eq i64 %19, %23
  br i1 %31, label %34, label %32

32:                                               ; preds = %16, %30
  %33 = phi i64 [ 0, %16 ], [ %23, %30 ]
  br label %45

34:                                               ; preds = %45, %30, %7
  %35 = phi i1 [ false, %7 ], [ true, %30 ], [ true, %45 ]
  %36 = phi ptr [ %14, %7 ], [ %17, %30 ], [ %17, %45 ]
  %37 = phi ptr [ %13, %7 ], [ %18, %30 ], [ %18, %45 ]
  %38 = phi i64 [ %12, %7 ], [ %19, %30 ], [ %19, %45 ]
  %39 = phi i32 [ %11, %7 ], [ %20, %30 ], [ %20, %45 ]
  call void @eval_AtA_times_u(i32 noundef %39, ptr noundef nonnull %37, ptr noundef nonnull %36)
  call void @eval_AtA_times_u(i32 noundef %39, ptr noundef nonnull %36, ptr noundef nonnull %37)
  call void @eval_AtA_times_u(i32 noundef %39, ptr noundef nonnull %37, ptr noundef nonnull %36)
  call void @eval_AtA_times_u(i32 noundef %39, ptr noundef nonnull %36, ptr noundef nonnull %37)
  call void @eval_AtA_times_u(i32 noundef %39, ptr noundef nonnull %37, ptr noundef nonnull %36)
  call void @eval_AtA_times_u(i32 noundef %39, ptr noundef nonnull %36, ptr noundef nonnull %37)
  call void @eval_AtA_times_u(i32 noundef %39, ptr noundef nonnull %37, ptr noundef nonnull %36)
  call void @eval_AtA_times_u(i32 noundef %39, ptr noundef nonnull %36, ptr noundef nonnull %37)
  call void @eval_AtA_times_u(i32 noundef %39, ptr noundef nonnull %37, ptr noundef nonnull %36)
  call void @eval_AtA_times_u(i32 noundef %39, ptr noundef nonnull %36, ptr noundef nonnull %37)
  call void @eval_AtA_times_u(i32 noundef %39, ptr noundef nonnull %37, ptr noundef nonnull %36)
  call void @eval_AtA_times_u(i32 noundef %39, ptr noundef nonnull %36, ptr noundef nonnull %37)
  call void @eval_AtA_times_u(i32 noundef %39, ptr noundef nonnull %37, ptr noundef nonnull %36)
  call void @eval_AtA_times_u(i32 noundef %39, ptr noundef nonnull %36, ptr noundef nonnull %37)
  call void @eval_AtA_times_u(i32 noundef %39, ptr noundef nonnull %37, ptr noundef nonnull %36)
  call void @eval_AtA_times_u(i32 noundef %39, ptr noundef nonnull %36, ptr noundef nonnull %37)
  call void @eval_AtA_times_u(i32 noundef %39, ptr noundef nonnull %37, ptr noundef nonnull %36)
  call void @eval_AtA_times_u(i32 noundef %39, ptr noundef nonnull %36, ptr noundef nonnull %37)
  call void @eval_AtA_times_u(i32 noundef %39, ptr noundef nonnull %37, ptr noundef nonnull %36)
  call void @eval_AtA_times_u(i32 noundef %39, ptr noundef nonnull %36, ptr noundef nonnull %37)
  br i1 %35, label %40, label %93

40:                                               ; preds = %34
  %41 = and i64 %38, 1
  %42 = icmp eq i64 %38, 1
  br i1 %42, label %76, label %43

43:                                               ; preds = %40
  %44 = and i64 %38, -2
  br label %50

45:                                               ; preds = %32, %45
  %46 = phi i64 [ %48, %45 ], [ %33, %32 ]
  %47 = getelementptr inbounds nuw [8 x i8], ptr %18, i64 %46
  store double 1.000000e+00, ptr %47, align 8, !tbaa !9
  %48 = add nuw nsw i64 %46, 1
  %49 = icmp eq i64 %48, %19
  br i1 %49, label %34, label %45, !llvm.loop !23

50:                                               ; preds = %50, %43
  %51 = phi i64 [ 0, %43 ], [ %71, %50 ]
  %52 = phi <2 x double> [ zeroinitializer, %43 ], [ %70, %50 ]
  %53 = phi i64 [ 0, %43 ], [ %72, %50 ]
  %54 = getelementptr inbounds nuw [8 x i8], ptr %37, i64 %51
  %55 = load double, ptr %54, align 8, !tbaa !9
  %56 = getelementptr inbounds nuw [8 x i8], ptr %36, i64 %51
  %57 = load double, ptr %56, align 8, !tbaa !9
  %58 = insertelement <2 x double> poison, double %57, i64 0
  %59 = insertelement <2 x double> %58, double %55, i64 1
  %60 = shufflevector <2 x double> %58, <2 x double> poison, <2 x i32> zeroinitializer
  %61 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %59, <2 x double> %60, <2 x double> %52)
  %62 = or disjoint i64 %51, 1
  %63 = getelementptr inbounds nuw [8 x i8], ptr %37, i64 %62
  %64 = load double, ptr %63, align 8, !tbaa !9
  %65 = getelementptr inbounds nuw [8 x i8], ptr %36, i64 %62
  %66 = load double, ptr %65, align 8, !tbaa !9
  %67 = insertelement <2 x double> poison, double %66, i64 0
  %68 = insertelement <2 x double> %67, double %64, i64 1
  %69 = shufflevector <2 x double> %67, <2 x double> poison, <2 x i32> zeroinitializer
  %70 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %68, <2 x double> %69, <2 x double> %61)
  %71 = add nuw nsw i64 %51, 2
  %72 = add i64 %53, 2
  %73 = icmp eq i64 %72, %44
  br i1 %73, label %74, label %50, !llvm.loop !24

74:                                               ; preds = %50
  %75 = icmp eq i64 %41, 0
  br i1 %75, label %88, label %76

76:                                               ; preds = %74, %40
  %77 = phi i64 [ 0, %40 ], [ %71, %74 ]
  %78 = phi <2 x double> [ zeroinitializer, %40 ], [ %70, %74 ]
  %79 = trunc i64 %38 to i1
  tail call void @llvm.assume(i1 %79)
  %80 = getelementptr inbounds nuw [8 x i8], ptr %37, i64 %77
  %81 = load double, ptr %80, align 8, !tbaa !9
  %82 = getelementptr inbounds nuw [8 x i8], ptr %36, i64 %77
  %83 = load double, ptr %82, align 8, !tbaa !9
  %84 = insertelement <2 x double> poison, double %83, i64 0
  %85 = insertelement <2 x double> %84, double %81, i64 1
  %86 = shufflevector <2 x double> %84, <2 x double> poison, <2 x i32> zeroinitializer
  %87 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %85, <2 x double> %86, <2 x double> %78)
  br label %88

88:                                               ; preds = %74, %76
  %89 = phi <2 x double> [ %70, %74 ], [ %87, %76 ]
  %90 = extractelement <2 x double> %89, i64 0
  %91 = extractelement <2 x double> %89, i64 1
  %92 = fdiv double %91, %90
  br label %93

93:                                               ; preds = %88, %34
  %94 = phi double [ +qnan, %34 ], [ %92, %88 ]
  %95 = tail call double @sqrt(double noundef %94) #9
  %96 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %95)
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #4

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @sqrt(double noundef) local_unnamed_addr #5

; Function Attrs: mustprogress nocallback nofree nounwind willreturn
declare i64 @strtol(ptr noundef readonly, ptr noundef captures(none), i32 noundef) local_unnamed_addr #6

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write)
declare void @llvm.assume(i1 noundef) #7

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare <2 x double> @llvm.fmuladd.v2f64(<2 x double>, <2 x double>, <2 x double>) #8

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #3 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { mustprogress nocallback nofree nounwind willreturn "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #7 = { nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write) }
attributes #8 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #9 = { nounwind }

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
!10 = !{!"double", !7, i64 0}
!11 = distinct !{!11, !12}
!12 = !{!"llvm.loop.mustprogress"}
!13 = distinct !{!13, !12}
!14 = distinct !{!14, !12}
!15 = distinct !{!15, !12}
!16 = !{!17, !17, i64 0}
!17 = !{!"p1 omnipotent char", !18, i64 0}
!18 = !{!"any pointer", !7, i64 0}
!19 = distinct !{null}
!20 = distinct !{!20, !12, !21, !22}
!21 = !{!"llvm.loop.isvectorized", i32 1}
!22 = !{!"llvm.loop.unroll.runtime.disable"}
!23 = distinct !{!23, !12, !22, !21}
!24 = distinct !{!24, !12}
