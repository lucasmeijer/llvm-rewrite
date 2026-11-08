; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/fbench.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/fbench.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/fbench.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@niter = dso_local global i32 1000, align 4
@spectral_line = internal global [9 x double] zeroinitializer, align 16
@clear_aperture = internal global double 0.000000e+00, align 8
@current_surfaces = internal global i16 0, align 2
@testcase = internal global [4 x [4 x double]] [[4 x double] [double 2.705000e+01, double 1.513700e+00, double 6.360000e+01, double 5.200000e-01], [4 x double] [double -1.668000e+01, double 1.000000e+00, double 0.000000e+00, double 1.380000e-01], [4 x double] [double -1.668000e+01, double 1.616400e+00, double 3.670000e+01, double 3.800000e-01], [4 x double] [double -7.810000e+01, double 1.000000e+00, double 0.000000e+00, double 0.000000e+00]], align 16
@s = internal global [10 x [5 x double]] zeroinitializer, align 16
@.str = private unnamed_addr constant [54 x i8] c"Ready to begin John Walker's floating point accuracy\0A\00", align 1
@.str.1 = private unnamed_addr constant [58 x i8] c"and performance benchmark.  %d iterations will be made.\0A\0A\00", align 1
@.str.2 = private unnamed_addr constant [56 x i8] c"\0AMeasured run time in seconds should be divided by %.f\0A\00", align 1
@.str.3 = private unnamed_addr constant [60 x i8] c"to normalise for reporting results.  For archival results,\0A\00", align 1
@.str.4 = private unnamed_addr constant [67 x i8] c"adjust iteration count so the benchmark runs about five minutes.\0A\0A\00", align 1
@itercount = dso_local global i32 0, align 4
@paraxial = internal global i16 0, align 2
@object_distance = internal global double 0.000000e+00, align 8
@od_sa = internal global [2 x [2 x double]] zeroinitializer, align 16
@axis_slope_angle = internal global double 0.000000e+00, align 8
@aberr_lspher = internal global double 0.000000e+00, align 8
@aberr_osc = internal global double 0.000000e+00, align 8
@aberr_lchrom = internal global double 0.000000e+00, align 8
@max_lspher = internal global double 0.000000e+00, align 8
@max_osc = internal global double 0.000000e+00, align 8
@max_lchrom = internal global double 0.000000e+00, align 8
@outarr = internal global [8 x [80 x i8]] zeroinitializer, align 16
@.str.5 = private unnamed_addr constant [24 x i8] c"%15s   %21.11f  %14.11f\00", align 1
@.str.6 = private unnamed_addr constant [13 x i8] c"Marginal ray\00", align 1
@.str.7 = private unnamed_addr constant [13 x i8] c"Paraxial ray\00", align 1
@.str.8 = private unnamed_addr constant [48 x i8] c"Longitudinal spherical aberration:      %16.11f\00", align 1
@.str.9 = private unnamed_addr constant [48 x i8] c"    (Maximum permissible):              %16.11f\00", align 1
@.str.10 = private unnamed_addr constant [48 x i8] c"Offense against sine condition (coma):  %16.11f\00", align 1
@.str.11 = private unnamed_addr constant [48 x i8] c"Axial chromatic aberration:             %16.11f\00", align 1
@refarr = internal global [8 x ptr] [ptr @.str.22, ptr @.str.23, ptr @.str.24, ptr @.str.25, ptr @.str.26, ptr @.str.27, ptr @.str.28, ptr @.str.25], align 16
@.str.12 = private unnamed_addr constant [33 x i8] c"\0AError in results on line %d...\0A\00", align 1
@.str.13 = private unnamed_addr constant [17 x i8] c"Expected:  \22%s\22\0A\00", align 1
@.str.14 = private unnamed_addr constant [17 x i8] c"Received:  \22%s\22\0A\00", align 1
@.str.15 = private unnamed_addr constant [13 x i8] c"(Errors)    \00", align 1
@.str.16 = private unnamed_addr constant [3 x i8] c"%c\00", align 1
@.str.17 = private unnamed_addr constant [2 x i8] c"\0A\00", align 1
@.str.18 = private unnamed_addr constant [48 x i8] c"\0A%d error%s in results.  This is VERY SERIOUS.\0A\00", align 1
@.str.19 = private unnamed_addr constant [2 x i8] c"s\00", align 1
@.str.20 = private unnamed_addr constant [1 x i8] zeroinitializer, align 1
@.str.21 = private unnamed_addr constant [24 x i8] c"\0ANo errors in results.\0A\00", align 1
@ray_height = internal global double 0.000000e+00, align 8
@from_index = internal global double 0.000000e+00, align 8
@radius_of_curvature = internal global double 0.000000e+00, align 8
@to_index = internal global double 0.000000e+00, align 8
@.str.22 = private unnamed_addr constant [56 x i8] c"   Marginal ray          47.09479120920   0.04178472683\00", align 1
@.str.23 = private unnamed_addr constant [56 x i8] c"   Paraxial ray          47.08372160249   0.04177864821\00", align 1
@.str.24 = private unnamed_addr constant [57 x i8] c"Longitudinal spherical aberration:        -0.01106960671\00", align 1
@.str.25 = private unnamed_addr constant [57 x i8] c"    (Maximum permissible):                 0.05306749907\00", align 1
@.str.26 = private unnamed_addr constant [57 x i8] c"Offense against sine condition (coma):     0.00008954761\00", align 1
@.str.27 = private unnamed_addr constant [57 x i8] c"    (Maximum permissible):                 0.00250000000\00", align 1
@.str.28 = private unnamed_addr constant [57 x i8] c"Axial chromatic aberration:                0.00448229032\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  %10 = alloca double, align 8
  %11 = alloca double, align 8
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %6) #6
  call void @llvm.lifetime.start.p0(ptr %7) #6
  call void @llvm.lifetime.start.p0(ptr %8) #6
  call void @llvm.lifetime.start.p0(ptr %9) #6
  call void @llvm.lifetime.start.p0(ptr %10) #6
  call void @llvm.lifetime.start.p0(ptr %11) #6
  store double 7.621000e+03, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 8), align 8, !tbaa !14
  store double f0x40BAD5F47AE147AE, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 16), align 16, !tbaa !14
  store double f0x40B9A2D0E5604189, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 24), align 8, !tbaa !14
  store double f0x40B707F1A9FBE76D, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 32), align 16, !tbaa !14
  store double f0x40B4958E978D4FDF, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 40), align 8, !tbaa !14
  store double f0x40B2FD5810624DD3, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 48), align 16, !tbaa !14
  store double f0x40B0F47A1CAC0831, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 56), align 8, !tbaa !14
  store double f0x40AF00FCED916873, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 64), align 16, !tbaa !14
  store i32 1000000, ptr @niter, align 4, !tbaa !9
  store double 4.000000e+00, ptr @clear_aperture, align 8, !tbaa !14
  store i16 4, ptr @current_surfaces, align 2, !tbaa !16
  store i32 0, ptr %6, align 4, !tbaa !9
  br label %12

