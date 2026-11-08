; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/fbench.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/fbench.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/fbench.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@niter = dso_local local_unnamed_addr global i32 1000, align 4
@spectral_line = internal unnamed_addr global [9 x double] zeroinitializer, align 16
@current_surfaces = internal unnamed_addr global i1 false, align 2
@testcase = internal unnamed_addr constant [4 x [4 x double]] [[4 x double] [double 2.705000e+01, double 1.513700e+00, double 6.360000e+01, double 5.200000e-01], [4 x double] [double -1.668000e+01, double 1.000000e+00, double 0.000000e+00, double 1.380000e-01], [4 x double] [double -1.668000e+01, double 1.616400e+00, double 3.670000e+01, double 3.800000e-01], [4 x double] [double -7.810000e+01, double 1.000000e+00, double 0.000000e+00, double 0.000000e+00]], align 16
@s = internal unnamed_addr global [10 x [5 x double]] zeroinitializer, align 16
@.str.1 = private unnamed_addr constant [58 x i8] c"and performance benchmark.  %d iterations will be made.\0A\0A\00", align 1
@.str.2 = private unnamed_addr constant [56 x i8] c"\0AMeasured run time in seconds should be divided by %.f\0A\00", align 1
@itercount = dso_local local_unnamed_addr global i32 0, align 4
@paraxial = internal unnamed_addr global i1 false, align 2
@object_distance = internal unnamed_addr global double 0.000000e+00, align 8
@od_sa.0 = internal unnamed_addr global double 0.000000e+00, align 16
@od_sa.1 = internal unnamed_addr global double 0.000000e+00, align 8
@od_sa.2 = internal unnamed_addr global double 0.000000e+00, align 16
@od_sa.3 = internal unnamed_addr global double 0.000000e+00, align 8
@axis_slope_angle = internal unnamed_addr global double 0.000000e+00, align 8
@aberr_lspher = internal unnamed_addr global double 0.000000e+00, align 8
@aberr_osc = internal unnamed_addr global double 0.000000e+00, align 8
@aberr_lchrom = internal unnamed_addr global double 0.000000e+00, align 8
@max_lspher = internal unnamed_addr global double 0.000000e+00, align 8
@max_osc = internal unnamed_addr global double 0.000000e+00, align 8
@max_lchrom = internal unnamed_addr global double 0.000000e+00, align 8
@outarr = internal global [8 x [80 x i8]] zeroinitializer, align 16
@.str.5 = private unnamed_addr constant [24 x i8] c"%15s   %21.11f  %14.11f\00", align 1
@.str.6 = private unnamed_addr constant [13 x i8] c"Marginal ray\00", align 1
@.str.7 = private unnamed_addr constant [13 x i8] c"Paraxial ray\00", align 1
@.str.8 = private unnamed_addr constant [48 x i8] c"Longitudinal spherical aberration:      %16.11f\00", align 1
@.str.9 = private unnamed_addr constant [48 x i8] c"    (Maximum permissible):              %16.11f\00", align 1
@.str.10 = private unnamed_addr constant [48 x i8] c"Offense against sine condition (coma):  %16.11f\00", align 1
@.str.11 = private unnamed_addr constant [48 x i8] c"Axial chromatic aberration:             %16.11f\00", align 1
@refarr = internal unnamed_addr constant [8 x ptr] [ptr @.str.22, ptr @.str.23, ptr @.str.24, ptr @.str.25, ptr @.str.26, ptr @.str.27, ptr @.str.28, ptr @.str.25], align 16
@.str.12 = private unnamed_addr constant [33 x i8] c"\0AError in results on line %d...\0A\00", align 1
@.str.13 = private unnamed_addr constant [17 x i8] c"Expected:  \22%s\22\0A\00", align 1
@.str.14 = private unnamed_addr constant [17 x i8] c"Received:  \22%s\22\0A\00", align 1
@.str.15 = private unnamed_addr constant [13 x i8] c"(Errors)    \00", align 1
@.str.18 = private unnamed_addr constant [48 x i8] c"\0A%d error%s in results.  This is VERY SERIOUS.\0A\00", align 1
@.str.19 = private unnamed_addr constant [2 x i8] c"s\00", align 1
@.str.20 = private unnamed_addr constant [1 x i8] zeroinitializer, align 1
@.str.22 = private unnamed_addr constant [56 x i8] c"   Marginal ray          47.09479120920   0.04178472683\00", align 1
@.str.23 = private unnamed_addr constant [56 x i8] c"   Paraxial ray          47.08372160249   0.04177864821\00", align 1
@.str.24 = private unnamed_addr constant [57 x i8] c"Longitudinal spherical aberration:        -0.01106960671\00", align 1
@.str.25 = private unnamed_addr constant [57 x i8] c"    (Maximum permissible):                 0.05306749907\00", align 1
@.str.26 = private unnamed_addr constant [57 x i8] c"Offense against sine condition (coma):     0.00008954761\00", align 1
@.str.27 = private unnamed_addr constant [57 x i8] c"    (Maximum permissible):                 0.00250000000\00", align 1
@.str.28 = private unnamed_addr constant [57 x i8] c"Axial chromatic aberration:                0.00448229032\00", align 1
@str = private unnamed_addr constant [53 x i8] c"Ready to begin John Walker's floating point accuracy\00", align 1
@str.29 = private unnamed_addr constant [59 x i8] c"to normalise for reporting results.  For archival results,\00", align 1
@str.30 = private unnamed_addr constant [66 x i8] c"adjust iteration count so the benchmark runs about five minutes.\0A\00", align 1
@str.31 = private unnamed_addr constant [23 x i8] c"\0ANo errors in results.\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main(i32 noundef %0, ptr nofree noundef readnone captures(none) %1) local_unnamed_addr #0 {
  store <2 x double> <double 7.621000e+03, double f0x40BAD5F47AE147AE>, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 8), align 8, !tbaa !9
  store <2 x double> <double f0x40B9A2D0E5604189, double f0x40B707F1A9FBE76D>, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 24), align 8, !tbaa !9
  store <2 x double> <double f0x40B4958E978D4FDF, double f0x40B2FD5810624DD3>, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 40), align 8, !tbaa !9
  store <2 x double> <double f0x40B0F47A1CAC0831, double f0x40AF00FCED916873>, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 56), align 8, !tbaa !9
  store i32 1000000, ptr @niter, align 4, !tbaa !11
  store i1 true, ptr @current_surfaces, align 2
  tail call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 16 dereferenceable(32) getelementptr inbounds nuw (i8, ptr @s, i64 48), ptr noundef nonnull align 16 dereferenceable(32) @testcase, i64 32, i1 false), !tbaa !9
  tail call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 8 dereferenceable(32) getelementptr inbounds nuw (i8, ptr @s, i64 88), ptr noundef nonnull align 16 dereferenceable(32) getelementptr inbounds nuw (i8, ptr @testcase, i64 32), i64 32, i1 false), !tbaa !9
  tail call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 16 dereferenceable(32) getelementptr inbounds nuw (i8, ptr @s, i64 128), ptr noundef nonnull align 16 dereferenceable(32) getelementptr inbounds nuw (i8, ptr @testcase, i64 64), i64 32, i1 false), !tbaa !9
  tail call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 8 dereferenceable(32) getelementptr inbounds nuw (i8, ptr @s, i64 168), ptr noundef nonnull align 16 dereferenceable(32) getelementptr inbounds nuw (i8, ptr @testcase, i64 96), i64 32, i1 false), !tbaa !9
  %3 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str)
  %4 = load i32, ptr @niter, align 4, !tbaa !11
  %5 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i32 noundef %4)
  %6 = load i32, ptr @niter, align 4, !tbaa !11
  %7 = sitofp i32 %6 to double
  %8 = fdiv double %7, 1.000000e+03
  %9 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.2, double noundef %8)
  %10 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str.29)
  %11 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str.30)
  store i32 0, ptr @itercount, align 4, !tbaa !11
  %12 = load i32, ptr @niter, align 4, !tbaa !11
  %13 = icmp sgt i32 %12, 0
  br i1 %13, label %17, label %14

