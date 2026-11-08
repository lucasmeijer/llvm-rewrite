; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/fbench.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
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

; Function Attrs: noinline nounwind uwtable
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
  store i32 %0, ptr %4, align 4
  store ptr %1, ptr %5, align 8
  store double 7.621000e+03, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 8), align 8
  store double f0x40BAD5F47AE147AE, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 16), align 16
  store double f0x40B9A2D0E5604189, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 24), align 8
  store double f0x40B707F1A9FBE76D, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 32), align 16
  store double f0x40B4958E978D4FDF, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 40), align 8
  store double f0x40B2FD5810624DD3, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 48), align 16
  store double f0x40B0F47A1CAC0831, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 56), align 8
  store double f0x40AF00FCED916873, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 64), align 16
  store i32 1000000, ptr @niter, align 4
  store double 4.000000e+00, ptr @clear_aperture, align 8
  store i16 4, ptr @current_surfaces, align 2
  store i32 0, ptr %6, align 4
  br label %12

12:                                               ; preds = %41, %2
  %13 = load i32, ptr %6, align 4
  %14 = load i16, ptr @current_surfaces, align 2
  %15 = sext i16 %14 to i32
  %16 = icmp slt i32 %13, %15
  br i1 %16, label %17, label %44

17:                                               ; preds = %12
  store i32 0, ptr %7, align 4
  br label %18

18:                                               ; preds = %37, %17
  %19 = load i32, ptr %7, align 4
  %20 = icmp slt i32 %19, 4
  br i1 %20, label %21, label %40

21:                                               ; preds = %18
  %22 = load i32, ptr %6, align 4
  %23 = sext i32 %22 to i64
  %24 = getelementptr inbounds [4 x [4 x double]], ptr @testcase, i64 0, i64 %23
  %25 = load i32, ptr %7, align 4
  %26 = sext i32 %25 to i64
  %27 = getelementptr inbounds [4 x double], ptr %24, i64 0, i64 %26
  %28 = load double, ptr %27, align 8
  %29 = load i32, ptr %6, align 4
  %30 = add nsw i32 %29, 1
  %31 = sext i32 %30 to i64
  %32 = getelementptr inbounds [10 x [5 x double]], ptr @s, i64 0, i64 %31
  %33 = load i32, ptr %7, align 4
  %34 = add nsw i32 %33, 1
  %35 = sext i32 %34 to i64
  %36 = getelementptr inbounds [5 x double], ptr %32, i64 0, i64 %35
  store double %28, ptr %36, align 8
  br label %37

37:                                               ; preds = %21
  %38 = load i32, ptr %7, align 4
  %39 = add nsw i32 %38, 1
  store i32 %39, ptr %7, align 4
  br label %18, !llvm.loop !5

40:                                               ; preds = %18
  br label %41

41:                                               ; preds = %40
  %42 = load i32, ptr %6, align 4
  %43 = add nsw i32 %42, 1
  store i32 %43, ptr %6, align 4
  br label %12, !llvm.loop !7

44:                                               ; preds = %12
  %45 = call i32 (ptr, ...) @printf(ptr noundef @.str)
  %46 = load i32, ptr @niter, align 4
  %47 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %46)
  %48 = load i32, ptr @niter, align 4
  %49 = sitofp i32 %48 to double
  %50 = fdiv double %49, 1.000000e+03
  %51 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, double noundef %50)
  %52 = call i32 (ptr, ...) @printf(ptr noundef @.str.3)
  %53 = call i32 (ptr, ...) @printf(ptr noundef @.str.4)
  store i32 0, ptr @itercount, align 4
  br label %54

54:                                               ; preds = %111, %44
  %55 = load i32, ptr @itercount, align 4
  %56 = load i32, ptr @niter, align 4
  %57 = icmp slt i32 %55, %56
  br i1 %57, label %58, label %114

58:                                               ; preds = %54
  store i16 0, ptr @paraxial, align 2
  br label %59