12:                                               ; preds = %41, %2
  %13 = load i32, ptr %6, align 4, !tbaa !9
  %14 = load i16, ptr @current_surfaces, align 2, !tbaa !16
  %15 = sext i16 %14 to i32
  %16 = icmp slt i32 %13, %15
  br i1 %16, label %17, label %44

17:                                               ; preds = %12
  store i32 0, ptr %7, align 4, !tbaa !9
  br label %18

18:                                               ; preds = %37, %17
  %19 = load i32, ptr %7, align 4, !tbaa !9
  %20 = icmp slt i32 %19, 4
  br i1 %20, label %21, label %40

21:                                               ; preds = %18
  %22 = load i32, ptr %6, align 4, !tbaa !9
  %23 = sext i32 %22 to i64
  %24 = getelementptr inbounds [4 x [4 x double]], ptr @testcase, i64 0, i64 %23
  %25 = load i32, ptr %7, align 4, !tbaa !9
  %26 = sext i32 %25 to i64
  %27 = getelementptr inbounds [4 x double], ptr %24, i64 0, i64 %26
  %28 = load double, ptr %27, align 8, !tbaa !14
  %29 = load i32, ptr %6, align 4, !tbaa !9
  %30 = add nsw i32 %29, 1
  %31 = sext i32 %30 to i64
  %32 = getelementptr inbounds [10 x [5 x double]], ptr @s, i64 0, i64 %31
  %33 = load i32, ptr %7, align 4, !tbaa !9
  %34 = add nsw i32 %33, 1
  %35 = sext i32 %34 to i64
  %36 = getelementptr inbounds [5 x double], ptr %32, i64 0, i64 %35
  store double %28, ptr %36, align 8, !tbaa !14
  br label %37

37:                                               ; preds = %21
  %38 = load i32, ptr %7, align 4, !tbaa !9
  %39 = add nsw i32 %38, 1
  store i32 %39, ptr %7, align 4, !tbaa !9
  br label %18, !llvm.loop !18

40:                                               ; preds = %18
  br label %41

41:                                               ; preds = %40
  %42 = load i32, ptr %6, align 4, !tbaa !9
  %43 = add nsw i32 %42, 1
  store i32 %43, ptr %6, align 4, !tbaa !9
  br label %12, !llvm.loop !20

44:                                               ; preds = %12
  %45 = call i32 (ptr, ...) @printf(ptr noundef @.str)
  %46 = load i32, ptr @niter, align 4, !tbaa !9
  %47 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %46)
  %48 = load i32, ptr @niter, align 4, !tbaa !9
  %49 = sitofp i32 %48 to double
  %50 = fdiv double %49, 1.000000e+03
  %51 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, double noundef %50)
  %52 = call i32 (ptr, ...) @printf(ptr noundef @.str.3)
  %53 = call i32 (ptr, ...) @printf(ptr noundef @.str.4)
  store i32 0, ptr @itercount, align 4, !tbaa !9
  br label %54

54:                                               ; preds = %111, %44
  %55 = load i32, ptr @itercount, align 4, !tbaa !9
  %56 = load i32, ptr @niter, align 4, !tbaa !9
  %57 = icmp slt i32 %55, %56
  br i1 %57, label %58, label %114

58:                                               ; preds = %54
  store i16 0, ptr @paraxial, align 2, !tbaa !16
  br label %59

59:                                               ; preds = %77, %58
  %60 = load i16, ptr @paraxial, align 2, !tbaa !16
  %61 = sext i16 %60 to i32
  %62 = icmp sle i32 %61, 1
  br i1 %62, label %63, label %80