14:                                               ; preds = %2
  %15 = load double, ptr @od_sa.0, align 16, !tbaa !9
  %16 = load double, ptr @od_sa.1, align 8, !tbaa !9
  br label %41

17:                                               ; preds = %2, %17
  store i1 false, ptr @paraxial, align 2
  tail call fastcc void @trace_line(i32 noundef 4, double noundef 2.000000e+00)
  %18 = load double, ptr @object_distance, align 8, !tbaa !9
  store double %18, ptr @od_sa.0, align 16, !tbaa !9
  %19 = load double, ptr @axis_slope_angle, align 8, !tbaa !9
  store double %19, ptr @od_sa.1, align 8, !tbaa !9
  store i1 true, ptr @paraxial, align 2
  tail call fastcc void @trace_line(i32 noundef 4, double noundef 2.000000e+00)
  %20 = load double, ptr @object_distance, align 8, !tbaa !9
  store double %20, ptr @od_sa.2, align 16, !tbaa !9
  %21 = load double, ptr @axis_slope_angle, align 8, !tbaa !9
  store double %21, ptr @od_sa.3, align 8, !tbaa !9
  store i1 false, ptr @paraxial, align 2
  tail call fastcc void @trace_line(i32 noundef 3, double noundef 2.000000e+00)
  %22 = load double, ptr @object_distance, align 8, !tbaa !9
  tail call fastcc void @trace_line(i32 noundef 6, double noundef 2.000000e+00)
  %23 = load double, ptr @object_distance, align 8, !tbaa !9
  %24 = fsub double %20, %18
  store double %24, ptr @aberr_lspher, align 8, !tbaa !9
  %25 = fmul double %20, %21
  %26 = tail call double @sin(double noundef %19) #8
  %27 = fsub double %23, %22
  store double %27, ptr @aberr_lchrom, align 8, !tbaa !9
  %28 = insertelement <2 x double> poison, double %18, i64 0
  %29 = insertelement <2 x double> %28, double %26, i64 1
  %30 = shufflevector <2 x double> %29, <2 x double> poison, <2 x i32> <i32 1, i32 1>
  %31 = fmul <2 x double> %29, %30
  %32 = insertelement <2 x double> <double poison, double 9.260000e-05>, double %25, i64 0
  %33 = fdiv <2 x double> %32, %31
  %34 = extractelement <2 x double> %33, i64 0
  %35 = fsub double 1.000000e+00, %34
  store double %35, ptr @aberr_osc, align 8, !tbaa !9
  %36 = extractelement <2 x double> %33, i64 1
  store double %36, ptr @max_lspher, align 8, !tbaa !9
  store double 2.500000e-03, ptr @max_osc, align 8, !tbaa !9
  store double %36, ptr @max_lchrom, align 8, !tbaa !9
  %37 = load i32, ptr @itercount, align 4, !tbaa !11
  %38 = add nsw i32 %37, 1
  store i32 %38, ptr @itercount, align 4, !tbaa !11
  %39 = load i32, ptr @niter, align 4, !tbaa !11
  %40 = icmp slt i32 %38, %39
  br i1 %40, label %17, label %41, !llvm.loop !12

