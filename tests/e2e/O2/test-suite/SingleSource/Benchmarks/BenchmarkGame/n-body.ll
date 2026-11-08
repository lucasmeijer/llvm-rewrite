; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/BenchmarkGame/n-body.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/BenchmarkGame/n-body.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/BenchmarkGame/n-body.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.planet = type { double, double, double, double, double, double, double }

@bodies = dso_local global [5 x %struct.planet] [%struct.planet { double 0.000000e+00, double 0.000000e+00, double 0.000000e+00, double 0.000000e+00, double 0.000000e+00, double 0.000000e+00, double f0x4043BD3CC9BE45DE }, %struct.planet { double f0x40135DA0343CD92C, double f0xBFF290ABC01FDB7C, double f0xBFBA86F96C25EBF0, double f0x3FE367069B93CCBC, double f0x40067EF2F57D949B, double f0xBF99D2D79A5A0715, double f0x3FA34C95D9AB33D8 }, %struct.planet { double f0x4020AFCDC332CA67, double f0x40107FCB31DE01B0, double f0xBFD9D353E1EB467C, double f0xBFF02C21B8879442, double f0x3FFD35E9BF1F8F13, double f0x3F813C485F1123B4, double f0x3F871D490D07C637 }, %struct.planet { double f0x4029C9EACEA7D9CF, double f0xC02E38E8D626667E, double f0xBFCC9557BE257DA0, double f0x3FF1531CA9911BEF, double f0x3FEBCC7F3E54BBC5, double f0xBF862F6BFAF23E7C, double f0x3F5C3DD29CF41EB3 }, %struct.planet { double f0x402EC267A905572A, double f0xC039EB5833C8A220, double f0x3FC6F1F393ABE540, double f0x3FEF54B61659BC4A, double f0x3FE307C631C4FBA3, double f0xBFA1CB88587665F6, double f0x3F60A8F3531799AC }], align 16
@.str = private unnamed_addr constant [6 x i8] c"%.9f\0A\00", align 1

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @advance(i32 noundef %0, ptr nofree noundef captures(none) %1, double noundef %2) local_unnamed_addr #0 {
  %4 = icmp sgt i32 %0, 0
  br i1 %4, label %5, label %116

5:                                                ; preds = %3
  %6 = zext nneg i32 %0 to i64
  %7 = zext nneg i32 %0 to i64
  br label %18

8:                                                ; preds = %34, %18
  %9 = add nuw nsw i64 %20, 1
  %10 = icmp eq i64 %21, %7
  br i1 %10, label %11, label %18, !llvm.loop !9

11:                                               ; preds = %8
  %12 = insertelement <2 x double> poison, double %2, i64 0
  %13 = shufflevector <2 x double> %12, <2 x double> poison, <2 x i32> zeroinitializer
  %14 = and i64 %7, 1
  %15 = icmp eq i32 %0, 1
  br i1 %15, label %103, label %16

16:                                               ; preds = %11
  %17 = and i64 %7, 2147483646
  br label %74

18:                                               ; preds = %5, %8
  %19 = phi i64 [ 0, %5 ], [ %21, %8 ]
  %20 = phi i64 [ 1, %5 ], [ %9, %8 ]
  %21 = add nuw nsw i64 %19, 1
  %22 = icmp samesign ult i64 %21, %6
  br i1 %22, label %23, label %8

23:                                               ; preds = %18
  %24 = getelementptr inbounds nuw [56 x i8], ptr %1, i64 %19
  %25 = load <2 x double>, ptr %24, align 8, !tbaa !11
  %26 = getelementptr inbounds nuw i8, ptr %24, i64 16
  %27 = load double, ptr %26, align 8, !tbaa !13
  %28 = getelementptr inbounds nuw i8, ptr %24, i64 24
  %29 = getelementptr inbounds nuw i8, ptr %24, i64 40
  %30 = getelementptr inbounds nuw i8, ptr %24, i64 48
  %31 = load double, ptr %30, align 8, !tbaa !15
  %32 = insertelement <2 x double> poison, double %31, i64 0
  %33 = shufflevector <2 x double> %32, <2 x double> poison, <2 x i32> zeroinitializer
  br label %34