63:                                               ; preds = %59
  %64 = load double, ptr @clear_aperture, align 8, !tbaa !14
  %65 = fdiv double %64, 2.000000e+00
  %66 = call i32 @trace_line(i32 noundef 4, double noundef %65)
  %67 = load double, ptr @object_distance, align 8, !tbaa !14
  %68 = load i16, ptr @paraxial, align 2, !tbaa !16
  %69 = sext i16 %68 to i64
  %70 = getelementptr inbounds [2 x [2 x double]], ptr @od_sa, i64 0, i64 %69
  %71 = getelementptr inbounds [2 x double], ptr %70, i64 0, i64 0
  store double %67, ptr %71, align 16, !tbaa !14
  %72 = load double, ptr @axis_slope_angle, align 8, !tbaa !14
  %73 = load i16, ptr @paraxial, align 2, !tbaa !16
  %74 = sext i16 %73 to i64
  %75 = getelementptr inbounds [2 x [2 x double]], ptr @od_sa, i64 0, i64 %74
  %76 = getelementptr inbounds [2 x double], ptr %75, i64 0, i64 1
  store double %72, ptr %76, align 8, !tbaa !14
  br label %77

77:                                               ; preds = %63
  %78 = load i16, ptr @paraxial, align 2, !tbaa !16
  %79 = add i16 %78, 1
  store i16 %79, ptr @paraxial, align 2, !tbaa !16
  br label %59, !llvm.loop !21

80:                                               ; preds = %59
  store i16 0, ptr @paraxial, align 2, !tbaa !16
  %81 = load double, ptr @clear_aperture, align 8, !tbaa !14
  %82 = fdiv double %81, 2.000000e+00
  %83 = call i32 @trace_line(i32 noundef 3, double noundef %82)
  %84 = load double, ptr @object_distance, align 8, !tbaa !14
  store double %84, ptr %11, align 8, !tbaa !14
  %85 = load double, ptr @clear_aperture, align 8, !tbaa !14
  %86 = fdiv double %85, 2.000000e+00
  %87 = call i32 @trace_line(i32 noundef 6, double noundef %86)
  %88 = load double, ptr @object_distance, align 8, !tbaa !14
  store double %88, ptr %10, align 8, !tbaa !14
  %89 = load double, ptr getelementptr inbounds nuw (i8, ptr @od_sa, i64 16), align 16, !tbaa !14
  %90 = load double, ptr @od_sa, align 16, !tbaa !14
  %91 = fsub double %89, %90
  store double %91, ptr @aberr_lspher, align 8, !tbaa !14
  %92 = load double, ptr getelementptr inbounds nuw (i8, ptr @od_sa, i64 16), align 16, !tbaa !14
  %93 = load double, ptr getelementptr inbounds nuw (i8, ptr @od_sa, i64 24), align 8, !tbaa !14
  %94 = fmul double %92, %93
  %95 = load double, ptr getelementptr inbounds nuw (i8, ptr @od_sa, i64 8), align 8, !tbaa !14
  %96 = call double @sin(double noundef %95) #6
  %97 = load double, ptr @od_sa, align 16, !tbaa !14
  %98 = fmul double %96, %97
  %99 = fdiv double %94, %98
  %100 = fsub double 1.000000e+00, %99
  store double %100, ptr @aberr_osc, align 8, !tbaa !14
  %101 = load double, ptr %10, align 8, !tbaa !14
  %102 = load double, ptr %11, align 8, !tbaa !14
  %103 = fsub double %101, %102
  store double %103, ptr @aberr_lchrom, align 8, !tbaa !14
  %104 = load double, ptr getelementptr inbounds nuw (i8, ptr @od_sa, i64 8), align 8, !tbaa !14
  %105 = call double @sin(double noundef %104) #6
  store double %105, ptr @max_lspher, align 8, !tbaa !14
  %106 = load double, ptr @max_lspher, align 8, !tbaa !14
  %107 = load double, ptr @max_lspher, align 8, !tbaa !14
  %108 = fmul double %106, %107
  %109 = fdiv double 9.260000e-05, %108
  store double %109, ptr @max_lspher, align 8, !tbaa !14
  store double 2.500000e-03, ptr @max_osc, align 8, !tbaa !14
  %110 = load double, ptr @max_lspher, align 8, !tbaa !14
  store double %110, ptr @max_lchrom, align 8, !tbaa !14
  br label %111

111:                                              ; preds = %80
  %112 = load i32, ptr @itercount, align 4, !tbaa !9
  %113 = add nsw i32 %112, 1
  store i32 %113, ptr @itercount, align 4, !tbaa !9
  br label %54, !llvm.loop !22