59:                                               ; preds = %77, %58
  %60 = load i16, ptr @paraxial, align 2
  %61 = sext i16 %60 to i32
  %62 = icmp sle i32 %61, 1
  br i1 %62, label %63, label %80

63:                                               ; preds = %59
  %64 = load double, ptr @clear_aperture, align 8
  %65 = fdiv double %64, 2.000000e+00
  %66 = call i32 @trace_line(i32 noundef 4, double noundef %65)
  %67 = load double, ptr @object_distance, align 8
  %68 = load i16, ptr @paraxial, align 2
  %69 = sext i16 %68 to i64
  %70 = getelementptr inbounds [2 x [2 x double]], ptr @od_sa, i64 0, i64 %69
  %71 = getelementptr inbounds [2 x double], ptr %70, i64 0, i64 0
  store double %67, ptr %71, align 16
  %72 = load double, ptr @axis_slope_angle, align 8
  %73 = load i16, ptr @paraxial, align 2
  %74 = sext i16 %73 to i64
  %75 = getelementptr inbounds [2 x [2 x double]], ptr @od_sa, i64 0, i64 %74
  %76 = getelementptr inbounds [2 x double], ptr %75, i64 0, i64 1
  store double %72, ptr %76, align 8
  br label %77

77:                                               ; preds = %63
  %78 = load i16, ptr @paraxial, align 2
  %79 = add i16 %78, 1
  store i16 %79, ptr @paraxial, align 2
  br label %59, !llvm.loop !8

80:                                               ; preds = %59
  store i16 0, ptr @paraxial, align 2
  %81 = load double, ptr @clear_aperture, align 8
  %82 = fdiv double %81, 2.000000e+00
  %83 = call i32 @trace_line(i32 noundef 3, double noundef %82)
  %84 = load double, ptr @object_distance, align 8
  store double %84, ptr %11, align 8
  %85 = load double, ptr @clear_aperture, align 8
  %86 = fdiv double %85, 2.000000e+00
  %87 = call i32 @trace_line(i32 noundef 6, double noundef %86)
  %88 = load double, ptr @object_distance, align 8
  store double %88, ptr %10, align 8
  %89 = load double, ptr getelementptr inbounds nuw (i8, ptr @od_sa, i64 16), align 16
  %90 = load double, ptr @od_sa, align 16
  %91 = fsub double %89, %90
  store double %91, ptr @aberr_lspher, align 8
  %92 = load double, ptr getelementptr inbounds nuw (i8, ptr @od_sa, i64 16), align 16
  %93 = load double, ptr getelementptr inbounds nuw (i8, ptr @od_sa, i64 24), align 8
  %94 = fmul double %92, %93
  %95 = load double, ptr getelementptr inbounds nuw (i8, ptr @od_sa, i64 8), align 8
  %96 = call double @sin(double noundef %95) #5
  %97 = load double, ptr @od_sa, align 16
  %98 = fmul double %96, %97
  %99 = fdiv double %94, %98
  %100 = fsub double 1.000000e+00, %99
  store double %100, ptr @aberr_osc, align 8
  %101 = load double, ptr %10, align 8
  %102 = load double, ptr %11, align 8
  %103 = fsub double %101, %102
  store double %103, ptr @aberr_lchrom, align 8
  %104 = load double, ptr getelementptr inbounds nuw (i8, ptr @od_sa, i64 8), align 8
  %105 = call double @sin(double noundef %104) #5
  store double %105, ptr @max_lspher, align 8
  %106 = load double, ptr @max_lspher, align 8
  %107 = load double, ptr @max_lspher, align 8
  %108 = fmul double %106, %107
  %109 = fdiv double 9.260000e-05, %108
  store double %109, ptr @max_lspher, align 8
  store double 2.500000e-03, ptr @max_osc, align 8
  %110 = load double, ptr @max_lspher, align 8
  store double %110, ptr @max_lchrom, align 8
  br label %111