34:                                               ; preds = %23, %34
  %35 = phi i64 [ %20, %23 ], [ %72, %34 ]
  %36 = getelementptr inbounds nuw [56 x i8], ptr %1, i64 %35
  %37 = getelementptr inbounds nuw i8, ptr %36, i64 16
  %38 = load double, ptr %37, align 8, !tbaa !13
  %39 = fsub double %27, %38
  %40 = getelementptr inbounds nuw i8, ptr %36, i64 48
  %41 = load double, ptr %40, align 8, !tbaa !15
  %42 = fneg double %41
  %43 = load double, ptr %29, align 8, !tbaa !16
  %44 = fmul double %39, %42
  %45 = getelementptr inbounds nuw i8, ptr %36, i64 24
  %46 = load <2 x double>, ptr %36, align 8, !tbaa !11
  %47 = fsub <2 x double> %25, %46
  %48 = fmul <2 x double> %47, %47
  %49 = extractelement <2 x double> %48, i64 1
  %50 = extractelement <2 x double> %47, i64 0
  %51 = tail call double @llvm.fmuladd.f64(double %50, double %50, double %49)
  %52 = tail call double @llvm.fmuladd.f64(double %39, double %39, double %51)
  %53 = tail call double @llvm.sqrt.f64(double %52)
  %54 = fmul double %53, %53
  %55 = fmul double %53, %54
  %56 = fdiv double %2, %55
  %57 = load <2 x double>, ptr %28, align 8, !tbaa !11
  %58 = insertelement <2 x double> poison, double %42, i64 0
  %59 = shufflevector <2 x double> %58, <2 x double> poison, <2 x i32> zeroinitializer
  %60 = fmul <2 x double> %47, %59
  %61 = insertelement <2 x double> poison, double %56, i64 0
  %62 = shufflevector <2 x double> %61, <2 x double> poison, <2 x i32> zeroinitializer
  %63 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %60, <2 x double> %62, <2 x double> %57)
  store <2 x double> %63, ptr %28, align 8, !tbaa !11
  %64 = tail call double @llvm.fmuladd.f64(double %44, double %56, double %43)
  store double %64, ptr %29, align 8, !tbaa !16
  %65 = fmul <2 x double> %47, %33
  %66 = load <2 x double>, ptr %45, align 8, !tbaa !11
  %67 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %65, <2 x double> %62, <2 x double> %66)
  store <2 x double> %67, ptr %45, align 8, !tbaa !11
  %68 = fmul double %39, %31
  %69 = getelementptr inbounds nuw i8, ptr %36, i64 40
  %70 = load double, ptr %69, align 8, !tbaa !16
  %71 = tail call double @llvm.fmuladd.f64(double %68, double %56, double %70)
  store double %71, ptr %69, align 8, !tbaa !16
  %72 = add nuw nsw i64 %35, 1
  %73 = icmp eq i64 %72, %7
  br i1 %73, label %8, label %34, !llvm.loop !17

74:                                               ; preds = %74, %16
  %75 = phi i64 [ 0, %16 ], [ %98, %74 ]
  %76 = phi i64 [ 0, %16 ], [ %99, %74 ]
  %77 = getelementptr inbounds nuw [56 x i8], ptr %1, i64 %75
  %78 = getelementptr inbounds nuw i8, ptr %77, i64 24
  %79 = load <2 x double>, ptr %78, align 8, !tbaa !11
  %80 = load <2 x double>, ptr %77, align 8, !tbaa !11
  %81 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %13, <2 x double> %79, <2 x double> %80)
  store <2 x double> %81, ptr %77, align 8, !tbaa !11
  %82 = getelementptr inbounds nuw i8, ptr %77, i64 40
  %83 = load double, ptr %82, align 8, !tbaa !16
  %84 = getelementptr inbounds nuw i8, ptr %77, i64 16
  %85 = load double, ptr %84, align 8, !tbaa !13
  %86 = tail call double @llvm.fmuladd.f64(double %2, double %83, double %85)
  store double %86, ptr %84, align 8, !tbaa !13
  %87 = getelementptr inbounds nuw [56 x i8], ptr %1, i64 %75
  %88 = getelementptr inbounds nuw i8, ptr %87, i64 56
  %89 = getelementptr inbounds nuw i8, ptr %87, i64 80
  %90 = load <2 x double>, ptr %89, align 8, !tbaa !11
  %91 = load <2 x double>, ptr %88, align 8, !tbaa !11
  %92 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %13, <2 x double> %90, <2 x double> %91)
  store <2 x double> %92, ptr %88, align 8, !tbaa !11
  %93 = getelementptr inbounds nuw i8, ptr %87, i64 96
  %94 = load double, ptr %93, align 8, !tbaa !16
  %95 = getelementptr inbounds nuw i8, ptr %87, i64 72
  %96 = load double, ptr %95, align 8, !tbaa !13
  %97 = tail call double @llvm.fmuladd.f64(double %2, double %94, double %96)
  store double %97, ptr %95, align 8, !tbaa !13
  %98 = add nuw nsw i64 %75, 2
  %99 = add i64 %76, 2
  %100 = icmp eq i64 %99, %17
  br i1 %100, label %101, label %74, !llvm.loop !18