41:                                               ; preds = %17, %14
  %42 = phi double [ %16, %14 ], [ %19, %17 ]
  %43 = phi double [ %15, %14 ], [ %18, %17 ]
  %44 = tail call i32 (ptr, ptr, ...) @sprintf(ptr noundef nonnull dereferenceable(1) @outarr, ptr noundef nonnull dereferenceable(1) @.str.5, ptr noundef nonnull @.str.6, double noundef %43, double noundef %42) #8
  %45 = load double, ptr @od_sa.2, align 16, !tbaa !9
  %46 = load double, ptr @od_sa.3, align 8, !tbaa !9
  %47 = tail call i32 (ptr, ptr, ...) @sprintf(ptr noundef nonnull dereferenceable(1) getelementptr inbounds nuw (i8, ptr @outarr, i64 80), ptr noundef nonnull dereferenceable(1) @.str.5, ptr noundef nonnull @.str.7, double noundef %45, double noundef %46) #8
  %48 = load double, ptr @aberr_lspher, align 8, !tbaa !9
  %49 = tail call i32 (ptr, ptr, ...) @sprintf(ptr noundef nonnull dereferenceable(1) getelementptr inbounds nuw (i8, ptr @outarr, i64 160), ptr noundef nonnull dereferenceable(1) @.str.8, double noundef %48) #8
  %50 = load double, ptr @max_lspher, align 8, !tbaa !9
  %51 = tail call i32 (ptr, ptr, ...) @sprintf(ptr noundef nonnull dereferenceable(1) getelementptr inbounds nuw (i8, ptr @outarr, i64 240), ptr noundef nonnull dereferenceable(1) @.str.9, double noundef %50) #8
  %52 = load double, ptr @aberr_osc, align 8, !tbaa !9
  %53 = tail call i32 (ptr, ptr, ...) @sprintf(ptr noundef nonnull dereferenceable(1) getelementptr inbounds nuw (i8, ptr @outarr, i64 320), ptr noundef nonnull dereferenceable(1) @.str.10, double noundef %52) #8
  %54 = load double, ptr @max_osc, align 8, !tbaa !9
  %55 = tail call i32 (ptr, ptr, ...) @sprintf(ptr noundef nonnull dereferenceable(1) getelementptr inbounds nuw (i8, ptr @outarr, i64 400), ptr noundef nonnull dereferenceable(1) @.str.9, double noundef %54) #8
  %56 = load double, ptr @aberr_lchrom, align 8, !tbaa !9
  %57 = tail call i32 (ptr, ptr, ...) @sprintf(ptr noundef nonnull dereferenceable(1) getelementptr inbounds nuw (i8, ptr @outarr, i64 480), ptr noundef nonnull dereferenceable(1) @.str.11, double noundef %56) #8
  %58 = load double, ptr @max_lchrom, align 8, !tbaa !9
  %59 = tail call i32 (ptr, ptr, ...) @sprintf(ptr noundef nonnull dereferenceable(1) getelementptr inbounds nuw (i8, ptr @outarr, i64 560), ptr noundef nonnull dereferenceable(1) @.str.9, double noundef %58) #8
  br label %60