111:                                              ; preds = %80
  %112 = load i32, ptr @itercount, align 4
  %113 = add nsw i32 %112, 1
  store i32 %113, ptr @itercount, align 4
  br label %54, !llvm.loop !9

114:                                              ; preds = %54
  %115 = load double, ptr @od_sa, align 16
  %116 = load double, ptr getelementptr inbounds nuw (i8, ptr @od_sa, i64 8), align 8
  %117 = call i32 (ptr, ptr, ...) @sprintf(ptr noundef @outarr, ptr noundef @.str.5, ptr noundef @.str.6, double noundef %115, double noundef %116) #5
  %118 = load double, ptr getelementptr inbounds nuw (i8, ptr @od_sa, i64 16), align 16
  %119 = load double, ptr getelementptr inbounds nuw (i8, ptr @od_sa, i64 24), align 8
  %120 = call i32 (ptr, ptr, ...) @sprintf(ptr noundef getelementptr inbounds nuw (i8, ptr @outarr, i64 80), ptr noundef @.str.5, ptr noundef @.str.7, double noundef %118, double noundef %119) #5
  %121 = load double, ptr @aberr_lspher, align 8
  %122 = call i32 (ptr, ptr, ...) @sprintf(ptr noundef getelementptr inbounds nuw (i8, ptr @outarr, i64 160), ptr noundef @.str.8, double noundef %121) #5
  %123 = load double, ptr @max_lspher, align 8
  %124 = call i32 (ptr, ptr, ...) @sprintf(ptr noundef getelementptr inbounds nuw (i8, ptr @outarr, i64 240), ptr noundef @.str.9, double noundef %123) #5
  %125 = load double, ptr @aberr_osc, align 8
  %126 = call i32 (ptr, ptr, ...) @sprintf(ptr noundef getelementptr inbounds nuw (i8, ptr @outarr, i64 320), ptr noundef @.str.10, double noundef %125) #5
  %127 = load double, ptr @max_osc, align 8
  %128 = call i32 (ptr, ptr, ...) @sprintf(ptr noundef getelementptr inbounds nuw (i8, ptr @outarr, i64 400), ptr noundef @.str.9, double noundef %127) #5
  %129 = load double, ptr @aberr_lchrom, align 8
  %130 = call i32 (ptr, ptr, ...) @sprintf(ptr noundef getelementptr inbounds nuw (i8, ptr @outarr, i64 480), ptr noundef @.str.11, double noundef %129) #5
  %131 = load double, ptr @max_lchrom, align 8
  %132 = call i32 (ptr, ptr, ...) @sprintf(ptr noundef getelementptr inbounds nuw (i8, ptr @outarr, i64 560), ptr noundef @.str.9, double noundef %131) #5
  store i32 0, ptr %9, align 4
  store i32 0, ptr %6, align 4
  br label %133

133:                                              ; preds = %222, %114
  %134 = load i32, ptr %6, align 4
  %135 = icmp slt i32 %134, 8
  br i1 %135, label %136, label %225

136:                                              ; preds = %133
  %137 = load i32, ptr %6, align 4
  %138 = sext i32 %137 to i64
  %139 = getelementptr inbounds [8 x [80 x i8]], ptr @outarr, i64 0, i64 %138
  %140 = getelementptr inbounds [80 x i8], ptr %139, i64 0, i64 0
  %141 = load i32, ptr %6, align 4
  %142 = sext i32 %141 to i64
  %143 = getelementptr inbounds [8 x ptr], ptr @refarr, i64 0, i64 %142
  %144 = load ptr, ptr %143, align 8
  %145 = call i32 @strcmp(ptr noundef %140, ptr noundef %144) #6
  %146 = icmp ne i32 %145, 0
  br i1 %146, label %147, label %221