101:                                              ; preds = %74
  %102 = icmp eq i64 %14, 0
  br i1 %102, label %116, label %103

103:                                              ; preds = %101, %11
  %104 = phi i64 [ 0, %11 ], [ %98, %101 ]
  %105 = trunc i32 %0 to i1
  tail call void @llvm.assume(i1 %105)
  %106 = getelementptr inbounds nuw [56 x i8], ptr %1, i64 %104
  %107 = getelementptr inbounds nuw i8, ptr %106, i64 24
  %108 = load <2 x double>, ptr %107, align 8, !tbaa !11
  %109 = load <2 x double>, ptr %106, align 8, !tbaa !11
  %110 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %13, <2 x double> %108, <2 x double> %109)
  store <2 x double> %110, ptr %106, align 8, !tbaa !11
  %111 = getelementptr inbounds nuw i8, ptr %106, i64 40
  %112 = load double, ptr %111, align 8, !tbaa !16
  %113 = getelementptr inbounds nuw i8, ptr %106, i64 16
  %114 = load double, ptr %113, align 8, !tbaa !13
  %115 = tail call double @llvm.fmuladd.f64(double %2, double %112, double %114)
  store double %115, ptr %113, align 8, !tbaa !13
  br label %116

116:                                              ; preds = %103, %101, %3
  ret void
}

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #1

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: read) uwtable
define dso_local double @energy(i32 noundef %0, ptr nofree noundef readonly captures(none) %1) local_unnamed_addr #2 {
  %3 = icmp sgt i32 %0, 0
  br i1 %3, label %4, label %60

4:                                                ; preds = %2
  %5 = zext nneg i32 %0 to i64
  %6 = zext nneg i32 %0 to i64
  br label %11

7:                                                ; preds = %37, %11
  %8 = phi double [ %28, %11 ], [ %57, %37 ]
  %9 = add nuw nsw i64 %13, 1
  %10 = icmp eq i64 %29, %6
  br i1 %10, label %60, label %11, !llvm.loop !19

11:                                               ; preds = %4, %7
  %12 = phi i64 [ 0, %4 ], [ %29, %7 ]
  %13 = phi i64 [ 1, %4 ], [ %9, %7 ]
  %14 = phi double [ 0.000000e+00, %4 ], [ %8, %7 ]
  %15 = getelementptr inbounds nuw [56 x i8], ptr %1, i64 %12
  %16 = getelementptr inbounds nuw i8, ptr %15, i64 48
  %17 = load double, ptr %16, align 8, !tbaa !15
  %18 = fmul double %17, 5.000000e-01
  %19 = getelementptr inbounds nuw i8, ptr %15, i64 24
  %20 = load double, ptr %19, align 8, !tbaa !20
  %21 = getelementptr inbounds nuw i8, ptr %15, i64 32
  %22 = load double, ptr %21, align 8, !tbaa !21
  %23 = fmul double %22, %22
  %24 = tail call double @llvm.fmuladd.f64(double %20, double %20, double %23)
  %25 = getelementptr inbounds nuw i8, ptr %15, i64 40
  %26 = load double, ptr %25, align 8, !tbaa !16
  %27 = tail call double @llvm.fmuladd.f64(double %26, double %26, double %24)
  %28 = tail call double @llvm.fmuladd.f64(double %18, double %27, double %14)
  %29 = add nuw nsw i64 %12, 1
  %30 = icmp samesign ult i64 %29, %5
  br i1 %30, label %31, label %7