60:                                               ; preds = %41, %100
  %61 = phi i64 [ 0, %41 ], [ %68, %100 ]
  %62 = phi i32 [ 0, %41 ], [ %101, %100 ]
  %63 = getelementptr inbounds nuw [80 x i8], ptr @outarr, i64 %61
  %64 = getelementptr inbounds nuw [8 x i8], ptr @refarr, i64 %61
  %65 = load ptr, ptr %64, align 8, !tbaa !14
  %66 = tail call i32 @strcmp(ptr noundef nonnull dereferenceable(1) %63, ptr noundef nonnull dereferenceable(1) %65) #9
  %67 = icmp eq i32 %66, 0
  %68 = add nuw nsw i64 %61, 1
  br i1 %67, label %100, label %69

69:                                               ; preds = %60
  %70 = trunc nuw nsw i64 %68 to i32
  %71 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.12, i32 noundef %70)
  %72 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.13, ptr noundef nonnull %65)
  %73 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.14, ptr noundef nonnull %63)
  %74 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.15)
  %75 = tail call i64 @strlen(ptr noundef nonnull dereferenceable(1) %65) #9
  %76 = trunc i64 %75 to i32
  %77 = icmp sgt i32 %76, 0
  br i1 %77, label %78, label %97

78:                                               ; preds = %69
  %79 = and i64 %75, 2147483647
  br label %80