114:                                              ; preds = %54
  %115 = load double, ptr @od_sa, align 16, !tbaa !14
  %116 = load double, ptr getelementptr inbounds nuw (i8, ptr @od_sa, i64 8), align 8, !tbaa !14
  %117 = call i32 (ptr, ptr, ...) @sprintf(ptr noundef @outarr, ptr noundef @.str.5, ptr noundef @.str.6, double noundef %115, double noundef %116) #6
  %118 = load double, ptr getelementptr inbounds nuw (i8, ptr @od_sa, i64 16), align 16, !tbaa !14
  %119 = load double, ptr getelementptr inbounds nuw (i8, ptr @od_sa, i64 24), align 8, !tbaa !14
  %120 = call i32 (ptr, ptr, ...) @sprintf(ptr noundef getelementptr inbounds nuw (i8, ptr @outarr, i64 80), ptr noundef @.str.5, ptr noundef @.str.7, double noundef %118, double noundef %119) #6
  %121 = load double, ptr @aberr_lspher, align 8, !tbaa !14
  %122 = call i32 (ptr, ptr, ...) @sprintf(ptr noundef getelementptr inbounds nuw (i8, ptr @outarr, i64 160), ptr noundef @.str.8, double noundef %121) #6
  %123 = load double, ptr @max_lspher, align 8, !tbaa !14
  %124 = call i32 (ptr, ptr, ...) @sprintf(ptr noundef getelementptr inbounds nuw (i8, ptr @outarr, i64 240), ptr noundef @.str.9, double noundef %123) #6
  %125 = load double, ptr @aberr_osc, align 8, !tbaa !14
  %126 = call i32 (ptr, ptr, ...) @sprintf(ptr noundef getelementptr inbounds nuw (i8, ptr @outarr, i64 320), ptr noundef @.str.10, double noundef %125) #6
  %127 = load double, ptr @max_osc, align 8, !tbaa !14
  %128 = call i32 (ptr, ptr, ...) @sprintf(ptr noundef getelementptr inbounds nuw (i8, ptr @outarr, i64 400), ptr noundef @.str.9, double noundef %127) #6
  %129 = load double, ptr @aberr_lchrom, align 8, !tbaa !14
  %130 = call i32 (ptr, ptr, ...) @sprintf(ptr noundef getelementptr inbounds nuw (i8, ptr @outarr, i64 480), ptr noundef @.str.11, double noundef %129) #6
  %131 = load double, ptr @max_lchrom, align 8, !tbaa !14
  %132 = call i32 (ptr, ptr, ...) @sprintf(ptr noundef getelementptr inbounds nuw (i8, ptr @outarr, i64 560), ptr noundef @.str.9, double noundef %131) #6
  store i32 0, ptr %9, align 4, !tbaa !9
  store i32 0, ptr %6, align 4, !tbaa !9
  br label %133

133:                                              ; preds = %222, %114
  %134 = load i32, ptr %6, align 4, !tbaa !9
  %135 = icmp slt i32 %134, 8
  br i1 %135, label %136, label %225

136:                                              ; preds = %133
  %137 = load i32, ptr %6, align 4, !tbaa !9
  %138 = sext i32 %137 to i64
  %139 = getelementptr inbounds [8 x [80 x i8]], ptr @outarr, i64 0, i64 %138
  %140 = getelementptr inbounds [80 x i8], ptr %139, i64 0, i64 0
  %141 = load i32, ptr %6, align 4, !tbaa !9
  %142 = sext i32 %141 to i64
  %143 = getelementptr inbounds [8 x ptr], ptr @refarr, i64 0, i64 %142
  %144 = load ptr, ptr %143, align 8, !tbaa !23
  %145 = call i32 @strcmp(ptr noundef %140, ptr noundef %144) #7
  %146 = icmp ne i32 %145, 0
  br i1 %146, label %147, label %221

147:                                              ; preds = %136
  %148 = load i32, ptr %6, align 4, !tbaa !9
  %149 = add nsw i32 %148, 1
  %150 = call i32 (ptr, ...) @printf(ptr noundef @.str.12, i32 noundef %149)
  %151 = load i32, ptr %6, align 4, !tbaa !9
  %152 = sext i32 %151 to i64
  %153 = getelementptr inbounds [8 x ptr], ptr @refarr, i64 0, i64 %152
  %154 = load ptr, ptr %153, align 8, !tbaa !23
  %155 = call i32 (ptr, ...) @printf(ptr noundef @.str.13, ptr noundef %154)
  %156 = load i32, ptr %6, align 4, !tbaa !9
  %157 = sext i32 %156 to i64
  %158 = getelementptr inbounds [8 x [80 x i8]], ptr @outarr, i64 0, i64 %157
  %159 = getelementptr inbounds [80 x i8], ptr %158, i64 0, i64 0
  %160 = call i32 (ptr, ...) @printf(ptr noundef @.str.14, ptr noundef %159)
  %161 = call i32 (ptr, ...) @printf(ptr noundef @.str.15)
  %162 = load i32, ptr %6, align 4, !tbaa !9
  %163 = sext i32 %162 to i64
  %164 = getelementptr inbounds [8 x ptr], ptr @refarr, i64 0, i64 %163
  %165 = load ptr, ptr %164, align 8, !tbaa !23
  %166 = call i64 @strlen(ptr noundef %165) #7
  %167 = trunc i64 %166 to i32
  store i32 %167, ptr %8, align 4, !tbaa !9
  store i32 0, ptr %7, align 4, !tbaa !9
  br label %168

168:                                              ; preds = %216, %147
  %169 = load i32, ptr %7, align 4, !tbaa !9
  %170 = load i32, ptr %8, align 4, !tbaa !9
  %171 = icmp slt i32 %169, %170
  br i1 %171, label %172, label %219