31:                                               ; preds = %11
  %32 = load double, ptr %15, align 8, !tbaa !22
  %33 = getelementptr inbounds nuw i8, ptr %15, i64 8
  %34 = load double, ptr %33, align 8, !tbaa !23
  %35 = getelementptr inbounds nuw i8, ptr %15, i64 16
  %36 = load double, ptr %35, align 8, !tbaa !13
  br label %37

37:                                               ; preds = %31, %37
  %38 = phi i64 [ %13, %31 ], [ %58, %37 ]
  %39 = phi double [ %28, %31 ], [ %57, %37 ]
  %40 = getelementptr inbounds nuw [56 x i8], ptr %1, i64 %38
  %41 = load double, ptr %40, align 8, !tbaa !22
  %42 = fsub double %32, %41
  %43 = getelementptr inbounds nuw i8, ptr %40, i64 8
  %44 = load double, ptr %43, align 8, !tbaa !23
  %45 = fsub double %34, %44
  %46 = getelementptr inbounds nuw i8, ptr %40, i64 16
  %47 = load double, ptr %46, align 8, !tbaa !13
  %48 = fsub double %36, %47
  %49 = fmul double %45, %45
  %50 = tail call double @llvm.fmuladd.f64(double %42, double %42, double %49)
  %51 = tail call double @llvm.fmuladd.f64(double %48, double %48, double %50)
  %52 = tail call double @llvm.sqrt.f64(double %51)
  %53 = getelementptr inbounds nuw i8, ptr %40, i64 48
  %54 = load double, ptr %53, align 8, !tbaa !15
  %55 = fmul double %17, %54
  %56 = fdiv double %55, %52
  %57 = fsub double %39, %56
  %58 = add nuw nsw i64 %38, 1
  %59 = icmp eq i64 %58, %6
  br i1 %59, label %7, label %37, !llvm.loop !24

60:                                               ; preds = %7, %2
  %61 = phi double [ 0.000000e+00, %2 ], [ %8, %7 ]
  ret double %61
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @offset_momentum(i32 noundef %0, ptr nofree noundef captures(none) %1) local_unnamed_addr #0 {
  %3 = icmp sgt i32 %0, 0
  br i1 %3, label %4, label %58

4:                                                ; preds = %2
  %5 = zext nneg i32 %0 to i64
  %6 = and i64 %5, 1
  %7 = icmp eq i32 %0, 1
  br i1 %7, label %42, label %8

8:                                                ; preds = %4
  %9 = and i64 %5, 2147483646
  br label %10

10:                                               ; preds = %10, %8
  %11 = phi i64 [ 0, %8 ], [ %37, %10 ]
  %12 = phi double [ 0.000000e+00, %8 ], [ %36, %10 ]
  %13 = phi <2 x double> [ zeroinitializer, %8 ], [ %33, %10 ]
  %14 = phi i64 [ 0, %8 ], [ %38, %10 ]
  %15 = getelementptr inbounds nuw [56 x i8], ptr %1, i64 %11
  %16 = getelementptr inbounds nuw i8, ptr %15, i64 24
  %17 = getelementptr inbounds nuw i8, ptr %15, i64 48
  %18 = load double, ptr %17, align 8, !tbaa !15
  %19 = load <2 x double>, ptr %16, align 8, !tbaa !11
  %20 = insertelement <2 x double> poison, double %18, i64 0
  %21 = shufflevector <2 x double> %20, <2 x double> poison, <2 x i32> zeroinitializer
  %22 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %19, <2 x double> %21, <2 x double> %13)
  %23 = getelementptr inbounds nuw i8, ptr %15, i64 40
  %24 = load double, ptr %23, align 8, !tbaa !16
  %25 = tail call double @llvm.fmuladd.f64(double %24, double %18, double %12)
  %26 = getelementptr inbounds nuw [56 x i8], ptr %1, i64 %11
  %27 = getelementptr inbounds nuw i8, ptr %26, i64 80
  %28 = getelementptr inbounds nuw i8, ptr %26, i64 104
  %29 = load double, ptr %28, align 8, !tbaa !15
  %30 = load <2 x double>, ptr %27, align 8, !tbaa !11
  %31 = insertelement <2 x double> poison, double %29, i64 0
  %32 = shufflevector <2 x double> %31, <2 x double> poison, <2 x i32> zeroinitializer
  %33 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %30, <2 x double> %32, <2 x double> %22)
  %34 = getelementptr inbounds nuw i8, ptr %26, i64 96
  %35 = load double, ptr %34, align 8, !tbaa !16
  %36 = tail call double @llvm.fmuladd.f64(double %35, double %29, double %25)
  %37 = add nuw nsw i64 %11, 2
  %38 = add i64 %14, 2
  %39 = icmp eq i64 %38, %9
  br i1 %39, label %40, label %10, !llvm.loop !25