80:                                               ; preds = %78, %80
  %81 = phi i64 [ 0, %78 ], [ %95, %80 ]
  %82 = phi i32 [ %62, %78 ], [ %94, %80 ]
  %83 = getelementptr inbounds nuw i8, ptr %65, i64 %81
  %84 = load i8, ptr %83, align 1, !tbaa !17
  %85 = getelementptr inbounds nuw i8, ptr %63, i64 %81
  %86 = load i8, ptr %85, align 1, !tbaa !17
  %87 = icmp eq i8 %84, %86
  %88 = select i1 %87, i32 32, i32 94
  %89 = tail call i32 @putchar(i32 %88)
  %90 = load i8, ptr %83, align 1, !tbaa !17
  %91 = load i8, ptr %85, align 1, !tbaa !17
  %92 = icmp ne i8 %90, %91
  %93 = zext i1 %92 to i32
  %94 = add nsw i32 %82, %93
  %95 = add nuw nsw i64 %81, 1
  %96 = icmp eq i64 %95, %79
  br i1 %96, label %97, label %80, !llvm.loop !18

97:                                               ; preds = %80, %69
  %98 = phi i32 [ %62, %69 ], [ %94, %80 ]
  %99 = tail call i32 @putchar(i32 10)
  br label %100

100:                                              ; preds = %60, %97
  %101 = phi i32 [ %98, %97 ], [ %62, %60 ]
  %102 = icmp eq i64 %68, 8
  br i1 %102, label %103, label %60, !llvm.loop !19

103:                                              ; preds = %100
  %104 = icmp sgt i32 %101, 0
  br i1 %104, label %105, label %109

105:                                              ; preds = %103
  %106 = icmp eq i32 %101, 1
  %107 = select i1 %106, ptr @.str.20, ptr @.str.19
  %108 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.18, i32 noundef %101, ptr noundef nonnull %107)
  br label %111

109:                                              ; preds = %103
  %110 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str.31)
  br label %111

111:                                              ; preds = %109, %105
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #1

; Function Attrs: nofree norecurse nosync nounwind memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable
define internal fastcc void @trace_line(i32 noundef range(i32 3, 7) %0, double noundef nofpclass(nan inf zero sub nnorm) %1) unnamed_addr #2 {
  store double 0.000000e+00, ptr @object_distance, align 8, !tbaa !9
  %3 = load i1, ptr @current_surfaces, align 2
  br i1 %3, label %4, label %121

4:                                                ; preds = %2
  %5 = load double, ptr @axis_slope_angle, align 8
  %6 = load <2 x double>, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 32), align 16
  %7 = zext nneg i32 %0 to i64
  %8 = getelementptr inbounds nuw [8 x i8], ptr @spectral_line, i64 %7
  %9 = load double, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 24), align 8
  %10 = load double, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 48), align 16
  %11 = fsub double %9, %10
  %12 = load i1, ptr @paraxial, align 2
  %13 = insertelement <2 x double> poison, double %11, i64 0
  br label %14

14:                                               ; preds = %4, %117
  %15 = phi i64 [ 1, %4 ], [ %119, %117 ]
  %16 = phi double [ 0.000000e+00, %4 ], [ %118, %117 ]
  %17 = phi double [ 1.000000e+00, %4 ], [ %39, %117 ]
  %18 = phi double [ %5, %4 ], [ %110, %117 ]
  %19 = phi double [ %1, %4 ], [ %109, %117 ]
  %20 = getelementptr inbounds nuw [40 x i8], ptr @s, i64 %15
  %21 = getelementptr inbounds nuw i8, ptr %20, i64 8
  %22 = load double, ptr %21, align 8, !tbaa !9
  %23 = getelementptr inbounds nuw i8, ptr %20, i64 16
  %24 = load double, ptr %23, align 8, !tbaa !9
  %25 = fcmp ogt double %24, 1.000000e+00
  br i1 %25, label %26, label %38