172:                                              ; preds = %168
  %173 = load i32, ptr %6, align 4, !tbaa !9
  %174 = sext i32 %173 to i64
  %175 = getelementptr inbounds [8 x ptr], ptr @refarr, i64 0, i64 %174
  %176 = load ptr, ptr %175, align 8, !tbaa !23
  %177 = load i32, ptr %7, align 4, !tbaa !9
  %178 = sext i32 %177 to i64
  %179 = getelementptr inbounds i8, ptr %176, i64 %178
  %180 = load i8, ptr %179, align 1, !tbaa !25
  %181 = sext i8 %180 to i32
  %182 = load i32, ptr %6, align 4, !tbaa !9
  %183 = sext i32 %182 to i64
  %184 = getelementptr inbounds [8 x [80 x i8]], ptr @outarr, i64 0, i64 %183
  %185 = load i32, ptr %7, align 4, !tbaa !9
  %186 = sext i32 %185 to i64
  %187 = getelementptr inbounds [80 x i8], ptr %184, i64 0, i64 %186
  %188 = load i8, ptr %187, align 1, !tbaa !25
  %189 = sext i8 %188 to i32
  %190 = icmp eq i32 %181, %189
  %191 = zext i1 %190 to i64
  %192 = select i1 %190, i32 32, i32 94
  %193 = call i32 (ptr, ...) @printf(ptr noundef @.str.16, i32 noundef %192)
  %194 = load i32, ptr %6, align 4, !tbaa !9
  %195 = sext i32 %194 to i64
  %196 = getelementptr inbounds [8 x ptr], ptr @refarr, i64 0, i64 %195
  %197 = load ptr, ptr %196, align 8, !tbaa !23
  %198 = load i32, ptr %7, align 4, !tbaa !9
  %199 = sext i32 %198 to i64
  %200 = getelementptr inbounds i8, ptr %197, i64 %199
  %201 = load i8, ptr %200, align 1, !tbaa !25
  %202 = sext i8 %201 to i32
  %203 = load i32, ptr %6, align 4, !tbaa !9
  %204 = sext i32 %203 to i64
  %205 = getelementptr inbounds [8 x [80 x i8]], ptr @outarr, i64 0, i64 %204
  %206 = load i32, ptr %7, align 4, !tbaa !9
  %207 = sext i32 %206 to i64
  %208 = getelementptr inbounds [80 x i8], ptr %205, i64 0, i64 %207
  %209 = load i8, ptr %208, align 1, !tbaa !25
  %210 = sext i8 %209 to i32
  %211 = icmp ne i32 %202, %210
  br i1 %211, label %212, label %215

212:                                              ; preds = %172
  %213 = load i32, ptr %9, align 4, !tbaa !9
  %214 = add nsw i32 %213, 1
  store i32 %214, ptr %9, align 4, !tbaa !9
  br label %215

215:                                              ; preds = %212, %172
  br label %216

216:                                              ; preds = %215
  %217 = load i32, ptr %7, align 4, !tbaa !9
  %218 = add nsw i32 %217, 1
  store i32 %218, ptr %7, align 4, !tbaa !9
  br label %168, !llvm.loop !26

219:                                              ; preds = %168
  %220 = call i32 (ptr, ...) @printf(ptr noundef @.str.17)
  br label %221

221:                                              ; preds = %219, %136
  br label %222

222:                                              ; preds = %221
  %223 = load i32, ptr %6, align 4, !tbaa !9
  %224 = add nsw i32 %223, 1
  store i32 %224, ptr %6, align 4, !tbaa !9
  br label %133, !llvm.loop !27

225:                                              ; preds = %133
  %226 = load i32, ptr %9, align 4, !tbaa !9
  %227 = icmp sgt i32 %226, 0
  br i1 %227, label %228, label %235

228:                                              ; preds = %225
  %229 = load i32, ptr %9, align 4, !tbaa !9
  %230 = load i32, ptr %9, align 4, !tbaa !9
  %231 = icmp sgt i32 %230, 1
  %232 = zext i1 %231 to i64
  %233 = select i1 %231, ptr @.str.19, ptr @.str.20
  %234 = call i32 (ptr, ...) @printf(ptr noundef @.str.18, i32 noundef %229, ptr noundef %233)
  br label %237

235:                                              ; preds = %225
  %236 = call i32 (ptr, ...) @printf(ptr noundef @.str.21)
  br label %237

237:                                              ; preds = %235, %228
  call void @llvm.lifetime.end.p0(ptr %11) #6
  call void @llvm.lifetime.end.p0(ptr %10) #6
  call void @llvm.lifetime.end.p0(ptr %9) #6
  call void @llvm.lifetime.end.p0(ptr %8) #6
  call void @llvm.lifetime.end.p0(ptr %7) #6
  call void @llvm.lifetime.end.p0(ptr %6) #6
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nounwind uwtable
define internal i32 @trace_line(i32 noundef %0, double noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca double, align 8
  %6 = alloca i32, align 4
  store i32 %0, ptr %4, align 4, !tbaa !9
  store double %1, ptr %5, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %6) #6
  store double 0.000000e+00, ptr @object_distance, align 8, !tbaa !14
  %7 = load double, ptr %5, align 8, !tbaa !14
  store double %7, ptr @ray_height, align 8, !tbaa !14
  store double 1.000000e+00, ptr @from_index, align 8, !tbaa !14
  store i32 1, ptr %6, align 4, !tbaa !9
  br label %8

8:                                                ; preds = %66, %2
  %9 = load i32, ptr %6, align 4, !tbaa !9
  %10 = load i16, ptr @current_surfaces, align 2, !tbaa !16
  %11 = sext i16 %10 to i32
  %12 = icmp sle i32 %9, %11
  br i1 %12, label %13, label %69

13:                                               ; preds = %8
  %14 = load i32, ptr %6, align 4, !tbaa !9
  %15 = sext i32 %14 to i64
  %16 = getelementptr inbounds [10 x [5 x double]], ptr @s, i64 0, i64 %15
  %17 = getelementptr inbounds [5 x double], ptr %16, i64 0, i64 1
  %18 = load double, ptr %17, align 8, !tbaa !14
  store double %18, ptr @radius_of_curvature, align 8, !tbaa !14
  %19 = load i32, ptr %6, align 4, !tbaa !9
  %20 = sext i32 %19 to i64
  %21 = getelementptr inbounds [10 x [5 x double]], ptr @s, i64 0, i64 %20
  %22 = getelementptr inbounds [5 x double], ptr %21, i64 0, i64 2
  %23 = load double, ptr %22, align 8, !tbaa !14
  store double %23, ptr @to_index, align 8, !tbaa !14
  %24 = load double, ptr @to_index, align 8, !tbaa !14
  %25 = fcmp ogt double %24, 1.000000e+00
  br i1 %25, label %26, label %51