40:                                               ; preds = %10
  %41 = icmp eq i64 %6, 0
  br i1 %41, label %58, label %42

42:                                               ; preds = %40, %4
  %43 = phi i64 [ 0, %4 ], [ %37, %40 ]
  %44 = phi double [ 0.000000e+00, %4 ], [ %36, %40 ]
  %45 = phi <2 x double> [ zeroinitializer, %4 ], [ %33, %40 ]
  %46 = trunc i32 %0 to i1
  tail call void @llvm.assume(i1 %46)
  %47 = getelementptr inbounds nuw [56 x i8], ptr %1, i64 %43
  %48 = getelementptr inbounds nuw i8, ptr %47, i64 24
  %49 = getelementptr inbounds nuw i8, ptr %47, i64 48
  %50 = load double, ptr %49, align 8, !tbaa !15
  %51 = load <2 x double>, ptr %48, align 8, !tbaa !11
  %52 = insertelement <2 x double> poison, double %50, i64 0
  %53 = shufflevector <2 x double> %52, <2 x double> poison, <2 x i32> zeroinitializer
  %54 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %51, <2 x double> %53, <2 x double> %45)
  %55 = getelementptr inbounds nuw i8, ptr %47, i64 40
  %56 = load double, ptr %55, align 8, !tbaa !16
  %57 = tail call double @llvm.fmuladd.f64(double %56, double %50, double %44)
  br label %58