147:                                              ; preds = %136
  %148 = load i32, ptr %6, align 4
  %149 = add nsw i32 %148, 1
  %150 = call i32 (ptr, ...) @printf(ptr noundef @.str.12, i32 noundef %149)
  %151 = load i32, ptr %6, align 4
  %152 = sext i32 %151 to i64
  %153 = getelementptr inbounds [8 x ptr], ptr @refarr, i64 0, i64 %152
  %154 = load ptr, ptr %153, align 8
  %155 = call i32 (ptr, ...) @printf(ptr noundef @.str.13, ptr noundef %154)
  %156 = load i32, ptr %6, align 4
  %157 = sext i32 %156 to i64
  %158 = getelementptr inbounds [8 x [80 x i8]], ptr @outarr, i64 0, i64 %157
  %159 = getelementptr inbounds [80 x i8], ptr %158, i64 0, i64 0
  %160 = call i32 (ptr, ...) @printf(ptr noundef @.str.14, ptr noundef %159)
  %161 = call i32 (ptr, ...) @printf(ptr noundef @.str.15)
  %162 = load i32, ptr %6, align 4
  %163 = sext i32 %162 to i64
  %164 = getelementptr inbounds [8 x ptr], ptr @refarr, i64 0, i64 %163
  %165 = load ptr, ptr %164, align 8
  %166 = call i64 @strlen(ptr noundef %165) #6
  %167 = trunc i64 %166 to i32
  store i32 %167, ptr %8, align 4
  store i32 0, ptr %7, align 4
  br label %168

168:                                              ; preds = %216, %147
  %169 = load i32, ptr %7, align 4
  %170 = load i32, ptr %8, align 4
  %171 = icmp slt i32 %169, %170
  br i1 %171, label %172, label %219

172:                                              ; preds = %168
  %173 = load i32, ptr %6, align 4
  %174 = sext i32 %173 to i64
  %175 = getelementptr inbounds [8 x ptr], ptr @refarr, i64 0, i64 %174
  %176 = load ptr, ptr %175, align 8
  %177 = load i32, ptr %7, align 4
  %178 = sext i32 %177 to i64
  %179 = getelementptr inbounds i8, ptr %176, i64 %178
  %180 = load i8, ptr %179, align 1
  %181 = sext i8 %180 to i32
  %182 = load i32, ptr %6, align 4
  %183 = sext i32 %182 to i64
  %184 = getelementptr inbounds [8 x [80 x i8]], ptr @outarr, i64 0, i64 %183
  %185 = load i32, ptr %7, align 4
  %186 = sext i32 %185 to i64
  %187 = getelementptr inbounds [80 x i8], ptr %184, i64 0, i64 %186
  %188 = load i8, ptr %187, align 1
  %189 = sext i8 %188 to i32
  %190 = icmp eq i32 %181, %189
  %191 = zext i1 %190 to i64
  %192 = select i1 %190, i32 32, i32 94
  %193 = call i32 (ptr, ...) @printf(ptr noundef @.str.16, i32 noundef %192)
  %194 = load i32, ptr %6, align 4
  %195 = sext i32 %194 to i64
  %196 = getelementptr inbounds [8 x ptr], ptr @refarr, i64 0, i64 %195
  %197 = load ptr, ptr %196, align 8
  %198 = load i32, ptr %7, align 4
  %199 = sext i32 %198 to i64
  %200 = getelementptr inbounds i8, ptr %197, i64 %199
  %201 = load i8, ptr %200, align 1
  %202 = sext i8 %201 to i32
  %203 = load i32, ptr %6, align 4
  %204 = sext i32 %203 to i64
  %205 = getelementptr inbounds [8 x [80 x i8]], ptr @outarr, i64 0, i64 %204
  %206 = load i32, ptr %7, align 4
  %207 = sext i32 %206 to i64
  %208 = getelementptr inbounds [80 x i8], ptr %205, i64 0, i64 %207
  %209 = load i8, ptr %208, align 1
  %210 = sext i8 %209 to i32
  %211 = icmp ne i32 %202, %210
  br i1 %211, label %212, label %215