26:                                               ; preds = %14
  %27 = load double, ptr %8, align 8, !tbaa !9
  %28 = getelementptr inbounds nuw i8, ptr %20, i64 24
  %29 = load double, ptr %28, align 8, !tbaa !9
  %30 = insertelement <2 x double> %6, double %24, i64 1
  %31 = insertelement <2 x double> <double poison, double 1.000000e+00>, double %27, i64 0
  %32 = fsub <2 x double> %30, %31
  %33 = insertelement <2 x double> %13, double %29, i64 1
  %34 = fdiv <2 x double> %32, %33
  %35 = extractelement <2 x double> %34, i64 0
  %36 = extractelement <2 x double> %34, i64 1
  %37 = tail call double @llvm.fmuladd.f64(double %35, double %36, double %24)
  br label %38

38:                                               ; preds = %26, %14
  %39 = phi double [ %37, %26 ], [ %24, %14 ]
  %40 = fcmp une double %22, 0.000000e+00
  br i1 %12, label %41, label %68

41:                                               ; preds = %38
  br i1 %40, label %42, label %58

42:                                               ; preds = %41
  %43 = fcmp oeq double %16, 0.000000e+00
  %44 = fdiv double %19, %22
  %45 = fsub double %16, %22
  %46 = fdiv double %45, %22
  %47 = fmul double %46, %18
  %48 = select i1 %43, double 0.000000e+00, double %18
  %49 = select i1 %43, double %44, double %47
  %50 = fdiv double %17, %39
  %51 = fmul double %49, %50
  %52 = fadd double %48, %49
  %53 = fsub double %52, %51
  store double %53, ptr @axis_slope_angle, align 8, !tbaa !9
  %54 = fcmp une double %16, 0.000000e+00
  %55 = fmul double %16, %48
  %56 = select i1 %54, double %55, double %19
  %57 = fdiv double %56, %53
  store double %57, ptr @object_distance, align 8, !tbaa !9
  br label %108

58:                                               ; preds = %41
  %59 = insertelement <2 x double> poison, double %39, i64 0
  %60 = insertelement <2 x double> %59, double %17, i64 1
  %61 = shufflevector <2 x double> %60, <2 x double> poison, <2 x i32> <i32 1, i32 0>
  %62 = fdiv <2 x double> %61, %60
  %63 = insertelement <2 x double> poison, double %18, i64 0
  %64 = insertelement <2 x double> %63, double %16, i64 1
  %65 = fmul <2 x double> %64, %62
  %66 = extractelement <2 x double> %65, i64 1
  store double %66, ptr @object_distance, align 8, !tbaa !9
  %67 = extractelement <2 x double> %65, i64 0
  store double %67, ptr @axis_slope_angle, align 8, !tbaa !9
  br label %108

68:                                               ; preds = %38
  br i1 %40, label %69, label %97

69:                                               ; preds = %68
  %70 = fcmp oeq double %16, 0.000000e+00
  br i1 %70, label %71, label %73

71:                                               ; preds = %69
  %72 = fdiv double %19, %22
  br label %78

73:                                               ; preds = %69
  %74 = fsub double %16, %22
  %75 = fdiv double %74, %22
  %76 = tail call double @sin(double noundef %18) #8
  %77 = fmul double %75, %76
  br label %78

78:                                               ; preds = %73, %71
  %79 = phi double [ 0.000000e+00, %71 ], [ %18, %73 ]
  %80 = phi double [ %72, %71 ], [ %77, %73 ]
  %81 = tail call double @asin(double noundef %80) #8
  %82 = fdiv double %17, %39
  %83 = fmul double %80, %82
  %84 = fadd double %79, %81
  %85 = tail call double @asin(double noundef %83) #8
  %86 = fsub double %84, %85
  store double %86, ptr @axis_slope_angle, align 8, !tbaa !9
  %87 = fmul double %84, 5.000000e-01
  %88 = tail call double @sin(double noundef %87) #8
  %89 = fmul double %22, 2.000000e+00
  %90 = fmul double %89, %88
  %91 = fmul double %88, %90
  %92 = tail call double @sin(double noundef %84) #8
  %93 = fmul double %22, %92
  %94 = tail call double @tan(double noundef %86) #8
  %95 = fdiv double 1.000000e+00, %94
  %96 = tail call double @llvm.fmuladd.f64(double %93, double %95, double %91)
  store double %96, ptr @object_distance, align 8, !tbaa !9
  br label %108