26:                                               ; preds = %13
  %27 = load double, ptr @to_index, align 8, !tbaa !14
  %28 = load double, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 32), align 16, !tbaa !14
  %29 = load i32, ptr %4, align 4, !tbaa !9
  %30 = sext i32 %29 to i64
  %31 = getelementptr inbounds [9 x double], ptr @spectral_line, i64 0, i64 %30
  %32 = load double, ptr %31, align 8, !tbaa !14
  %33 = fsub double %28, %32
  %34 = load double, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 24), align 8, !tbaa !14
  %35 = load double, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 48), align 16, !tbaa !14
  %36 = fsub double %34, %35
  %37 = fdiv double %33, %36
  %38 = load i32, ptr %6, align 4, !tbaa !9
  %39 = sext i32 %38 to i64
  %40 = getelementptr inbounds [10 x [5 x double]], ptr @s, i64 0, i64 %39
  %41 = getelementptr inbounds [5 x double], ptr %40, i64 0, i64 2
  %42 = load double, ptr %41, align 8, !tbaa !14
  %43 = fsub double %42, 1.000000e+00
  %44 = load i32, ptr %6, align 4, !tbaa !9
  %45 = sext i32 %44 to i64
  %46 = getelementptr inbounds [10 x [5 x double]], ptr @s, i64 0, i64 %45
  %47 = getelementptr inbounds [5 x double], ptr %46, i64 0, i64 3
  %48 = load double, ptr %47, align 8, !tbaa !14
  %49 = fdiv double %43, %48
  %50 = call double @llvm.fmuladd.f64(double %37, double %49, double %27)
  store double %50, ptr @to_index, align 8, !tbaa !14
  br label %51

51:                                               ; preds = %26, %13
  call void @transit_surface()
  %52 = load double, ptr @to_index, align 8, !tbaa !14
  store double %52, ptr @from_index, align 8, !tbaa !14
  %53 = load i32, ptr %6, align 4, !tbaa !9
  %54 = load i16, ptr @current_surfaces, align 2, !tbaa !16
  %55 = sext i16 %54 to i32
  %56 = icmp slt i32 %53, %55
  br i1 %56, label %57, label %65

57:                                               ; preds = %51
  %58 = load double, ptr @object_distance, align 8, !tbaa !14
  %59 = load i32, ptr %6, align 4, !tbaa !9
  %60 = sext i32 %59 to i64
  %61 = getelementptr inbounds [10 x [5 x double]], ptr @s, i64 0, i64 %60
  %62 = getelementptr inbounds [5 x double], ptr %61, i64 0, i64 4
  %63 = load double, ptr %62, align 8, !tbaa !14
  %64 = fsub double %58, %63
  store double %64, ptr @object_distance, align 8, !tbaa !14
  br label %65

65:                                               ; preds = %57, %51
  br label %66

66:                                               ; preds = %65
  %67 = load i32, ptr %6, align 4, !tbaa !9
  %68 = add nsw i32 %67, 1
  store i32 %68, ptr %6, align 4, !tbaa !9
  br label %8, !llvm.loop !28

69:                                               ; preds = %8
  call void @llvm.lifetime.end.p0(ptr %6) #6
  %70 = load i32, ptr %3, align 4
  ret i32 %70
}

; Function Attrs: nounwind
declare double @sin(double noundef) #3

; Function Attrs: nounwind
declare i32 @sprintf(ptr noundef, ptr noundef, ...) #3

; Function Attrs: nounwind willreturn memory(read)
declare i32 @strcmp(ptr noundef, ptr noundef) #4

; Function Attrs: nounwind willreturn memory(read)
declare i64 @strlen(ptr noundef) #4

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #5

; Function Attrs: nounwind uwtable
define internal void @transit_surface() #0 {
  %1 = alloca double, align 8
  %2 = alloca double, align 8
  %3 = alloca double, align 8
  %4 = alloca double, align 8
  %5 = alloca double, align 8
  %6 = alloca double, align 8
  %7 = alloca i32, align 4
  call void @llvm.lifetime.start.p0(ptr %1) #6
  call void @llvm.lifetime.start.p0(ptr %2) #6
  call void @llvm.lifetime.start.p0(ptr %3) #6
  call void @llvm.lifetime.start.p0(ptr %4) #6
  call void @llvm.lifetime.start.p0(ptr %5) #6
  call void @llvm.lifetime.start.p0(ptr %6) #6
  %8 = load i16, ptr @paraxial, align 2, !tbaa !16
  %9 = icmp ne i16 %8, 0
  br i1 %9, label %10, label %61

10:                                               ; preds = %0
  %11 = load double, ptr @radius_of_curvature, align 8, !tbaa !14
  %12 = fcmp une double %11, 0.000000e+00
  br i1 %12, label %13, label %50

13:                                               ; preds = %10
  %14 = load double, ptr @object_distance, align 8, !tbaa !14
  %15 = fcmp oeq double %14, 0.000000e+00
  br i1 %15, label %16, label %20