212:                                              ; preds = %172
  %213 = load i32, ptr %9, align 4
  %214 = add nsw i32 %213, 1
  store i32 %214, ptr %9, align 4
  br label %215

215:                                              ; preds = %212, %172
  br label %216

216:                                              ; preds = %215
  %217 = load i32, ptr %7, align 4
  %218 = add nsw i32 %217, 1
  store i32 %218, ptr %7, align 4
  br label %168, !llvm.loop !10

219:                                              ; preds = %168
  %220 = call i32 (ptr, ...) @printf(ptr noundef @.str.17)
  br label %221

221:                                              ; preds = %219, %136
  br label %222

222:                                              ; preds = %221
  %223 = load i32, ptr %6, align 4
  %224 = add nsw i32 %223, 1
  store i32 %224, ptr %6, align 4
  br label %133, !llvm.loop !11

225:                                              ; preds = %133
  %226 = load i32, ptr %9, align 4
  %227 = icmp sgt i32 %226, 0
  br i1 %227, label %228, label %235

228:                                              ; preds = %225
  %229 = load i32, ptr %9, align 4
  %230 = load i32, ptr %9, align 4
  %231 = icmp sgt i32 %230, 1
  %232 = zext i1 %231 to i64
  %233 = select i1 %231, ptr @.str.19, ptr @.str.20
  %234 = call i32 (ptr, ...) @printf(ptr noundef @.str.18, i32 noundef %229, ptr noundef %233)
  br label %237

235:                                              ; preds = %225
  %236 = call i32 (ptr, ...) @printf(ptr noundef @.str.21)
  br label %237

237:                                              ; preds = %235, %228
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: noinline nounwind uwtable
define internal i32 @trace_line(i32 noundef %0, double noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca double, align 8
  %6 = alloca i32, align 4
  store i32 %0, ptr %4, align 4
  store double %1, ptr %5, align 8
  store double 0.000000e+00, ptr @object_distance, align 8
  %7 = load double, ptr %5, align 8
  store double %7, ptr @ray_height, align 8
  store double 1.000000e+00, ptr @from_index, align 8
  store i32 1, ptr %6, align 4
  br label %8

8:                                                ; preds = %66, %2
  %9 = load i32, ptr %6, align 4
  %10 = load i16, ptr @current_surfaces, align 2
  %11 = sext i16 %10 to i32
  %12 = icmp sle i32 %9, %11
  br i1 %12, label %13, label %69

13:                                               ; preds = %8
  %14 = load i32, ptr %6, align 4
  %15 = sext i32 %14 to i64
  %16 = getelementptr inbounds [10 x [5 x double]], ptr @s, i64 0, i64 %15
  %17 = getelementptr inbounds [5 x double], ptr %16, i64 0, i64 1
  %18 = load double, ptr %17, align 8
  store double %18, ptr @radius_of_curvature, align 8
  %19 = load i32, ptr %6, align 4
  %20 = sext i32 %19 to i64
  %21 = getelementptr inbounds [10 x [5 x double]], ptr @s, i64 0, i64 %20
  %22 = getelementptr inbounds [5 x double], ptr %21, i64 0, i64 2
  %23 = load double, ptr %22, align 8
  store double %23, ptr @to_index, align 8
  %24 = load double, ptr @to_index, align 8
  %25 = fcmp ogt double %24, 1.000000e+00
  br i1 %25, label %26, label %51

26:                                               ; preds = %13
  %27 = load double, ptr @to_index, align 8
  %28 = load double, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 32), align 16
  %29 = load i32, ptr %4, align 4
  %30 = sext i32 %29 to i64
  %31 = getelementptr inbounds [9 x double], ptr @spectral_line, i64 0, i64 %30
  %32 = load double, ptr %31, align 8
  %33 = fsub double %28, %32
  %34 = load double, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 24), align 8
  %35 = load double, ptr getelementptr inbounds nuw (i8, ptr @spectral_line, i64 48), align 16
  %36 = fsub double %34, %35
  %37 = fdiv double %33, %36
  %38 = load i32, ptr %6, align 4
  %39 = sext i32 %38 to i64
  %40 = getelementptr inbounds [10 x [5 x double]], ptr @s, i64 0, i64 %39
  %41 = getelementptr inbounds [5 x double], ptr %40, i64 0, i64 2
  %42 = load double, ptr %41, align 8
  %43 = fsub double %42, 1.000000e+00
  %44 = load i32, ptr %6, align 4
  %45 = sext i32 %44 to i64
  %46 = getelementptr inbounds [10 x [5 x double]], ptr @s, i64 0, i64 %45
  %47 = getelementptr inbounds [5 x double], ptr %46, i64 0, i64 3
  %48 = load double, ptr %47, align 8
  %49 = fdiv double %43, %48
  %50 = call double @llvm.fmuladd.f64(double %37, double %49, double %27)
  store double %50, ptr @to_index, align 8
  br label %51