97:                                               ; preds = %68
  %98 = fdiv double %17, %39
  %99 = tail call double @sin(double noundef %18) #8
  %100 = fmul double %98, %99
  %101 = tail call double @asin(double noundef %100) #8
  %102 = tail call double @cos(double noundef %101) #8
  %103 = fmul double %39, %102
  %104 = tail call double @cos(double noundef %18) #8
  %105 = fmul double %17, %104
  %106 = fdiv double %103, %105
  %107 = fmul double %16, %106
  store double %107, ptr @object_distance, align 8, !tbaa !9
  store double %101, ptr @axis_slope_angle, align 8, !tbaa !9
  br label %108

108:                                              ; preds = %42, %58, %78, %97
  %109 = phi double [ %56, %42 ], [ %19, %58 ], [ %19, %78 ], [ %19, %97 ]
  %110 = phi double [ %53, %42 ], [ %67, %58 ], [ %86, %78 ], [ %101, %97 ]
  %111 = phi double [ %57, %42 ], [ %66, %58 ], [ %96, %78 ], [ %107, %97 ]
  %112 = icmp samesign ult i64 %15, 4
  br i1 %112, label %113, label %117

113:                                              ; preds = %108
  %114 = getelementptr inbounds nuw i8, ptr %20, i64 32
  %115 = load double, ptr %114, align 8, !tbaa !9
  %116 = fsub double %111, %115
  store double %116, ptr @object_distance, align 8, !tbaa !9
  br label %117

117:                                              ; preds = %108, %113
  %118 = phi double [ %111, %108 ], [ %116, %113 ]
  %119 = add nuw nsw i64 %15, 1
  %120 = icmp eq i64 %119, 5
  br i1 %120, label %121, label %14, !llvm.loop !20

121:                                              ; preds = %117, %2
  ret void
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @sin(double noundef) local_unnamed_addr #3

; Function Attrs: nofree nounwind
declare noundef i32 @sprintf(ptr noalias noundef writeonly captures(none), ptr noundef readonly captures(none), ...) local_unnamed_addr #1

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: read)
declare i32 @strcmp(ptr noundef captures(none), ptr noundef captures(none)) local_unnamed_addr #4

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: read)
declare i64 @strlen(ptr noundef captures(none)) local_unnamed_addr #4

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #5

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @asin(double noundef) local_unnamed_addr #3

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @tan(double noundef) local_unnamed_addr #3

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @cos(double noundef) local_unnamed_addr #3

; Function Attrs: nofree nounwind
declare noundef i32 @puts(ptr noundef readonly captures(none)) local_unnamed_addr #6

; Function Attrs: nofree nounwind
declare noundef i32 @putchar(i32 noundef) local_unnamed_addr #6

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #7

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nofree norecurse nosync nounwind memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: read) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #6 = { nofree nounwind }
attributes #7 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #8 = { nounwind }
attributes #9 = { nounwind willreturn memory(read) }

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
!11 = !{!6, !6, i64 0}
!12 = distinct !{!12, !13}
!13 = !{!"llvm.loop.mustprogress"}
!14 = !{!15, !15, i64 0}
!15 = !{!"p1 omnipotent char", !16, i64 0}
!16 = !{!"any pointer", !7, i64 0}
!17 = !{!7, !7, i64 0}
!18 = distinct !{!18, !13}
!19 = distinct !{!19, !13}
!20 = distinct !{!20, !13}