16:                                               ; preds = %13
  store double 0.000000e+00, ptr @axis_slope_angle, align 8, !tbaa !14
  %17 = load double, ptr @ray_height, align 8, !tbaa !14
  %18 = load double, ptr @radius_of_curvature, align 8, !tbaa !14
  %19 = fdiv double %17, %18
  store double %19, ptr %3, align 8, !tbaa !14
  br label %28

20:                                               ; preds = %13
  %21 = load double, ptr @object_distance, align 8, !tbaa !14
  %22 = load double, ptr @radius_of_curvature, align 8, !tbaa !14
  %23 = fsub double %21, %22
  %24 = load double, ptr @radius_of_curvature, align 8, !tbaa !14
  %25 = fdiv double %23, %24
  %26 = load double, ptr @axis_slope_angle, align 8, !tbaa !14
  %27 = fmul double %25, %26
  store double %27, ptr %3, align 8, !tbaa !14
  br label %28

28:                                               ; preds = %20, %16
  %29 = load double, ptr @from_index, align 8, !tbaa !14
  %30 = load double, ptr @to_index, align 8, !tbaa !14
  %31 = fdiv double %29, %30
  %32 = load double, ptr %3, align 8, !tbaa !14
  %33 = fmul double %31, %32
  store double %33, ptr %4, align 8, !tbaa !14
  %34 = load double, ptr @axis_slope_angle, align 8, !tbaa !14
  store double %34, ptr %5, align 8, !tbaa !14
  %35 = load double, ptr @axis_slope_angle, align 8, !tbaa !14
  %36 = load double, ptr %3, align 8, !tbaa !14
  %37 = fadd double %35, %36
  %38 = load double, ptr %4, align 8, !tbaa !14
  %39 = fsub double %37, %38
  store double %39, ptr @axis_slope_angle, align 8, !tbaa !14
  %40 = load double, ptr @object_distance, align 8, !tbaa !14
  %41 = fcmp une double %40, 0.000000e+00
  br i1 %41, label %42, label %46

42:                                               ; preds = %28
  %43 = load double, ptr @object_distance, align 8, !tbaa !14
  %44 = load double, ptr %5, align 8, !tbaa !14
  %45 = fmul double %43, %44
  store double %45, ptr @ray_height, align 8, !tbaa !14
  br label %46

46:                                               ; preds = %42, %28
  %47 = load double, ptr @ray_height, align 8, !tbaa !14
  %48 = load double, ptr @axis_slope_angle, align 8, !tbaa !14
  %49 = fdiv double %47, %48
  store double %49, ptr @object_distance, align 8, !tbaa !14
  store i32 1, ptr %7, align 4
  br label %140

50:                                               ; preds = %10
  %51 = load double, ptr @object_distance, align 8, !tbaa !14
  %52 = load double, ptr @to_index, align 8, !tbaa !14
  %53 = load double, ptr @from_index, align 8, !tbaa !14
  %54 = fdiv double %52, %53
  %55 = fmul double %51, %54
  store double %55, ptr @object_distance, align 8, !tbaa !14
  %56 = load double, ptr @axis_slope_angle, align 8, !tbaa !14
  %57 = load double, ptr @from_index, align 8, !tbaa !14
  %58 = load double, ptr @to_index, align 8, !tbaa !14
  %59 = fdiv double %57, %58
  %60 = fmul double %56, %59
  store double %60, ptr @axis_slope_angle, align 8, !tbaa !14
  store i32 1, ptr %7, align 4
  br label %140

61:                                               ; preds = %0
  %62 = load double, ptr @radius_of_curvature, align 8, !tbaa !14
  %63 = fcmp une double %62, 0.000000e+00
  br i1 %63, label %64, label %117

64:                                               ; preds = %61
  %65 = load double, ptr @object_distance, align 8, !tbaa !14
  %66 = fcmp oeq double %65, 0.000000e+00
  br i1 %66, label %67, label %71

67:                                               ; preds = %64
  store double 0.000000e+00, ptr @axis_slope_angle, align 8, !tbaa !14
  %68 = load double, ptr @ray_height, align 8, !tbaa !14
  %69 = load double, ptr @radius_of_curvature, align 8, !tbaa !14
  %70 = fdiv double %68, %69
  store double %70, ptr %3, align 8, !tbaa !14
  br label %80

71:                                               ; preds = %64
  %72 = load double, ptr @object_distance, align 8, !tbaa !14
  %73 = load double, ptr @radius_of_curvature, align 8, !tbaa !14
  %74 = fsub double %72, %73
  %75 = load double, ptr @radius_of_curvature, align 8, !tbaa !14
  %76 = fdiv double %74, %75
  %77 = load double, ptr @axis_slope_angle, align 8, !tbaa !14
  %78 = call double @sin(double noundef %77) #6
  %79 = fmul double %76, %78
  store double %79, ptr %3, align 8, !tbaa !14
  br label %80