51:                                               ; preds = %26, %13
  call void @transit_surface()
  %52 = load double, ptr @to_index, align 8
  store double %52, ptr @from_index, align 8
  %53 = load i32, ptr %6, align 4
  %54 = load i16, ptr @current_surfaces, align 2
  %55 = sext i16 %54 to i32
  %56 = icmp slt i32 %53, %55
  br i1 %56, label %57, label %65

57:                                               ; preds = %51
  %58 = load double, ptr @object_distance, align 8
  %59 = load i32, ptr %6, align 4
  %60 = sext i32 %59 to i64
  %61 = getelementptr inbounds [10 x [5 x double]], ptr @s, i64 0, i64 %60
  %62 = getelementptr inbounds [5 x double], ptr %61, i64 0, i64 4
  %63 = load double, ptr %62, align 8
  %64 = fsub double %58, %63
  store double %64, ptr @object_distance, align 8
  br label %65

65:                                               ; preds = %57, %51
  br label %66

66:                                               ; preds = %65
  %67 = load i32, ptr %6, align 4
  %68 = add nsw i32 %67, 1
  store i32 %68, ptr %6, align 4
  br label %8, !llvm.loop !12

69:                                               ; preds = %8
  %70 = load i32, ptr %3, align 4
  ret i32 %70
}

; Function Attrs: nounwind
declare double @sin(double noundef) #2

; Function Attrs: nounwind
declare i32 @sprintf(ptr noundef, ptr noundef, ...) #2

; Function Attrs: nounwind willreturn memory(read)
declare i32 @strcmp(ptr noundef, ptr noundef) #3

; Function Attrs: nounwind willreturn memory(read)
declare i64 @strlen(ptr noundef) #3

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #4

; Function Attrs: noinline nounwind uwtable
define internal void @transit_surface() #0 {
  %1 = alloca double, align 8
  %2 = alloca double, align 8
  %3 = alloca double, align 8
  %4 = alloca double, align 8
  %5 = alloca double, align 8
  %6 = alloca double, align 8
  %7 = load i16, ptr @paraxial, align 2
  %8 = icmp ne i16 %7, 0
  br i1 %8, label %9, label %60

9:                                                ; preds = %0
  %10 = load double, ptr @radius_of_curvature, align 8
  %11 = fcmp une double %10, 0.000000e+00
  br i1 %11, label %12, label %49

12:                                               ; preds = %9
  %13 = load double, ptr @object_distance, align 8
  %14 = fcmp oeq double %13, 0.000000e+00
  br i1 %14, label %15, label %19

15:                                               ; preds = %12
  store double 0.000000e+00, ptr @axis_slope_angle, align 8
  %16 = load double, ptr @ray_height, align 8
  %17 = load double, ptr @radius_of_curvature, align 8
  %18 = fdiv double %16, %17
  store double %18, ptr %3, align 8
  br label %27