58:                                               ; preds = %42, %40, %2
  %59 = phi double [ 0.000000e+00, %2 ], [ %36, %40 ], [ %57, %42 ]
  %60 = phi <2 x double> [ zeroinitializer, %2 ], [ %33, %40 ], [ %54, %42 ]
  %61 = fdiv <2 x double> %60, splat (double f0xC043BD3CC9BE45DE)
  %62 = getelementptr inbounds nuw i8, ptr %1, i64 24
  store <2 x double> %61, ptr %62, align 8, !tbaa !11
  %63 = fdiv double %59, f0xC043BD3CC9BE45DE
  %64 = getelementptr inbounds nuw i8, ptr %1, i64 40
  store double %63, ptr %64, align 8, !tbaa !16
  ret void
}

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main(i32 noundef %0, ptr nofree noundef readnone captures(none) %1) local_unnamed_addr #3 {
  %3 = load double, ptr getelementptr inbounds nuw (i8, ptr @bodies, i64 48), align 16, !tbaa !15
  %4 = load double, ptr getelementptr inbounds nuw (i8, ptr @bodies, i64 40), align 8, !tbaa !16
  %5 = tail call double @llvm.fmuladd.f64(double %4, double %3, double 0.000000e+00)
  %6 = load double, ptr getelementptr inbounds nuw (i8, ptr @bodies, i64 104), align 8, !tbaa !15
  %7 = load double, ptr getelementptr inbounds nuw (i8, ptr @bodies, i64 96), align 16, !tbaa !16
  %8 = tail call double @llvm.fmuladd.f64(double %7, double %6, double %5)
  %9 = load double, ptr getelementptr inbounds nuw (i8, ptr @bodies, i64 160), align 16, !tbaa !15
  %10 = load double, ptr getelementptr inbounds nuw (i8, ptr @bodies, i64 152), align 8, !tbaa !16
  %11 = tail call double @llvm.fmuladd.f64(double %10, double %9, double %8)
  %12 = load double, ptr getelementptr inbounds nuw (i8, ptr @bodies, i64 216), align 8, !tbaa !15
  %13 = load double, ptr getelementptr inbounds nuw (i8, ptr @bodies, i64 208), align 16, !tbaa !16
  %14 = tail call double @llvm.fmuladd.f64(double %13, double %12, double %11)
  %15 = load double, ptr getelementptr inbounds nuw (i8, ptr @bodies, i64 272), align 16, !tbaa !15
  %16 = load double, ptr getelementptr inbounds nuw (i8, ptr @bodies, i64 264), align 8, !tbaa !16
  %17 = tail call double @llvm.fmuladd.f64(double %16, double %15, double %14)
  %18 = load <2 x double>, ptr getelementptr inbounds nuw (i8, ptr @bodies, i64 24), align 8, !tbaa !11
  %19 = insertelement <2 x double> poison, double %3, i64 0
  %20 = shufflevector <2 x double> %19, <2 x double> poison, <2 x i32> zeroinitializer
  %21 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %18, <2 x double> %20, <2 x double> zeroinitializer)
  %22 = load <2 x double>, ptr getelementptr inbounds nuw (i8, ptr @bodies, i64 80), align 16, !tbaa !11
  %23 = insertelement <2 x double> poison, double %6, i64 0
  %24 = shufflevector <2 x double> %23, <2 x double> poison, <2 x i32> zeroinitializer
  %25 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %22, <2 x double> %24, <2 x double> %21)
  %26 = load <2 x double>, ptr getelementptr inbounds nuw (i8, ptr @bodies, i64 136), align 8, !tbaa !11
  %27 = insertelement <2 x double> poison, double %9, i64 0
  %28 = shufflevector <2 x double> %27, <2 x double> poison, <2 x i32> zeroinitializer
  %29 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %26, <2 x double> %28, <2 x double> %25)
  %30 = load <2 x double>, ptr getelementptr inbounds nuw (i8, ptr @bodies, i64 192), align 16, !tbaa !11
  %31 = insertelement <2 x double> poison, double %12, i64 0
  %32 = shufflevector <2 x double> %31, <2 x double> poison, <2 x i32> zeroinitializer
  %33 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %30, <2 x double> %32, <2 x double> %29)
  %34 = load <2 x double>, ptr getelementptr inbounds nuw (i8, ptr @bodies, i64 248), align 8, !tbaa !11
  %35 = insertelement <2 x double> poison, double %15, i64 0
  %36 = shufflevector <2 x double> %35, <2 x double> poison, <2 x i32> zeroinitializer
  %37 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %34, <2 x double> %36, <2 x double> %33)
  %38 = fdiv <2 x double> %37, splat (double f0xC043BD3CC9BE45DE)
  store <2 x double> %38, ptr getelementptr inbounds nuw (i8, ptr @bodies, i64 24), align 8, !tbaa !11
  %39 = fdiv double %17, f0xC043BD3CC9BE45DE
  store double %39, ptr getelementptr inbounds nuw (i8, ptr @bodies, i64 40), align 8, !tbaa !16
  br label %44

40:                                               ; preds = %70, %44
  %41 = phi double [ %61, %44 ], [ %90, %70 ]
  %42 = add nuw nsw i64 %46, 1
  %43 = icmp eq i64 %62, 5
  br i1 %43, label %93, label %44, !llvm.loop !19