80:                                               ; preds = %71, %67
  %81 = load double, ptr %3, align 8, !tbaa !14
  %82 = call double @asin(double noundef %81) #6
  store double %82, ptr %1, align 8, !tbaa !14
  %83 = load double, ptr @from_index, align 8, !tbaa !14
  %84 = load double, ptr @to_index, align 8, !tbaa !14
  %85 = fdiv double %83, %84
  %86 = load double, ptr %3, align 8, !tbaa !14
  %87 = fmul double %85, %86
  store double %87, ptr %4, align 8, !tbaa !14
  %88 = load double, ptr @axis_slope_angle, align 8, !tbaa !14
  store double %88, ptr %5, align 8, !tbaa !14
  %89 = load double, ptr @axis_slope_angle, align 8, !tbaa !14
  %90 = load double, ptr %1, align 8, !tbaa !14
  %91 = fadd double %89, %90
  %92 = load double, ptr %4, align 8, !tbaa !14
  %93 = call double @asin(double noundef %92) #6
  %94 = fsub double %91, %93
  store double %94, ptr @axis_slope_angle, align 8, !tbaa !14
  %95 = load double, ptr %5, align 8, !tbaa !14
  %96 = load double, ptr %1, align 8, !tbaa !14
  %97 = fadd double %95, %96
  %98 = fdiv double %97, 2.000000e+00
  %99 = call double @sin(double noundef %98) #6
  store double %99, ptr %6, align 8, !tbaa !14
  %100 = load double, ptr @radius_of_curvature, align 8, !tbaa !14
  %101 = fmul double 2.000000e+00, %100
  %102 = load double, ptr %6, align 8, !tbaa !14
  %103 = fmul double %101, %102
  %104 = load double, ptr %6, align 8, !tbaa !14
  %105 = fmul double %103, %104
  store double %105, ptr %6, align 8, !tbaa !14
  %106 = load double, ptr @radius_of_curvature, align 8, !tbaa !14
  %107 = load double, ptr %5, align 8, !tbaa !14
  %108 = load double, ptr %1, align 8, !tbaa !14
  %109 = fadd double %107, %108
  %110 = call double @sin(double noundef %109) #6
  %111 = fmul double %106, %110
  %112 = load double, ptr @axis_slope_angle, align 8, !tbaa !14
  %113 = call double @tan(double noundef %112) #6
  %114 = fdiv double 1.000000e+00, %113
  %115 = load double, ptr %6, align 8, !tbaa !14
  %116 = call double @llvm.fmuladd.f64(double %111, double %114, double %115)
  store double %116, ptr @object_distance, align 8, !tbaa !14
  store i32 1, ptr %7, align 4
  br label %140

117:                                              ; preds = %61
  %118 = load double, ptr @from_index, align 8, !tbaa !14
  %119 = load double, ptr @to_index, align 8, !tbaa !14
  %120 = fdiv double %118, %119
  %121 = load double, ptr @axis_slope_angle, align 8, !tbaa !14
  %122 = call double @sin(double noundef %121) #6
  %123 = fmul double %120, %122
  %124 = call double @asin(double noundef %123) #6
  %125 = fneg double %124
  store double %125, ptr %2, align 8, !tbaa !14
  %126 = load double, ptr @object_distance, align 8, !tbaa !14
  %127 = load double, ptr @to_index, align 8, !tbaa !14
  %128 = load double, ptr %2, align 8, !tbaa !14
  %129 = fneg double %128
  %130 = call double @cos(double noundef %129) #6
  %131 = fmul double %127, %130
  %132 = load double, ptr @from_index, align 8, !tbaa !14
  %133 = load double, ptr @axis_slope_angle, align 8, !tbaa !14
  %134 = call double @cos(double noundef %133) #6
  %135 = fmul double %132, %134
  %136 = fdiv double %131, %135
  %137 = fmul double %126, %136
  store double %137, ptr @object_distance, align 8, !tbaa !14
  %138 = load double, ptr %2, align 8, !tbaa !14
  %139 = fneg double %138
  store double %139, ptr @axis_slope_angle, align 8, !tbaa !14
  store i32 0, ptr %7, align 4
  br label %140

140:                                              ; preds = %117, %80, %50, %46
  call void @llvm.lifetime.end.p0(ptr %6) #6
  call void @llvm.lifetime.end.p0(ptr %5) #6
  call void @llvm.lifetime.end.p0(ptr %4) #6
  call void @llvm.lifetime.end.p0(ptr %3) #6
  call void @llvm.lifetime.end.p0(ptr %2) #6
  call void @llvm.lifetime.end.p0(ptr %1) #6
  %141 = load i32, ptr %7, align 4
  switch i32 %141, label %143 [
    i32 0, label %142
    i32 1, label %142
  ]

142:                                              ; preds = %140, %140
  ret void

143:                                              ; preds = %140
  unreachable
}

; Function Attrs: nounwind
declare double @asin(double noundef) #3

; Function Attrs: nounwind
declare double @tan(double noundef) #3

; Function Attrs: nounwind
declare double @cos(double noundef) #3

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind willreturn memory(read) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #6 = { nounwind }
attributes #7 = { nounwind willreturn memory(read) }

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
!11 = !{!"p2 omnipotent char", !12, i64 0}
!12 = !{!"any p2 pointer", !13, i64 0}
!13 = !{!"any pointer", !7, i64 0}
!14 = !{!15, !15, i64 0}
!15 = !{!"double", !7, i64 0}
!16 = !{!17, !17, i64 0}
!17 = !{!"short", !7, i64 0}
!18 = distinct !{!18, !19}
!19 = !{!"llvm.loop.mustprogress"}
!20 = distinct !{!20, !19}
!21 = distinct !{!21, !19}
!22 = distinct !{!22, !19}
!23 = !{!24, !24, i64 0}
!24 = !{!"p1 omnipotent char", !13, i64 0}
!25 = !{!7, !7, i64 0}
!26 = distinct !{!26, !19}
!27 = distinct !{!27, !19}
!28 = distinct !{!28, !19}