19:                                               ; preds = %12
  %20 = load double, ptr @object_distance, align 8
  %21 = load double, ptr @radius_of_curvature, align 8
  %22 = fsub double %20, %21
  %23 = load double, ptr @radius_of_curvature, align 8
  %24 = fdiv double %22, %23
  %25 = load double, ptr @axis_slope_angle, align 8
  %26 = fmul double %24, %25
  store double %26, ptr %3, align 8
  br label %27

27:                                               ; preds = %19, %15
  %28 = load double, ptr @from_index, align 8
  %29 = load double, ptr @to_index, align 8
  %30 = fdiv double %28, %29
  %31 = load double, ptr %3, align 8
  %32 = fmul double %30, %31
  store double %32, ptr %4, align 8
  %33 = load double, ptr @axis_slope_angle, align 8
  store double %33, ptr %5, align 8
  %34 = load double, ptr @axis_slope_angle, align 8
  %35 = load double, ptr %3, align 8
  %36 = fadd double %34, %35
  %37 = load double, ptr %4, align 8
  %38 = fsub double %36, %37
  store double %38, ptr @axis_slope_angle, align 8
  %39 = load double, ptr @object_distance, align 8
  %40 = fcmp une double %39, 0.000000e+00
  br i1 %40, label %41, label %45

41:                                               ; preds = %27
  %42 = load double, ptr @object_distance, align 8
  %43 = load double, ptr %5, align 8
  %44 = fmul double %42, %43
  store double %44, ptr @ray_height, align 8
  br label %45

45:                                               ; preds = %41, %27
  %46 = load double, ptr @ray_height, align 8
  %47 = load double, ptr @axis_slope_angle, align 8
  %48 = fdiv double %46, %47
  store double %48, ptr @object_distance, align 8
  br label %139

49:                                               ; preds = %9
  %50 = load double, ptr @object_distance, align 8
  %51 = load double, ptr @to_index, align 8
  %52 = load double, ptr @from_index, align 8
  %53 = fdiv double %51, %52
  %54 = fmul double %50, %53
  store double %54, ptr @object_distance, align 8
  %55 = load double, ptr @axis_slope_angle, align 8
  %56 = load double, ptr @from_index, align 8
  %57 = load double, ptr @to_index, align 8
  %58 = fdiv double %56, %57
  %59 = fmul double %55, %58
  store double %59, ptr @axis_slope_angle, align 8
  br label %139

60:                                               ; preds = %0
  %61 = load double, ptr @radius_of_curvature, align 8
  %62 = fcmp une double %61, 0.000000e+00
  br i1 %62, label %63, label %116

63:                                               ; preds = %60
  %64 = load double, ptr @object_distance, align 8
  %65 = fcmp oeq double %64, 0.000000e+00
  br i1 %65, label %66, label %70

66:                                               ; preds = %63
  store double 0.000000e+00, ptr @axis_slope_angle, align 8
  %67 = load double, ptr @ray_height, align 8
  %68 = load double, ptr @radius_of_curvature, align 8
  %69 = fdiv double %67, %68
  store double %69, ptr %3, align 8
  br label %79

70:                                               ; preds = %63
  %71 = load double, ptr @object_distance, align 8
  %72 = load double, ptr @radius_of_curvature, align 8
  %73 = fsub double %71, %72
  %74 = load double, ptr @radius_of_curvature, align 8
  %75 = fdiv double %73, %74
  %76 = load double, ptr @axis_slope_angle, align 8
  %77 = call double @sin(double noundef %76) #5
  %78 = fmul double %75, %77
  store double %78, ptr %3, align 8
  br label %79