44:                                               ; preds = %40, %2
  %45 = phi i64 [ 0, %2 ], [ %62, %40 ]
  %46 = phi i64 [ 1, %2 ], [ %42, %40 ]
  %47 = phi double [ 0.000000e+00, %2 ], [ %41, %40 ]
  %48 = getelementptr inbounds nuw [56 x i8], ptr @bodies, i64 %45
  %49 = getelementptr inbounds nuw i8, ptr %48, i64 48
  %50 = load double, ptr %49, align 8, !tbaa !15
  %51 = fmul double %50, 5.000000e-01
  %52 = getelementptr inbounds nuw i8, ptr %48, i64 24
  %53 = load double, ptr %52, align 8, !tbaa !20
  %54 = getelementptr inbounds nuw i8, ptr %48, i64 32
  %55 = load double, ptr %54, align 8, !tbaa !21
  %56 = fmul double %55, %55
  %57 = tail call double @llvm.fmuladd.f64(double %53, double %53, double %56)
  %58 = getelementptr inbounds nuw i8, ptr %48, i64 40
  %59 = load double, ptr %58, align 8, !tbaa !16
  %60 = tail call double @llvm.fmuladd.f64(double %59, double %59, double %57)
  %61 = tail call double @llvm.fmuladd.f64(double %51, double %60, double %47)
  %62 = add nuw nsw i64 %45, 1
  %63 = icmp samesign ult i64 %45, 4
  br i1 %63, label %64, label %40

64:                                               ; preds = %44
  %65 = load double, ptr %48, align 8, !tbaa !22
  %66 = getelementptr inbounds nuw i8, ptr %48, i64 8
  %67 = load double, ptr %66, align 8, !tbaa !23
  %68 = getelementptr inbounds nuw i8, ptr %48, i64 16
  %69 = load double, ptr %68, align 8, !tbaa !13
  br label %70

70:                                               ; preds = %70, %64
  %71 = phi i64 [ %46, %64 ], [ %91, %70 ]
  %72 = phi double [ %61, %64 ], [ %90, %70 ]
  %73 = getelementptr inbounds nuw [56 x i8], ptr @bodies, i64 %71
  %74 = load double, ptr %73, align 8, !tbaa !22
  %75 = fsub double %65, %74
  %76 = getelementptr inbounds nuw i8, ptr %73, i64 8
  %77 = load double, ptr %76, align 8, !tbaa !23
  %78 = fsub double %67, %77
  %79 = getelementptr inbounds nuw i8, ptr %73, i64 16
  %80 = load double, ptr %79, align 8, !tbaa !13
  %81 = fsub double %69, %80
  %82 = fmul double %78, %78
  %83 = tail call double @llvm.fmuladd.f64(double %75, double %75, double %82)
  %84 = tail call double @llvm.fmuladd.f64(double %81, double %81, double %83)
  %85 = tail call double @llvm.sqrt.f64(double %84)
  %86 = getelementptr inbounds nuw i8, ptr %73, i64 48
  %87 = load double, ptr %86, align 8, !tbaa !15
  %88 = fmul double %50, %87
  %89 = fdiv double %88, %85
  %90 = fsub double %72, %89
  %91 = add nuw nsw i64 %71, 1
  %92 = icmp eq i64 %91, 5
  br i1 %92, label %40, label %70, !llvm.loop !24

93:                                               ; preds = %40
  %94 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %41)
  br label %95

95:                                               ; preds = %93, %95
  %96 = phi i32 [ 1, %93 ], [ %97, %95 ]
  tail call void @advance(i32 noundef 5, ptr noundef nonnull @bodies, double noundef 1.000000e-02)
  %97 = add nuw nsw i32 %96, 1
  %98 = icmp eq i32 %97, 5000001
  br i1 %98, label %103, label %95, !llvm.loop !26

99:                                               ; preds = %129, %103
  %100 = phi double [ %120, %103 ], [ %149, %129 ]
  %101 = add nuw nsw i64 %105, 1
  %102 = icmp eq i64 %121, 5
  br i1 %102, label %152, label %103, !llvm.loop !19