79:                                               ; preds = %70, %66
  %80 = load double, ptr %3, align 8
  %81 = call double @asin(double noundef %80) #5
  store double %81, ptr %1, align 8
  %82 = load double, ptr @from_index, align 8
  %83 = load double, ptr @to_index, align 8
  %84 = fdiv double %82, %83
  %85 = load double, ptr %3, align 8
  %86 = fmul double %84, %85
  store double %86, ptr %4, align 8
  %87 = load double, ptr @axis_slope_angle, align 8
  store double %87, ptr %5, align 8
  %88 = load double, ptr @axis_slope_angle, align 8
  %89 = load double, ptr %1, align 8
  %90 = fadd double %88, %89
  %91 = load double, ptr %4, align 8
  %92 = call double @asin(double noundef %91) #5
  %93 = fsub double %90, %92
  store double %93, ptr @axis_slope_angle, align 8
  %94 = load double, ptr %5, align 8
  %95 = load double, ptr %1, align 8
  %96 = fadd double %94, %95
  %97 = fdiv double %96, 2.000000e+00
  %98 = call double @sin(double noundef %97) #5
  store double %98, ptr %6, align 8
  %99 = load double, ptr @radius_of_curvature, align 8
  %100 = fmul double 2.000000e+00, %99
  %101 = load double, ptr %6, align 8
  %102 = fmul double %100, %101
  %103 = load double, ptr %6, align 8
  %104 = fmul double %102, %103
  store double %104, ptr %6, align 8
  %105 = load double, ptr @radius_of_curvature, align 8
  %106 = load double, ptr %5, align 8
  %107 = load double, ptr %1, align 8
  %108 = fadd double %106, %107
  %109 = call double @sin(double noundef %108) #5
  %110 = fmul double %105, %109
  %111 = load double, ptr @axis_slope_angle, align 8
  %112 = call double @tan(double noundef %111) #5
  %113 = fdiv double 1.000000e+00, %112
  %114 = load double, ptr %6, align 8
  %115 = call double @llvm.fmuladd.f64(double %110, double %113, double %114)
  store double %115, ptr @object_distance, align 8
  br label %139

116:                                              ; preds = %60
  %117 = load double, ptr @from_index, align 8
  %118 = load double, ptr @to_index, align 8
  %119 = fdiv double %117, %118
  %120 = load double, ptr @axis_slope_angle, align 8
  %121 = call double @sin(double noundef %120) #5
  %122 = fmul double %119, %121
  %123 = call double @asin(double noundef %122) #5
  %124 = fneg double %123
  store double %124, ptr %2, align 8
  %125 = load double, ptr @object_distance, align 8
  %126 = load double, ptr @to_index, align 8
  %127 = load double, ptr %2, align 8
  %128 = fneg double %127
  %129 = call double @cos(double noundef %128) #5
  %130 = fmul double %126, %129
  %131 = load double, ptr @from_index, align 8
  %132 = load double, ptr @axis_slope_angle, align 8
  %133 = call double @cos(double noundef %132) #5
  %134 = fmul double %131, %133
  %135 = fdiv double %130, %134
  %136 = fmul double %125, %135
  store double %136, ptr @object_distance, align 8
  %137 = load double, ptr %2, align 8
  %138 = fneg double %137
  store double %138, ptr @axis_slope_angle, align 8
  br label %139

139:                                              ; preds = %116, %79, %49, %45
  ret void
}

; Function Attrs: nounwind
declare double @asin(double noundef) #2

; Function Attrs: nounwind
declare double @tan(double noundef) #2

; Function Attrs: nounwind
declare double @cos(double noundef) #2

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nounwind "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind willreturn memory(read) "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #5 = { nounwind }
attributes #6 = { nounwind willreturn memory(read) }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{i32 7, !"frame-pointer", i32 2}
!4 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
!5 = distinct !{!5, !6}
!6 = !{!"llvm.loop.mustprogress"}
!7 = distinct !{!7, !6}
!8 = distinct !{!8, !6}
!9 = distinct !{!9, !6}
!10 = distinct !{!10, !6}
!11 = distinct !{!11, !6}
!12 = distinct !{!12, !6}