103:                                              ; preds = %95, %99
  %104 = phi i64 [ %121, %99 ], [ 0, %95 ]
  %105 = phi i64 [ %101, %99 ], [ 1, %95 ]
  %106 = phi double [ %100, %99 ], [ 0.000000e+00, %95 ]
  %107 = getelementptr inbounds nuw [56 x i8], ptr @bodies, i64 %104
  %108 = getelementptr inbounds nuw i8, ptr %107, i64 48
  %109 = load double, ptr %108, align 8, !tbaa !15
  %110 = fmul double %109, 5.000000e-01
  %111 = getelementptr inbounds nuw i8, ptr %107, i64 24
  %112 = load double, ptr %111, align 8, !tbaa !20
  %113 = getelementptr inbounds nuw i8, ptr %107, i64 32
  %114 = load double, ptr %113, align 8, !tbaa !21
  %115 = fmul double %114, %114
  %116 = tail call double @llvm.fmuladd.f64(double %112, double %112, double %115)
  %117 = getelementptr inbounds nuw i8, ptr %107, i64 40
  %118 = load double, ptr %117, align 8, !tbaa !16
  %119 = tail call double @llvm.fmuladd.f64(double %118, double %118, double %116)
  %120 = tail call double @llvm.fmuladd.f64(double %110, double %119, double %106)
  %121 = add nuw nsw i64 %104, 1
  %122 = icmp samesign ult i64 %104, 4
  br i1 %122, label %123, label %99

123:                                              ; preds = %103
  %124 = load double, ptr %107, align 8, !tbaa !22
  %125 = getelementptr inbounds nuw i8, ptr %107, i64 8
  %126 = load double, ptr %125, align 8, !tbaa !23
  %127 = getelementptr inbounds nuw i8, ptr %107, i64 16
  %128 = load double, ptr %127, align 8, !tbaa !13
  br label %129

129:                                              ; preds = %129, %123
  %130 = phi i64 [ %105, %123 ], [ %150, %129 ]
  %131 = phi double [ %120, %123 ], [ %149, %129 ]
  %132 = getelementptr inbounds nuw [56 x i8], ptr @bodies, i64 %130
  %133 = load double, ptr %132, align 8, !tbaa !22
  %134 = fsub double %124, %133
  %135 = getelementptr inbounds nuw i8, ptr %132, i64 8
  %136 = load double, ptr %135, align 8, !tbaa !23
  %137 = fsub double %126, %136
  %138 = getelementptr inbounds nuw i8, ptr %132, i64 16
  %139 = load double, ptr %138, align 8, !tbaa !13
  %140 = fsub double %128, %139
  %141 = fmul double %137, %137
  %142 = tail call double @llvm.fmuladd.f64(double %134, double %134, double %141)
  %143 = tail call double @llvm.fmuladd.f64(double %140, double %140, double %142)
  %144 = tail call double @llvm.sqrt.f64(double %143)
  %145 = getelementptr inbounds nuw i8, ptr %132, i64 48
  %146 = load double, ptr %145, align 8, !tbaa !15
  %147 = fmul double %109, %146
  %148 = fdiv double %147, %144
  %149 = fsub double %131, %148
  %150 = add nuw nsw i64 %130, 1
  %151 = icmp eq i64 %150, 5
  br i1 %151, label %99, label %129, !llvm.loop !24

152:                                              ; preds = %99
  %153 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %100)
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #4

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.sqrt.f64(double) #5

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare <2 x double> @llvm.fmuladd.v2f64(<2 x double>, <2 x double>, <2 x double>) #5

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write)
declare void @llvm.assume(i1 noundef) #6

attributes #0 = { nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #2 = { nofree norecurse nosync nounwind memory(argmem: read) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #6 = { nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write) }

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
!9 = distinct !{!9, !10}
!10 = !{!"llvm.loop.mustprogress"}
!11 = !{!12, !12, i64 0}
!12 = !{!"double", !7, i64 0}
!13 = !{!14, !12, i64 16}
!14 = !{!"planet", !12, i64 0, !12, i64 8, !12, i64 16, !12, i64 24, !12, i64 32, !12, i64 40, !12, i64 48}
!15 = !{!14, !12, i64 48}
!16 = !{!14, !12, i64 40}
!17 = distinct !{!17, !10}
!18 = distinct !{!18, !10}
!19 = distinct !{!19, !10}
!20 = !{!14, !12, i64 24}
!21 = !{!14, !12, i64 32}
!22 = !{!14, !12, i64 0}
!23 = !{!14, !12, i64 8}
!24 = distinct !{!24, !10}
!25 = distinct !{!25, !10}
!26 = distinct !{!26, !10}
