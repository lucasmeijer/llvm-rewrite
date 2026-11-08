; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/oourafft.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/oourafft.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/oourafft.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.timeval = type { i64, i64 }

@.str = private unnamed_addr constant [45 x i8] c"FFT sanity check failed! Difference is: %le\0A\00", align 1
@.str.1 = private unnamed_addr constant [7 x i8] c"%e %e\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca ptr, align 8
  %8 = alloca ptr, align 8
  %9 = alloca double, align 8
  %10 = alloca double, align 8
  %11 = alloca double, align 8
  %12 = alloca double, align 8
  %13 = alloca double, align 8
  %14 = alloca i32, align 4
  %15 = alloca double, align 8
  %16 = alloca double, align 8
  %17 = alloca double, align 8
  %18 = alloca double, align 8
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #9
  call void @llvm.lifetime.start.p0(ptr %3) #9
  call void @llvm.lifetime.start.p0(ptr %4) #9
  call void @llvm.lifetime.start.p0(ptr %5) #9
  call void @llvm.lifetime.start.p0(ptr %6) #9
  call void @llvm.lifetime.start.p0(ptr %7) #9
  call void @llvm.lifetime.start.p0(ptr %8) #9
  call void @llvm.lifetime.start.p0(ptr %9) #9
  call void @llvm.lifetime.start.p0(ptr %10) #9
  call void @llvm.lifetime.start.p0(ptr %11) #9
  call void @llvm.lifetime.start.p0(ptr %12) #9
  store double 0.000000e+00, ptr %12, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %13) #9
  %19 = call double @get_time()
  store double %19, ptr %9, align 8, !tbaa !9
  %20 = call double @get_time()
  store double %20, ptr %10, align 8, !tbaa !9
  %21 = load double, ptr %10, align 8, !tbaa !9
  %22 = load double, ptr %9, align 8, !tbaa !9
  %23 = fsub double %21, %22
  store double %23, ptr %11, align 8, !tbaa !9
  %24 = call double @sqrt(double noundef 1.024000e+03) #9
  %25 = fmul double %24, 4.000000e+00
  %26 = fptoui double %25 to i64
  %27 = call noalias align 16 ptr @memalign(i64 noundef 16, i64 noundef %26) #10
  store ptr %27, ptr %4, align 8, !tbaa !11
  %28 = call noalias align 16 ptr @memalign(i64 noundef 16, i64 noundef 20480) #10
  store ptr %28, ptr %8, align 8, !tbaa !14
  %29 = load ptr, ptr %4, align 8, !tbaa !11
  %30 = load ptr, ptr %8, align 8, !tbaa !14
  call void @makewt(i32 noundef 512, ptr noundef %29, ptr noundef %30)
  %31 = call noalias align 16 ptr @memalign(i64 noundef 16, i64 noundef 16384) #10
  store ptr %31, ptr %5, align 8, !tbaa !14
  %32 = call noalias align 16 ptr @memalign(i64 noundef 16, i64 noundef 16384) #10
  store ptr %32, ptr %6, align 8, !tbaa !14
  %33 = call noalias align 16 ptr @memalign(i64 noundef 16, i64 noundef 16384) #10
  store ptr %33, ptr %7, align 8, !tbaa !14
  %34 = load ptr, ptr %5, align 8, !tbaa !14
  call void @putdata(i32 noundef 0, i32 noundef 2047, ptr noundef %34)
  %35 = load ptr, ptr %5, align 8, !tbaa !14
  %36 = load ptr, ptr %4, align 8, !tbaa !11
  %37 = load ptr, ptr %8, align 8, !tbaa !14
  call void @cdft(i32 noundef 2048, i32 noundef 1, ptr noundef %35, ptr noundef %36, ptr noundef %37)
  %38 = load ptr, ptr %5, align 8, !tbaa !14
  %39 = load ptr, ptr %4, align 8, !tbaa !11
  %40 = load ptr, ptr %8, align 8, !tbaa !14
  call void @cdft(i32 noundef 2048, i32 noundef -1, ptr noundef %38, ptr noundef %39, ptr noundef %40)
  %41 = load ptr, ptr %5, align 8, !tbaa !14
  %42 = call double @errorcheck(i32 noundef 0, i32 noundef 2047, double noundef f0x3F50000000000000, ptr noundef %41)
  store double %42, ptr %13, align 8, !tbaa !9
  %43 = load double, ptr %13, align 8, !tbaa !9
  %44 = call double @llvm.fabs.f64(double %43)
  %45 = fcmp ogt double %44, 1.000000e-10
  br i1 %45, label %46, label %49

46:                                               ; preds = %0
  %47 = load double, ptr %13, align 8, !tbaa !9
  %48 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %47)
  call void @abort() #11
  unreachable

49:                                               ; preds = %0
  %50 = load ptr, ptr %5, align 8, !tbaa !14
  call void @llvm.memset.p0.i64(ptr align 8 %50, i8 0, i64 16384, i1 false)
  %51 = load ptr, ptr %5, align 8, !tbaa !14
  call void @putdata(i32 noundef 0, i32 noundef 1023, ptr noundef %51)
  %52 = load ptr, ptr %5, align 8, !tbaa !14
  %53 = load ptr, ptr %4, align 8, !tbaa !11
  %54 = load ptr, ptr %8, align 8, !tbaa !14
  call void @cdft(i32 noundef 2048, i32 noundef 1, ptr noundef %52, ptr noundef %53, ptr noundef %54)
  store i32 0, ptr %3, align 4, !tbaa !16
  br label %55

55:                                               ; preds = %73, %49
  %56 = load i32, ptr %3, align 4, !tbaa !16
  %57 = icmp slt i32 %56, 1024
  br i1 %57, label %58, label %76

58:                                               ; preds = %55
  %59 = load ptr, ptr %5, align 8, !tbaa !14
  %60 = load i32, ptr %3, align 4, !tbaa !16
  %61 = mul nsw i32 2, %60
  %62 = add nsw i32 %61, 1
  %63 = sext i32 %62 to i64
  %64 = getelementptr inbounds double, ptr %59, i64 %63
  %65 = load double, ptr %64, align 8, !tbaa !9
  %66 = fneg double %65
  %67 = load ptr, ptr %5, align 8, !tbaa !14
  %68 = load i32, ptr %3, align 4, !tbaa !16
  %69 = mul nsw i32 2, %68
  %70 = add nsw i32 %69, 1
  %71 = sext i32 %70 to i64
  %72 = getelementptr inbounds double, ptr %67, i64 %71
  store double %66, ptr %72, align 8, !tbaa !9
  br label %73

73:                                               ; preds = %58
  %74 = load i32, ptr %3, align 4, !tbaa !16
  %75 = add nsw i32 %74, 1
  store i32 %75, ptr %3, align 4, !tbaa !16
  br label %55, !llvm.loop !17

76:                                               ; preds = %55
  %77 = load ptr, ptr %7, align 8, !tbaa !14
  call void @llvm.memset.p0.i64(ptr align 8 %77, i8 0, i64 16384, i1 false)
  %78 = load ptr, ptr %7, align 8, !tbaa !14
  call void @putdata(i32 noundef 0, i32 noundef 1023, ptr noundef %78)
  %79 = call double @get_time()
  store double %79, ptr %9, align 8, !tbaa !9
  store i32 0, ptr %2, align 4, !tbaa !16
  br label %80

80:                                               ; preds = %150, %76
  %81 = load i32, ptr %2, align 4, !tbaa !16
  %82 = icmp slt i32 %81, 150000
  br i1 %82, label %83, label %153

83:                                               ; preds = %80
  call void @llvm.lifetime.start.p0(ptr %14) #9
  %84 = load ptr, ptr %6, align 8, !tbaa !14
  %85 = load ptr, ptr %7, align 8, !tbaa !14
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %84, ptr align 8 %85, i64 16384, i1 false)
  %86 = load ptr, ptr %6, align 8, !tbaa !14
  %87 = load ptr, ptr %4, align 8, !tbaa !11
  %88 = load ptr, ptr %8, align 8, !tbaa !14
  call void @cdft(i32 noundef 2048, i32 noundef 1, ptr noundef %86, ptr noundef %87, ptr noundef %88)
  store i32 0, ptr %14, align 4, !tbaa !16
  br label %89

89:                                               ; preds = %143, %83
  %90 = load i32, ptr %14, align 4, !tbaa !16
  %91 = icmp slt i32 %90, 1024
  br i1 %91, label %92, label %146

92:                                               ; preds = %89
  call void @llvm.lifetime.start.p0(ptr %15) #9
  %93 = load ptr, ptr %6, align 8, !tbaa !14
  %94 = load i32, ptr %14, align 4, !tbaa !16
  %95 = mul nsw i32 2, %94
  %96 = sext i32 %95 to i64
  %97 = getelementptr inbounds double, ptr %93, i64 %96
  %98 = load double, ptr %97, align 8, !tbaa !9
  store double %98, ptr %15, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %16) #9
  %99 = load ptr, ptr %5, align 8, !tbaa !14
  %100 = load i32, ptr %14, align 4, !tbaa !16
  %101 = mul nsw i32 2, %100
  %102 = sext i32 %101 to i64
  %103 = getelementptr inbounds double, ptr %99, i64 %102
  %104 = load double, ptr %103, align 8, !tbaa !9
  store double %104, ptr %16, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %17) #9
  %105 = load ptr, ptr %6, align 8, !tbaa !14
  %106 = load i32, ptr %14, align 4, !tbaa !16
  %107 = mul nsw i32 2, %106
  %108 = add nsw i32 %107, 1
  %109 = sext i32 %108 to i64
  %110 = getelementptr inbounds double, ptr %105, i64 %109
  %111 = load double, ptr %110, align 8, !tbaa !9
  store double %111, ptr %17, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %18) #9
  %112 = load ptr, ptr %5, align 8, !tbaa !14
  %113 = load i32, ptr %14, align 4, !tbaa !16
  %114 = mul nsw i32 2, %113
  %115 = add nsw i32 %114, 1
  %116 = sext i32 %115 to i64
  %117 = getelementptr inbounds double, ptr %112, i64 %116
  %118 = load double, ptr %117, align 8, !tbaa !9
  store double %118, ptr %18, align 8, !tbaa !9
  %119 = load double, ptr %15, align 8, !tbaa !9
  %120 = load double, ptr %16, align 8, !tbaa !9
  %121 = load double, ptr %17, align 8, !tbaa !9
  %122 = load double, ptr %18, align 8, !tbaa !9
  %123 = fmul double %121, %122
  %124 = fneg double %123
  %125 = call double @llvm.fmuladd.f64(double %119, double %120, double %124)
  %126 = load ptr, ptr %6, align 8, !tbaa !14
  %127 = load i32, ptr %14, align 4, !tbaa !16
  %128 = mul nsw i32 2, %127
  %129 = sext i32 %128 to i64
  %130 = getelementptr inbounds double, ptr %126, i64 %129
  store double %125, ptr %130, align 8, !tbaa !9
  %131 = load double, ptr %15, align 8, !tbaa !9
  %132 = load double, ptr %18, align 8, !tbaa !9
  %133 = load double, ptr %17, align 8, !tbaa !9
  %134 = load double, ptr %16, align 8, !tbaa !9
  %135 = fmul double %133, %134
  %136 = call double @llvm.fmuladd.f64(double %131, double %132, double %135)
  %137 = load ptr, ptr %6, align 8, !tbaa !14
  %138 = load i32, ptr %14, align 4, !tbaa !16
  %139 = mul nsw i32 2, %138
  %140 = add nsw i32 %139, 1
  %141 = sext i32 %140 to i64
  %142 = getelementptr inbounds double, ptr %137, i64 %141
  store double %136, ptr %142, align 8, !tbaa !9
  call void @llvm.lifetime.end.p0(ptr %18) #9
  call void @llvm.lifetime.end.p0(ptr %17) #9
  call void @llvm.lifetime.end.p0(ptr %16) #9
  call void @llvm.lifetime.end.p0(ptr %15) #9
  br label %143

143:                                              ; preds = %92
  %144 = load i32, ptr %14, align 4, !tbaa !16
  %145 = add nsw i32 %144, 1
  store i32 %145, ptr %14, align 4, !tbaa !16
  br label %89, !llvm.loop !19

146:                                              ; preds = %89
  %147 = load ptr, ptr %6, align 8, !tbaa !14
  %148 = load ptr, ptr %4, align 8, !tbaa !11
  %149 = load ptr, ptr %8, align 8, !tbaa !14
  call void @cdft(i32 noundef 2048, i32 noundef -1, ptr noundef %147, ptr noundef %148, ptr noundef %149)
  call void @llvm.lifetime.end.p0(ptr %14) #9
  br label %150

150:                                              ; preds = %146
  %151 = load i32, ptr %2, align 4, !tbaa !16
  %152 = add nsw i32 %151, 1
  store i32 %152, ptr %2, align 4, !tbaa !16
  br label %80, !llvm.loop !20

153:                                              ; preds = %80
  %154 = call double @get_time()
  store double %154, ptr %10, align 8, !tbaa !9
  %155 = load double, ptr %10, align 8, !tbaa !9
  %156 = load double, ptr %9, align 8, !tbaa !9
  %157 = fsub double %155, %156
  %158 = load double, ptr %11, align 8, !tbaa !9
  %159 = fsub double %157, %158
  %160 = load double, ptr %12, align 8, !tbaa !9
  %161 = fadd double %160, %159
  store double %161, ptr %12, align 8, !tbaa !9
  store i32 0, ptr %3, align 4, !tbaa !16
  br label %162

162:                                              ; preds = %205, %153
  %163 = load i32, ptr %3, align 4, !tbaa !16
  %164 = icmp slt i32 %163, 1024
  br i1 %164, label %165, label %208

165:                                              ; preds = %162
  %166 = load ptr, ptr %6, align 8, !tbaa !14
  %167 = load i32, ptr %3, align 4, !tbaa !16
  %168 = mul nsw i32 2, %167
  %169 = sext i32 %168 to i64
  %170 = getelementptr inbounds double, ptr %166, i64 %169
  %171 = load double, ptr %170, align 8, !tbaa !9
  %172 = call double @llvm.fabs.f64(double %171)
  %173 = fcmp ogt double %172, 1.000000e-09
  br i1 %173, label %174, label %181

174:                                              ; preds = %165
  %175 = load ptr, ptr %6, align 8, !tbaa !14
  %176 = load i32, ptr %3, align 4, !tbaa !16
  %177 = mul nsw i32 2, %176
  %178 = sext i32 %177 to i64
  %179 = getelementptr inbounds double, ptr %175, i64 %178
  %180 = load double, ptr %179, align 8, !tbaa !9
  br label %182

181:                                              ; preds = %165
  br label %182

182:                                              ; preds = %181, %174
  %183 = phi double [ %180, %174 ], [ 0.000000e+00, %181 ]
  %184 = load ptr, ptr %6, align 8, !tbaa !14
  %185 = load i32, ptr %3, align 4, !tbaa !16
  %186 = mul nsw i32 2, %185
  %187 = add nsw i32 %186, 1
  %188 = sext i32 %187 to i64
  %189 = getelementptr inbounds double, ptr %184, i64 %188
  %190 = load double, ptr %189, align 8, !tbaa !9
  %191 = call double @llvm.fabs.f64(double %190)
  %192 = fcmp ogt double %191, 1.000000e-09
  br i1 %192, label %193, label %201

193:                                              ; preds = %182
  %194 = load ptr, ptr %6, align 8, !tbaa !14
  %195 = load i32, ptr %3, align 4, !tbaa !16
  %196 = mul nsw i32 2, %195
  %197 = add nsw i32 %196, 1
  %198 = sext i32 %197 to i64
  %199 = getelementptr inbounds double, ptr %194, i64 %198
  %200 = load double, ptr %199, align 8, !tbaa !9
  br label %202

201:                                              ; preds = %182
  br label %202

202:                                              ; preds = %201, %193
  %203 = phi double [ %200, %193 ], [ 0.000000e+00, %201 ]
  %204 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, double noundef %183, double noundef %203)
  br label %205

205:                                              ; preds = %202
  %206 = load i32, ptr %3, align 4, !tbaa !16
  %207 = add nsw i32 %206, 1
  store i32 %207, ptr %3, align 4, !tbaa !16
  br label %162, !llvm.loop !21

208:                                              ; preds = %162
  %209 = load ptr, ptr %5, align 8, !tbaa !14
  call void @free(ptr noundef %209) #9
  %210 = load ptr, ptr %8, align 8, !tbaa !14
  call void @free(ptr noundef %210) #9
  %211 = load ptr, ptr %4, align 8, !tbaa !11
  call void @free(ptr noundef %211) #9
  %212 = load ptr, ptr %6, align 8, !tbaa !14
  call void @free(ptr noundef %212) #9
  %213 = load ptr, ptr %7, align 8, !tbaa !14
  call void @free(ptr noundef %213) #9
  call void @llvm.lifetime.end.p0(ptr %13) #9
  call void @llvm.lifetime.end.p0(ptr %12) #9
  call void @llvm.lifetime.end.p0(ptr %11) #9
  call void @llvm.lifetime.end.p0(ptr %10) #9
  call void @llvm.lifetime.end.p0(ptr %9) #9
  call void @llvm.lifetime.end.p0(ptr %8) #9
  call void @llvm.lifetime.end.p0(ptr %7) #9
  call void @llvm.lifetime.end.p0(ptr %6) #9
  call void @llvm.lifetime.end.p0(ptr %5) #9
  call void @llvm.lifetime.end.p0(ptr %4) #9
  call void @llvm.lifetime.end.p0(ptr %3) #9
  call void @llvm.lifetime.end.p0(ptr %2) #9
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local double @get_time() #0 {
  %1 = alloca %struct.timeval, align 8
  call void @llvm.lifetime.start.p0(ptr %1) #9
  %2 = call i32 @gettimeofday(ptr noundef %1, ptr noundef null) #9
  %3 = getelementptr inbounds nuw %struct.timeval, ptr %1, i32 0, i32 0
  %4 = load i64, ptr %3, align 8, !tbaa !22
  %5 = sitofp i64 %4 to double
  %6 = getelementptr inbounds nuw %struct.timeval, ptr %1, i32 0, i32 1
  %7 = load i64, ptr %6, align 8, !tbaa !25
  %8 = sitofp i64 %7 to double
  %9 = call double @llvm.fmuladd.f64(double %8, double f0x3EB0C6F7A0B5ED8D, double %5)
  call void @llvm.lifetime.end.p0(ptr %1) #9
  ret double %9
}

; Function Attrs: nounwind allocsize(1)
declare noalias ptr @memalign(i64 noundef, i64 noundef) #2

; Function Attrs: nounwind
declare double @sqrt(double noundef) #3

; Function Attrs: nounwind uwtable
define dso_local void @makewt(i32 noundef %0, ptr noundef %1, ptr noundef %2) #0 {
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca double, align 8
  %10 = alloca double, align 8
  %11 = alloca double, align 8
  store i32 %0, ptr %4, align 4, !tbaa !16
  store ptr %1, ptr %5, align 8, !tbaa !11
  store ptr %2, ptr %6, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %7) #9
  call void @llvm.lifetime.start.p0(ptr %8) #9
  call void @llvm.lifetime.start.p0(ptr %9) #9
  call void @llvm.lifetime.start.p0(ptr %10) #9
  call void @llvm.lifetime.start.p0(ptr %11) #9
  %12 = load i32, ptr %4, align 4, !tbaa !16
  %13 = icmp sgt i32 %12, 2
  br i1 %13, label %14, label %96

14:                                               ; preds = %3
  %15 = load i32, ptr %4, align 4, !tbaa !16
  %16 = ashr i32 %15, 1
  store i32 %16, ptr %8, align 4, !tbaa !16
  %17 = call double @atan(double noundef 1.000000e+00) #9
  %18 = load i32, ptr %8, align 4, !tbaa !16
  %19 = sitofp i32 %18 to double
  %20 = fdiv double %17, %19
  store double %20, ptr %9, align 8, !tbaa !9
  %21 = load ptr, ptr %6, align 8, !tbaa !14
  %22 = getelementptr inbounds double, ptr %21, i64 0
  store double 1.000000e+00, ptr %22, align 8, !tbaa !9
  %23 = load ptr, ptr %6, align 8, !tbaa !14
  %24 = getelementptr inbounds double, ptr %23, i64 1
  store double 0.000000e+00, ptr %24, align 8, !tbaa !9
  %25 = load double, ptr %9, align 8, !tbaa !9
  %26 = load i32, ptr %8, align 4, !tbaa !16
  %27 = sitofp i32 %26 to double
  %28 = fmul double %25, %27
  %29 = call double @cos(double noundef %28) #9
  %30 = load ptr, ptr %6, align 8, !tbaa !14
  %31 = load i32, ptr %8, align 4, !tbaa !16
  %32 = sext i32 %31 to i64
  %33 = getelementptr inbounds double, ptr %30, i64 %32
  store double %29, ptr %33, align 8, !tbaa !9
  %34 = load ptr, ptr %6, align 8, !tbaa !14
  %35 = load i32, ptr %8, align 4, !tbaa !16
  %36 = sext i32 %35 to i64
  %37 = getelementptr inbounds double, ptr %34, i64 %36
  %38 = load double, ptr %37, align 8, !tbaa !9
  %39 = load ptr, ptr %6, align 8, !tbaa !14
  %40 = load i32, ptr %8, align 4, !tbaa !16
  %41 = add nsw i32 %40, 1
  %42 = sext i32 %41 to i64
  %43 = getelementptr inbounds double, ptr %39, i64 %42
  store double %38, ptr %43, align 8, !tbaa !9
  %44 = load i32, ptr %8, align 4, !tbaa !16
  %45 = icmp sgt i32 %44, 2
  br i1 %45, label %46, label %95

46:                                               ; preds = %14
  store i32 2, ptr %7, align 4, !tbaa !16
  br label %47

47:                                               ; preds = %88, %46
  %48 = load i32, ptr %7, align 4, !tbaa !16
  %49 = load i32, ptr %8, align 4, !tbaa !16
  %50 = icmp slt i32 %48, %49
  br i1 %50, label %51, label %91

51:                                               ; preds = %47
  %52 = load double, ptr %9, align 8, !tbaa !9
  %53 = load i32, ptr %7, align 4, !tbaa !16
  %54 = sitofp i32 %53 to double
  %55 = fmul double %52, %54
  %56 = call double @cos(double noundef %55) #9
  store double %56, ptr %10, align 8, !tbaa !9
  %57 = load double, ptr %9, align 8, !tbaa !9
  %58 = load i32, ptr %7, align 4, !tbaa !16
  %59 = sitofp i32 %58 to double
  %60 = fmul double %57, %59
  %61 = call double @sin(double noundef %60) #9
  store double %61, ptr %11, align 8, !tbaa !9
  %62 = load double, ptr %10, align 8, !tbaa !9
  %63 = load ptr, ptr %6, align 8, !tbaa !14
  %64 = load i32, ptr %7, align 4, !tbaa !16
  %65 = sext i32 %64 to i64
  %66 = getelementptr inbounds double, ptr %63, i64 %65
  store double %62, ptr %66, align 8, !tbaa !9
  %67 = load double, ptr %11, align 8, !tbaa !9
  %68 = load ptr, ptr %6, align 8, !tbaa !14
  %69 = load i32, ptr %7, align 4, !tbaa !16
  %70 = add nsw i32 %69, 1
  %71 = sext i32 %70 to i64
  %72 = getelementptr inbounds double, ptr %68, i64 %71
  store double %67, ptr %72, align 8, !tbaa !9
  %73 = load double, ptr %11, align 8, !tbaa !9
  %74 = load ptr, ptr %6, align 8, !tbaa !14
  %75 = load i32, ptr %4, align 4, !tbaa !16
  %76 = load i32, ptr %7, align 4, !tbaa !16
  %77 = sub nsw i32 %75, %76
  %78 = sext i32 %77 to i64
  %79 = getelementptr inbounds double, ptr %74, i64 %78
  store double %73, ptr %79, align 8, !tbaa !9
  %80 = load double, ptr %10, align 8, !tbaa !9
  %81 = load ptr, ptr %6, align 8, !tbaa !14
  %82 = load i32, ptr %4, align 4, !tbaa !16
  %83 = load i32, ptr %7, align 4, !tbaa !16
  %84 = sub nsw i32 %82, %83
  %85 = add nsw i32 %84, 1
  %86 = sext i32 %85 to i64
  %87 = getelementptr inbounds double, ptr %81, i64 %86
  store double %80, ptr %87, align 8, !tbaa !9
  br label %88

88:                                               ; preds = %51
  %89 = load i32, ptr %7, align 4, !tbaa !16
  %90 = add nsw i32 %89, 2
  store i32 %90, ptr %7, align 4, !tbaa !16
  br label %47, !llvm.loop !26

91:                                               ; preds = %47
  %92 = load i32, ptr %4, align 4, !tbaa !16
  %93 = load ptr, ptr %5, align 8, !tbaa !11
  %94 = load ptr, ptr %6, align 8, !tbaa !14
  call void @bitrv2(i32 noundef %92, ptr noundef %93, ptr noundef %94)
  br label %95

95:                                               ; preds = %91, %14
  br label %96

96:                                               ; preds = %95, %3
  call void @llvm.lifetime.end.p0(ptr %11) #9
  call void @llvm.lifetime.end.p0(ptr %10) #9
  call void @llvm.lifetime.end.p0(ptr %9) #9
  call void @llvm.lifetime.end.p0(ptr %8) #9
  call void @llvm.lifetime.end.p0(ptr %7) #9
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local void @putdata(i32 noundef %0, i32 noundef %1, ptr noundef %2) #0 {
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca ptr, align 8
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  store i32 %0, ptr %4, align 4, !tbaa !16
  store i32 %1, ptr %5, align 4, !tbaa !16
  store ptr %2, ptr %6, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %7) #9
  call void @llvm.lifetime.start.p0(ptr %8) #9
  store i32 0, ptr %8, align 4, !tbaa !16
  %9 = load i32, ptr %4, align 4, !tbaa !16
  store i32 %9, ptr %7, align 4, !tbaa !16
  br label %10

10:                                               ; preds = %25, %3
  %11 = load i32, ptr %7, align 4, !tbaa !16
  %12 = load i32, ptr %5, align 4, !tbaa !16
  %13 = icmp sle i32 %11, %12
  br i1 %13, label %14, label %28

14:                                               ; preds = %10
  %15 = load i32, ptr %8, align 4, !tbaa !16
  %16 = mul nsw i32 %15, 7141
  %17 = add nsw i32 %16, 54773
  %18 = srem i32 %17, 259200
  store i32 %18, ptr %8, align 4, !tbaa !16
  %19 = sitofp i32 %18 to double
  %20 = fmul double %19, f0x3ED02E85C0898B71
  %21 = load ptr, ptr %6, align 8, !tbaa !14
  %22 = load i32, ptr %7, align 4, !tbaa !16
  %23 = sext i32 %22 to i64
  %24 = getelementptr inbounds double, ptr %21, i64 %23
  store double %20, ptr %24, align 8, !tbaa !9
  br label %25

25:                                               ; preds = %14
  %26 = load i32, ptr %7, align 4, !tbaa !16
  %27 = add nsw i32 %26, 1
  store i32 %27, ptr %7, align 4, !tbaa !16
  br label %10, !llvm.loop !27

28:                                               ; preds = %10
  call void @llvm.lifetime.end.p0(ptr %8) #9
  call void @llvm.lifetime.end.p0(ptr %7) #9
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local void @cdft(i32 noundef %0, i32 noundef %1, ptr noundef %2, ptr noundef %3, ptr noundef %4) #0 {
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca ptr, align 8
  %9 = alloca ptr, align 8
  %10 = alloca ptr, align 8
  store i32 %0, ptr %6, align 4, !tbaa !16
  store i32 %1, ptr %7, align 4, !tbaa !16
  store ptr %2, ptr %8, align 8, !tbaa !14
  store ptr %3, ptr %9, align 8, !tbaa !11
  store ptr %4, ptr %10, align 8, !tbaa !14
  %11 = load i32, ptr %6, align 4, !tbaa !16
  %12 = icmp sgt i32 %11, 4
  br i1 %12, label %13, label %31

13:                                               ; preds = %5
  %14 = load i32, ptr %7, align 4, !tbaa !16
  %15 = icmp sge i32 %14, 0
  br i1 %15, label %16, label %23

16:                                               ; preds = %13
  %17 = load i32, ptr %6, align 4, !tbaa !16
  %18 = load ptr, ptr %9, align 8, !tbaa !11
  %19 = load ptr, ptr %8, align 8, !tbaa !14
  call void @bitrv2(i32 noundef %17, ptr noundef %18, ptr noundef %19)
  %20 = load i32, ptr %6, align 4, !tbaa !16
  %21 = load ptr, ptr %8, align 8, !tbaa !14
  %22 = load ptr, ptr %10, align 8, !tbaa !14
  call void @cftfsub(i32 noundef %20, ptr noundef %21, ptr noundef %22)
  br label %30

23:                                               ; preds = %13
  %24 = load i32, ptr %6, align 4, !tbaa !16
  %25 = load ptr, ptr %9, align 8, !tbaa !11
  %26 = load ptr, ptr %8, align 8, !tbaa !14
  call void @bitrv2conj(i32 noundef %24, ptr noundef %25, ptr noundef %26)
  %27 = load i32, ptr %6, align 4, !tbaa !16
  %28 = load ptr, ptr %8, align 8, !tbaa !14
  %29 = load ptr, ptr %10, align 8, !tbaa !14
  call void @cftbsub(i32 noundef %27, ptr noundef %28, ptr noundef %29)
  br label %30

30:                                               ; preds = %23, %16
  br label %39

31:                                               ; preds = %5
  %32 = load i32, ptr %6, align 4, !tbaa !16
  %33 = icmp eq i32 %32, 4
  br i1 %33, label %34, label %38

34:                                               ; preds = %31
  %35 = load i32, ptr %6, align 4, !tbaa !16
  %36 = load ptr, ptr %8, align 8, !tbaa !14
  %37 = load ptr, ptr %10, align 8, !tbaa !14
  call void @cftfsub(i32 noundef %35, ptr noundef %36, ptr noundef %37)
  br label %38

38:                                               ; preds = %34, %31
  br label %39

39:                                               ; preds = %38, %30
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local double @errorcheck(i32 noundef %0, i32 noundef %1, double noundef %2, ptr noundef %3) #0 {
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca double, align 8
  %8 = alloca ptr, align 8
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  %11 = alloca double, align 8
  %12 = alloca double, align 8
  store i32 %0, ptr %5, align 4, !tbaa !16
  store i32 %1, ptr %6, align 4, !tbaa !16
  store double %2, ptr %7, align 8, !tbaa !9
  store ptr %3, ptr %8, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %9) #9
  call void @llvm.lifetime.start.p0(ptr %10) #9
  store i32 0, ptr %10, align 4, !tbaa !16
  call void @llvm.lifetime.start.p0(ptr %11) #9
  store double 0.000000e+00, ptr %11, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %12) #9
  %13 = load i32, ptr %5, align 4, !tbaa !16
  store i32 %13, ptr %9, align 4, !tbaa !16
  br label %14

14:                                               ; preds = %44, %4
  %15 = load i32, ptr %9, align 4, !tbaa !16
  %16 = load i32, ptr %6, align 4, !tbaa !16
  %17 = icmp sle i32 %15, %16
  br i1 %17, label %18, label %47

18:                                               ; preds = %14
  %19 = load i32, ptr %10, align 4, !tbaa !16
  %20 = mul nsw i32 %19, 7141
  %21 = add nsw i32 %20, 54773
  %22 = srem i32 %21, 259200
  store i32 %22, ptr %10, align 4, !tbaa !16
  %23 = sitofp i32 %22 to double
  %24 = load ptr, ptr %8, align 8, !tbaa !14
  %25 = load i32, ptr %9, align 4, !tbaa !16
  %26 = sext i32 %25 to i64
  %27 = getelementptr inbounds double, ptr %24, i64 %26
  %28 = load double, ptr %27, align 8, !tbaa !9
  %29 = load double, ptr %7, align 8, !tbaa !9
  %30 = fmul double %28, %29
  %31 = fneg double %30
  %32 = call double @llvm.fmuladd.f64(double %23, double f0x3ED02E85C0898B71, double %31)
  store double %32, ptr %12, align 8, !tbaa !9
  %33 = load double, ptr %11, align 8, !tbaa !9
  %34 = load double, ptr %12, align 8, !tbaa !9
  %35 = call double @llvm.fabs.f64(double %34)
  %36 = fcmp ogt double %33, %35
  br i1 %36, label %37, label %39

37:                                               ; preds = %18
  %38 = load double, ptr %11, align 8, !tbaa !9
  br label %42

39:                                               ; preds = %18
  %40 = load double, ptr %12, align 8, !tbaa !9
  %41 = call double @llvm.fabs.f64(double %40)
  br label %42

42:                                               ; preds = %39, %37
  %43 = phi double [ %38, %37 ], [ %41, %39 ]
  store double %43, ptr %11, align 8, !tbaa !9
  br label %44

44:                                               ; preds = %42
  %45 = load i32, ptr %9, align 4, !tbaa !16
  %46 = add nsw i32 %45, 1
  store i32 %46, ptr %9, align 4, !tbaa !16
  br label %14, !llvm.loop !28

47:                                               ; preds = %14
  %48 = load double, ptr %11, align 8, !tbaa !9
  call void @llvm.lifetime.end.p0(ptr %12) #9
  call void @llvm.lifetime.end.p0(ptr %11) #9
  call void @llvm.lifetime.end.p0(ptr %10) #9
  call void @llvm.lifetime.end.p0(ptr %9) #9
  ret double %48
}

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fabs.f64(double) #4

declare i32 @printf(ptr noundef, ...) #5

; Function Attrs: cold noreturn nounwind
declare void @abort() #6

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #7

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #4

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind
declare void @free(ptr noundef) #3

; Function Attrs: nounwind
declare i32 @gettimeofday(ptr noundef, ptr noundef) #3

; Function Attrs: nounwind uwtable
define internal void @bitrv2(i32 noundef %0, ptr noundef %1, ptr noundef %2) #0 {
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  %11 = alloca i32, align 4
  %12 = alloca i32, align 4
  %13 = alloca i32, align 4
  %14 = alloca double, align 8
  %15 = alloca double, align 8
  %16 = alloca double, align 8
  %17 = alloca double, align 8
  store i32 %0, ptr %4, align 4, !tbaa !16
  store ptr %1, ptr %5, align 8, !tbaa !11
  store ptr %2, ptr %6, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %7) #9
  call void @llvm.lifetime.start.p0(ptr %8) #9
  call void @llvm.lifetime.start.p0(ptr %9) #9
  call void @llvm.lifetime.start.p0(ptr %10) #9
  call void @llvm.lifetime.start.p0(ptr %11) #9
  call void @llvm.lifetime.start.p0(ptr %12) #9
  call void @llvm.lifetime.start.p0(ptr %13) #9
  call void @llvm.lifetime.start.p0(ptr %14) #9
  call void @llvm.lifetime.start.p0(ptr %15) #9
  call void @llvm.lifetime.start.p0(ptr %16) #9
  call void @llvm.lifetime.start.p0(ptr %17) #9
  %18 = load ptr, ptr %5, align 8, !tbaa !11
  %19 = getelementptr inbounds i32, ptr %18, i64 0
  store i32 0, ptr %19, align 4, !tbaa !16
  %20 = load i32, ptr %4, align 4, !tbaa !16
  store i32 %20, ptr %11, align 4, !tbaa !16
  store i32 1, ptr %12, align 4, !tbaa !16
  br label %21

21:                                               ; preds = %50, %3
  %22 = load i32, ptr %12, align 4, !tbaa !16
  %23 = shl i32 %22, 3
  %24 = load i32, ptr %11, align 4, !tbaa !16
  %25 = icmp slt i32 %23, %24
  br i1 %25, label %26, label %53

26:                                               ; preds = %21
  %27 = load i32, ptr %11, align 4, !tbaa !16
  %28 = ashr i32 %27, 1
  store i32 %28, ptr %11, align 4, !tbaa !16
  store i32 0, ptr %7, align 4, !tbaa !16
  br label %29

29:                                               ; preds = %47, %26
  %30 = load i32, ptr %7, align 4, !tbaa !16
  %31 = load i32, ptr %12, align 4, !tbaa !16
  %32 = icmp slt i32 %30, %31
  br i1 %32, label %33, label %50

33:                                               ; preds = %29
  %34 = load ptr, ptr %5, align 8, !tbaa !11
  %35 = load i32, ptr %7, align 4, !tbaa !16
  %36 = sext i32 %35 to i64
  %37 = getelementptr inbounds i32, ptr %34, i64 %36
  %38 = load i32, ptr %37, align 4, !tbaa !16
  %39 = load i32, ptr %11, align 4, !tbaa !16
  %40 = add nsw i32 %38, %39
  %41 = load ptr, ptr %5, align 8, !tbaa !11
  %42 = load i32, ptr %12, align 4, !tbaa !16
  %43 = load i32, ptr %7, align 4, !tbaa !16
  %44 = add nsw i32 %42, %43
  %45 = sext i32 %44 to i64
  %46 = getelementptr inbounds i32, ptr %41, i64 %45
  store i32 %40, ptr %46, align 4, !tbaa !16
  br label %47

47:                                               ; preds = %33
  %48 = load i32, ptr %7, align 4, !tbaa !16
  %49 = add nsw i32 %48, 1
  store i32 %49, ptr %7, align 4, !tbaa !16
  br label %29, !llvm.loop !29

50:                                               ; preds = %29
  %51 = load i32, ptr %12, align 4, !tbaa !16
  %52 = shl i32 %51, 1
  store i32 %52, ptr %12, align 4, !tbaa !16
  br label %21, !llvm.loop !30

53:                                               ; preds = %21
  %54 = load i32, ptr %12, align 4, !tbaa !16
  %55 = mul nsw i32 2, %54
  store i32 %55, ptr %13, align 4, !tbaa !16
  %56 = load i32, ptr %12, align 4, !tbaa !16
  %57 = shl i32 %56, 3
  %58 = load i32, ptr %11, align 4, !tbaa !16
  %59 = icmp eq i32 %57, %58
  br i1 %59, label %60, label %348

60:                                               ; preds = %53
  store i32 0, ptr %9, align 4, !tbaa !16
  br label %61

61:                                               ; preds = %344, %60
  %62 = load i32, ptr %9, align 4, !tbaa !16
  %63 = load i32, ptr %12, align 4, !tbaa !16
  %64 = icmp slt i32 %62, %63
  br i1 %64, label %65, label %347

65:                                               ; preds = %61
  store i32 0, ptr %7, align 4, !tbaa !16
  br label %66

66:                                               ; preds = %283, %65
  %67 = load i32, ptr %7, align 4, !tbaa !16
  %68 = load i32, ptr %9, align 4, !tbaa !16
  %69 = icmp slt i32 %67, %68
  br i1 %69, label %70, label %286

70:                                               ; preds = %66
  %71 = load i32, ptr %7, align 4, !tbaa !16
  %72 = mul nsw i32 2, %71
  %73 = load ptr, ptr %5, align 8, !tbaa !11
  %74 = load i32, ptr %9, align 4, !tbaa !16
  %75 = sext i32 %74 to i64
  %76 = getelementptr inbounds i32, ptr %73, i64 %75
  %77 = load i32, ptr %76, align 4, !tbaa !16
  %78 = add nsw i32 %72, %77
  store i32 %78, ptr %8, align 4, !tbaa !16
  %79 = load i32, ptr %9, align 4, !tbaa !16
  %80 = mul nsw i32 2, %79
  %81 = load ptr, ptr %5, align 8, !tbaa !11
  %82 = load i32, ptr %7, align 4, !tbaa !16
  %83 = sext i32 %82 to i64
  %84 = getelementptr inbounds i32, ptr %81, i64 %83
  %85 = load i32, ptr %84, align 4, !tbaa !16
  %86 = add nsw i32 %80, %85
  store i32 %86, ptr %10, align 4, !tbaa !16
  %87 = load ptr, ptr %6, align 8, !tbaa !14
  %88 = load i32, ptr %8, align 4, !tbaa !16
  %89 = sext i32 %88 to i64
  %90 = getelementptr inbounds double, ptr %87, i64 %89
  %91 = load double, ptr %90, align 8, !tbaa !9
  store double %91, ptr %14, align 8, !tbaa !9
  %92 = load ptr, ptr %6, align 8, !tbaa !14
  %93 = load i32, ptr %8, align 4, !tbaa !16
  %94 = add nsw i32 %93, 1
  %95 = sext i32 %94 to i64
  %96 = getelementptr inbounds double, ptr %92, i64 %95
  %97 = load double, ptr %96, align 8, !tbaa !9
  store double %97, ptr %15, align 8, !tbaa !9
  %98 = load ptr, ptr %6, align 8, !tbaa !14
  %99 = load i32, ptr %10, align 4, !tbaa !16
  %100 = sext i32 %99 to i64
  %101 = getelementptr inbounds double, ptr %98, i64 %100
  %102 = load double, ptr %101, align 8, !tbaa !9
  store double %102, ptr %16, align 8, !tbaa !9
  %103 = load ptr, ptr %6, align 8, !tbaa !14
  %104 = load i32, ptr %10, align 4, !tbaa !16
  %105 = add nsw i32 %104, 1
  %106 = sext i32 %105 to i64
  %107 = getelementptr inbounds double, ptr %103, i64 %106
  %108 = load double, ptr %107, align 8, !tbaa !9
  store double %108, ptr %17, align 8, !tbaa !9
  %109 = load double, ptr %16, align 8, !tbaa !9
  %110 = load ptr, ptr %6, align 8, !tbaa !14
  %111 = load i32, ptr %8, align 4, !tbaa !16
  %112 = sext i32 %111 to i64
  %113 = getelementptr inbounds double, ptr %110, i64 %112
  store double %109, ptr %113, align 8, !tbaa !9
  %114 = load double, ptr %17, align 8, !tbaa !9
  %115 = load ptr, ptr %6, align 8, !tbaa !14
  %116 = load i32, ptr %8, align 4, !tbaa !16
  %117 = add nsw i32 %116, 1
  %118 = sext i32 %117 to i64
  %119 = getelementptr inbounds double, ptr %115, i64 %118
  store double %114, ptr %119, align 8, !tbaa !9
  %120 = load double, ptr %14, align 8, !tbaa !9
  %121 = load ptr, ptr %6, align 8, !tbaa !14
  %122 = load i32, ptr %10, align 4, !tbaa !16
  %123 = sext i32 %122 to i64
  %124 = getelementptr inbounds double, ptr %121, i64 %123
  store double %120, ptr %124, align 8, !tbaa !9
  %125 = load double, ptr %15, align 8, !tbaa !9
  %126 = load ptr, ptr %6, align 8, !tbaa !14
  %127 = load i32, ptr %10, align 4, !tbaa !16
  %128 = add nsw i32 %127, 1
  %129 = sext i32 %128 to i64
  %130 = getelementptr inbounds double, ptr %126, i64 %129
  store double %125, ptr %130, align 8, !tbaa !9
  %131 = load i32, ptr %13, align 4, !tbaa !16
  %132 = load i32, ptr %8, align 4, !tbaa !16
  %133 = add nsw i32 %132, %131
  store i32 %133, ptr %8, align 4, !tbaa !16
  %134 = load i32, ptr %13, align 4, !tbaa !16
  %135 = mul nsw i32 2, %134
  %136 = load i32, ptr %10, align 4, !tbaa !16
  %137 = add nsw i32 %136, %135
  store i32 %137, ptr %10, align 4, !tbaa !16
  %138 = load ptr, ptr %6, align 8, !tbaa !14
  %139 = load i32, ptr %8, align 4, !tbaa !16
  %140 = sext i32 %139 to i64
  %141 = getelementptr inbounds double, ptr %138, i64 %140
  %142 = load double, ptr %141, align 8, !tbaa !9
  store double %142, ptr %14, align 8, !tbaa !9
  %143 = load ptr, ptr %6, align 8, !tbaa !14
  %144 = load i32, ptr %8, align 4, !tbaa !16
  %145 = add nsw i32 %144, 1
  %146 = sext i32 %145 to i64
  %147 = getelementptr inbounds double, ptr %143, i64 %146
  %148 = load double, ptr %147, align 8, !tbaa !9
  store double %148, ptr %15, align 8, !tbaa !9
  %149 = load ptr, ptr %6, align 8, !tbaa !14
  %150 = load i32, ptr %10, align 4, !tbaa !16
  %151 = sext i32 %150 to i64
  %152 = getelementptr inbounds double, ptr %149, i64 %151
  %153 = load double, ptr %152, align 8, !tbaa !9
  store double %153, ptr %16, align 8, !tbaa !9
  %154 = load ptr, ptr %6, align 8, !tbaa !14
  %155 = load i32, ptr %10, align 4, !tbaa !16
  %156 = add nsw i32 %155, 1
  %157 = sext i32 %156 to i64
  %158 = getelementptr inbounds double, ptr %154, i64 %157
  %159 = load double, ptr %158, align 8, !tbaa !9
  store double %159, ptr %17, align 8, !tbaa !9
  %160 = load double, ptr %16, align 8, !tbaa !9
  %161 = load ptr, ptr %6, align 8, !tbaa !14
  %162 = load i32, ptr %8, align 4, !tbaa !16
  %163 = sext i32 %162 to i64
  %164 = getelementptr inbounds double, ptr %161, i64 %163
  store double %160, ptr %164, align 8, !tbaa !9
  %165 = load double, ptr %17, align 8, !tbaa !9
  %166 = load ptr, ptr %6, align 8, !tbaa !14
  %167 = load i32, ptr %8, align 4, !tbaa !16
  %168 = add nsw i32 %167, 1
  %169 = sext i32 %168 to i64
  %170 = getelementptr inbounds double, ptr %166, i64 %169
  store double %165, ptr %170, align 8, !tbaa !9
  %171 = load double, ptr %14, align 8, !tbaa !9
  %172 = load ptr, ptr %6, align 8, !tbaa !14
  %173 = load i32, ptr %10, align 4, !tbaa !16
  %174 = sext i32 %173 to i64
  %175 = getelementptr inbounds double, ptr %172, i64 %174
  store double %171, ptr %175, align 8, !tbaa !9
  %176 = load double, ptr %15, align 8, !tbaa !9
  %177 = load ptr, ptr %6, align 8, !tbaa !14
  %178 = load i32, ptr %10, align 4, !tbaa !16
  %179 = add nsw i32 %178, 1
  %180 = sext i32 %179 to i64
  %181 = getelementptr inbounds double, ptr %177, i64 %180
  store double %176, ptr %181, align 8, !tbaa !9
  %182 = load i32, ptr %13, align 4, !tbaa !16
  %183 = load i32, ptr %8, align 4, !tbaa !16
  %184 = add nsw i32 %183, %182
  store i32 %184, ptr %8, align 4, !tbaa !16
  %185 = load i32, ptr %13, align 4, !tbaa !16
  %186 = load i32, ptr %10, align 4, !tbaa !16
  %187 = sub nsw i32 %186, %185
  store i32 %187, ptr %10, align 4, !tbaa !16
  %188 = load ptr, ptr %6, align 8, !tbaa !14
  %189 = load i32, ptr %8, align 4, !tbaa !16
  %190 = sext i32 %189 to i64
  %191 = getelementptr inbounds double, ptr %188, i64 %190
  %192 = load double, ptr %191, align 8, !tbaa !9
  store double %192, ptr %14, align 8, !tbaa !9
  %193 = load ptr, ptr %6, align 8, !tbaa !14
  %194 = load i32, ptr %8, align 4, !tbaa !16
  %195 = add nsw i32 %194, 1
  %196 = sext i32 %195 to i64
  %197 = getelementptr inbounds double, ptr %193, i64 %196
  %198 = load double, ptr %197, align 8, !tbaa !9
  store double %198, ptr %15, align 8, !tbaa !9
  %199 = load ptr, ptr %6, align 8, !tbaa !14
  %200 = load i32, ptr %10, align 4, !tbaa !16
  %201 = sext i32 %200 to i64
  %202 = getelementptr inbounds double, ptr %199, i64 %201
  %203 = load double, ptr %202, align 8, !tbaa !9
  store double %203, ptr %16, align 8, !tbaa !9
  %204 = load ptr, ptr %6, align 8, !tbaa !14
  %205 = load i32, ptr %10, align 4, !tbaa !16
  %206 = add nsw i32 %205, 1
  %207 = sext i32 %206 to i64
  %208 = getelementptr inbounds double, ptr %204, i64 %207
  %209 = load double, ptr %208, align 8, !tbaa !9
  store double %209, ptr %17, align 8, !tbaa !9
  %210 = load double, ptr %16, align 8, !tbaa !9
  %211 = load ptr, ptr %6, align 8, !tbaa !14
  %212 = load i32, ptr %8, align 4, !tbaa !16
  %213 = sext i32 %212 to i64
  %214 = getelementptr inbounds double, ptr %211, i64 %213
  store double %210, ptr %214, align 8, !tbaa !9
  %215 = load double, ptr %17, align 8, !tbaa !9
  %216 = load ptr, ptr %6, align 8, !tbaa !14
  %217 = load i32, ptr %8, align 4, !tbaa !16
  %218 = add nsw i32 %217, 1
  %219 = sext i32 %218 to i64
  %220 = getelementptr inbounds double, ptr %216, i64 %219
  store double %215, ptr %220, align 8, !tbaa !9
  %221 = load double, ptr %14, align 8, !tbaa !9
  %222 = load ptr, ptr %6, align 8, !tbaa !14
  %223 = load i32, ptr %10, align 4, !tbaa !16
  %224 = sext i32 %223 to i64
  %225 = getelementptr inbounds double, ptr %222, i64 %224
  store double %221, ptr %225, align 8, !tbaa !9
  %226 = load double, ptr %15, align 8, !tbaa !9
  %227 = load ptr, ptr %6, align 8, !tbaa !14
  %228 = load i32, ptr %10, align 4, !tbaa !16
  %229 = add nsw i32 %228, 1
  %230 = sext i32 %229 to i64
  %231 = getelementptr inbounds double, ptr %227, i64 %230
  store double %226, ptr %231, align 8, !tbaa !9
  %232 = load i32, ptr %13, align 4, !tbaa !16
  %233 = load i32, ptr %8, align 4, !tbaa !16
  %234 = add nsw i32 %233, %232
  store i32 %234, ptr %8, align 4, !tbaa !16
  %235 = load i32, ptr %13, align 4, !tbaa !16
  %236 = mul nsw i32 2, %235
  %237 = load i32, ptr %10, align 4, !tbaa !16
  %238 = add nsw i32 %237, %236
  store i32 %238, ptr %10, align 4, !tbaa !16
  %239 = load ptr, ptr %6, align 8, !tbaa !14
  %240 = load i32, ptr %8, align 4, !tbaa !16
  %241 = sext i32 %240 to i64
  %242 = getelementptr inbounds double, ptr %239, i64 %241
  %243 = load double, ptr %242, align 8, !tbaa !9
  store double %243, ptr %14, align 8, !tbaa !9
  %244 = load ptr, ptr %6, align 8, !tbaa !14
  %245 = load i32, ptr %8, align 4, !tbaa !16
  %246 = add nsw i32 %245, 1
  %247 = sext i32 %246 to i64
  %248 = getelementptr inbounds double, ptr %244, i64 %247
  %249 = load double, ptr %248, align 8, !tbaa !9
  store double %249, ptr %15, align 8, !tbaa !9
  %250 = load ptr, ptr %6, align 8, !tbaa !14
  %251 = load i32, ptr %10, align 4, !tbaa !16
  %252 = sext i32 %251 to i64
  %253 = getelementptr inbounds double, ptr %250, i64 %252
  %254 = load double, ptr %253, align 8, !tbaa !9
  store double %254, ptr %16, align 8, !tbaa !9
  %255 = load ptr, ptr %6, align 8, !tbaa !14
  %256 = load i32, ptr %10, align 4, !tbaa !16
  %257 = add nsw i32 %256, 1
  %258 = sext i32 %257 to i64
  %259 = getelementptr inbounds double, ptr %255, i64 %258
  %260 = load double, ptr %259, align 8, !tbaa !9
  store double %260, ptr %17, align 8, !tbaa !9
  %261 = load double, ptr %16, align 8, !tbaa !9
  %262 = load ptr, ptr %6, align 8, !tbaa !14
  %263 = load i32, ptr %8, align 4, !tbaa !16
  %264 = sext i32 %263 to i64
  %265 = getelementptr inbounds double, ptr %262, i64 %264
  store double %261, ptr %265, align 8, !tbaa !9
  %266 = load double, ptr %17, align 8, !tbaa !9
  %267 = load ptr, ptr %6, align 8, !tbaa !14
  %268 = load i32, ptr %8, align 4, !tbaa !16
  %269 = add nsw i32 %268, 1
  %270 = sext i32 %269 to i64
  %271 = getelementptr inbounds double, ptr %267, i64 %270
  store double %266, ptr %271, align 8, !tbaa !9
  %272 = load double, ptr %14, align 8, !tbaa !9
  %273 = load ptr, ptr %6, align 8, !tbaa !14
  %274 = load i32, ptr %10, align 4, !tbaa !16
  %275 = sext i32 %274 to i64
  %276 = getelementptr inbounds double, ptr %273, i64 %275
  store double %272, ptr %276, align 8, !tbaa !9
  %277 = load double, ptr %15, align 8, !tbaa !9
  %278 = load ptr, ptr %6, align 8, !tbaa !14
  %279 = load i32, ptr %10, align 4, !tbaa !16
  %280 = add nsw i32 %279, 1
  %281 = sext i32 %280 to i64
  %282 = getelementptr inbounds double, ptr %278, i64 %281
  store double %277, ptr %282, align 8, !tbaa !9
  br label %283

283:                                              ; preds = %70
  %284 = load i32, ptr %7, align 4, !tbaa !16
  %285 = add nsw i32 %284, 1
  store i32 %285, ptr %7, align 4, !tbaa !16
  br label %66, !llvm.loop !31

286:                                              ; preds = %66
  %287 = load i32, ptr %9, align 4, !tbaa !16
  %288 = mul nsw i32 2, %287
  %289 = load i32, ptr %13, align 4, !tbaa !16
  %290 = add nsw i32 %288, %289
  %291 = load ptr, ptr %5, align 8, !tbaa !11
  %292 = load i32, ptr %9, align 4, !tbaa !16
  %293 = sext i32 %292 to i64
  %294 = getelementptr inbounds i32, ptr %291, i64 %293
  %295 = load i32, ptr %294, align 4, !tbaa !16
  %296 = add nsw i32 %290, %295
  store i32 %296, ptr %8, align 4, !tbaa !16
  %297 = load i32, ptr %8, align 4, !tbaa !16
  %298 = load i32, ptr %13, align 4, !tbaa !16
  %299 = add nsw i32 %297, %298
  store i32 %299, ptr %10, align 4, !tbaa !16
  %300 = load ptr, ptr %6, align 8, !tbaa !14
  %301 = load i32, ptr %8, align 4, !tbaa !16
  %302 = sext i32 %301 to i64
  %303 = getelementptr inbounds double, ptr %300, i64 %302
  %304 = load double, ptr %303, align 8, !tbaa !9
  store double %304, ptr %14, align 8, !tbaa !9
  %305 = load ptr, ptr %6, align 8, !tbaa !14
  %306 = load i32, ptr %8, align 4, !tbaa !16
  %307 = add nsw i32 %306, 1
  %308 = sext i32 %307 to i64
  %309 = getelementptr inbounds double, ptr %305, i64 %308
  %310 = load double, ptr %309, align 8, !tbaa !9
  store double %310, ptr %15, align 8, !tbaa !9
  %311 = load ptr, ptr %6, align 8, !tbaa !14
  %312 = load i32, ptr %10, align 4, !tbaa !16
  %313 = sext i32 %312 to i64
  %314 = getelementptr inbounds double, ptr %311, i64 %313
  %315 = load double, ptr %314, align 8, !tbaa !9
  store double %315, ptr %16, align 8, !tbaa !9
  %316 = load ptr, ptr %6, align 8, !tbaa !14
  %317 = load i32, ptr %10, align 4, !tbaa !16
  %318 = add nsw i32 %317, 1
  %319 = sext i32 %318 to i64
  %320 = getelementptr inbounds double, ptr %316, i64 %319
  %321 = load double, ptr %320, align 8, !tbaa !9
  store double %321, ptr %17, align 8, !tbaa !9
  %322 = load double, ptr %16, align 8, !tbaa !9
  %323 = load ptr, ptr %6, align 8, !tbaa !14
  %324 = load i32, ptr %8, align 4, !tbaa !16
  %325 = sext i32 %324 to i64
  %326 = getelementptr inbounds double, ptr %323, i64 %325
  store double %322, ptr %326, align 8, !tbaa !9
  %327 = load double, ptr %17, align 8, !tbaa !9
  %328 = load ptr, ptr %6, align 8, !tbaa !14
  %329 = load i32, ptr %8, align 4, !tbaa !16
  %330 = add nsw i32 %329, 1
  %331 = sext i32 %330 to i64
  %332 = getelementptr inbounds double, ptr %328, i64 %331
  store double %327, ptr %332, align 8, !tbaa !9
  %333 = load double, ptr %14, align 8, !tbaa !9
  %334 = load ptr, ptr %6, align 8, !tbaa !14
  %335 = load i32, ptr %10, align 4, !tbaa !16
  %336 = sext i32 %335 to i64
  %337 = getelementptr inbounds double, ptr %334, i64 %336
  store double %333, ptr %337, align 8, !tbaa !9
  %338 = load double, ptr %15, align 8, !tbaa !9
  %339 = load ptr, ptr %6, align 8, !tbaa !14
  %340 = load i32, ptr %10, align 4, !tbaa !16
  %341 = add nsw i32 %340, 1
  %342 = sext i32 %341 to i64
  %343 = getelementptr inbounds double, ptr %339, i64 %342
  store double %338, ptr %343, align 8, !tbaa !9
  br label %344

344:                                              ; preds = %286
  %345 = load i32, ptr %9, align 4, !tbaa !16
  %346 = add nsw i32 %345, 1
  store i32 %346, ptr %9, align 4, !tbaa !16
  br label %61, !llvm.loop !32

347:                                              ; preds = %61
  br label %477

348:                                              ; preds = %53
  store i32 1, ptr %9, align 4, !tbaa !16
  br label %349

349:                                              ; preds = %473, %348
  %350 = load i32, ptr %9, align 4, !tbaa !16
  %351 = load i32, ptr %12, align 4, !tbaa !16
  %352 = icmp slt i32 %350, %351
  br i1 %352, label %353, label %476

353:                                              ; preds = %349
  store i32 0, ptr %7, align 4, !tbaa !16
  br label %354

354:                                              ; preds = %469, %353
  %355 = load i32, ptr %7, align 4, !tbaa !16
  %356 = load i32, ptr %9, align 4, !tbaa !16
  %357 = icmp slt i32 %355, %356
  br i1 %357, label %358, label %472

358:                                              ; preds = %354
  %359 = load i32, ptr %7, align 4, !tbaa !16
  %360 = mul nsw i32 2, %359
  %361 = load ptr, ptr %5, align 8, !tbaa !11
  %362 = load i32, ptr %9, align 4, !tbaa !16
  %363 = sext i32 %362 to i64
  %364 = getelementptr inbounds i32, ptr %361, i64 %363
  %365 = load i32, ptr %364, align 4, !tbaa !16
  %366 = add nsw i32 %360, %365
  store i32 %366, ptr %8, align 4, !tbaa !16
  %367 = load i32, ptr %9, align 4, !tbaa !16
  %368 = mul nsw i32 2, %367
  %369 = load ptr, ptr %5, align 8, !tbaa !11
  %370 = load i32, ptr %7, align 4, !tbaa !16
  %371 = sext i32 %370 to i64
  %372 = getelementptr inbounds i32, ptr %369, i64 %371
  %373 = load i32, ptr %372, align 4, !tbaa !16
  %374 = add nsw i32 %368, %373
  store i32 %374, ptr %10, align 4, !tbaa !16
  %375 = load ptr, ptr %6, align 8, !tbaa !14
  %376 = load i32, ptr %8, align 4, !tbaa !16
  %377 = sext i32 %376 to i64
  %378 = getelementptr inbounds double, ptr %375, i64 %377
  %379 = load double, ptr %378, align 8, !tbaa !9
  store double %379, ptr %14, align 8, !tbaa !9
  %380 = load ptr, ptr %6, align 8, !tbaa !14
  %381 = load i32, ptr %8, align 4, !tbaa !16
  %382 = add nsw i32 %381, 1
  %383 = sext i32 %382 to i64
  %384 = getelementptr inbounds double, ptr %380, i64 %383
  %385 = load double, ptr %384, align 8, !tbaa !9
  store double %385, ptr %15, align 8, !tbaa !9
  %386 = load ptr, ptr %6, align 8, !tbaa !14
  %387 = load i32, ptr %10, align 4, !tbaa !16
  %388 = sext i32 %387 to i64
  %389 = getelementptr inbounds double, ptr %386, i64 %388
  %390 = load double, ptr %389, align 8, !tbaa !9
  store double %390, ptr %16, align 8, !tbaa !9
  %391 = load ptr, ptr %6, align 8, !tbaa !14
  %392 = load i32, ptr %10, align 4, !tbaa !16
  %393 = add nsw i32 %392, 1
  %394 = sext i32 %393 to i64
  %395 = getelementptr inbounds double, ptr %391, i64 %394
  %396 = load double, ptr %395, align 8, !tbaa !9
  store double %396, ptr %17, align 8, !tbaa !9
  %397 = load double, ptr %16, align 8, !tbaa !9
  %398 = load ptr, ptr %6, align 8, !tbaa !14
  %399 = load i32, ptr %8, align 4, !tbaa !16
  %400 = sext i32 %399 to i64
  %401 = getelementptr inbounds double, ptr %398, i64 %400
  store double %397, ptr %401, align 8, !tbaa !9
  %402 = load double, ptr %17, align 8, !tbaa !9
  %403 = load ptr, ptr %6, align 8, !tbaa !14
  %404 = load i32, ptr %8, align 4, !tbaa !16
  %405 = add nsw i32 %404, 1
  %406 = sext i32 %405 to i64
  %407 = getelementptr inbounds double, ptr %403, i64 %406
  store double %402, ptr %407, align 8, !tbaa !9
  %408 = load double, ptr %14, align 8, !tbaa !9
  %409 = load ptr, ptr %6, align 8, !tbaa !14
  %410 = load i32, ptr %10, align 4, !tbaa !16
  %411 = sext i32 %410 to i64
  %412 = getelementptr inbounds double, ptr %409, i64 %411
  store double %408, ptr %412, align 8, !tbaa !9
  %413 = load double, ptr %15, align 8, !tbaa !9
  %414 = load ptr, ptr %6, align 8, !tbaa !14
  %415 = load i32, ptr %10, align 4, !tbaa !16
  %416 = add nsw i32 %415, 1
  %417 = sext i32 %416 to i64
  %418 = getelementptr inbounds double, ptr %414, i64 %417
  store double %413, ptr %418, align 8, !tbaa !9
  %419 = load i32, ptr %13, align 4, !tbaa !16
  %420 = load i32, ptr %8, align 4, !tbaa !16
  %421 = add nsw i32 %420, %419
  store i32 %421, ptr %8, align 4, !tbaa !16
  %422 = load i32, ptr %13, align 4, !tbaa !16
  %423 = load i32, ptr %10, align 4, !tbaa !16
  %424 = add nsw i32 %423, %422
  store i32 %424, ptr %10, align 4, !tbaa !16
  %425 = load ptr, ptr %6, align 8, !tbaa !14
  %426 = load i32, ptr %8, align 4, !tbaa !16
  %427 = sext i32 %426 to i64
  %428 = getelementptr inbounds double, ptr %425, i64 %427
  %429 = load double, ptr %428, align 8, !tbaa !9
  store double %429, ptr %14, align 8, !tbaa !9
  %430 = load ptr, ptr %6, align 8, !tbaa !14
  %431 = load i32, ptr %8, align 4, !tbaa !16
  %432 = add nsw i32 %431, 1
  %433 = sext i32 %432 to i64
  %434 = getelementptr inbounds double, ptr %430, i64 %433
  %435 = load double, ptr %434, align 8, !tbaa !9
  store double %435, ptr %15, align 8, !tbaa !9
  %436 = load ptr, ptr %6, align 8, !tbaa !14
  %437 = load i32, ptr %10, align 4, !tbaa !16
  %438 = sext i32 %437 to i64
  %439 = getelementptr inbounds double, ptr %436, i64 %438
  %440 = load double, ptr %439, align 8, !tbaa !9
  store double %440, ptr %16, align 8, !tbaa !9
  %441 = load ptr, ptr %6, align 8, !tbaa !14
  %442 = load i32, ptr %10, align 4, !tbaa !16
  %443 = add nsw i32 %442, 1
  %444 = sext i32 %443 to i64
  %445 = getelementptr inbounds double, ptr %441, i64 %444
  %446 = load double, ptr %445, align 8, !tbaa !9
  store double %446, ptr %17, align 8, !tbaa !9
  %447 = load double, ptr %16, align 8, !tbaa !9
  %448 = load ptr, ptr %6, align 8, !tbaa !14
  %449 = load i32, ptr %8, align 4, !tbaa !16
  %450 = sext i32 %449 to i64
  %451 = getelementptr inbounds double, ptr %448, i64 %450
  store double %447, ptr %451, align 8, !tbaa !9
  %452 = load double, ptr %17, align 8, !tbaa !9
  %453 = load ptr, ptr %6, align 8, !tbaa !14
  %454 = load i32, ptr %8, align 4, !tbaa !16
  %455 = add nsw i32 %454, 1
  %456 = sext i32 %455 to i64
  %457 = getelementptr inbounds double, ptr %453, i64 %456
  store double %452, ptr %457, align 8, !tbaa !9
  %458 = load double, ptr %14, align 8, !tbaa !9
  %459 = load ptr, ptr %6, align 8, !tbaa !14
  %460 = load i32, ptr %10, align 4, !tbaa !16
  %461 = sext i32 %460 to i64
  %462 = getelementptr inbounds double, ptr %459, i64 %461
  store double %458, ptr %462, align 8, !tbaa !9
  %463 = load double, ptr %15, align 8, !tbaa !9
  %464 = load ptr, ptr %6, align 8, !tbaa !14
  %465 = load i32, ptr %10, align 4, !tbaa !16
  %466 = add nsw i32 %465, 1
  %467 = sext i32 %466 to i64
  %468 = getelementptr inbounds double, ptr %464, i64 %467
  store double %463, ptr %468, align 8, !tbaa !9
  br label %469

469:                                              ; preds = %358
  %470 = load i32, ptr %7, align 4, !tbaa !16
  %471 = add nsw i32 %470, 1
  store i32 %471, ptr %7, align 4, !tbaa !16
  br label %354, !llvm.loop !33

472:                                              ; preds = %354
  br label %473

473:                                              ; preds = %472
  %474 = load i32, ptr %9, align 4, !tbaa !16
  %475 = add nsw i32 %474, 1
  store i32 %475, ptr %9, align 4, !tbaa !16
  br label %349, !llvm.loop !34

476:                                              ; preds = %349
  br label %477

477:                                              ; preds = %476, %347
  call void @llvm.lifetime.end.p0(ptr %17) #9
  call void @llvm.lifetime.end.p0(ptr %16) #9
  call void @llvm.lifetime.end.p0(ptr %15) #9
  call void @llvm.lifetime.end.p0(ptr %14) #9
  call void @llvm.lifetime.end.p0(ptr %13) #9
  call void @llvm.lifetime.end.p0(ptr %12) #9
  call void @llvm.lifetime.end.p0(ptr %11) #9
  call void @llvm.lifetime.end.p0(ptr %10) #9
  call void @llvm.lifetime.end.p0(ptr %9) #9
  call void @llvm.lifetime.end.p0(ptr %8) #9
  call void @llvm.lifetime.end.p0(ptr %7) #9
  ret void
}

; Function Attrs: nounwind uwtable
define internal void @cftfsub(i32 noundef %0, ptr noundef %1, ptr noundef %2) #0 {
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  %11 = alloca i32, align 4
  %12 = alloca double, align 8
  %13 = alloca double, align 8
  %14 = alloca double, align 8
  %15 = alloca double, align 8
  %16 = alloca double, align 8
  %17 = alloca double, align 8
  %18 = alloca double, align 8
  %19 = alloca double, align 8
  store i32 %0, ptr %4, align 4, !tbaa !16
  store ptr %1, ptr %5, align 8, !tbaa !14
  store ptr %2, ptr %6, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %7) #9
  call void @llvm.lifetime.start.p0(ptr %8) #9
  call void @llvm.lifetime.start.p0(ptr %9) #9
  call void @llvm.lifetime.start.p0(ptr %10) #9
  call void @llvm.lifetime.start.p0(ptr %11) #9
  call void @llvm.lifetime.start.p0(ptr %12) #9
  call void @llvm.lifetime.start.p0(ptr %13) #9
  call void @llvm.lifetime.start.p0(ptr %14) #9
  call void @llvm.lifetime.start.p0(ptr %15) #9
  call void @llvm.lifetime.start.p0(ptr %16) #9
  call void @llvm.lifetime.start.p0(ptr %17) #9
  call void @llvm.lifetime.start.p0(ptr %18) #9
  call void @llvm.lifetime.start.p0(ptr %19) #9
  store i32 2, ptr %11, align 4, !tbaa !16
  %20 = load i32, ptr %4, align 4, !tbaa !16
  %21 = icmp sgt i32 %20, 8
  br i1 %21, label %22, label %39

22:                                               ; preds = %3
  %23 = load i32, ptr %4, align 4, !tbaa !16
  %24 = load ptr, ptr %5, align 8, !tbaa !14
  %25 = load ptr, ptr %6, align 8, !tbaa !14
  call void @cft1st(i32 noundef %23, ptr noundef %24, ptr noundef %25)
  store i32 8, ptr %11, align 4, !tbaa !16
  br label %26

26:                                               ; preds = %31, %22
  %27 = load i32, ptr %11, align 4, !tbaa !16
  %28 = shl i32 %27, 2
  %29 = load i32, ptr %4, align 4, !tbaa !16
  %30 = icmp slt i32 %28, %29
  br i1 %30, label %31, label %38

31:                                               ; preds = %26
  %32 = load i32, ptr %4, align 4, !tbaa !16
  %33 = load i32, ptr %11, align 4, !tbaa !16
  %34 = load ptr, ptr %5, align 8, !tbaa !14
  %35 = load ptr, ptr %6, align 8, !tbaa !14
  call void @cftmdl(i32 noundef %32, i32 noundef %33, ptr noundef %34, ptr noundef %35)
  %36 = load i32, ptr %11, align 4, !tbaa !16
  %37 = shl i32 %36, 2
  store i32 %37, ptr %11, align 4, !tbaa !16
  br label %26, !llvm.loop !35

38:                                               ; preds = %26
  br label %39

39:                                               ; preds = %38, %3
  %40 = load i32, ptr %11, align 4, !tbaa !16
  %41 = shl i32 %40, 2
  %42 = load i32, ptr %4, align 4, !tbaa !16
  %43 = icmp eq i32 %41, %42
  br i1 %43, label %44, label %219

44:                                               ; preds = %39
  store i32 0, ptr %7, align 4, !tbaa !16
  br label %45

45:                                               ; preds = %215, %44
  %46 = load i32, ptr %7, align 4, !tbaa !16
  %47 = load i32, ptr %11, align 4, !tbaa !16
  %48 = icmp slt i32 %46, %47
  br i1 %48, label %49, label %218

49:                                               ; preds = %45
  %50 = load i32, ptr %7, align 4, !tbaa !16
  %51 = load i32, ptr %11, align 4, !tbaa !16
  %52 = add nsw i32 %50, %51
  store i32 %52, ptr %8, align 4, !tbaa !16
  %53 = load i32, ptr %8, align 4, !tbaa !16
  %54 = load i32, ptr %11, align 4, !tbaa !16
  %55 = add nsw i32 %53, %54
  store i32 %55, ptr %9, align 4, !tbaa !16
  %56 = load i32, ptr %9, align 4, !tbaa !16
  %57 = load i32, ptr %11, align 4, !tbaa !16
  %58 = add nsw i32 %56, %57
  store i32 %58, ptr %10, align 4, !tbaa !16
  %59 = load ptr, ptr %5, align 8, !tbaa !14
  %60 = load i32, ptr %7, align 4, !tbaa !16
  %61 = sext i32 %60 to i64
  %62 = getelementptr inbounds double, ptr %59, i64 %61
  %63 = load double, ptr %62, align 8, !tbaa !9
  %64 = load ptr, ptr %5, align 8, !tbaa !14
  %65 = load i32, ptr %8, align 4, !tbaa !16
  %66 = sext i32 %65 to i64
  %67 = getelementptr inbounds double, ptr %64, i64 %66
  %68 = load double, ptr %67, align 8, !tbaa !9
  %69 = fadd double %63, %68
  store double %69, ptr %12, align 8, !tbaa !9
  %70 = load ptr, ptr %5, align 8, !tbaa !14
  %71 = load i32, ptr %7, align 4, !tbaa !16
  %72 = add nsw i32 %71, 1
  %73 = sext i32 %72 to i64
  %74 = getelementptr inbounds double, ptr %70, i64 %73
  %75 = load double, ptr %74, align 8, !tbaa !9
  %76 = load ptr, ptr %5, align 8, !tbaa !14
  %77 = load i32, ptr %8, align 4, !tbaa !16
  %78 = add nsw i32 %77, 1
  %79 = sext i32 %78 to i64
  %80 = getelementptr inbounds double, ptr %76, i64 %79
  %81 = load double, ptr %80, align 8, !tbaa !9
  %82 = fadd double %75, %81
  store double %82, ptr %13, align 8, !tbaa !9
  %83 = load ptr, ptr %5, align 8, !tbaa !14
  %84 = load i32, ptr %7, align 4, !tbaa !16
  %85 = sext i32 %84 to i64
  %86 = getelementptr inbounds double, ptr %83, i64 %85
  %87 = load double, ptr %86, align 8, !tbaa !9
  %88 = load ptr, ptr %5, align 8, !tbaa !14
  %89 = load i32, ptr %8, align 4, !tbaa !16
  %90 = sext i32 %89 to i64
  %91 = getelementptr inbounds double, ptr %88, i64 %90
  %92 = load double, ptr %91, align 8, !tbaa !9
  %93 = fsub double %87, %92
  store double %93, ptr %14, align 8, !tbaa !9
  %94 = load ptr, ptr %5, align 8, !tbaa !14
  %95 = load i32, ptr %7, align 4, !tbaa !16
  %96 = add nsw i32 %95, 1
  %97 = sext i32 %96 to i64
  %98 = getelementptr inbounds double, ptr %94, i64 %97
  %99 = load double, ptr %98, align 8, !tbaa !9
  %100 = load ptr, ptr %5, align 8, !tbaa !14
  %101 = load i32, ptr %8, align 4, !tbaa !16
  %102 = add nsw i32 %101, 1
  %103 = sext i32 %102 to i64
  %104 = getelementptr inbounds double, ptr %100, i64 %103
  %105 = load double, ptr %104, align 8, !tbaa !9
  %106 = fsub double %99, %105
  store double %106, ptr %15, align 8, !tbaa !9
  %107 = load ptr, ptr %5, align 8, !tbaa !14
  %108 = load i32, ptr %9, align 4, !tbaa !16
  %109 = sext i32 %108 to i64
  %110 = getelementptr inbounds double, ptr %107, i64 %109
  %111 = load double, ptr %110, align 8, !tbaa !9
  %112 = load ptr, ptr %5, align 8, !tbaa !14
  %113 = load i32, ptr %10, align 4, !tbaa !16
  %114 = sext i32 %113 to i64
  %115 = getelementptr inbounds double, ptr %112, i64 %114
  %116 = load double, ptr %115, align 8, !tbaa !9
  %117 = fadd double %111, %116
  store double %117, ptr %16, align 8, !tbaa !9
  %118 = load ptr, ptr %5, align 8, !tbaa !14
  %119 = load i32, ptr %9, align 4, !tbaa !16
  %120 = add nsw i32 %119, 1
  %121 = sext i32 %120 to i64
  %122 = getelementptr inbounds double, ptr %118, i64 %121
  %123 = load double, ptr %122, align 8, !tbaa !9
  %124 = load ptr, ptr %5, align 8, !tbaa !14
  %125 = load i32, ptr %10, align 4, !tbaa !16
  %126 = add nsw i32 %125, 1
  %127 = sext i32 %126 to i64
  %128 = getelementptr inbounds double, ptr %124, i64 %127
  %129 = load double, ptr %128, align 8, !tbaa !9
  %130 = fadd double %123, %129
  store double %130, ptr %17, align 8, !tbaa !9
  %131 = load ptr, ptr %5, align 8, !tbaa !14
  %132 = load i32, ptr %9, align 4, !tbaa !16
  %133 = sext i32 %132 to i64
  %134 = getelementptr inbounds double, ptr %131, i64 %133
  %135 = load double, ptr %134, align 8, !tbaa !9
  %136 = load ptr, ptr %5, align 8, !tbaa !14
  %137 = load i32, ptr %10, align 4, !tbaa !16
  %138 = sext i32 %137 to i64
  %139 = getelementptr inbounds double, ptr %136, i64 %138
  %140 = load double, ptr %139, align 8, !tbaa !9
  %141 = fsub double %135, %140
  store double %141, ptr %18, align 8, !tbaa !9
  %142 = load ptr, ptr %5, align 8, !tbaa !14
  %143 = load i32, ptr %9, align 4, !tbaa !16
  %144 = add nsw i32 %143, 1
  %145 = sext i32 %144 to i64
  %146 = getelementptr inbounds double, ptr %142, i64 %145
  %147 = load double, ptr %146, align 8, !tbaa !9
  %148 = load ptr, ptr %5, align 8, !tbaa !14
  %149 = load i32, ptr %10, align 4, !tbaa !16
  %150 = add nsw i32 %149, 1
  %151 = sext i32 %150 to i64
  %152 = getelementptr inbounds double, ptr %148, i64 %151
  %153 = load double, ptr %152, align 8, !tbaa !9
  %154 = fsub double %147, %153
  store double %154, ptr %19, align 8, !tbaa !9
  %155 = load double, ptr %12, align 8, !tbaa !9
  %156 = load double, ptr %16, align 8, !tbaa !9
  %157 = fadd double %155, %156
  %158 = load ptr, ptr %5, align 8, !tbaa !14
  %159 = load i32, ptr %7, align 4, !tbaa !16
  %160 = sext i32 %159 to i64
  %161 = getelementptr inbounds double, ptr %158, i64 %160
  store double %157, ptr %161, align 8, !tbaa !9
  %162 = load double, ptr %13, align 8, !tbaa !9
  %163 = load double, ptr %17, align 8, !tbaa !9
  %164 = fadd double %162, %163
  %165 = load ptr, ptr %5, align 8, !tbaa !14
  %166 = load i32, ptr %7, align 4, !tbaa !16
  %167 = add nsw i32 %166, 1
  %168 = sext i32 %167 to i64
  %169 = getelementptr inbounds double, ptr %165, i64 %168
  store double %164, ptr %169, align 8, !tbaa !9
  %170 = load double, ptr %12, align 8, !tbaa !9
  %171 = load double, ptr %16, align 8, !tbaa !9
  %172 = fsub double %170, %171
  %173 = load ptr, ptr %5, align 8, !tbaa !14
  %174 = load i32, ptr %9, align 4, !tbaa !16
  %175 = sext i32 %174 to i64
  %176 = getelementptr inbounds double, ptr %173, i64 %175
  store double %172, ptr %176, align 8, !tbaa !9
  %177 = load double, ptr %13, align 8, !tbaa !9
  %178 = load double, ptr %17, align 8, !tbaa !9
  %179 = fsub double %177, %178
  %180 = load ptr, ptr %5, align 8, !tbaa !14
  %181 = load i32, ptr %9, align 4, !tbaa !16
  %182 = add nsw i32 %181, 1
  %183 = sext i32 %182 to i64
  %184 = getelementptr inbounds double, ptr %180, i64 %183
  store double %179, ptr %184, align 8, !tbaa !9
  %185 = load double, ptr %14, align 8, !tbaa !9
  %186 = load double, ptr %19, align 8, !tbaa !9
  %187 = fsub double %185, %186
  %188 = load ptr, ptr %5, align 8, !tbaa !14
  %189 = load i32, ptr %8, align 4, !tbaa !16
  %190 = sext i32 %189 to i64
  %191 = getelementptr inbounds double, ptr %188, i64 %190
  store double %187, ptr %191, align 8, !tbaa !9
  %192 = load double, ptr %15, align 8, !tbaa !9
  %193 = load double, ptr %18, align 8, !tbaa !9
  %194 = fadd double %192, %193
  %195 = load ptr, ptr %5, align 8, !tbaa !14
  %196 = load i32, ptr %8, align 4, !tbaa !16
  %197 = add nsw i32 %196, 1
  %198 = sext i32 %197 to i64
  %199 = getelementptr inbounds double, ptr %195, i64 %198
  store double %194, ptr %199, align 8, !tbaa !9
  %200 = load double, ptr %14, align 8, !tbaa !9
  %201 = load double, ptr %19, align 8, !tbaa !9
  %202 = fadd double %200, %201
  %203 = load ptr, ptr %5, align 8, !tbaa !14
  %204 = load i32, ptr %10, align 4, !tbaa !16
  %205 = sext i32 %204 to i64
  %206 = getelementptr inbounds double, ptr %203, i64 %205
  store double %202, ptr %206, align 8, !tbaa !9
  %207 = load double, ptr %15, align 8, !tbaa !9
  %208 = load double, ptr %18, align 8, !tbaa !9
  %209 = fsub double %207, %208
  %210 = load ptr, ptr %5, align 8, !tbaa !14
  %211 = load i32, ptr %10, align 4, !tbaa !16
  %212 = add nsw i32 %211, 1
  %213 = sext i32 %212 to i64
  %214 = getelementptr inbounds double, ptr %210, i64 %213
  store double %209, ptr %214, align 8, !tbaa !9
  br label %215

215:                                              ; preds = %49
  %216 = load i32, ptr %7, align 4, !tbaa !16
  %217 = add nsw i32 %216, 2
  store i32 %217, ptr %7, align 4, !tbaa !16
  br label %45, !llvm.loop !36

218:                                              ; preds = %45
  br label %291

219:                                              ; preds = %39
  store i32 0, ptr %7, align 4, !tbaa !16
  br label %220

220:                                              ; preds = %287, %219
  %221 = load i32, ptr %7, align 4, !tbaa !16
  %222 = load i32, ptr %11, align 4, !tbaa !16
  %223 = icmp slt i32 %221, %222
  br i1 %223, label %224, label %290

224:                                              ; preds = %220
  %225 = load i32, ptr %7, align 4, !tbaa !16
  %226 = load i32, ptr %11, align 4, !tbaa !16
  %227 = add nsw i32 %225, %226
  store i32 %227, ptr %8, align 4, !tbaa !16
  %228 = load ptr, ptr %5, align 8, !tbaa !14
  %229 = load i32, ptr %7, align 4, !tbaa !16
  %230 = sext i32 %229 to i64
  %231 = getelementptr inbounds double, ptr %228, i64 %230
  %232 = load double, ptr %231, align 8, !tbaa !9
  %233 = load ptr, ptr %5, align 8, !tbaa !14
  %234 = load i32, ptr %8, align 4, !tbaa !16
  %235 = sext i32 %234 to i64
  %236 = getelementptr inbounds double, ptr %233, i64 %235
  %237 = load double, ptr %236, align 8, !tbaa !9
  %238 = fsub double %232, %237
  store double %238, ptr %12, align 8, !tbaa !9
  %239 = load ptr, ptr %5, align 8, !tbaa !14
  %240 = load i32, ptr %7, align 4, !tbaa !16
  %241 = add nsw i32 %240, 1
  %242 = sext i32 %241 to i64
  %243 = getelementptr inbounds double, ptr %239, i64 %242
  %244 = load double, ptr %243, align 8, !tbaa !9
  %245 = load ptr, ptr %5, align 8, !tbaa !14
  %246 = load i32, ptr %8, align 4, !tbaa !16
  %247 = add nsw i32 %246, 1
  %248 = sext i32 %247 to i64
  %249 = getelementptr inbounds double, ptr %245, i64 %248
  %250 = load double, ptr %249, align 8, !tbaa !9
  %251 = fsub double %244, %250
  store double %251, ptr %13, align 8, !tbaa !9
  %252 = load ptr, ptr %5, align 8, !tbaa !14
  %253 = load i32, ptr %8, align 4, !tbaa !16
  %254 = sext i32 %253 to i64
  %255 = getelementptr inbounds double, ptr %252, i64 %254
  %256 = load double, ptr %255, align 8, !tbaa !9
  %257 = load ptr, ptr %5, align 8, !tbaa !14
  %258 = load i32, ptr %7, align 4, !tbaa !16
  %259 = sext i32 %258 to i64
  %260 = getelementptr inbounds double, ptr %257, i64 %259
  %261 = load double, ptr %260, align 8, !tbaa !9
  %262 = fadd double %261, %256
  store double %262, ptr %260, align 8, !tbaa !9
  %263 = load ptr, ptr %5, align 8, !tbaa !14
  %264 = load i32, ptr %8, align 4, !tbaa !16
  %265 = add nsw i32 %264, 1
  %266 = sext i32 %265 to i64
  %267 = getelementptr inbounds double, ptr %263, i64 %266
  %268 = load double, ptr %267, align 8, !tbaa !9
  %269 = load ptr, ptr %5, align 8, !tbaa !14
  %270 = load i32, ptr %7, align 4, !tbaa !16
  %271 = add nsw i32 %270, 1
  %272 = sext i32 %271 to i64
  %273 = getelementptr inbounds double, ptr %269, i64 %272
  %274 = load double, ptr %273, align 8, !tbaa !9
  %275 = fadd double %274, %268
  store double %275, ptr %273, align 8, !tbaa !9
  %276 = load double, ptr %12, align 8, !tbaa !9
  %277 = load ptr, ptr %5, align 8, !tbaa !14
  %278 = load i32, ptr %8, align 4, !tbaa !16
  %279 = sext i32 %278 to i64
  %280 = getelementptr inbounds double, ptr %277, i64 %279
  store double %276, ptr %280, align 8, !tbaa !9
  %281 = load double, ptr %13, align 8, !tbaa !9
  %282 = load ptr, ptr %5, align 8, !tbaa !14
  %283 = load i32, ptr %8, align 4, !tbaa !16
  %284 = add nsw i32 %283, 1
  %285 = sext i32 %284 to i64
  %286 = getelementptr inbounds double, ptr %282, i64 %285
  store double %281, ptr %286, align 8, !tbaa !9
  br label %287

287:                                              ; preds = %224
  %288 = load i32, ptr %7, align 4, !tbaa !16
  %289 = add nsw i32 %288, 2
  store i32 %289, ptr %7, align 4, !tbaa !16
  br label %220, !llvm.loop !37

290:                                              ; preds = %220
  br label %291

291:                                              ; preds = %290, %218
  call void @llvm.lifetime.end.p0(ptr %19) #9
  call void @llvm.lifetime.end.p0(ptr %18) #9
  call void @llvm.lifetime.end.p0(ptr %17) #9
  call void @llvm.lifetime.end.p0(ptr %16) #9
  call void @llvm.lifetime.end.p0(ptr %15) #9
  call void @llvm.lifetime.end.p0(ptr %14) #9
  call void @llvm.lifetime.end.p0(ptr %13) #9
  call void @llvm.lifetime.end.p0(ptr %12) #9
  call void @llvm.lifetime.end.p0(ptr %11) #9
  call void @llvm.lifetime.end.p0(ptr %10) #9
  call void @llvm.lifetime.end.p0(ptr %9) #9
  call void @llvm.lifetime.end.p0(ptr %8) #9
  call void @llvm.lifetime.end.p0(ptr %7) #9
  ret void
}

; Function Attrs: nounwind uwtable
define internal void @bitrv2conj(i32 noundef %0, ptr noundef %1, ptr noundef %2) #0 {
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  %11 = alloca i32, align 4
  %12 = alloca i32, align 4
  %13 = alloca i32, align 4
  %14 = alloca double, align 8
  %15 = alloca double, align 8
  %16 = alloca double, align 8
  %17 = alloca double, align 8
  store i32 %0, ptr %4, align 4, !tbaa !16
  store ptr %1, ptr %5, align 8, !tbaa !11
  store ptr %2, ptr %6, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %7) #9
  call void @llvm.lifetime.start.p0(ptr %8) #9
  call void @llvm.lifetime.start.p0(ptr %9) #9
  call void @llvm.lifetime.start.p0(ptr %10) #9
  call void @llvm.lifetime.start.p0(ptr %11) #9
  call void @llvm.lifetime.start.p0(ptr %12) #9
  call void @llvm.lifetime.start.p0(ptr %13) #9
  call void @llvm.lifetime.start.p0(ptr %14) #9
  call void @llvm.lifetime.start.p0(ptr %15) #9
  call void @llvm.lifetime.start.p0(ptr %16) #9
  call void @llvm.lifetime.start.p0(ptr %17) #9
  %18 = load ptr, ptr %5, align 8, !tbaa !11
  %19 = getelementptr inbounds i32, ptr %18, i64 0
  store i32 0, ptr %19, align 4, !tbaa !16
  %20 = load i32, ptr %4, align 4, !tbaa !16
  store i32 %20, ptr %11, align 4, !tbaa !16
  store i32 1, ptr %12, align 4, !tbaa !16
  br label %21

21:                                               ; preds = %50, %3
  %22 = load i32, ptr %12, align 4, !tbaa !16
  %23 = shl i32 %22, 3
  %24 = load i32, ptr %11, align 4, !tbaa !16
  %25 = icmp slt i32 %23, %24
  br i1 %25, label %26, label %53

26:                                               ; preds = %21
  %27 = load i32, ptr %11, align 4, !tbaa !16
  %28 = ashr i32 %27, 1
  store i32 %28, ptr %11, align 4, !tbaa !16
  store i32 0, ptr %7, align 4, !tbaa !16
  br label %29

29:                                               ; preds = %47, %26
  %30 = load i32, ptr %7, align 4, !tbaa !16
  %31 = load i32, ptr %12, align 4, !tbaa !16
  %32 = icmp slt i32 %30, %31
  br i1 %32, label %33, label %50

33:                                               ; preds = %29
  %34 = load ptr, ptr %5, align 8, !tbaa !11
  %35 = load i32, ptr %7, align 4, !tbaa !16
  %36 = sext i32 %35 to i64
  %37 = getelementptr inbounds i32, ptr %34, i64 %36
  %38 = load i32, ptr %37, align 4, !tbaa !16
  %39 = load i32, ptr %11, align 4, !tbaa !16
  %40 = add nsw i32 %38, %39
  %41 = load ptr, ptr %5, align 8, !tbaa !11
  %42 = load i32, ptr %12, align 4, !tbaa !16
  %43 = load i32, ptr %7, align 4, !tbaa !16
  %44 = add nsw i32 %42, %43
  %45 = sext i32 %44 to i64
  %46 = getelementptr inbounds i32, ptr %41, i64 %45
  store i32 %40, ptr %46, align 4, !tbaa !16
  br label %47

47:                                               ; preds = %33
  %48 = load i32, ptr %7, align 4, !tbaa !16
  %49 = add nsw i32 %48, 1
  store i32 %49, ptr %7, align 4, !tbaa !16
  br label %29, !llvm.loop !38

50:                                               ; preds = %29
  %51 = load i32, ptr %12, align 4, !tbaa !16
  %52 = shl i32 %51, 1
  store i32 %52, ptr %12, align 4, !tbaa !16
  br label %21, !llvm.loop !39

53:                                               ; preds = %21
  %54 = load i32, ptr %12, align 4, !tbaa !16
  %55 = mul nsw i32 2, %54
  store i32 %55, ptr %13, align 4, !tbaa !16
  %56 = load i32, ptr %12, align 4, !tbaa !16
  %57 = shl i32 %56, 3
  %58 = load i32, ptr %11, align 4, !tbaa !16
  %59 = icmp eq i32 %57, %58
  br i1 %59, label %60, label %386

60:                                               ; preds = %53
  store i32 0, ptr %9, align 4, !tbaa !16
  br label %61

61:                                               ; preds = %382, %60
  %62 = load i32, ptr %9, align 4, !tbaa !16
  %63 = load i32, ptr %12, align 4, !tbaa !16
  %64 = icmp slt i32 %62, %63
  br i1 %64, label %65, label %385

65:                                               ; preds = %61
  store i32 0, ptr %7, align 4, !tbaa !16
  br label %66

66:                                               ; preds = %291, %65
  %67 = load i32, ptr %7, align 4, !tbaa !16
  %68 = load i32, ptr %9, align 4, !tbaa !16
  %69 = icmp slt i32 %67, %68
  br i1 %69, label %70, label %294

70:                                               ; preds = %66
  %71 = load i32, ptr %7, align 4, !tbaa !16
  %72 = mul nsw i32 2, %71
  %73 = load ptr, ptr %5, align 8, !tbaa !11
  %74 = load i32, ptr %9, align 4, !tbaa !16
  %75 = sext i32 %74 to i64
  %76 = getelementptr inbounds i32, ptr %73, i64 %75
  %77 = load i32, ptr %76, align 4, !tbaa !16
  %78 = add nsw i32 %72, %77
  store i32 %78, ptr %8, align 4, !tbaa !16
  %79 = load i32, ptr %9, align 4, !tbaa !16
  %80 = mul nsw i32 2, %79
  %81 = load ptr, ptr %5, align 8, !tbaa !11
  %82 = load i32, ptr %7, align 4, !tbaa !16
  %83 = sext i32 %82 to i64
  %84 = getelementptr inbounds i32, ptr %81, i64 %83
  %85 = load i32, ptr %84, align 4, !tbaa !16
  %86 = add nsw i32 %80, %85
  store i32 %86, ptr %10, align 4, !tbaa !16
  %87 = load ptr, ptr %6, align 8, !tbaa !14
  %88 = load i32, ptr %8, align 4, !tbaa !16
  %89 = sext i32 %88 to i64
  %90 = getelementptr inbounds double, ptr %87, i64 %89
  %91 = load double, ptr %90, align 8, !tbaa !9
  store double %91, ptr %14, align 8, !tbaa !9
  %92 = load ptr, ptr %6, align 8, !tbaa !14
  %93 = load i32, ptr %8, align 4, !tbaa !16
  %94 = add nsw i32 %93, 1
  %95 = sext i32 %94 to i64
  %96 = getelementptr inbounds double, ptr %92, i64 %95
  %97 = load double, ptr %96, align 8, !tbaa !9
  %98 = fneg double %97
  store double %98, ptr %15, align 8, !tbaa !9
  %99 = load ptr, ptr %6, align 8, !tbaa !14
  %100 = load i32, ptr %10, align 4, !tbaa !16
  %101 = sext i32 %100 to i64
  %102 = getelementptr inbounds double, ptr %99, i64 %101
  %103 = load double, ptr %102, align 8, !tbaa !9
  store double %103, ptr %16, align 8, !tbaa !9
  %104 = load ptr, ptr %6, align 8, !tbaa !14
  %105 = load i32, ptr %10, align 4, !tbaa !16
  %106 = add nsw i32 %105, 1
  %107 = sext i32 %106 to i64
  %108 = getelementptr inbounds double, ptr %104, i64 %107
  %109 = load double, ptr %108, align 8, !tbaa !9
  %110 = fneg double %109
  store double %110, ptr %17, align 8, !tbaa !9
  %111 = load double, ptr %16, align 8, !tbaa !9
  %112 = load ptr, ptr %6, align 8, !tbaa !14
  %113 = load i32, ptr %8, align 4, !tbaa !16
  %114 = sext i32 %113 to i64
  %115 = getelementptr inbounds double, ptr %112, i64 %114
  store double %111, ptr %115, align 8, !tbaa !9
  %116 = load double, ptr %17, align 8, !tbaa !9
  %117 = load ptr, ptr %6, align 8, !tbaa !14
  %118 = load i32, ptr %8, align 4, !tbaa !16
  %119 = add nsw i32 %118, 1
  %120 = sext i32 %119 to i64
  %121 = getelementptr inbounds double, ptr %117, i64 %120
  store double %116, ptr %121, align 8, !tbaa !9
  %122 = load double, ptr %14, align 8, !tbaa !9
  %123 = load ptr, ptr %6, align 8, !tbaa !14
  %124 = load i32, ptr %10, align 4, !tbaa !16
  %125 = sext i32 %124 to i64
  %126 = getelementptr inbounds double, ptr %123, i64 %125
  store double %122, ptr %126, align 8, !tbaa !9
  %127 = load double, ptr %15, align 8, !tbaa !9
  %128 = load ptr, ptr %6, align 8, !tbaa !14
  %129 = load i32, ptr %10, align 4, !tbaa !16
  %130 = add nsw i32 %129, 1
  %131 = sext i32 %130 to i64
  %132 = getelementptr inbounds double, ptr %128, i64 %131
  store double %127, ptr %132, align 8, !tbaa !9
  %133 = load i32, ptr %13, align 4, !tbaa !16
  %134 = load i32, ptr %8, align 4, !tbaa !16
  %135 = add nsw i32 %134, %133
  store i32 %135, ptr %8, align 4, !tbaa !16
  %136 = load i32, ptr %13, align 4, !tbaa !16
  %137 = mul nsw i32 2, %136
  %138 = load i32, ptr %10, align 4, !tbaa !16
  %139 = add nsw i32 %138, %137
  store i32 %139, ptr %10, align 4, !tbaa !16
  %140 = load ptr, ptr %6, align 8, !tbaa !14
  %141 = load i32, ptr %8, align 4, !tbaa !16
  %142 = sext i32 %141 to i64
  %143 = getelementptr inbounds double, ptr %140, i64 %142
  %144 = load double, ptr %143, align 8, !tbaa !9
  store double %144, ptr %14, align 8, !tbaa !9
  %145 = load ptr, ptr %6, align 8, !tbaa !14
  %146 = load i32, ptr %8, align 4, !tbaa !16
  %147 = add nsw i32 %146, 1
  %148 = sext i32 %147 to i64
  %149 = getelementptr inbounds double, ptr %145, i64 %148
  %150 = load double, ptr %149, align 8, !tbaa !9
  %151 = fneg double %150
  store double %151, ptr %15, align 8, !tbaa !9
  %152 = load ptr, ptr %6, align 8, !tbaa !14
  %153 = load i32, ptr %10, align 4, !tbaa !16
  %154 = sext i32 %153 to i64
  %155 = getelementptr inbounds double, ptr %152, i64 %154
  %156 = load double, ptr %155, align 8, !tbaa !9
  store double %156, ptr %16, align 8, !tbaa !9
  %157 = load ptr, ptr %6, align 8, !tbaa !14
  %158 = load i32, ptr %10, align 4, !tbaa !16
  %159 = add nsw i32 %158, 1
  %160 = sext i32 %159 to i64
  %161 = getelementptr inbounds double, ptr %157, i64 %160
  %162 = load double, ptr %161, align 8, !tbaa !9
  %163 = fneg double %162
  store double %163, ptr %17, align 8, !tbaa !9
  %164 = load double, ptr %16, align 8, !tbaa !9
  %165 = load ptr, ptr %6, align 8, !tbaa !14
  %166 = load i32, ptr %8, align 4, !tbaa !16
  %167 = sext i32 %166 to i64
  %168 = getelementptr inbounds double, ptr %165, i64 %167
  store double %164, ptr %168, align 8, !tbaa !9
  %169 = load double, ptr %17, align 8, !tbaa !9
  %170 = load ptr, ptr %6, align 8, !tbaa !14
  %171 = load i32, ptr %8, align 4, !tbaa !16
  %172 = add nsw i32 %171, 1
  %173 = sext i32 %172 to i64
  %174 = getelementptr inbounds double, ptr %170, i64 %173
  store double %169, ptr %174, align 8, !tbaa !9
  %175 = load double, ptr %14, align 8, !tbaa !9
  %176 = load ptr, ptr %6, align 8, !tbaa !14
  %177 = load i32, ptr %10, align 4, !tbaa !16
  %178 = sext i32 %177 to i64
  %179 = getelementptr inbounds double, ptr %176, i64 %178
  store double %175, ptr %179, align 8, !tbaa !9
  %180 = load double, ptr %15, align 8, !tbaa !9
  %181 = load ptr, ptr %6, align 8, !tbaa !14
  %182 = load i32, ptr %10, align 4, !tbaa !16
  %183 = add nsw i32 %182, 1
  %184 = sext i32 %183 to i64
  %185 = getelementptr inbounds double, ptr %181, i64 %184
  store double %180, ptr %185, align 8, !tbaa !9
  %186 = load i32, ptr %13, align 4, !tbaa !16
  %187 = load i32, ptr %8, align 4, !tbaa !16
  %188 = add nsw i32 %187, %186
  store i32 %188, ptr %8, align 4, !tbaa !16
  %189 = load i32, ptr %13, align 4, !tbaa !16
  %190 = load i32, ptr %10, align 4, !tbaa !16
  %191 = sub nsw i32 %190, %189
  store i32 %191, ptr %10, align 4, !tbaa !16
  %192 = load ptr, ptr %6, align 8, !tbaa !14
  %193 = load i32, ptr %8, align 4, !tbaa !16
  %194 = sext i32 %193 to i64
  %195 = getelementptr inbounds double, ptr %192, i64 %194
  %196 = load double, ptr %195, align 8, !tbaa !9
  store double %196, ptr %14, align 8, !tbaa !9
  %197 = load ptr, ptr %6, align 8, !tbaa !14
  %198 = load i32, ptr %8, align 4, !tbaa !16
  %199 = add nsw i32 %198, 1
  %200 = sext i32 %199 to i64
  %201 = getelementptr inbounds double, ptr %197, i64 %200
  %202 = load double, ptr %201, align 8, !tbaa !9
  %203 = fneg double %202
  store double %203, ptr %15, align 8, !tbaa !9
  %204 = load ptr, ptr %6, align 8, !tbaa !14
  %205 = load i32, ptr %10, align 4, !tbaa !16
  %206 = sext i32 %205 to i64
  %207 = getelementptr inbounds double, ptr %204, i64 %206
  %208 = load double, ptr %207, align 8, !tbaa !9
  store double %208, ptr %16, align 8, !tbaa !9
  %209 = load ptr, ptr %6, align 8, !tbaa !14
  %210 = load i32, ptr %10, align 4, !tbaa !16
  %211 = add nsw i32 %210, 1
  %212 = sext i32 %211 to i64
  %213 = getelementptr inbounds double, ptr %209, i64 %212
  %214 = load double, ptr %213, align 8, !tbaa !9
  %215 = fneg double %214
  store double %215, ptr %17, align 8, !tbaa !9
  %216 = load double, ptr %16, align 8, !tbaa !9
  %217 = load ptr, ptr %6, align 8, !tbaa !14
  %218 = load i32, ptr %8, align 4, !tbaa !16
  %219 = sext i32 %218 to i64
  %220 = getelementptr inbounds double, ptr %217, i64 %219
  store double %216, ptr %220, align 8, !tbaa !9
  %221 = load double, ptr %17, align 8, !tbaa !9
  %222 = load ptr, ptr %6, align 8, !tbaa !14
  %223 = load i32, ptr %8, align 4, !tbaa !16
  %224 = add nsw i32 %223, 1
  %225 = sext i32 %224 to i64
  %226 = getelementptr inbounds double, ptr %222, i64 %225
  store double %221, ptr %226, align 8, !tbaa !9
  %227 = load double, ptr %14, align 8, !tbaa !9
  %228 = load ptr, ptr %6, align 8, !tbaa !14
  %229 = load i32, ptr %10, align 4, !tbaa !16
  %230 = sext i32 %229 to i64
  %231 = getelementptr inbounds double, ptr %228, i64 %230
  store double %227, ptr %231, align 8, !tbaa !9
  %232 = load double, ptr %15, align 8, !tbaa !9
  %233 = load ptr, ptr %6, align 8, !tbaa !14
  %234 = load i32, ptr %10, align 4, !tbaa !16
  %235 = add nsw i32 %234, 1
  %236 = sext i32 %235 to i64
  %237 = getelementptr inbounds double, ptr %233, i64 %236
  store double %232, ptr %237, align 8, !tbaa !9
  %238 = load i32, ptr %13, align 4, !tbaa !16
  %239 = load i32, ptr %8, align 4, !tbaa !16
  %240 = add nsw i32 %239, %238
  store i32 %240, ptr %8, align 4, !tbaa !16
  %241 = load i32, ptr %13, align 4, !tbaa !16
  %242 = mul nsw i32 2, %241
  %243 = load i32, ptr %10, align 4, !tbaa !16
  %244 = add nsw i32 %243, %242
  store i32 %244, ptr %10, align 4, !tbaa !16
  %245 = load ptr, ptr %6, align 8, !tbaa !14
  %246 = load i32, ptr %8, align 4, !tbaa !16
  %247 = sext i32 %246 to i64
  %248 = getelementptr inbounds double, ptr %245, i64 %247
  %249 = load double, ptr %248, align 8, !tbaa !9
  store double %249, ptr %14, align 8, !tbaa !9
  %250 = load ptr, ptr %6, align 8, !tbaa !14
  %251 = load i32, ptr %8, align 4, !tbaa !16
  %252 = add nsw i32 %251, 1
  %253 = sext i32 %252 to i64
  %254 = getelementptr inbounds double, ptr %250, i64 %253
  %255 = load double, ptr %254, align 8, !tbaa !9
  %256 = fneg double %255
  store double %256, ptr %15, align 8, !tbaa !9
  %257 = load ptr, ptr %6, align 8, !tbaa !14
  %258 = load i32, ptr %10, align 4, !tbaa !16
  %259 = sext i32 %258 to i64
  %260 = getelementptr inbounds double, ptr %257, i64 %259
  %261 = load double, ptr %260, align 8, !tbaa !9
  store double %261, ptr %16, align 8, !tbaa !9
  %262 = load ptr, ptr %6, align 8, !tbaa !14
  %263 = load i32, ptr %10, align 4, !tbaa !16
  %264 = add nsw i32 %263, 1
  %265 = sext i32 %264 to i64
  %266 = getelementptr inbounds double, ptr %262, i64 %265
  %267 = load double, ptr %266, align 8, !tbaa !9
  %268 = fneg double %267
  store double %268, ptr %17, align 8, !tbaa !9
  %269 = load double, ptr %16, align 8, !tbaa !9
  %270 = load ptr, ptr %6, align 8, !tbaa !14
  %271 = load i32, ptr %8, align 4, !tbaa !16
  %272 = sext i32 %271 to i64
  %273 = getelementptr inbounds double, ptr %270, i64 %272
  store double %269, ptr %273, align 8, !tbaa !9
  %274 = load double, ptr %17, align 8, !tbaa !9
  %275 = load ptr, ptr %6, align 8, !tbaa !14
  %276 = load i32, ptr %8, align 4, !tbaa !16
  %277 = add nsw i32 %276, 1
  %278 = sext i32 %277 to i64
  %279 = getelementptr inbounds double, ptr %275, i64 %278
  store double %274, ptr %279, align 8, !tbaa !9
  %280 = load double, ptr %14, align 8, !tbaa !9
  %281 = load ptr, ptr %6, align 8, !tbaa !14
  %282 = load i32, ptr %10, align 4, !tbaa !16
  %283 = sext i32 %282 to i64
  %284 = getelementptr inbounds double, ptr %281, i64 %283
  store double %280, ptr %284, align 8, !tbaa !9
  %285 = load double, ptr %15, align 8, !tbaa !9
  %286 = load ptr, ptr %6, align 8, !tbaa !14
  %287 = load i32, ptr %10, align 4, !tbaa !16
  %288 = add nsw i32 %287, 1
  %289 = sext i32 %288 to i64
  %290 = getelementptr inbounds double, ptr %286, i64 %289
  store double %285, ptr %290, align 8, !tbaa !9
  br label %291

291:                                              ; preds = %70
  %292 = load i32, ptr %7, align 4, !tbaa !16
  %293 = add nsw i32 %292, 1
  store i32 %293, ptr %7, align 4, !tbaa !16
  br label %66, !llvm.loop !40

294:                                              ; preds = %66
  %295 = load i32, ptr %9, align 4, !tbaa !16
  %296 = mul nsw i32 2, %295
  %297 = load ptr, ptr %5, align 8, !tbaa !11
  %298 = load i32, ptr %9, align 4, !tbaa !16
  %299 = sext i32 %298 to i64
  %300 = getelementptr inbounds i32, ptr %297, i64 %299
  %301 = load i32, ptr %300, align 4, !tbaa !16
  %302 = add nsw i32 %296, %301
  store i32 %302, ptr %10, align 4, !tbaa !16
  %303 = load ptr, ptr %6, align 8, !tbaa !14
  %304 = load i32, ptr %10, align 4, !tbaa !16
  %305 = add nsw i32 %304, 1
  %306 = sext i32 %305 to i64
  %307 = getelementptr inbounds double, ptr %303, i64 %306
  %308 = load double, ptr %307, align 8, !tbaa !9
  %309 = fneg double %308
  %310 = load ptr, ptr %6, align 8, !tbaa !14
  %311 = load i32, ptr %10, align 4, !tbaa !16
  %312 = add nsw i32 %311, 1
  %313 = sext i32 %312 to i64
  %314 = getelementptr inbounds double, ptr %310, i64 %313
  store double %309, ptr %314, align 8, !tbaa !9
  %315 = load i32, ptr %10, align 4, !tbaa !16
  %316 = load i32, ptr %13, align 4, !tbaa !16
  %317 = add nsw i32 %315, %316
  store i32 %317, ptr %8, align 4, !tbaa !16
  %318 = load i32, ptr %8, align 4, !tbaa !16
  %319 = load i32, ptr %13, align 4, !tbaa !16
  %320 = add nsw i32 %318, %319
  store i32 %320, ptr %10, align 4, !tbaa !16
  %321 = load ptr, ptr %6, align 8, !tbaa !14
  %322 = load i32, ptr %8, align 4, !tbaa !16
  %323 = sext i32 %322 to i64
  %324 = getelementptr inbounds double, ptr %321, i64 %323
  %325 = load double, ptr %324, align 8, !tbaa !9
  store double %325, ptr %14, align 8, !tbaa !9
  %326 = load ptr, ptr %6, align 8, !tbaa !14
  %327 = load i32, ptr %8, align 4, !tbaa !16
  %328 = add nsw i32 %327, 1
  %329 = sext i32 %328 to i64
  %330 = getelementptr inbounds double, ptr %326, i64 %329
  %331 = load double, ptr %330, align 8, !tbaa !9
  %332 = fneg double %331
  store double %332, ptr %15, align 8, !tbaa !9
  %333 = load ptr, ptr %6, align 8, !tbaa !14
  %334 = load i32, ptr %10, align 4, !tbaa !16
  %335 = sext i32 %334 to i64
  %336 = getelementptr inbounds double, ptr %333, i64 %335
  %337 = load double, ptr %336, align 8, !tbaa !9
  store double %337, ptr %16, align 8, !tbaa !9
  %338 = load ptr, ptr %6, align 8, !tbaa !14
  %339 = load i32, ptr %10, align 4, !tbaa !16
  %340 = add nsw i32 %339, 1
  %341 = sext i32 %340 to i64
  %342 = getelementptr inbounds double, ptr %338, i64 %341
  %343 = load double, ptr %342, align 8, !tbaa !9
  %344 = fneg double %343
  store double %344, ptr %17, align 8, !tbaa !9
  %345 = load double, ptr %16, align 8, !tbaa !9
  %346 = load ptr, ptr %6, align 8, !tbaa !14
  %347 = load i32, ptr %8, align 4, !tbaa !16
  %348 = sext i32 %347 to i64
  %349 = getelementptr inbounds double, ptr %346, i64 %348
  store double %345, ptr %349, align 8, !tbaa !9
  %350 = load double, ptr %17, align 8, !tbaa !9
  %351 = load ptr, ptr %6, align 8, !tbaa !14
  %352 = load i32, ptr %8, align 4, !tbaa !16
  %353 = add nsw i32 %352, 1
  %354 = sext i32 %353 to i64
  %355 = getelementptr inbounds double, ptr %351, i64 %354
  store double %350, ptr %355, align 8, !tbaa !9
  %356 = load double, ptr %14, align 8, !tbaa !9
  %357 = load ptr, ptr %6, align 8, !tbaa !14
  %358 = load i32, ptr %10, align 4, !tbaa !16
  %359 = sext i32 %358 to i64
  %360 = getelementptr inbounds double, ptr %357, i64 %359
  store double %356, ptr %360, align 8, !tbaa !9
  %361 = load double, ptr %15, align 8, !tbaa !9
  %362 = load ptr, ptr %6, align 8, !tbaa !14
  %363 = load i32, ptr %10, align 4, !tbaa !16
  %364 = add nsw i32 %363, 1
  %365 = sext i32 %364 to i64
  %366 = getelementptr inbounds double, ptr %362, i64 %365
  store double %361, ptr %366, align 8, !tbaa !9
  %367 = load i32, ptr %13, align 4, !tbaa !16
  %368 = load i32, ptr %10, align 4, !tbaa !16
  %369 = add nsw i32 %368, %367
  store i32 %369, ptr %10, align 4, !tbaa !16
  %370 = load ptr, ptr %6, align 8, !tbaa !14
  %371 = load i32, ptr %10, align 4, !tbaa !16
  %372 = add nsw i32 %371, 1
  %373 = sext i32 %372 to i64
  %374 = getelementptr inbounds double, ptr %370, i64 %373
  %375 = load double, ptr %374, align 8, !tbaa !9
  %376 = fneg double %375
  %377 = load ptr, ptr %6, align 8, !tbaa !14
  %378 = load i32, ptr %10, align 4, !tbaa !16
  %379 = add nsw i32 %378, 1
  %380 = sext i32 %379 to i64
  %381 = getelementptr inbounds double, ptr %377, i64 %380
  store double %376, ptr %381, align 8, !tbaa !9
  br label %382

382:                                              ; preds = %294
  %383 = load i32, ptr %9, align 4, !tbaa !16
  %384 = add nsw i32 %383, 1
  store i32 %384, ptr %9, align 4, !tbaa !16
  br label %61, !llvm.loop !41

385:                                              ; preds = %61
  br label %573

386:                                              ; preds = %53
  %387 = load ptr, ptr %6, align 8, !tbaa !14
  %388 = getelementptr inbounds double, ptr %387, i64 1
  %389 = load double, ptr %388, align 8, !tbaa !9
  %390 = fneg double %389
  %391 = load ptr, ptr %6, align 8, !tbaa !14
  %392 = getelementptr inbounds double, ptr %391, i64 1
  store double %390, ptr %392, align 8, !tbaa !9
  %393 = load ptr, ptr %6, align 8, !tbaa !14
  %394 = load i32, ptr %13, align 4, !tbaa !16
  %395 = add nsw i32 %394, 1
  %396 = sext i32 %395 to i64
  %397 = getelementptr inbounds double, ptr %393, i64 %396
  %398 = load double, ptr %397, align 8, !tbaa !9
  %399 = fneg double %398
  %400 = load ptr, ptr %6, align 8, !tbaa !14
  %401 = load i32, ptr %13, align 4, !tbaa !16
  %402 = add nsw i32 %401, 1
  %403 = sext i32 %402 to i64
  %404 = getelementptr inbounds double, ptr %400, i64 %403
  store double %399, ptr %404, align 8, !tbaa !9
  store i32 1, ptr %9, align 4, !tbaa !16
  br label %405

405:                                              ; preds = %569, %386
  %406 = load i32, ptr %9, align 4, !tbaa !16
  %407 = load i32, ptr %12, align 4, !tbaa !16
  %408 = icmp slt i32 %406, %407
  br i1 %408, label %409, label %572

409:                                              ; preds = %405
  store i32 0, ptr %7, align 4, !tbaa !16
  br label %410

410:                                              ; preds = %529, %409
  %411 = load i32, ptr %7, align 4, !tbaa !16
  %412 = load i32, ptr %9, align 4, !tbaa !16
  %413 = icmp slt i32 %411, %412
  br i1 %413, label %414, label %532

414:                                              ; preds = %410
  %415 = load i32, ptr %7, align 4, !tbaa !16
  %416 = mul nsw i32 2, %415
  %417 = load ptr, ptr %5, align 8, !tbaa !11
  %418 = load i32, ptr %9, align 4, !tbaa !16
  %419 = sext i32 %418 to i64
  %420 = getelementptr inbounds i32, ptr %417, i64 %419
  %421 = load i32, ptr %420, align 4, !tbaa !16
  %422 = add nsw i32 %416, %421
  store i32 %422, ptr %8, align 4, !tbaa !16
  %423 = load i32, ptr %9, align 4, !tbaa !16
  %424 = mul nsw i32 2, %423
  %425 = load ptr, ptr %5, align 8, !tbaa !11
  %426 = load i32, ptr %7, align 4, !tbaa !16
  %427 = sext i32 %426 to i64
  %428 = getelementptr inbounds i32, ptr %425, i64 %427
  %429 = load i32, ptr %428, align 4, !tbaa !16
  %430 = add nsw i32 %424, %429
  store i32 %430, ptr %10, align 4, !tbaa !16
  %431 = load ptr, ptr %6, align 8, !tbaa !14
  %432 = load i32, ptr %8, align 4, !tbaa !16
  %433 = sext i32 %432 to i64
  %434 = getelementptr inbounds double, ptr %431, i64 %433
  %435 = load double, ptr %434, align 8, !tbaa !9
  store double %435, ptr %14, align 8, !tbaa !9
  %436 = load ptr, ptr %6, align 8, !tbaa !14
  %437 = load i32, ptr %8, align 4, !tbaa !16
  %438 = add nsw i32 %437, 1
  %439 = sext i32 %438 to i64
  %440 = getelementptr inbounds double, ptr %436, i64 %439
  %441 = load double, ptr %440, align 8, !tbaa !9
  %442 = fneg double %441
  store double %442, ptr %15, align 8, !tbaa !9
  %443 = load ptr, ptr %6, align 8, !tbaa !14
  %444 = load i32, ptr %10, align 4, !tbaa !16
  %445 = sext i32 %444 to i64
  %446 = getelementptr inbounds double, ptr %443, i64 %445
  %447 = load double, ptr %446, align 8, !tbaa !9
  store double %447, ptr %16, align 8, !tbaa !9
  %448 = load ptr, ptr %6, align 8, !tbaa !14
  %449 = load i32, ptr %10, align 4, !tbaa !16
  %450 = add nsw i32 %449, 1
  %451 = sext i32 %450 to i64
  %452 = getelementptr inbounds double, ptr %448, i64 %451
  %453 = load double, ptr %452, align 8, !tbaa !9
  %454 = fneg double %453
  store double %454, ptr %17, align 8, !tbaa !9
  %455 = load double, ptr %16, align 8, !tbaa !9
  %456 = load ptr, ptr %6, align 8, !tbaa !14
  %457 = load i32, ptr %8, align 4, !tbaa !16
  %458 = sext i32 %457 to i64
  %459 = getelementptr inbounds double, ptr %456, i64 %458
  store double %455, ptr %459, align 8, !tbaa !9
  %460 = load double, ptr %17, align 8, !tbaa !9
  %461 = load ptr, ptr %6, align 8, !tbaa !14
  %462 = load i32, ptr %8, align 4, !tbaa !16
  %463 = add nsw i32 %462, 1
  %464 = sext i32 %463 to i64
  %465 = getelementptr inbounds double, ptr %461, i64 %464
  store double %460, ptr %465, align 8, !tbaa !9
  %466 = load double, ptr %14, align 8, !tbaa !9
  %467 = load ptr, ptr %6, align 8, !tbaa !14
  %468 = load i32, ptr %10, align 4, !tbaa !16
  %469 = sext i32 %468 to i64
  %470 = getelementptr inbounds double, ptr %467, i64 %469
  store double %466, ptr %470, align 8, !tbaa !9
  %471 = load double, ptr %15, align 8, !tbaa !9
  %472 = load ptr, ptr %6, align 8, !tbaa !14
  %473 = load i32, ptr %10, align 4, !tbaa !16
  %474 = add nsw i32 %473, 1
  %475 = sext i32 %474 to i64
  %476 = getelementptr inbounds double, ptr %472, i64 %475
  store double %471, ptr %476, align 8, !tbaa !9
  %477 = load i32, ptr %13, align 4, !tbaa !16
  %478 = load i32, ptr %8, align 4, !tbaa !16
  %479 = add nsw i32 %478, %477
  store i32 %479, ptr %8, align 4, !tbaa !16
  %480 = load i32, ptr %13, align 4, !tbaa !16
  %481 = load i32, ptr %10, align 4, !tbaa !16
  %482 = add nsw i32 %481, %480
  store i32 %482, ptr %10, align 4, !tbaa !16
  %483 = load ptr, ptr %6, align 8, !tbaa !14
  %484 = load i32, ptr %8, align 4, !tbaa !16
  %485 = sext i32 %484 to i64
  %486 = getelementptr inbounds double, ptr %483, i64 %485
  %487 = load double, ptr %486, align 8, !tbaa !9
  store double %487, ptr %14, align 8, !tbaa !9
  %488 = load ptr, ptr %6, align 8, !tbaa !14
  %489 = load i32, ptr %8, align 4, !tbaa !16
  %490 = add nsw i32 %489, 1
  %491 = sext i32 %490 to i64
  %492 = getelementptr inbounds double, ptr %488, i64 %491
  %493 = load double, ptr %492, align 8, !tbaa !9
  %494 = fneg double %493
  store double %494, ptr %15, align 8, !tbaa !9
  %495 = load ptr, ptr %6, align 8, !tbaa !14
  %496 = load i32, ptr %10, align 4, !tbaa !16
  %497 = sext i32 %496 to i64
  %498 = getelementptr inbounds double, ptr %495, i64 %497
  %499 = load double, ptr %498, align 8, !tbaa !9
  store double %499, ptr %16, align 8, !tbaa !9
  %500 = load ptr, ptr %6, align 8, !tbaa !14
  %501 = load i32, ptr %10, align 4, !tbaa !16
  %502 = add nsw i32 %501, 1
  %503 = sext i32 %502 to i64
  %504 = getelementptr inbounds double, ptr %500, i64 %503
  %505 = load double, ptr %504, align 8, !tbaa !9
  %506 = fneg double %505
  store double %506, ptr %17, align 8, !tbaa !9
  %507 = load double, ptr %16, align 8, !tbaa !9
  %508 = load ptr, ptr %6, align 8, !tbaa !14
  %509 = load i32, ptr %8, align 4, !tbaa !16
  %510 = sext i32 %509 to i64
  %511 = getelementptr inbounds double, ptr %508, i64 %510
  store double %507, ptr %511, align 8, !tbaa !9
  %512 = load double, ptr %17, align 8, !tbaa !9
  %513 = load ptr, ptr %6, align 8, !tbaa !14
  %514 = load i32, ptr %8, align 4, !tbaa !16
  %515 = add nsw i32 %514, 1
  %516 = sext i32 %515 to i64
  %517 = getelementptr inbounds double, ptr %513, i64 %516
  store double %512, ptr %517, align 8, !tbaa !9
  %518 = load double, ptr %14, align 8, !tbaa !9
  %519 = load ptr, ptr %6, align 8, !tbaa !14
  %520 = load i32, ptr %10, align 4, !tbaa !16
  %521 = sext i32 %520 to i64
  %522 = getelementptr inbounds double, ptr %519, i64 %521
  store double %518, ptr %522, align 8, !tbaa !9
  %523 = load double, ptr %15, align 8, !tbaa !9
  %524 = load ptr, ptr %6, align 8, !tbaa !14
  %525 = load i32, ptr %10, align 4, !tbaa !16
  %526 = add nsw i32 %525, 1
  %527 = sext i32 %526 to i64
  %528 = getelementptr inbounds double, ptr %524, i64 %527
  store double %523, ptr %528, align 8, !tbaa !9
  br label %529

529:                                              ; preds = %414
  %530 = load i32, ptr %7, align 4, !tbaa !16
  %531 = add nsw i32 %530, 1
  store i32 %531, ptr %7, align 4, !tbaa !16
  br label %410, !llvm.loop !42

532:                                              ; preds = %410
  %533 = load i32, ptr %9, align 4, !tbaa !16
  %534 = mul nsw i32 2, %533
  %535 = load ptr, ptr %5, align 8, !tbaa !11
  %536 = load i32, ptr %9, align 4, !tbaa !16
  %537 = sext i32 %536 to i64
  %538 = getelementptr inbounds i32, ptr %535, i64 %537
  %539 = load i32, ptr %538, align 4, !tbaa !16
  %540 = add nsw i32 %534, %539
  store i32 %540, ptr %10, align 4, !tbaa !16
  %541 = load ptr, ptr %6, align 8, !tbaa !14
  %542 = load i32, ptr %10, align 4, !tbaa !16
  %543 = add nsw i32 %542, 1
  %544 = sext i32 %543 to i64
  %545 = getelementptr inbounds double, ptr %541, i64 %544
  %546 = load double, ptr %545, align 8, !tbaa !9
  %547 = fneg double %546
  %548 = load ptr, ptr %6, align 8, !tbaa !14
  %549 = load i32, ptr %10, align 4, !tbaa !16
  %550 = add nsw i32 %549, 1
  %551 = sext i32 %550 to i64
  %552 = getelementptr inbounds double, ptr %548, i64 %551
  store double %547, ptr %552, align 8, !tbaa !9
  %553 = load ptr, ptr %6, align 8, !tbaa !14
  %554 = load i32, ptr %10, align 4, !tbaa !16
  %555 = load i32, ptr %13, align 4, !tbaa !16
  %556 = add nsw i32 %554, %555
  %557 = add nsw i32 %556, 1
  %558 = sext i32 %557 to i64
  %559 = getelementptr inbounds double, ptr %553, i64 %558
  %560 = load double, ptr %559, align 8, !tbaa !9
  %561 = fneg double %560
  %562 = load ptr, ptr %6, align 8, !tbaa !14
  %563 = load i32, ptr %10, align 4, !tbaa !16
  %564 = load i32, ptr %13, align 4, !tbaa !16
  %565 = add nsw i32 %563, %564
  %566 = add nsw i32 %565, 1
  %567 = sext i32 %566 to i64
  %568 = getelementptr inbounds double, ptr %562, i64 %567
  store double %561, ptr %568, align 8, !tbaa !9
  br label %569

569:                                              ; preds = %532
  %570 = load i32, ptr %9, align 4, !tbaa !16
  %571 = add nsw i32 %570, 1
  store i32 %571, ptr %9, align 4, !tbaa !16
  br label %405, !llvm.loop !43

572:                                              ; preds = %405
  br label %573

573:                                              ; preds = %572, %385
  call void @llvm.lifetime.end.p0(ptr %17) #9
  call void @llvm.lifetime.end.p0(ptr %16) #9
  call void @llvm.lifetime.end.p0(ptr %15) #9
  call void @llvm.lifetime.end.p0(ptr %14) #9
  call void @llvm.lifetime.end.p0(ptr %13) #9
  call void @llvm.lifetime.end.p0(ptr %12) #9
  call void @llvm.lifetime.end.p0(ptr %11) #9
  call void @llvm.lifetime.end.p0(ptr %10) #9
  call void @llvm.lifetime.end.p0(ptr %9) #9
  call void @llvm.lifetime.end.p0(ptr %8) #9
  call void @llvm.lifetime.end.p0(ptr %7) #9
  ret void
}

; Function Attrs: nounwind uwtable
define internal void @cftbsub(i32 noundef %0, ptr noundef %1, ptr noundef %2) #0 {
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  %11 = alloca i32, align 4
  %12 = alloca double, align 8
  %13 = alloca double, align 8
  %14 = alloca double, align 8
  %15 = alloca double, align 8
  %16 = alloca double, align 8
  %17 = alloca double, align 8
  %18 = alloca double, align 8
  %19 = alloca double, align 8
  store i32 %0, ptr %4, align 4, !tbaa !16
  store ptr %1, ptr %5, align 8, !tbaa !14
  store ptr %2, ptr %6, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %7) #9
  call void @llvm.lifetime.start.p0(ptr %8) #9
  call void @llvm.lifetime.start.p0(ptr %9) #9
  call void @llvm.lifetime.start.p0(ptr %10) #9
  call void @llvm.lifetime.start.p0(ptr %11) #9
  call void @llvm.lifetime.start.p0(ptr %12) #9
  call void @llvm.lifetime.start.p0(ptr %13) #9
  call void @llvm.lifetime.start.p0(ptr %14) #9
  call void @llvm.lifetime.start.p0(ptr %15) #9
  call void @llvm.lifetime.start.p0(ptr %16) #9
  call void @llvm.lifetime.start.p0(ptr %17) #9
  call void @llvm.lifetime.start.p0(ptr %18) #9
  call void @llvm.lifetime.start.p0(ptr %19) #9
  store i32 2, ptr %11, align 4, !tbaa !16
  %20 = load i32, ptr %4, align 4, !tbaa !16
  %21 = icmp sgt i32 %20, 8
  br i1 %21, label %22, label %39

22:                                               ; preds = %3
  %23 = load i32, ptr %4, align 4, !tbaa !16
  %24 = load ptr, ptr %5, align 8, !tbaa !14
  %25 = load ptr, ptr %6, align 8, !tbaa !14
  call void @cft1st(i32 noundef %23, ptr noundef %24, ptr noundef %25)
  store i32 8, ptr %11, align 4, !tbaa !16
  br label %26

26:                                               ; preds = %31, %22
  %27 = load i32, ptr %11, align 4, !tbaa !16
  %28 = shl i32 %27, 2
  %29 = load i32, ptr %4, align 4, !tbaa !16
  %30 = icmp slt i32 %28, %29
  br i1 %30, label %31, label %38

31:                                               ; preds = %26
  %32 = load i32, ptr %4, align 4, !tbaa !16
  %33 = load i32, ptr %11, align 4, !tbaa !16
  %34 = load ptr, ptr %5, align 8, !tbaa !14
  %35 = load ptr, ptr %6, align 8, !tbaa !14
  call void @cftmdl(i32 noundef %32, i32 noundef %33, ptr noundef %34, ptr noundef %35)
  %36 = load i32, ptr %11, align 4, !tbaa !16
  %37 = shl i32 %36, 2
  store i32 %37, ptr %11, align 4, !tbaa !16
  br label %26, !llvm.loop !44

38:                                               ; preds = %26
  br label %39

39:                                               ; preds = %38, %3
  %40 = load i32, ptr %11, align 4, !tbaa !16
  %41 = shl i32 %40, 2
  %42 = load i32, ptr %4, align 4, !tbaa !16
  %43 = icmp eq i32 %41, %42
  br i1 %43, label %44, label %221

44:                                               ; preds = %39
  store i32 0, ptr %7, align 4, !tbaa !16
  br label %45

45:                                               ; preds = %217, %44
  %46 = load i32, ptr %7, align 4, !tbaa !16
  %47 = load i32, ptr %11, align 4, !tbaa !16
  %48 = icmp slt i32 %46, %47
  br i1 %48, label %49, label %220

49:                                               ; preds = %45
  %50 = load i32, ptr %7, align 4, !tbaa !16
  %51 = load i32, ptr %11, align 4, !tbaa !16
  %52 = add nsw i32 %50, %51
  store i32 %52, ptr %8, align 4, !tbaa !16
  %53 = load i32, ptr %8, align 4, !tbaa !16
  %54 = load i32, ptr %11, align 4, !tbaa !16
  %55 = add nsw i32 %53, %54
  store i32 %55, ptr %9, align 4, !tbaa !16
  %56 = load i32, ptr %9, align 4, !tbaa !16
  %57 = load i32, ptr %11, align 4, !tbaa !16
  %58 = add nsw i32 %56, %57
  store i32 %58, ptr %10, align 4, !tbaa !16
  %59 = load ptr, ptr %5, align 8, !tbaa !14
  %60 = load i32, ptr %7, align 4, !tbaa !16
  %61 = sext i32 %60 to i64
  %62 = getelementptr inbounds double, ptr %59, i64 %61
  %63 = load double, ptr %62, align 8, !tbaa !9
  %64 = load ptr, ptr %5, align 8, !tbaa !14
  %65 = load i32, ptr %8, align 4, !tbaa !16
  %66 = sext i32 %65 to i64
  %67 = getelementptr inbounds double, ptr %64, i64 %66
  %68 = load double, ptr %67, align 8, !tbaa !9
  %69 = fadd double %63, %68
  store double %69, ptr %12, align 8, !tbaa !9
  %70 = load ptr, ptr %5, align 8, !tbaa !14
  %71 = load i32, ptr %7, align 4, !tbaa !16
  %72 = add nsw i32 %71, 1
  %73 = sext i32 %72 to i64
  %74 = getelementptr inbounds double, ptr %70, i64 %73
  %75 = load double, ptr %74, align 8, !tbaa !9
  %76 = fneg double %75
  %77 = load ptr, ptr %5, align 8, !tbaa !14
  %78 = load i32, ptr %8, align 4, !tbaa !16
  %79 = add nsw i32 %78, 1
  %80 = sext i32 %79 to i64
  %81 = getelementptr inbounds double, ptr %77, i64 %80
  %82 = load double, ptr %81, align 8, !tbaa !9
  %83 = fsub double %76, %82
  store double %83, ptr %13, align 8, !tbaa !9
  %84 = load ptr, ptr %5, align 8, !tbaa !14
  %85 = load i32, ptr %7, align 4, !tbaa !16
  %86 = sext i32 %85 to i64
  %87 = getelementptr inbounds double, ptr %84, i64 %86
  %88 = load double, ptr %87, align 8, !tbaa !9
  %89 = load ptr, ptr %5, align 8, !tbaa !14
  %90 = load i32, ptr %8, align 4, !tbaa !16
  %91 = sext i32 %90 to i64
  %92 = getelementptr inbounds double, ptr %89, i64 %91
  %93 = load double, ptr %92, align 8, !tbaa !9
  %94 = fsub double %88, %93
  store double %94, ptr %14, align 8, !tbaa !9
  %95 = load ptr, ptr %5, align 8, !tbaa !14
  %96 = load i32, ptr %7, align 4, !tbaa !16
  %97 = add nsw i32 %96, 1
  %98 = sext i32 %97 to i64
  %99 = getelementptr inbounds double, ptr %95, i64 %98
  %100 = load double, ptr %99, align 8, !tbaa !9
  %101 = fneg double %100
  %102 = load ptr, ptr %5, align 8, !tbaa !14
  %103 = load i32, ptr %8, align 4, !tbaa !16
  %104 = add nsw i32 %103, 1
  %105 = sext i32 %104 to i64
  %106 = getelementptr inbounds double, ptr %102, i64 %105
  %107 = load double, ptr %106, align 8, !tbaa !9
  %108 = fadd double %101, %107
  store double %108, ptr %15, align 8, !tbaa !9
  %109 = load ptr, ptr %5, align 8, !tbaa !14
  %110 = load i32, ptr %9, align 4, !tbaa !16
  %111 = sext i32 %110 to i64
  %112 = getelementptr inbounds double, ptr %109, i64 %111
  %113 = load double, ptr %112, align 8, !tbaa !9
  %114 = load ptr, ptr %5, align 8, !tbaa !14
  %115 = load i32, ptr %10, align 4, !tbaa !16
  %116 = sext i32 %115 to i64
  %117 = getelementptr inbounds double, ptr %114, i64 %116
  %118 = load double, ptr %117, align 8, !tbaa !9
  %119 = fadd double %113, %118
  store double %119, ptr %16, align 8, !tbaa !9
  %120 = load ptr, ptr %5, align 8, !tbaa !14
  %121 = load i32, ptr %9, align 4, !tbaa !16
  %122 = add nsw i32 %121, 1
  %123 = sext i32 %122 to i64
  %124 = getelementptr inbounds double, ptr %120, i64 %123
  %125 = load double, ptr %124, align 8, !tbaa !9
  %126 = load ptr, ptr %5, align 8, !tbaa !14
  %127 = load i32, ptr %10, align 4, !tbaa !16
  %128 = add nsw i32 %127, 1
  %129 = sext i32 %128 to i64
  %130 = getelementptr inbounds double, ptr %126, i64 %129
  %131 = load double, ptr %130, align 8, !tbaa !9
  %132 = fadd double %125, %131
  store double %132, ptr %17, align 8, !tbaa !9
  %133 = load ptr, ptr %5, align 8, !tbaa !14
  %134 = load i32, ptr %9, align 4, !tbaa !16
  %135 = sext i32 %134 to i64
  %136 = getelementptr inbounds double, ptr %133, i64 %135
  %137 = load double, ptr %136, align 8, !tbaa !9
  %138 = load ptr, ptr %5, align 8, !tbaa !14
  %139 = load i32, ptr %10, align 4, !tbaa !16
  %140 = sext i32 %139 to i64
  %141 = getelementptr inbounds double, ptr %138, i64 %140
  %142 = load double, ptr %141, align 8, !tbaa !9
  %143 = fsub double %137, %142
  store double %143, ptr %18, align 8, !tbaa !9
  %144 = load ptr, ptr %5, align 8, !tbaa !14
  %145 = load i32, ptr %9, align 4, !tbaa !16
  %146 = add nsw i32 %145, 1
  %147 = sext i32 %146 to i64
  %148 = getelementptr inbounds double, ptr %144, i64 %147
  %149 = load double, ptr %148, align 8, !tbaa !9
  %150 = load ptr, ptr %5, align 8, !tbaa !14
  %151 = load i32, ptr %10, align 4, !tbaa !16
  %152 = add nsw i32 %151, 1
  %153 = sext i32 %152 to i64
  %154 = getelementptr inbounds double, ptr %150, i64 %153
  %155 = load double, ptr %154, align 8, !tbaa !9
  %156 = fsub double %149, %155
  store double %156, ptr %19, align 8, !tbaa !9
  %157 = load double, ptr %12, align 8, !tbaa !9
  %158 = load double, ptr %16, align 8, !tbaa !9
  %159 = fadd double %157, %158
  %160 = load ptr, ptr %5, align 8, !tbaa !14
  %161 = load i32, ptr %7, align 4, !tbaa !16
  %162 = sext i32 %161 to i64
  %163 = getelementptr inbounds double, ptr %160, i64 %162
  store double %159, ptr %163, align 8, !tbaa !9
  %164 = load double, ptr %13, align 8, !tbaa !9
  %165 = load double, ptr %17, align 8, !tbaa !9
  %166 = fsub double %164, %165
  %167 = load ptr, ptr %5, align 8, !tbaa !14
  %168 = load i32, ptr %7, align 4, !tbaa !16
  %169 = add nsw i32 %168, 1
  %170 = sext i32 %169 to i64
  %171 = getelementptr inbounds double, ptr %167, i64 %170
  store double %166, ptr %171, align 8, !tbaa !9
  %172 = load double, ptr %12, align 8, !tbaa !9
  %173 = load double, ptr %16, align 8, !tbaa !9
  %174 = fsub double %172, %173
  %175 = load ptr, ptr %5, align 8, !tbaa !14
  %176 = load i32, ptr %9, align 4, !tbaa !16
  %177 = sext i32 %176 to i64
  %178 = getelementptr inbounds double, ptr %175, i64 %177
  store double %174, ptr %178, align 8, !tbaa !9
  %179 = load double, ptr %13, align 8, !tbaa !9
  %180 = load double, ptr %17, align 8, !tbaa !9
  %181 = fadd double %179, %180
  %182 = load ptr, ptr %5, align 8, !tbaa !14
  %183 = load i32, ptr %9, align 4, !tbaa !16
  %184 = add nsw i32 %183, 1
  %185 = sext i32 %184 to i64
  %186 = getelementptr inbounds double, ptr %182, i64 %185
  store double %181, ptr %186, align 8, !tbaa !9
  %187 = load double, ptr %14, align 8, !tbaa !9
  %188 = load double, ptr %19, align 8, !tbaa !9
  %189 = fsub double %187, %188
  %190 = load ptr, ptr %5, align 8, !tbaa !14
  %191 = load i32, ptr %8, align 4, !tbaa !16
  %192 = sext i32 %191 to i64
  %193 = getelementptr inbounds double, ptr %190, i64 %192
  store double %189, ptr %193, align 8, !tbaa !9
  %194 = load double, ptr %15, align 8, !tbaa !9
  %195 = load double, ptr %18, align 8, !tbaa !9
  %196 = fsub double %194, %195
  %197 = load ptr, ptr %5, align 8, !tbaa !14
  %198 = load i32, ptr %8, align 4, !tbaa !16
  %199 = add nsw i32 %198, 1
  %200 = sext i32 %199 to i64
  %201 = getelementptr inbounds double, ptr %197, i64 %200
  store double %196, ptr %201, align 8, !tbaa !9
  %202 = load double, ptr %14, align 8, !tbaa !9
  %203 = load double, ptr %19, align 8, !tbaa !9
  %204 = fadd double %202, %203
  %205 = load ptr, ptr %5, align 8, !tbaa !14
  %206 = load i32, ptr %10, align 4, !tbaa !16
  %207 = sext i32 %206 to i64
  %208 = getelementptr inbounds double, ptr %205, i64 %207
  store double %204, ptr %208, align 8, !tbaa !9
  %209 = load double, ptr %15, align 8, !tbaa !9
  %210 = load double, ptr %18, align 8, !tbaa !9
  %211 = fadd double %209, %210
  %212 = load ptr, ptr %5, align 8, !tbaa !14
  %213 = load i32, ptr %10, align 4, !tbaa !16
  %214 = add nsw i32 %213, 1
  %215 = sext i32 %214 to i64
  %216 = getelementptr inbounds double, ptr %212, i64 %215
  store double %211, ptr %216, align 8, !tbaa !9
  br label %217

217:                                              ; preds = %49
  %218 = load i32, ptr %7, align 4, !tbaa !16
  %219 = add nsw i32 %218, 2
  store i32 %219, ptr %7, align 4, !tbaa !16
  br label %45, !llvm.loop !45

220:                                              ; preds = %45
  br label %300

221:                                              ; preds = %39
  store i32 0, ptr %7, align 4, !tbaa !16
  br label %222

222:                                              ; preds = %296, %221
  %223 = load i32, ptr %7, align 4, !tbaa !16
  %224 = load i32, ptr %11, align 4, !tbaa !16
  %225 = icmp slt i32 %223, %224
  br i1 %225, label %226, label %299

226:                                              ; preds = %222
  %227 = load i32, ptr %7, align 4, !tbaa !16
  %228 = load i32, ptr %11, align 4, !tbaa !16
  %229 = add nsw i32 %227, %228
  store i32 %229, ptr %8, align 4, !tbaa !16
  %230 = load ptr, ptr %5, align 8, !tbaa !14
  %231 = load i32, ptr %7, align 4, !tbaa !16
  %232 = sext i32 %231 to i64
  %233 = getelementptr inbounds double, ptr %230, i64 %232
  %234 = load double, ptr %233, align 8, !tbaa !9
  %235 = load ptr, ptr %5, align 8, !tbaa !14
  %236 = load i32, ptr %8, align 4, !tbaa !16
  %237 = sext i32 %236 to i64
  %238 = getelementptr inbounds double, ptr %235, i64 %237
  %239 = load double, ptr %238, align 8, !tbaa !9
  %240 = fsub double %234, %239
  store double %240, ptr %12, align 8, !tbaa !9
  %241 = load ptr, ptr %5, align 8, !tbaa !14
  %242 = load i32, ptr %7, align 4, !tbaa !16
  %243 = add nsw i32 %242, 1
  %244 = sext i32 %243 to i64
  %245 = getelementptr inbounds double, ptr %241, i64 %244
  %246 = load double, ptr %245, align 8, !tbaa !9
  %247 = fneg double %246
  %248 = load ptr, ptr %5, align 8, !tbaa !14
  %249 = load i32, ptr %8, align 4, !tbaa !16
  %250 = add nsw i32 %249, 1
  %251 = sext i32 %250 to i64
  %252 = getelementptr inbounds double, ptr %248, i64 %251
  %253 = load double, ptr %252, align 8, !tbaa !9
  %254 = fadd double %247, %253
  store double %254, ptr %13, align 8, !tbaa !9
  %255 = load ptr, ptr %5, align 8, !tbaa !14
  %256 = load i32, ptr %8, align 4, !tbaa !16
  %257 = sext i32 %256 to i64
  %258 = getelementptr inbounds double, ptr %255, i64 %257
  %259 = load double, ptr %258, align 8, !tbaa !9
  %260 = load ptr, ptr %5, align 8, !tbaa !14
  %261 = load i32, ptr %7, align 4, !tbaa !16
  %262 = sext i32 %261 to i64
  %263 = getelementptr inbounds double, ptr %260, i64 %262
  %264 = load double, ptr %263, align 8, !tbaa !9
  %265 = fadd double %264, %259
  store double %265, ptr %263, align 8, !tbaa !9
  %266 = load ptr, ptr %5, align 8, !tbaa !14
  %267 = load i32, ptr %7, align 4, !tbaa !16
  %268 = add nsw i32 %267, 1
  %269 = sext i32 %268 to i64
  %270 = getelementptr inbounds double, ptr %266, i64 %269
  %271 = load double, ptr %270, align 8, !tbaa !9
  %272 = fneg double %271
  %273 = load ptr, ptr %5, align 8, !tbaa !14
  %274 = load i32, ptr %8, align 4, !tbaa !16
  %275 = add nsw i32 %274, 1
  %276 = sext i32 %275 to i64
  %277 = getelementptr inbounds double, ptr %273, i64 %276
  %278 = load double, ptr %277, align 8, !tbaa !9
  %279 = fsub double %272, %278
  %280 = load ptr, ptr %5, align 8, !tbaa !14
  %281 = load i32, ptr %7, align 4, !tbaa !16
  %282 = add nsw i32 %281, 1
  %283 = sext i32 %282 to i64
  %284 = getelementptr inbounds double, ptr %280, i64 %283
  store double %279, ptr %284, align 8, !tbaa !9
  %285 = load double, ptr %12, align 8, !tbaa !9
  %286 = load ptr, ptr %5, align 8, !tbaa !14
  %287 = load i32, ptr %8, align 4, !tbaa !16
  %288 = sext i32 %287 to i64
  %289 = getelementptr inbounds double, ptr %286, i64 %288
  store double %285, ptr %289, align 8, !tbaa !9
  %290 = load double, ptr %13, align 8, !tbaa !9
  %291 = load ptr, ptr %5, align 8, !tbaa !14
  %292 = load i32, ptr %8, align 4, !tbaa !16
  %293 = add nsw i32 %292, 1
  %294 = sext i32 %293 to i64
  %295 = getelementptr inbounds double, ptr %291, i64 %294
  store double %290, ptr %295, align 8, !tbaa !9
  br label %296

296:                                              ; preds = %226
  %297 = load i32, ptr %7, align 4, !tbaa !16
  %298 = add nsw i32 %297, 2
  store i32 %298, ptr %7, align 4, !tbaa !16
  br label %222, !llvm.loop !46

299:                                              ; preds = %222
  br label %300

300:                                              ; preds = %299, %220
  call void @llvm.lifetime.end.p0(ptr %19) #9
  call void @llvm.lifetime.end.p0(ptr %18) #9
  call void @llvm.lifetime.end.p0(ptr %17) #9
  call void @llvm.lifetime.end.p0(ptr %16) #9
  call void @llvm.lifetime.end.p0(ptr %15) #9
  call void @llvm.lifetime.end.p0(ptr %14) #9
  call void @llvm.lifetime.end.p0(ptr %13) #9
  call void @llvm.lifetime.end.p0(ptr %12) #9
  call void @llvm.lifetime.end.p0(ptr %11) #9
  call void @llvm.lifetime.end.p0(ptr %10) #9
  call void @llvm.lifetime.end.p0(ptr %9) #9
  call void @llvm.lifetime.end.p0(ptr %8) #9
  call void @llvm.lifetime.end.p0(ptr %7) #9
  ret void
}

; Function Attrs: nounwind
declare double @atan(double noundef) #3

; Function Attrs: nounwind
declare double @cos(double noundef) #3

; Function Attrs: nounwind
declare double @sin(double noundef) #3

; Function Attrs: inlinehint nounwind uwtable
define internal void @cft1st(i32 noundef %0, ptr noundef %1, ptr noundef %2) #8 {
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  %10 = alloca double, align 8
  %11 = alloca double, align 8
  %12 = alloca double, align 8
  %13 = alloca double, align 8
  %14 = alloca double, align 8
  %15 = alloca double, align 8
  %16 = alloca double, align 8
  %17 = alloca double, align 8
  %18 = alloca double, align 8
  %19 = alloca double, align 8
  %20 = alloca double, align 8
  %21 = alloca double, align 8
  %22 = alloca double, align 8
  %23 = alloca double, align 8
  store i32 %0, ptr %4, align 4, !tbaa !16
  store ptr %1, ptr %5, align 8, !tbaa !14
  store ptr %2, ptr %6, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %7) #9
  call void @llvm.lifetime.start.p0(ptr %8) #9
  call void @llvm.lifetime.start.p0(ptr %9) #9
  call void @llvm.lifetime.start.p0(ptr %10) #9
  call void @llvm.lifetime.start.p0(ptr %11) #9
  call void @llvm.lifetime.start.p0(ptr %12) #9
  call void @llvm.lifetime.start.p0(ptr %13) #9
  call void @llvm.lifetime.start.p0(ptr %14) #9
  call void @llvm.lifetime.start.p0(ptr %15) #9
  call void @llvm.lifetime.start.p0(ptr %16) #9
  call void @llvm.lifetime.start.p0(ptr %17) #9
  call void @llvm.lifetime.start.p0(ptr %18) #9
  call void @llvm.lifetime.start.p0(ptr %19) #9
  call void @llvm.lifetime.start.p0(ptr %20) #9
  call void @llvm.lifetime.start.p0(ptr %21) #9
  call void @llvm.lifetime.start.p0(ptr %22) #9
  call void @llvm.lifetime.start.p0(ptr %23) #9
  %24 = load ptr, ptr %5, align 8, !tbaa !14
  %25 = getelementptr inbounds double, ptr %24, i64 0
  %26 = load double, ptr %25, align 8, !tbaa !9
  %27 = load ptr, ptr %5, align 8, !tbaa !14
  %28 = getelementptr inbounds double, ptr %27, i64 2
  %29 = load double, ptr %28, align 8, !tbaa !9
  %30 = fadd double %26, %29
  store double %30, ptr %16, align 8, !tbaa !9
  %31 = load ptr, ptr %5, align 8, !tbaa !14
  %32 = getelementptr inbounds double, ptr %31, i64 1
  %33 = load double, ptr %32, align 8, !tbaa !9
  %34 = load ptr, ptr %5, align 8, !tbaa !14
  %35 = getelementptr inbounds double, ptr %34, i64 3
  %36 = load double, ptr %35, align 8, !tbaa !9
  %37 = fadd double %33, %36
  store double %37, ptr %17, align 8, !tbaa !9
  %38 = load ptr, ptr %5, align 8, !tbaa !14
  %39 = getelementptr inbounds double, ptr %38, i64 0
  %40 = load double, ptr %39, align 8, !tbaa !9
  %41 = load ptr, ptr %5, align 8, !tbaa !14
  %42 = getelementptr inbounds double, ptr %41, i64 2
  %43 = load double, ptr %42, align 8, !tbaa !9
  %44 = fsub double %40, %43
  store double %44, ptr %18, align 8, !tbaa !9
  %45 = load ptr, ptr %5, align 8, !tbaa !14
  %46 = getelementptr inbounds double, ptr %45, i64 1
  %47 = load double, ptr %46, align 8, !tbaa !9
  %48 = load ptr, ptr %5, align 8, !tbaa !14
  %49 = getelementptr inbounds double, ptr %48, i64 3
  %50 = load double, ptr %49, align 8, !tbaa !9
  %51 = fsub double %47, %50
  store double %51, ptr %19, align 8, !tbaa !9
  %52 = load ptr, ptr %5, align 8, !tbaa !14
  %53 = getelementptr inbounds double, ptr %52, i64 4
  %54 = load double, ptr %53, align 8, !tbaa !9
  %55 = load ptr, ptr %5, align 8, !tbaa !14
  %56 = getelementptr inbounds double, ptr %55, i64 6
  %57 = load double, ptr %56, align 8, !tbaa !9
  %58 = fadd double %54, %57
  store double %58, ptr %20, align 8, !tbaa !9
  %59 = load ptr, ptr %5, align 8, !tbaa !14
  %60 = getelementptr inbounds double, ptr %59, i64 5
  %61 = load double, ptr %60, align 8, !tbaa !9
  %62 = load ptr, ptr %5, align 8, !tbaa !14
  %63 = getelementptr inbounds double, ptr %62, i64 7
  %64 = load double, ptr %63, align 8, !tbaa !9
  %65 = fadd double %61, %64
  store double %65, ptr %21, align 8, !tbaa !9
  %66 = load ptr, ptr %5, align 8, !tbaa !14
  %67 = getelementptr inbounds double, ptr %66, i64 4
  %68 = load double, ptr %67, align 8, !tbaa !9
  %69 = load ptr, ptr %5, align 8, !tbaa !14
  %70 = getelementptr inbounds double, ptr %69, i64 6
  %71 = load double, ptr %70, align 8, !tbaa !9
  %72 = fsub double %68, %71
  store double %72, ptr %22, align 8, !tbaa !9
  %73 = load ptr, ptr %5, align 8, !tbaa !14
  %74 = getelementptr inbounds double, ptr %73, i64 5
  %75 = load double, ptr %74, align 8, !tbaa !9
  %76 = load ptr, ptr %5, align 8, !tbaa !14
  %77 = getelementptr inbounds double, ptr %76, i64 7
  %78 = load double, ptr %77, align 8, !tbaa !9
  %79 = fsub double %75, %78
  store double %79, ptr %23, align 8, !tbaa !9
  %80 = load double, ptr %16, align 8, !tbaa !9
  %81 = load double, ptr %20, align 8, !tbaa !9
  %82 = fadd double %80, %81
  %83 = load ptr, ptr %5, align 8, !tbaa !14
  %84 = getelementptr inbounds double, ptr %83, i64 0
  store double %82, ptr %84, align 8, !tbaa !9
  %85 = load double, ptr %17, align 8, !tbaa !9
  %86 = load double, ptr %21, align 8, !tbaa !9
  %87 = fadd double %85, %86
  %88 = load ptr, ptr %5, align 8, !tbaa !14
  %89 = getelementptr inbounds double, ptr %88, i64 1
  store double %87, ptr %89, align 8, !tbaa !9
  %90 = load double, ptr %16, align 8, !tbaa !9
  %91 = load double, ptr %20, align 8, !tbaa !9
  %92 = fsub double %90, %91
  %93 = load ptr, ptr %5, align 8, !tbaa !14
  %94 = getelementptr inbounds double, ptr %93, i64 4
  store double %92, ptr %94, align 8, !tbaa !9
  %95 = load double, ptr %17, align 8, !tbaa !9
  %96 = load double, ptr %21, align 8, !tbaa !9
  %97 = fsub double %95, %96
  %98 = load ptr, ptr %5, align 8, !tbaa !14
  %99 = getelementptr inbounds double, ptr %98, i64 5
  store double %97, ptr %99, align 8, !tbaa !9
  %100 = load double, ptr %18, align 8, !tbaa !9
  %101 = load double, ptr %23, align 8, !tbaa !9
  %102 = fsub double %100, %101
  %103 = load ptr, ptr %5, align 8, !tbaa !14
  %104 = getelementptr inbounds double, ptr %103, i64 2
  store double %102, ptr %104, align 8, !tbaa !9
  %105 = load double, ptr %19, align 8, !tbaa !9
  %106 = load double, ptr %22, align 8, !tbaa !9
  %107 = fadd double %105, %106
  %108 = load ptr, ptr %5, align 8, !tbaa !14
  %109 = getelementptr inbounds double, ptr %108, i64 3
  store double %107, ptr %109, align 8, !tbaa !9
  %110 = load double, ptr %18, align 8, !tbaa !9
  %111 = load double, ptr %23, align 8, !tbaa !9
  %112 = fadd double %110, %111
  %113 = load ptr, ptr %5, align 8, !tbaa !14
  %114 = getelementptr inbounds double, ptr %113, i64 6
  store double %112, ptr %114, align 8, !tbaa !9
  %115 = load double, ptr %19, align 8, !tbaa !9
  %116 = load double, ptr %22, align 8, !tbaa !9
  %117 = fsub double %115, %116
  %118 = load ptr, ptr %5, align 8, !tbaa !14
  %119 = getelementptr inbounds double, ptr %118, i64 7
  store double %117, ptr %119, align 8, !tbaa !9
  %120 = load ptr, ptr %6, align 8, !tbaa !14
  %121 = getelementptr inbounds double, ptr %120, i64 2
  %122 = load double, ptr %121, align 8, !tbaa !9
  store double %122, ptr %10, align 8, !tbaa !9
  %123 = load ptr, ptr %5, align 8, !tbaa !14
  %124 = getelementptr inbounds double, ptr %123, i64 8
  %125 = load double, ptr %124, align 8, !tbaa !9
  %126 = load ptr, ptr %5, align 8, !tbaa !14
  %127 = getelementptr inbounds double, ptr %126, i64 10
  %128 = load double, ptr %127, align 8, !tbaa !9
  %129 = fadd double %125, %128
  store double %129, ptr %16, align 8, !tbaa !9
  %130 = load ptr, ptr %5, align 8, !tbaa !14
  %131 = getelementptr inbounds double, ptr %130, i64 9
  %132 = load double, ptr %131, align 8, !tbaa !9
  %133 = load ptr, ptr %5, align 8, !tbaa !14
  %134 = getelementptr inbounds double, ptr %133, i64 11
  %135 = load double, ptr %134, align 8, !tbaa !9
  %136 = fadd double %132, %135
  store double %136, ptr %17, align 8, !tbaa !9
  %137 = load ptr, ptr %5, align 8, !tbaa !14
  %138 = getelementptr inbounds double, ptr %137, i64 8
  %139 = load double, ptr %138, align 8, !tbaa !9
  %140 = load ptr, ptr %5, align 8, !tbaa !14
  %141 = getelementptr inbounds double, ptr %140, i64 10
  %142 = load double, ptr %141, align 8, !tbaa !9
  %143 = fsub double %139, %142
  store double %143, ptr %18, align 8, !tbaa !9
  %144 = load ptr, ptr %5, align 8, !tbaa !14
  %145 = getelementptr inbounds double, ptr %144, i64 9
  %146 = load double, ptr %145, align 8, !tbaa !9
  %147 = load ptr, ptr %5, align 8, !tbaa !14
  %148 = getelementptr inbounds double, ptr %147, i64 11
  %149 = load double, ptr %148, align 8, !tbaa !9
  %150 = fsub double %146, %149
  store double %150, ptr %19, align 8, !tbaa !9
  %151 = load ptr, ptr %5, align 8, !tbaa !14
  %152 = getelementptr inbounds double, ptr %151, i64 12
  %153 = load double, ptr %152, align 8, !tbaa !9
  %154 = load ptr, ptr %5, align 8, !tbaa !14
  %155 = getelementptr inbounds double, ptr %154, i64 14
  %156 = load double, ptr %155, align 8, !tbaa !9
  %157 = fadd double %153, %156
  store double %157, ptr %20, align 8, !tbaa !9
  %158 = load ptr, ptr %5, align 8, !tbaa !14
  %159 = getelementptr inbounds double, ptr %158, i64 13
  %160 = load double, ptr %159, align 8, !tbaa !9
  %161 = load ptr, ptr %5, align 8, !tbaa !14
  %162 = getelementptr inbounds double, ptr %161, i64 15
  %163 = load double, ptr %162, align 8, !tbaa !9
  %164 = fadd double %160, %163
  store double %164, ptr %21, align 8, !tbaa !9
  %165 = load ptr, ptr %5, align 8, !tbaa !14
  %166 = getelementptr inbounds double, ptr %165, i64 12
  %167 = load double, ptr %166, align 8, !tbaa !9
  %168 = load ptr, ptr %5, align 8, !tbaa !14
  %169 = getelementptr inbounds double, ptr %168, i64 14
  %170 = load double, ptr %169, align 8, !tbaa !9
  %171 = fsub double %167, %170
  store double %171, ptr %22, align 8, !tbaa !9
  %172 = load ptr, ptr %5, align 8, !tbaa !14
  %173 = getelementptr inbounds double, ptr %172, i64 13
  %174 = load double, ptr %173, align 8, !tbaa !9
  %175 = load ptr, ptr %5, align 8, !tbaa !14
  %176 = getelementptr inbounds double, ptr %175, i64 15
  %177 = load double, ptr %176, align 8, !tbaa !9
  %178 = fsub double %174, %177
  store double %178, ptr %23, align 8, !tbaa !9
  %179 = load double, ptr %16, align 8, !tbaa !9
  %180 = load double, ptr %20, align 8, !tbaa !9
  %181 = fadd double %179, %180
  %182 = load ptr, ptr %5, align 8, !tbaa !14
  %183 = getelementptr inbounds double, ptr %182, i64 8
  store double %181, ptr %183, align 8, !tbaa !9
  %184 = load double, ptr %17, align 8, !tbaa !9
  %185 = load double, ptr %21, align 8, !tbaa !9
  %186 = fadd double %184, %185
  %187 = load ptr, ptr %5, align 8, !tbaa !14
  %188 = getelementptr inbounds double, ptr %187, i64 9
  store double %186, ptr %188, align 8, !tbaa !9
  %189 = load double, ptr %21, align 8, !tbaa !9
  %190 = load double, ptr %17, align 8, !tbaa !9
  %191 = fsub double %189, %190
  %192 = load ptr, ptr %5, align 8, !tbaa !14
  %193 = getelementptr inbounds double, ptr %192, i64 12
  store double %191, ptr %193, align 8, !tbaa !9
  %194 = load double, ptr %16, align 8, !tbaa !9
  %195 = load double, ptr %20, align 8, !tbaa !9
  %196 = fsub double %194, %195
  %197 = load ptr, ptr %5, align 8, !tbaa !14
  %198 = getelementptr inbounds double, ptr %197, i64 13
  store double %196, ptr %198, align 8, !tbaa !9
  %199 = load double, ptr %18, align 8, !tbaa !9
  %200 = load double, ptr %23, align 8, !tbaa !9
  %201 = fsub double %199, %200
  store double %201, ptr %16, align 8, !tbaa !9
  %202 = load double, ptr %19, align 8, !tbaa !9
  %203 = load double, ptr %22, align 8, !tbaa !9
  %204 = fadd double %202, %203
  store double %204, ptr %17, align 8, !tbaa !9
  %205 = load double, ptr %10, align 8, !tbaa !9
  %206 = load double, ptr %16, align 8, !tbaa !9
  %207 = load double, ptr %17, align 8, !tbaa !9
  %208 = fsub double %206, %207
  %209 = fmul double %205, %208
  %210 = load ptr, ptr %5, align 8, !tbaa !14
  %211 = getelementptr inbounds double, ptr %210, i64 10
  store double %209, ptr %211, align 8, !tbaa !9
  %212 = load double, ptr %10, align 8, !tbaa !9
  %213 = load double, ptr %16, align 8, !tbaa !9
  %214 = load double, ptr %17, align 8, !tbaa !9
  %215 = fadd double %213, %214
  %216 = fmul double %212, %215
  %217 = load ptr, ptr %5, align 8, !tbaa !14
  %218 = getelementptr inbounds double, ptr %217, i64 11
  store double %216, ptr %218, align 8, !tbaa !9
  %219 = load double, ptr %23, align 8, !tbaa !9
  %220 = load double, ptr %18, align 8, !tbaa !9
  %221 = fadd double %219, %220
  store double %221, ptr %16, align 8, !tbaa !9
  %222 = load double, ptr %22, align 8, !tbaa !9
  %223 = load double, ptr %19, align 8, !tbaa !9
  %224 = fsub double %222, %223
  store double %224, ptr %17, align 8, !tbaa !9
  %225 = load double, ptr %10, align 8, !tbaa !9
  %226 = load double, ptr %17, align 8, !tbaa !9
  %227 = load double, ptr %16, align 8, !tbaa !9
  %228 = fsub double %226, %227
  %229 = fmul double %225, %228
  %230 = load ptr, ptr %5, align 8, !tbaa !14
  %231 = getelementptr inbounds double, ptr %230, i64 14
  store double %229, ptr %231, align 8, !tbaa !9
  %232 = load double, ptr %10, align 8, !tbaa !9
  %233 = load double, ptr %17, align 8, !tbaa !9
  %234 = load double, ptr %16, align 8, !tbaa !9
  %235 = fadd double %233, %234
  %236 = fmul double %232, %235
  %237 = load ptr, ptr %5, align 8, !tbaa !14
  %238 = getelementptr inbounds double, ptr %237, i64 15
  store double %236, ptr %238, align 8, !tbaa !9
  store i32 0, ptr %8, align 4, !tbaa !16
  store i32 16, ptr %7, align 4, !tbaa !16
  br label %239

239:                                              ; preds = %719, %3
  %240 = load i32, ptr %7, align 4, !tbaa !16
  %241 = load i32, ptr %4, align 4, !tbaa !16
  %242 = icmp slt i32 %240, %241
  br i1 %242, label %243, label %722

243:                                              ; preds = %239
  %244 = load i32, ptr %8, align 4, !tbaa !16
  %245 = add nsw i32 %244, 2
  store i32 %245, ptr %8, align 4, !tbaa !16
  %246 = load i32, ptr %8, align 4, !tbaa !16
  %247 = mul nsw i32 2, %246
  store i32 %247, ptr %9, align 4, !tbaa !16
  %248 = load ptr, ptr %6, align 8, !tbaa !14
  %249 = load i32, ptr %8, align 4, !tbaa !16
  %250 = sext i32 %249 to i64
  %251 = getelementptr inbounds double, ptr %248, i64 %250
  %252 = load double, ptr %251, align 8, !tbaa !9
  store double %252, ptr %12, align 8, !tbaa !9
  %253 = load ptr, ptr %6, align 8, !tbaa !14
  %254 = load i32, ptr %8, align 4, !tbaa !16
  %255 = add nsw i32 %254, 1
  %256 = sext i32 %255 to i64
  %257 = getelementptr inbounds double, ptr %253, i64 %256
  %258 = load double, ptr %257, align 8, !tbaa !9
  store double %258, ptr %13, align 8, !tbaa !9
  %259 = load ptr, ptr %6, align 8, !tbaa !14
  %260 = load i32, ptr %9, align 4, !tbaa !16
  %261 = sext i32 %260 to i64
  %262 = getelementptr inbounds double, ptr %259, i64 %261
  %263 = load double, ptr %262, align 8, !tbaa !9
  store double %263, ptr %10, align 8, !tbaa !9
  %264 = load ptr, ptr %6, align 8, !tbaa !14
  %265 = load i32, ptr %9, align 4, !tbaa !16
  %266 = add nsw i32 %265, 1
  %267 = sext i32 %266 to i64
  %268 = getelementptr inbounds double, ptr %264, i64 %267
  %269 = load double, ptr %268, align 8, !tbaa !9
  store double %269, ptr %11, align 8, !tbaa !9
  %270 = load double, ptr %10, align 8, !tbaa !9
  %271 = load double, ptr %13, align 8, !tbaa !9
  %272 = fmul double 2.000000e+00, %271
  %273 = load double, ptr %11, align 8, !tbaa !9
  %274 = fneg double %272
  %275 = call double @llvm.fmuladd.f64(double %274, double %273, double %270)
  store double %275, ptr %14, align 8, !tbaa !9
  %276 = load double, ptr %13, align 8, !tbaa !9
  %277 = fmul double 2.000000e+00, %276
  %278 = load double, ptr %10, align 8, !tbaa !9
  %279 = load double, ptr %11, align 8, !tbaa !9
  %280 = fneg double %279
  %281 = call double @llvm.fmuladd.f64(double %277, double %278, double %280)
  store double %281, ptr %15, align 8, !tbaa !9
  %282 = load ptr, ptr %5, align 8, !tbaa !14
  %283 = load i32, ptr %7, align 4, !tbaa !16
  %284 = sext i32 %283 to i64
  %285 = getelementptr inbounds double, ptr %282, i64 %284
  %286 = load double, ptr %285, align 8, !tbaa !9
  %287 = load ptr, ptr %5, align 8, !tbaa !14
  %288 = load i32, ptr %7, align 4, !tbaa !16
  %289 = add nsw i32 %288, 2
  %290 = sext i32 %289 to i64
  %291 = getelementptr inbounds double, ptr %287, i64 %290
  %292 = load double, ptr %291, align 8, !tbaa !9
  %293 = fadd double %286, %292
  store double %293, ptr %16, align 8, !tbaa !9
  %294 = load ptr, ptr %5, align 8, !tbaa !14
  %295 = load i32, ptr %7, align 4, !tbaa !16
  %296 = add nsw i32 %295, 1
  %297 = sext i32 %296 to i64
  %298 = getelementptr inbounds double, ptr %294, i64 %297
  %299 = load double, ptr %298, align 8, !tbaa !9
  %300 = load ptr, ptr %5, align 8, !tbaa !14
  %301 = load i32, ptr %7, align 4, !tbaa !16
  %302 = add nsw i32 %301, 3
  %303 = sext i32 %302 to i64
  %304 = getelementptr inbounds double, ptr %300, i64 %303
  %305 = load double, ptr %304, align 8, !tbaa !9
  %306 = fadd double %299, %305
  store double %306, ptr %17, align 8, !tbaa !9
  %307 = load ptr, ptr %5, align 8, !tbaa !14
  %308 = load i32, ptr %7, align 4, !tbaa !16
  %309 = sext i32 %308 to i64
  %310 = getelementptr inbounds double, ptr %307, i64 %309
  %311 = load double, ptr %310, align 8, !tbaa !9
  %312 = load ptr, ptr %5, align 8, !tbaa !14
  %313 = load i32, ptr %7, align 4, !tbaa !16
  %314 = add nsw i32 %313, 2
  %315 = sext i32 %314 to i64
  %316 = getelementptr inbounds double, ptr %312, i64 %315
  %317 = load double, ptr %316, align 8, !tbaa !9
  %318 = fsub double %311, %317
  store double %318, ptr %18, align 8, !tbaa !9
  %319 = load ptr, ptr %5, align 8, !tbaa !14
  %320 = load i32, ptr %7, align 4, !tbaa !16
  %321 = add nsw i32 %320, 1
  %322 = sext i32 %321 to i64
  %323 = getelementptr inbounds double, ptr %319, i64 %322
  %324 = load double, ptr %323, align 8, !tbaa !9
  %325 = load ptr, ptr %5, align 8, !tbaa !14
  %326 = load i32, ptr %7, align 4, !tbaa !16
  %327 = add nsw i32 %326, 3
  %328 = sext i32 %327 to i64
  %329 = getelementptr inbounds double, ptr %325, i64 %328
  %330 = load double, ptr %329, align 8, !tbaa !9
  %331 = fsub double %324, %330
  store double %331, ptr %19, align 8, !tbaa !9
  %332 = load ptr, ptr %5, align 8, !tbaa !14
  %333 = load i32, ptr %7, align 4, !tbaa !16
  %334 = add nsw i32 %333, 4
  %335 = sext i32 %334 to i64
  %336 = getelementptr inbounds double, ptr %332, i64 %335
  %337 = load double, ptr %336, align 8, !tbaa !9
  %338 = load ptr, ptr %5, align 8, !tbaa !14
  %339 = load i32, ptr %7, align 4, !tbaa !16
  %340 = add nsw i32 %339, 6
  %341 = sext i32 %340 to i64
  %342 = getelementptr inbounds double, ptr %338, i64 %341
  %343 = load double, ptr %342, align 8, !tbaa !9
  %344 = fadd double %337, %343
  store double %344, ptr %20, align 8, !tbaa !9
  %345 = load ptr, ptr %5, align 8, !tbaa !14
  %346 = load i32, ptr %7, align 4, !tbaa !16
  %347 = add nsw i32 %346, 5
  %348 = sext i32 %347 to i64
  %349 = getelementptr inbounds double, ptr %345, i64 %348
  %350 = load double, ptr %349, align 8, !tbaa !9
  %351 = load ptr, ptr %5, align 8, !tbaa !14
  %352 = load i32, ptr %7, align 4, !tbaa !16
  %353 = add nsw i32 %352, 7
  %354 = sext i32 %353 to i64
  %355 = getelementptr inbounds double, ptr %351, i64 %354
  %356 = load double, ptr %355, align 8, !tbaa !9
  %357 = fadd double %350, %356
  store double %357, ptr %21, align 8, !tbaa !9
  %358 = load ptr, ptr %5, align 8, !tbaa !14
  %359 = load i32, ptr %7, align 4, !tbaa !16
  %360 = add nsw i32 %359, 4
  %361 = sext i32 %360 to i64
  %362 = getelementptr inbounds double, ptr %358, i64 %361
  %363 = load double, ptr %362, align 8, !tbaa !9
  %364 = load ptr, ptr %5, align 8, !tbaa !14
  %365 = load i32, ptr %7, align 4, !tbaa !16
  %366 = add nsw i32 %365, 6
  %367 = sext i32 %366 to i64
  %368 = getelementptr inbounds double, ptr %364, i64 %367
  %369 = load double, ptr %368, align 8, !tbaa !9
  %370 = fsub double %363, %369
  store double %370, ptr %22, align 8, !tbaa !9
  %371 = load ptr, ptr %5, align 8, !tbaa !14
  %372 = load i32, ptr %7, align 4, !tbaa !16
  %373 = add nsw i32 %372, 5
  %374 = sext i32 %373 to i64
  %375 = getelementptr inbounds double, ptr %371, i64 %374
  %376 = load double, ptr %375, align 8, !tbaa !9
  %377 = load ptr, ptr %5, align 8, !tbaa !14
  %378 = load i32, ptr %7, align 4, !tbaa !16
  %379 = add nsw i32 %378, 7
  %380 = sext i32 %379 to i64
  %381 = getelementptr inbounds double, ptr %377, i64 %380
  %382 = load double, ptr %381, align 8, !tbaa !9
  %383 = fsub double %376, %382
  store double %383, ptr %23, align 8, !tbaa !9
  %384 = load double, ptr %16, align 8, !tbaa !9
  %385 = load double, ptr %20, align 8, !tbaa !9
  %386 = fadd double %384, %385
  %387 = load ptr, ptr %5, align 8, !tbaa !14
  %388 = load i32, ptr %7, align 4, !tbaa !16
  %389 = sext i32 %388 to i64
  %390 = getelementptr inbounds double, ptr %387, i64 %389
  store double %386, ptr %390, align 8, !tbaa !9
  %391 = load double, ptr %17, align 8, !tbaa !9
  %392 = load double, ptr %21, align 8, !tbaa !9
  %393 = fadd double %391, %392
  %394 = load ptr, ptr %5, align 8, !tbaa !14
  %395 = load i32, ptr %7, align 4, !tbaa !16
  %396 = add nsw i32 %395, 1
  %397 = sext i32 %396 to i64
  %398 = getelementptr inbounds double, ptr %394, i64 %397
  store double %393, ptr %398, align 8, !tbaa !9
  %399 = load double, ptr %20, align 8, !tbaa !9
  %400 = load double, ptr %16, align 8, !tbaa !9
  %401 = fsub double %400, %399
  store double %401, ptr %16, align 8, !tbaa !9
  %402 = load double, ptr %21, align 8, !tbaa !9
  %403 = load double, ptr %17, align 8, !tbaa !9
  %404 = fsub double %403, %402
  store double %404, ptr %17, align 8, !tbaa !9
  %405 = load double, ptr %12, align 8, !tbaa !9
  %406 = load double, ptr %16, align 8, !tbaa !9
  %407 = load double, ptr %13, align 8, !tbaa !9
  %408 = load double, ptr %17, align 8, !tbaa !9
  %409 = fmul double %407, %408
  %410 = fneg double %409
  %411 = call double @llvm.fmuladd.f64(double %405, double %406, double %410)
  %412 = load ptr, ptr %5, align 8, !tbaa !14
  %413 = load i32, ptr %7, align 4, !tbaa !16
  %414 = add nsw i32 %413, 4
  %415 = sext i32 %414 to i64
  %416 = getelementptr inbounds double, ptr %412, i64 %415
  store double %411, ptr %416, align 8, !tbaa !9
  %417 = load double, ptr %12, align 8, !tbaa !9
  %418 = load double, ptr %17, align 8, !tbaa !9
  %419 = load double, ptr %13, align 8, !tbaa !9
  %420 = load double, ptr %16, align 8, !tbaa !9
  %421 = fmul double %419, %420
  %422 = call double @llvm.fmuladd.f64(double %417, double %418, double %421)
  %423 = load ptr, ptr %5, align 8, !tbaa !14
  %424 = load i32, ptr %7, align 4, !tbaa !16
  %425 = add nsw i32 %424, 5
  %426 = sext i32 %425 to i64
  %427 = getelementptr inbounds double, ptr %423, i64 %426
  store double %422, ptr %427, align 8, !tbaa !9
  %428 = load double, ptr %18, align 8, !tbaa !9
  %429 = load double, ptr %23, align 8, !tbaa !9
  %430 = fsub double %428, %429
  store double %430, ptr %16, align 8, !tbaa !9
  %431 = load double, ptr %19, align 8, !tbaa !9
  %432 = load double, ptr %22, align 8, !tbaa !9
  %433 = fadd double %431, %432
  store double %433, ptr %17, align 8, !tbaa !9
  %434 = load double, ptr %10, align 8, !tbaa !9
  %435 = load double, ptr %16, align 8, !tbaa !9
  %436 = load double, ptr %11, align 8, !tbaa !9
  %437 = load double, ptr %17, align 8, !tbaa !9
  %438 = fmul double %436, %437
  %439 = fneg double %438
  %440 = call double @llvm.fmuladd.f64(double %434, double %435, double %439)
  %441 = load ptr, ptr %5, align 8, !tbaa !14
  %442 = load i32, ptr %7, align 4, !tbaa !16
  %443 = add nsw i32 %442, 2
  %444 = sext i32 %443 to i64
  %445 = getelementptr inbounds double, ptr %441, i64 %444
  store double %440, ptr %445, align 8, !tbaa !9
  %446 = load double, ptr %10, align 8, !tbaa !9
  %447 = load double, ptr %17, align 8, !tbaa !9
  %448 = load double, ptr %11, align 8, !tbaa !9
  %449 = load double, ptr %16, align 8, !tbaa !9
  %450 = fmul double %448, %449
  %451 = call double @llvm.fmuladd.f64(double %446, double %447, double %450)
  %452 = load ptr, ptr %5, align 8, !tbaa !14
  %453 = load i32, ptr %7, align 4, !tbaa !16
  %454 = add nsw i32 %453, 3
  %455 = sext i32 %454 to i64
  %456 = getelementptr inbounds double, ptr %452, i64 %455
  store double %451, ptr %456, align 8, !tbaa !9
  %457 = load double, ptr %18, align 8, !tbaa !9
  %458 = load double, ptr %23, align 8, !tbaa !9
  %459 = fadd double %457, %458
  store double %459, ptr %16, align 8, !tbaa !9
  %460 = load double, ptr %19, align 8, !tbaa !9
  %461 = load double, ptr %22, align 8, !tbaa !9
  %462 = fsub double %460, %461
  store double %462, ptr %17, align 8, !tbaa !9
  %463 = load double, ptr %14, align 8, !tbaa !9
  %464 = load double, ptr %16, align 8, !tbaa !9
  %465 = load double, ptr %15, align 8, !tbaa !9
  %466 = load double, ptr %17, align 8, !tbaa !9
  %467 = fmul double %465, %466
  %468 = fneg double %467
  %469 = call double @llvm.fmuladd.f64(double %463, double %464, double %468)
  %470 = load ptr, ptr %5, align 8, !tbaa !14
  %471 = load i32, ptr %7, align 4, !tbaa !16
  %472 = add nsw i32 %471, 6
  %473 = sext i32 %472 to i64
  %474 = getelementptr inbounds double, ptr %470, i64 %473
  store double %469, ptr %474, align 8, !tbaa !9
  %475 = load double, ptr %14, align 8, !tbaa !9
  %476 = load double, ptr %17, align 8, !tbaa !9
  %477 = load double, ptr %15, align 8, !tbaa !9
  %478 = load double, ptr %16, align 8, !tbaa !9
  %479 = fmul double %477, %478
  %480 = call double @llvm.fmuladd.f64(double %475, double %476, double %479)
  %481 = load ptr, ptr %5, align 8, !tbaa !14
  %482 = load i32, ptr %7, align 4, !tbaa !16
  %483 = add nsw i32 %482, 7
  %484 = sext i32 %483 to i64
  %485 = getelementptr inbounds double, ptr %481, i64 %484
  store double %480, ptr %485, align 8, !tbaa !9
  %486 = load ptr, ptr %6, align 8, !tbaa !14
  %487 = load i32, ptr %9, align 4, !tbaa !16
  %488 = add nsw i32 %487, 2
  %489 = sext i32 %488 to i64
  %490 = getelementptr inbounds double, ptr %486, i64 %489
  %491 = load double, ptr %490, align 8, !tbaa !9
  store double %491, ptr %10, align 8, !tbaa !9
  %492 = load ptr, ptr %6, align 8, !tbaa !14
  %493 = load i32, ptr %9, align 4, !tbaa !16
  %494 = add nsw i32 %493, 3
  %495 = sext i32 %494 to i64
  %496 = getelementptr inbounds double, ptr %492, i64 %495
  %497 = load double, ptr %496, align 8, !tbaa !9
  store double %497, ptr %11, align 8, !tbaa !9
  %498 = load double, ptr %10, align 8, !tbaa !9
  %499 = load double, ptr %12, align 8, !tbaa !9
  %500 = fmul double 2.000000e+00, %499
  %501 = load double, ptr %11, align 8, !tbaa !9
  %502 = fneg double %500
  %503 = call double @llvm.fmuladd.f64(double %502, double %501, double %498)
  store double %503, ptr %14, align 8, !tbaa !9
  %504 = load double, ptr %12, align 8, !tbaa !9
  %505 = fmul double 2.000000e+00, %504
  %506 = load double, ptr %10, align 8, !tbaa !9
  %507 = load double, ptr %11, align 8, !tbaa !9
  %508 = fneg double %507
  %509 = call double @llvm.fmuladd.f64(double %505, double %506, double %508)
  store double %509, ptr %15, align 8, !tbaa !9
  %510 = load ptr, ptr %5, align 8, !tbaa !14
  %511 = load i32, ptr %7, align 4, !tbaa !16
  %512 = add nsw i32 %511, 8
  %513 = sext i32 %512 to i64
  %514 = getelementptr inbounds double, ptr %510, i64 %513
  %515 = load double, ptr %514, align 8, !tbaa !9
  %516 = load ptr, ptr %5, align 8, !tbaa !14
  %517 = load i32, ptr %7, align 4, !tbaa !16
  %518 = add nsw i32 %517, 10
  %519 = sext i32 %518 to i64
  %520 = getelementptr inbounds double, ptr %516, i64 %519
  %521 = load double, ptr %520, align 8, !tbaa !9
  %522 = fadd double %515, %521
  store double %522, ptr %16, align 8, !tbaa !9
  %523 = load ptr, ptr %5, align 8, !tbaa !14
  %524 = load i32, ptr %7, align 4, !tbaa !16
  %525 = add nsw i32 %524, 9
  %526 = sext i32 %525 to i64
  %527 = getelementptr inbounds double, ptr %523, i64 %526
  %528 = load double, ptr %527, align 8, !tbaa !9
  %529 = load ptr, ptr %5, align 8, !tbaa !14
  %530 = load i32, ptr %7, align 4, !tbaa !16
  %531 = add nsw i32 %530, 11
  %532 = sext i32 %531 to i64
  %533 = getelementptr inbounds double, ptr %529, i64 %532
  %534 = load double, ptr %533, align 8, !tbaa !9
  %535 = fadd double %528, %534
  store double %535, ptr %17, align 8, !tbaa !9
  %536 = load ptr, ptr %5, align 8, !tbaa !14
  %537 = load i32, ptr %7, align 4, !tbaa !16
  %538 = add nsw i32 %537, 8
  %539 = sext i32 %538 to i64
  %540 = getelementptr inbounds double, ptr %536, i64 %539
  %541 = load double, ptr %540, align 8, !tbaa !9
  %542 = load ptr, ptr %5, align 8, !tbaa !14
  %543 = load i32, ptr %7, align 4, !tbaa !16
  %544 = add nsw i32 %543, 10
  %545 = sext i32 %544 to i64
  %546 = getelementptr inbounds double, ptr %542, i64 %545
  %547 = load double, ptr %546, align 8, !tbaa !9
  %548 = fsub double %541, %547
  store double %548, ptr %18, align 8, !tbaa !9
  %549 = load ptr, ptr %5, align 8, !tbaa !14
  %550 = load i32, ptr %7, align 4, !tbaa !16
  %551 = add nsw i32 %550, 9
  %552 = sext i32 %551 to i64
  %553 = getelementptr inbounds double, ptr %549, i64 %552
  %554 = load double, ptr %553, align 8, !tbaa !9
  %555 = load ptr, ptr %5, align 8, !tbaa !14
  %556 = load i32, ptr %7, align 4, !tbaa !16
  %557 = add nsw i32 %556, 11
  %558 = sext i32 %557 to i64
  %559 = getelementptr inbounds double, ptr %555, i64 %558
  %560 = load double, ptr %559, align 8, !tbaa !9
  %561 = fsub double %554, %560
  store double %561, ptr %19, align 8, !tbaa !9
  %562 = load ptr, ptr %5, align 8, !tbaa !14
  %563 = load i32, ptr %7, align 4, !tbaa !16
  %564 = add nsw i32 %563, 12
  %565 = sext i32 %564 to i64
  %566 = getelementptr inbounds double, ptr %562, i64 %565
  %567 = load double, ptr %566, align 8, !tbaa !9
  %568 = load ptr, ptr %5, align 8, !tbaa !14
  %569 = load i32, ptr %7, align 4, !tbaa !16
  %570 = add nsw i32 %569, 14
  %571 = sext i32 %570 to i64
  %572 = getelementptr inbounds double, ptr %568, i64 %571
  %573 = load double, ptr %572, align 8, !tbaa !9
  %574 = fadd double %567, %573
  store double %574, ptr %20, align 8, !tbaa !9
  %575 = load ptr, ptr %5, align 8, !tbaa !14
  %576 = load i32, ptr %7, align 4, !tbaa !16
  %577 = add nsw i32 %576, 13
  %578 = sext i32 %577 to i64
  %579 = getelementptr inbounds double, ptr %575, i64 %578
  %580 = load double, ptr %579, align 8, !tbaa !9
  %581 = load ptr, ptr %5, align 8, !tbaa !14
  %582 = load i32, ptr %7, align 4, !tbaa !16
  %583 = add nsw i32 %582, 15
  %584 = sext i32 %583 to i64
  %585 = getelementptr inbounds double, ptr %581, i64 %584
  %586 = load double, ptr %585, align 8, !tbaa !9
  %587 = fadd double %580, %586
  store double %587, ptr %21, align 8, !tbaa !9
  %588 = load ptr, ptr %5, align 8, !tbaa !14
  %589 = load i32, ptr %7, align 4, !tbaa !16
  %590 = add nsw i32 %589, 12
  %591 = sext i32 %590 to i64
  %592 = getelementptr inbounds double, ptr %588, i64 %591
  %593 = load double, ptr %592, align 8, !tbaa !9
  %594 = load ptr, ptr %5, align 8, !tbaa !14
  %595 = load i32, ptr %7, align 4, !tbaa !16
  %596 = add nsw i32 %595, 14
  %597 = sext i32 %596 to i64
  %598 = getelementptr inbounds double, ptr %594, i64 %597
  %599 = load double, ptr %598, align 8, !tbaa !9
  %600 = fsub double %593, %599
  store double %600, ptr %22, align 8, !tbaa !9
  %601 = load ptr, ptr %5, align 8, !tbaa !14
  %602 = load i32, ptr %7, align 4, !tbaa !16
  %603 = add nsw i32 %602, 13
  %604 = sext i32 %603 to i64
  %605 = getelementptr inbounds double, ptr %601, i64 %604
  %606 = load double, ptr %605, align 8, !tbaa !9
  %607 = load ptr, ptr %5, align 8, !tbaa !14
  %608 = load i32, ptr %7, align 4, !tbaa !16
  %609 = add nsw i32 %608, 15
  %610 = sext i32 %609 to i64
  %611 = getelementptr inbounds double, ptr %607, i64 %610
  %612 = load double, ptr %611, align 8, !tbaa !9
  %613 = fsub double %606, %612
  store double %613, ptr %23, align 8, !tbaa !9
  %614 = load double, ptr %16, align 8, !tbaa !9
  %615 = load double, ptr %20, align 8, !tbaa !9
  %616 = fadd double %614, %615
  %617 = load ptr, ptr %5, align 8, !tbaa !14
  %618 = load i32, ptr %7, align 4, !tbaa !16
  %619 = add nsw i32 %618, 8
  %620 = sext i32 %619 to i64
  %621 = getelementptr inbounds double, ptr %617, i64 %620
  store double %616, ptr %621, align 8, !tbaa !9
  %622 = load double, ptr %17, align 8, !tbaa !9
  %623 = load double, ptr %21, align 8, !tbaa !9
  %624 = fadd double %622, %623
  %625 = load ptr, ptr %5, align 8, !tbaa !14
  %626 = load i32, ptr %7, align 4, !tbaa !16
  %627 = add nsw i32 %626, 9
  %628 = sext i32 %627 to i64
  %629 = getelementptr inbounds double, ptr %625, i64 %628
  store double %624, ptr %629, align 8, !tbaa !9
  %630 = load double, ptr %20, align 8, !tbaa !9
  %631 = load double, ptr %16, align 8, !tbaa !9
  %632 = fsub double %631, %630
  store double %632, ptr %16, align 8, !tbaa !9
  %633 = load double, ptr %21, align 8, !tbaa !9
  %634 = load double, ptr %17, align 8, !tbaa !9
  %635 = fsub double %634, %633
  store double %635, ptr %17, align 8, !tbaa !9
  %636 = load double, ptr %13, align 8, !tbaa !9
  %637 = fneg double %636
  %638 = load double, ptr %16, align 8, !tbaa !9
  %639 = load double, ptr %12, align 8, !tbaa !9
  %640 = load double, ptr %17, align 8, !tbaa !9
  %641 = fmul double %639, %640
  %642 = fneg double %641
  %643 = call double @llvm.fmuladd.f64(double %637, double %638, double %642)
  %644 = load ptr, ptr %5, align 8, !tbaa !14
  %645 = load i32, ptr %7, align 4, !tbaa !16
  %646 = add nsw i32 %645, 12
  %647 = sext i32 %646 to i64
  %648 = getelementptr inbounds double, ptr %644, i64 %647
  store double %643, ptr %648, align 8, !tbaa !9
  %649 = load double, ptr %13, align 8, !tbaa !9
  %650 = fneg double %649
  %651 = load double, ptr %17, align 8, !tbaa !9
  %652 = load double, ptr %12, align 8, !tbaa !9
  %653 = load double, ptr %16, align 8, !tbaa !9
  %654 = fmul double %652, %653
  %655 = call double @llvm.fmuladd.f64(double %650, double %651, double %654)
  %656 = load ptr, ptr %5, align 8, !tbaa !14
  %657 = load i32, ptr %7, align 4, !tbaa !16
  %658 = add nsw i32 %657, 13
  %659 = sext i32 %658 to i64
  %660 = getelementptr inbounds double, ptr %656, i64 %659
  store double %655, ptr %660, align 8, !tbaa !9
  %661 = load double, ptr %18, align 8, !tbaa !9
  %662 = load double, ptr %23, align 8, !tbaa !9
  %663 = fsub double %661, %662
  store double %663, ptr %16, align 8, !tbaa !9
  %664 = load double, ptr %19, align 8, !tbaa !9
  %665 = load double, ptr %22, align 8, !tbaa !9
  %666 = fadd double %664, %665
  store double %666, ptr %17, align 8, !tbaa !9
  %667 = load double, ptr %10, align 8, !tbaa !9
  %668 = load double, ptr %16, align 8, !tbaa !9
  %669 = load double, ptr %11, align 8, !tbaa !9
  %670 = load double, ptr %17, align 8, !tbaa !9
  %671 = fmul double %669, %670
  %672 = fneg double %671
  %673 = call double @llvm.fmuladd.f64(double %667, double %668, double %672)
  %674 = load ptr, ptr %5, align 8, !tbaa !14
  %675 = load i32, ptr %7, align 4, !tbaa !16
  %676 = add nsw i32 %675, 10
  %677 = sext i32 %676 to i64
  %678 = getelementptr inbounds double, ptr %674, i64 %677
  store double %673, ptr %678, align 8, !tbaa !9
  %679 = load double, ptr %10, align 8, !tbaa !9
  %680 = load double, ptr %17, align 8, !tbaa !9
  %681 = load double, ptr %11, align 8, !tbaa !9
  %682 = load double, ptr %16, align 8, !tbaa !9
  %683 = fmul double %681, %682
  %684 = call double @llvm.fmuladd.f64(double %679, double %680, double %683)
  %685 = load ptr, ptr %5, align 8, !tbaa !14
  %686 = load i32, ptr %7, align 4, !tbaa !16
  %687 = add nsw i32 %686, 11
  %688 = sext i32 %687 to i64
  %689 = getelementptr inbounds double, ptr %685, i64 %688
  store double %684, ptr %689, align 8, !tbaa !9
  %690 = load double, ptr %18, align 8, !tbaa !9
  %691 = load double, ptr %23, align 8, !tbaa !9
  %692 = fadd double %690, %691
  store double %692, ptr %16, align 8, !tbaa !9
  %693 = load double, ptr %19, align 8, !tbaa !9
  %694 = load double, ptr %22, align 8, !tbaa !9
  %695 = fsub double %693, %694
  store double %695, ptr %17, align 8, !tbaa !9
  %696 = load double, ptr %14, align 8, !tbaa !9
  %697 = load double, ptr %16, align 8, !tbaa !9
  %698 = load double, ptr %15, align 8, !tbaa !9
  %699 = load double, ptr %17, align 8, !tbaa !9
  %700 = fmul double %698, %699
  %701 = fneg double %700
  %702 = call double @llvm.fmuladd.f64(double %696, double %697, double %701)
  %703 = load ptr, ptr %5, align 8, !tbaa !14
  %704 = load i32, ptr %7, align 4, !tbaa !16
  %705 = add nsw i32 %704, 14
  %706 = sext i32 %705 to i64
  %707 = getelementptr inbounds double, ptr %703, i64 %706
  store double %702, ptr %707, align 8, !tbaa !9
  %708 = load double, ptr %14, align 8, !tbaa !9
  %709 = load double, ptr %17, align 8, !tbaa !9
  %710 = load double, ptr %15, align 8, !tbaa !9
  %711 = load double, ptr %16, align 8, !tbaa !9
  %712 = fmul double %710, %711
  %713 = call double @llvm.fmuladd.f64(double %708, double %709, double %712)
  %714 = load ptr, ptr %5, align 8, !tbaa !14
  %715 = load i32, ptr %7, align 4, !tbaa !16
  %716 = add nsw i32 %715, 15
  %717 = sext i32 %716 to i64
  %718 = getelementptr inbounds double, ptr %714, i64 %717
  store double %713, ptr %718, align 8, !tbaa !9
  br label %719

719:                                              ; preds = %243
  %720 = load i32, ptr %7, align 4, !tbaa !16
  %721 = add nsw i32 %720, 16
  store i32 %721, ptr %7, align 4, !tbaa !16
  br label %239, !llvm.loop !47

722:                                              ; preds = %239
  call void @llvm.lifetime.end.p0(ptr %23) #9
  call void @llvm.lifetime.end.p0(ptr %22) #9
  call void @llvm.lifetime.end.p0(ptr %21) #9
  call void @llvm.lifetime.end.p0(ptr %20) #9
  call void @llvm.lifetime.end.p0(ptr %19) #9
  call void @llvm.lifetime.end.p0(ptr %18) #9
  call void @llvm.lifetime.end.p0(ptr %17) #9
  call void @llvm.lifetime.end.p0(ptr %16) #9
  call void @llvm.lifetime.end.p0(ptr %15) #9
  call void @llvm.lifetime.end.p0(ptr %14) #9
  call void @llvm.lifetime.end.p0(ptr %13) #9
  call void @llvm.lifetime.end.p0(ptr %12) #9
  call void @llvm.lifetime.end.p0(ptr %11) #9
  call void @llvm.lifetime.end.p0(ptr %10) #9
  call void @llvm.lifetime.end.p0(ptr %9) #9
  call void @llvm.lifetime.end.p0(ptr %8) #9
  call void @llvm.lifetime.end.p0(ptr %7) #9
  ret void
}

; Function Attrs: inlinehint nounwind uwtable
define internal void @cftmdl(i32 noundef %0, i32 noundef %1, ptr noundef %2, ptr noundef %3) #8 {
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca ptr, align 8
  %8 = alloca ptr, align 8
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  %11 = alloca i32, align 4
  %12 = alloca i32, align 4
  %13 = alloca i32, align 4
  %14 = alloca i32, align 4
  %15 = alloca i32, align 4
  %16 = alloca i32, align 4
  %17 = alloca i32, align 4
  %18 = alloca double, align 8
  %19 = alloca double, align 8
  %20 = alloca double, align 8
  %21 = alloca double, align 8
  %22 = alloca double, align 8
  %23 = alloca double, align 8
  %24 = alloca double, align 8
  %25 = alloca double, align 8
  %26 = alloca double, align 8
  %27 = alloca double, align 8
  %28 = alloca double, align 8
  %29 = alloca double, align 8
  %30 = alloca double, align 8
  %31 = alloca double, align 8
  store i32 %0, ptr %5, align 4, !tbaa !16
  store i32 %1, ptr %6, align 4, !tbaa !16
  store ptr %2, ptr %7, align 8, !tbaa !14
  store ptr %3, ptr %8, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %9) #9
  call void @llvm.lifetime.start.p0(ptr %10) #9
  call void @llvm.lifetime.start.p0(ptr %11) #9
  call void @llvm.lifetime.start.p0(ptr %12) #9
  call void @llvm.lifetime.start.p0(ptr %13) #9
  call void @llvm.lifetime.start.p0(ptr %14) #9
  call void @llvm.lifetime.start.p0(ptr %15) #9
  call void @llvm.lifetime.start.p0(ptr %16) #9
  call void @llvm.lifetime.start.p0(ptr %17) #9
  call void @llvm.lifetime.start.p0(ptr %18) #9
  call void @llvm.lifetime.start.p0(ptr %19) #9
  call void @llvm.lifetime.start.p0(ptr %20) #9
  call void @llvm.lifetime.start.p0(ptr %21) #9
  call void @llvm.lifetime.start.p0(ptr %22) #9
  call void @llvm.lifetime.start.p0(ptr %23) #9
  call void @llvm.lifetime.start.p0(ptr %24) #9
  call void @llvm.lifetime.start.p0(ptr %25) #9
  call void @llvm.lifetime.start.p0(ptr %26) #9
  call void @llvm.lifetime.start.p0(ptr %27) #9
  call void @llvm.lifetime.start.p0(ptr %28) #9
  call void @llvm.lifetime.start.p0(ptr %29) #9
  call void @llvm.lifetime.start.p0(ptr %30) #9
  call void @llvm.lifetime.start.p0(ptr %31) #9
  %32 = load i32, ptr %6, align 4, !tbaa !16
  %33 = shl i32 %32, 2
  store i32 %33, ptr %16, align 4, !tbaa !16
  store i32 0, ptr %9, align 4, !tbaa !16
  br label %34

34:                                               ; preds = %204, %4
  %35 = load i32, ptr %9, align 4, !tbaa !16
  %36 = load i32, ptr %6, align 4, !tbaa !16
  %37 = icmp slt i32 %35, %36
  br i1 %37, label %38, label %207

38:                                               ; preds = %34
  %39 = load i32, ptr %9, align 4, !tbaa !16
  %40 = load i32, ptr %6, align 4, !tbaa !16
  %41 = add nsw i32 %39, %40
  store i32 %41, ptr %10, align 4, !tbaa !16
  %42 = load i32, ptr %10, align 4, !tbaa !16
  %43 = load i32, ptr %6, align 4, !tbaa !16
  %44 = add nsw i32 %42, %43
  store i32 %44, ptr %11, align 4, !tbaa !16
  %45 = load i32, ptr %11, align 4, !tbaa !16
  %46 = load i32, ptr %6, align 4, !tbaa !16
  %47 = add nsw i32 %45, %46
  store i32 %47, ptr %12, align 4, !tbaa !16
  %48 = load ptr, ptr %7, align 8, !tbaa !14
  %49 = load i32, ptr %9, align 4, !tbaa !16
  %50 = sext i32 %49 to i64
  %51 = getelementptr inbounds double, ptr %48, i64 %50
  %52 = load double, ptr %51, align 8, !tbaa !9
  %53 = load ptr, ptr %7, align 8, !tbaa !14
  %54 = load i32, ptr %10, align 4, !tbaa !16
  %55 = sext i32 %54 to i64
  %56 = getelementptr inbounds double, ptr %53, i64 %55
  %57 = load double, ptr %56, align 8, !tbaa !9
  %58 = fadd double %52, %57
  store double %58, ptr %24, align 8, !tbaa !9
  %59 = load ptr, ptr %7, align 8, !tbaa !14
  %60 = load i32, ptr %9, align 4, !tbaa !16
  %61 = add nsw i32 %60, 1
  %62 = sext i32 %61 to i64
  %63 = getelementptr inbounds double, ptr %59, i64 %62
  %64 = load double, ptr %63, align 8, !tbaa !9
  %65 = load ptr, ptr %7, align 8, !tbaa !14
  %66 = load i32, ptr %10, align 4, !tbaa !16
  %67 = add nsw i32 %66, 1
  %68 = sext i32 %67 to i64
  %69 = getelementptr inbounds double, ptr %65, i64 %68
  %70 = load double, ptr %69, align 8, !tbaa !9
  %71 = fadd double %64, %70
  store double %71, ptr %25, align 8, !tbaa !9
  %72 = load ptr, ptr %7, align 8, !tbaa !14
  %73 = load i32, ptr %9, align 4, !tbaa !16
  %74 = sext i32 %73 to i64
  %75 = getelementptr inbounds double, ptr %72, i64 %74
  %76 = load double, ptr %75, align 8, !tbaa !9
  %77 = load ptr, ptr %7, align 8, !tbaa !14
  %78 = load i32, ptr %10, align 4, !tbaa !16
  %79 = sext i32 %78 to i64
  %80 = getelementptr inbounds double, ptr %77, i64 %79
  %81 = load double, ptr %80, align 8, !tbaa !9
  %82 = fsub double %76, %81
  store double %82, ptr %26, align 8, !tbaa !9
  %83 = load ptr, ptr %7, align 8, !tbaa !14
  %84 = load i32, ptr %9, align 4, !tbaa !16
  %85 = add nsw i32 %84, 1
  %86 = sext i32 %85 to i64
  %87 = getelementptr inbounds double, ptr %83, i64 %86
  %88 = load double, ptr %87, align 8, !tbaa !9
  %89 = load ptr, ptr %7, align 8, !tbaa !14
  %90 = load i32, ptr %10, align 4, !tbaa !16
  %91 = add nsw i32 %90, 1
  %92 = sext i32 %91 to i64
  %93 = getelementptr inbounds double, ptr %89, i64 %92
  %94 = load double, ptr %93, align 8, !tbaa !9
  %95 = fsub double %88, %94
  store double %95, ptr %27, align 8, !tbaa !9
  %96 = load ptr, ptr %7, align 8, !tbaa !14
  %97 = load i32, ptr %11, align 4, !tbaa !16
  %98 = sext i32 %97 to i64
  %99 = getelementptr inbounds double, ptr %96, i64 %98
  %100 = load double, ptr %99, align 8, !tbaa !9
  %101 = load ptr, ptr %7, align 8, !tbaa !14
  %102 = load i32, ptr %12, align 4, !tbaa !16
  %103 = sext i32 %102 to i64
  %104 = getelementptr inbounds double, ptr %101, i64 %103
  %105 = load double, ptr %104, align 8, !tbaa !9
  %106 = fadd double %100, %105
  store double %106, ptr %28, align 8, !tbaa !9
  %107 = load ptr, ptr %7, align 8, !tbaa !14
  %108 = load i32, ptr %11, align 4, !tbaa !16
  %109 = add nsw i32 %108, 1
  %110 = sext i32 %109 to i64
  %111 = getelementptr inbounds double, ptr %107, i64 %110
  %112 = load double, ptr %111, align 8, !tbaa !9
  %113 = load ptr, ptr %7, align 8, !tbaa !14
  %114 = load i32, ptr %12, align 4, !tbaa !16
  %115 = add nsw i32 %114, 1
  %116 = sext i32 %115 to i64
  %117 = getelementptr inbounds double, ptr %113, i64 %116
  %118 = load double, ptr %117, align 8, !tbaa !9
  %119 = fadd double %112, %118
  store double %119, ptr %29, align 8, !tbaa !9
  %120 = load ptr, ptr %7, align 8, !tbaa !14
  %121 = load i32, ptr %11, align 4, !tbaa !16
  %122 = sext i32 %121 to i64
  %123 = getelementptr inbounds double, ptr %120, i64 %122
  %124 = load double, ptr %123, align 8, !tbaa !9
  %125 = load ptr, ptr %7, align 8, !tbaa !14
  %126 = load i32, ptr %12, align 4, !tbaa !16
  %127 = sext i32 %126 to i64
  %128 = getelementptr inbounds double, ptr %125, i64 %127
  %129 = load double, ptr %128, align 8, !tbaa !9
  %130 = fsub double %124, %129
  store double %130, ptr %30, align 8, !tbaa !9
  %131 = load ptr, ptr %7, align 8, !tbaa !14
  %132 = load i32, ptr %11, align 4, !tbaa !16
  %133 = add nsw i32 %132, 1
  %134 = sext i32 %133 to i64
  %135 = getelementptr inbounds double, ptr %131, i64 %134
  %136 = load double, ptr %135, align 8, !tbaa !9
  %137 = load ptr, ptr %7, align 8, !tbaa !14
  %138 = load i32, ptr %12, align 4, !tbaa !16
  %139 = add nsw i32 %138, 1
  %140 = sext i32 %139 to i64
  %141 = getelementptr inbounds double, ptr %137, i64 %140
  %142 = load double, ptr %141, align 8, !tbaa !9
  %143 = fsub double %136, %142
  store double %143, ptr %31, align 8, !tbaa !9
  %144 = load double, ptr %24, align 8, !tbaa !9
  %145 = load double, ptr %28, align 8, !tbaa !9
  %146 = fadd double %144, %145
  %147 = load ptr, ptr %7, align 8, !tbaa !14
  %148 = load i32, ptr %9, align 4, !tbaa !16
  %149 = sext i32 %148 to i64
  %150 = getelementptr inbounds double, ptr %147, i64 %149
  store double %146, ptr %150, align 8, !tbaa !9
  %151 = load double, ptr %25, align 8, !tbaa !9
  %152 = load double, ptr %29, align 8, !tbaa !9
  %153 = fadd double %151, %152
  %154 = load ptr, ptr %7, align 8, !tbaa !14
  %155 = load i32, ptr %9, align 4, !tbaa !16
  %156 = add nsw i32 %155, 1
  %157 = sext i32 %156 to i64
  %158 = getelementptr inbounds double, ptr %154, i64 %157
  store double %153, ptr %158, align 8, !tbaa !9
  %159 = load double, ptr %24, align 8, !tbaa !9
  %160 = load double, ptr %28, align 8, !tbaa !9
  %161 = fsub double %159, %160
  %162 = load ptr, ptr %7, align 8, !tbaa !14
  %163 = load i32, ptr %11, align 4, !tbaa !16
  %164 = sext i32 %163 to i64
  %165 = getelementptr inbounds double, ptr %162, i64 %164
  store double %161, ptr %165, align 8, !tbaa !9
  %166 = load double, ptr %25, align 8, !tbaa !9
  %167 = load double, ptr %29, align 8, !tbaa !9
  %168 = fsub double %166, %167
  %169 = load ptr, ptr %7, align 8, !tbaa !14
  %170 = load i32, ptr %11, align 4, !tbaa !16
  %171 = add nsw i32 %170, 1
  %172 = sext i32 %171 to i64
  %173 = getelementptr inbounds double, ptr %169, i64 %172
  store double %168, ptr %173, align 8, !tbaa !9
  %174 = load double, ptr %26, align 8, !tbaa !9
  %175 = load double, ptr %31, align 8, !tbaa !9
  %176 = fsub double %174, %175
  %177 = load ptr, ptr %7, align 8, !tbaa !14
  %178 = load i32, ptr %10, align 4, !tbaa !16
  %179 = sext i32 %178 to i64
  %180 = getelementptr inbounds double, ptr %177, i64 %179
  store double %176, ptr %180, align 8, !tbaa !9
  %181 = load double, ptr %27, align 8, !tbaa !9
  %182 = load double, ptr %30, align 8, !tbaa !9
  %183 = fadd double %181, %182
  %184 = load ptr, ptr %7, align 8, !tbaa !14
  %185 = load i32, ptr %10, align 4, !tbaa !16
  %186 = add nsw i32 %185, 1
  %187 = sext i32 %186 to i64
  %188 = getelementptr inbounds double, ptr %184, i64 %187
  store double %183, ptr %188, align 8, !tbaa !9
  %189 = load double, ptr %26, align 8, !tbaa !9
  %190 = load double, ptr %31, align 8, !tbaa !9
  %191 = fadd double %189, %190
  %192 = load ptr, ptr %7, align 8, !tbaa !14
  %193 = load i32, ptr %12, align 4, !tbaa !16
  %194 = sext i32 %193 to i64
  %195 = getelementptr inbounds double, ptr %192, i64 %194
  store double %191, ptr %195, align 8, !tbaa !9
  %196 = load double, ptr %27, align 8, !tbaa !9
  %197 = load double, ptr %30, align 8, !tbaa !9
  %198 = fsub double %196, %197
  %199 = load ptr, ptr %7, align 8, !tbaa !14
  %200 = load i32, ptr %12, align 4, !tbaa !16
  %201 = add nsw i32 %200, 1
  %202 = sext i32 %201 to i64
  %203 = getelementptr inbounds double, ptr %199, i64 %202
  store double %198, ptr %203, align 8, !tbaa !9
  br label %204

204:                                              ; preds = %38
  %205 = load i32, ptr %9, align 4, !tbaa !16
  %206 = add nsw i32 %205, 2
  store i32 %206, ptr %9, align 4, !tbaa !16
  br label %34, !llvm.loop !48

207:                                              ; preds = %34
  %208 = load ptr, ptr %8, align 8, !tbaa !14
  %209 = getelementptr inbounds double, ptr %208, i64 2
  %210 = load double, ptr %209, align 8, !tbaa !9
  store double %210, ptr %18, align 8, !tbaa !9
  %211 = load i32, ptr %16, align 4, !tbaa !16
  store i32 %211, ptr %9, align 4, !tbaa !16
  br label %212

212:                                              ; preds = %404, %207
  %213 = load i32, ptr %9, align 4, !tbaa !16
  %214 = load i32, ptr %6, align 4, !tbaa !16
  %215 = load i32, ptr %16, align 4, !tbaa !16
  %216 = add nsw i32 %214, %215
  %217 = icmp slt i32 %213, %216
  br i1 %217, label %218, label %407

218:                                              ; preds = %212
  %219 = load i32, ptr %9, align 4, !tbaa !16
  %220 = load i32, ptr %6, align 4, !tbaa !16
  %221 = add nsw i32 %219, %220
  store i32 %221, ptr %10, align 4, !tbaa !16
  %222 = load i32, ptr %10, align 4, !tbaa !16
  %223 = load i32, ptr %6, align 4, !tbaa !16
  %224 = add nsw i32 %222, %223
  store i32 %224, ptr %11, align 4, !tbaa !16
  %225 = load i32, ptr %11, align 4, !tbaa !16
  %226 = load i32, ptr %6, align 4, !tbaa !16
  %227 = add nsw i32 %225, %226
  store i32 %227, ptr %12, align 4, !tbaa !16
  %228 = load ptr, ptr %7, align 8, !tbaa !14
  %229 = load i32, ptr %9, align 4, !tbaa !16
  %230 = sext i32 %229 to i64
  %231 = getelementptr inbounds double, ptr %228, i64 %230
  %232 = load double, ptr %231, align 8, !tbaa !9
  %233 = load ptr, ptr %7, align 8, !tbaa !14
  %234 = load i32, ptr %10, align 4, !tbaa !16
  %235 = sext i32 %234 to i64
  %236 = getelementptr inbounds double, ptr %233, i64 %235
  %237 = load double, ptr %236, align 8, !tbaa !9
  %238 = fadd double %232, %237
  store double %238, ptr %24, align 8, !tbaa !9
  %239 = load ptr, ptr %7, align 8, !tbaa !14
  %240 = load i32, ptr %9, align 4, !tbaa !16
  %241 = add nsw i32 %240, 1
  %242 = sext i32 %241 to i64
  %243 = getelementptr inbounds double, ptr %239, i64 %242
  %244 = load double, ptr %243, align 8, !tbaa !9
  %245 = load ptr, ptr %7, align 8, !tbaa !14
  %246 = load i32, ptr %10, align 4, !tbaa !16
  %247 = add nsw i32 %246, 1
  %248 = sext i32 %247 to i64
  %249 = getelementptr inbounds double, ptr %245, i64 %248
  %250 = load double, ptr %249, align 8, !tbaa !9
  %251 = fadd double %244, %250
  store double %251, ptr %25, align 8, !tbaa !9
  %252 = load ptr, ptr %7, align 8, !tbaa !14
  %253 = load i32, ptr %9, align 4, !tbaa !16
  %254 = sext i32 %253 to i64
  %255 = getelementptr inbounds double, ptr %252, i64 %254
  %256 = load double, ptr %255, align 8, !tbaa !9
  %257 = load ptr, ptr %7, align 8, !tbaa !14
  %258 = load i32, ptr %10, align 4, !tbaa !16
  %259 = sext i32 %258 to i64
  %260 = getelementptr inbounds double, ptr %257, i64 %259
  %261 = load double, ptr %260, align 8, !tbaa !9
  %262 = fsub double %256, %261
  store double %262, ptr %26, align 8, !tbaa !9
  %263 = load ptr, ptr %7, align 8, !tbaa !14
  %264 = load i32, ptr %9, align 4, !tbaa !16
  %265 = add nsw i32 %264, 1
  %266 = sext i32 %265 to i64
  %267 = getelementptr inbounds double, ptr %263, i64 %266
  %268 = load double, ptr %267, align 8, !tbaa !9
  %269 = load ptr, ptr %7, align 8, !tbaa !14
  %270 = load i32, ptr %10, align 4, !tbaa !16
  %271 = add nsw i32 %270, 1
  %272 = sext i32 %271 to i64
  %273 = getelementptr inbounds double, ptr %269, i64 %272
  %274 = load double, ptr %273, align 8, !tbaa !9
  %275 = fsub double %268, %274
  store double %275, ptr %27, align 8, !tbaa !9
  %276 = load ptr, ptr %7, align 8, !tbaa !14
  %277 = load i32, ptr %11, align 4, !tbaa !16
  %278 = sext i32 %277 to i64
  %279 = getelementptr inbounds double, ptr %276, i64 %278
  %280 = load double, ptr %279, align 8, !tbaa !9
  %281 = load ptr, ptr %7, align 8, !tbaa !14
  %282 = load i32, ptr %12, align 4, !tbaa !16
  %283 = sext i32 %282 to i64
  %284 = getelementptr inbounds double, ptr %281, i64 %283
  %285 = load double, ptr %284, align 8, !tbaa !9
  %286 = fadd double %280, %285
  store double %286, ptr %28, align 8, !tbaa !9
  %287 = load ptr, ptr %7, align 8, !tbaa !14
  %288 = load i32, ptr %11, align 4, !tbaa !16
  %289 = add nsw i32 %288, 1
  %290 = sext i32 %289 to i64
  %291 = getelementptr inbounds double, ptr %287, i64 %290
  %292 = load double, ptr %291, align 8, !tbaa !9
  %293 = load ptr, ptr %7, align 8, !tbaa !14
  %294 = load i32, ptr %12, align 4, !tbaa !16
  %295 = add nsw i32 %294, 1
  %296 = sext i32 %295 to i64
  %297 = getelementptr inbounds double, ptr %293, i64 %296
  %298 = load double, ptr %297, align 8, !tbaa !9
  %299 = fadd double %292, %298
  store double %299, ptr %29, align 8, !tbaa !9
  %300 = load ptr, ptr %7, align 8, !tbaa !14
  %301 = load i32, ptr %11, align 4, !tbaa !16
  %302 = sext i32 %301 to i64
  %303 = getelementptr inbounds double, ptr %300, i64 %302
  %304 = load double, ptr %303, align 8, !tbaa !9
  %305 = load ptr, ptr %7, align 8, !tbaa !14
  %306 = load i32, ptr %12, align 4, !tbaa !16
  %307 = sext i32 %306 to i64
  %308 = getelementptr inbounds double, ptr %305, i64 %307
  %309 = load double, ptr %308, align 8, !tbaa !9
  %310 = fsub double %304, %309
  store double %310, ptr %30, align 8, !tbaa !9
  %311 = load ptr, ptr %7, align 8, !tbaa !14
  %312 = load i32, ptr %11, align 4, !tbaa !16
  %313 = add nsw i32 %312, 1
  %314 = sext i32 %313 to i64
  %315 = getelementptr inbounds double, ptr %311, i64 %314
  %316 = load double, ptr %315, align 8, !tbaa !9
  %317 = load ptr, ptr %7, align 8, !tbaa !14
  %318 = load i32, ptr %12, align 4, !tbaa !16
  %319 = add nsw i32 %318, 1
  %320 = sext i32 %319 to i64
  %321 = getelementptr inbounds double, ptr %317, i64 %320
  %322 = load double, ptr %321, align 8, !tbaa !9
  %323 = fsub double %316, %322
  store double %323, ptr %31, align 8, !tbaa !9
  %324 = load double, ptr %24, align 8, !tbaa !9
  %325 = load double, ptr %28, align 8, !tbaa !9
  %326 = fadd double %324, %325
  %327 = load ptr, ptr %7, align 8, !tbaa !14
  %328 = load i32, ptr %9, align 4, !tbaa !16
  %329 = sext i32 %328 to i64
  %330 = getelementptr inbounds double, ptr %327, i64 %329
  store double %326, ptr %330, align 8, !tbaa !9
  %331 = load double, ptr %25, align 8, !tbaa !9
  %332 = load double, ptr %29, align 8, !tbaa !9
  %333 = fadd double %331, %332
  %334 = load ptr, ptr %7, align 8, !tbaa !14
  %335 = load i32, ptr %9, align 4, !tbaa !16
  %336 = add nsw i32 %335, 1
  %337 = sext i32 %336 to i64
  %338 = getelementptr inbounds double, ptr %334, i64 %337
  store double %333, ptr %338, align 8, !tbaa !9
  %339 = load double, ptr %29, align 8, !tbaa !9
  %340 = load double, ptr %25, align 8, !tbaa !9
  %341 = fsub double %339, %340
  %342 = load ptr, ptr %7, align 8, !tbaa !14
  %343 = load i32, ptr %11, align 4, !tbaa !16
  %344 = sext i32 %343 to i64
  %345 = getelementptr inbounds double, ptr %342, i64 %344
  store double %341, ptr %345, align 8, !tbaa !9
  %346 = load double, ptr %24, align 8, !tbaa !9
  %347 = load double, ptr %28, align 8, !tbaa !9
  %348 = fsub double %346, %347
  %349 = load ptr, ptr %7, align 8, !tbaa !14
  %350 = load i32, ptr %11, align 4, !tbaa !16
  %351 = add nsw i32 %350, 1
  %352 = sext i32 %351 to i64
  %353 = getelementptr inbounds double, ptr %349, i64 %352
  store double %348, ptr %353, align 8, !tbaa !9
  %354 = load double, ptr %26, align 8, !tbaa !9
  %355 = load double, ptr %31, align 8, !tbaa !9
  %356 = fsub double %354, %355
  store double %356, ptr %24, align 8, !tbaa !9
  %357 = load double, ptr %27, align 8, !tbaa !9
  %358 = load double, ptr %30, align 8, !tbaa !9
  %359 = fadd double %357, %358
  store double %359, ptr %25, align 8, !tbaa !9
  %360 = load double, ptr %18, align 8, !tbaa !9
  %361 = load double, ptr %24, align 8, !tbaa !9
  %362 = load double, ptr %25, align 8, !tbaa !9
  %363 = fsub double %361, %362
  %364 = fmul double %360, %363
  %365 = load ptr, ptr %7, align 8, !tbaa !14
  %366 = load i32, ptr %10, align 4, !tbaa !16
  %367 = sext i32 %366 to i64
  %368 = getelementptr inbounds double, ptr %365, i64 %367
  store double %364, ptr %368, align 8, !tbaa !9
  %369 = load double, ptr %18, align 8, !tbaa !9
  %370 = load double, ptr %24, align 8, !tbaa !9
  %371 = load double, ptr %25, align 8, !tbaa !9
  %372 = fadd double %370, %371
  %373 = fmul double %369, %372
  %374 = load ptr, ptr %7, align 8, !tbaa !14
  %375 = load i32, ptr %10, align 4, !tbaa !16
  %376 = add nsw i32 %375, 1
  %377 = sext i32 %376 to i64
  %378 = getelementptr inbounds double, ptr %374, i64 %377
  store double %373, ptr %378, align 8, !tbaa !9
  %379 = load double, ptr %31, align 8, !tbaa !9
  %380 = load double, ptr %26, align 8, !tbaa !9
  %381 = fadd double %379, %380
  store double %381, ptr %24, align 8, !tbaa !9
  %382 = load double, ptr %30, align 8, !tbaa !9
  %383 = load double, ptr %27, align 8, !tbaa !9
  %384 = fsub double %382, %383
  store double %384, ptr %25, align 8, !tbaa !9
  %385 = load double, ptr %18, align 8, !tbaa !9
  %386 = load double, ptr %25, align 8, !tbaa !9
  %387 = load double, ptr %24, align 8, !tbaa !9
  %388 = fsub double %386, %387
  %389 = fmul double %385, %388
  %390 = load ptr, ptr %7, align 8, !tbaa !14
  %391 = load i32, ptr %12, align 4, !tbaa !16
  %392 = sext i32 %391 to i64
  %393 = getelementptr inbounds double, ptr %390, i64 %392
  store double %389, ptr %393, align 8, !tbaa !9
  %394 = load double, ptr %18, align 8, !tbaa !9
  %395 = load double, ptr %25, align 8, !tbaa !9
  %396 = load double, ptr %24, align 8, !tbaa !9
  %397 = fadd double %395, %396
  %398 = fmul double %394, %397
  %399 = load ptr, ptr %7, align 8, !tbaa !14
  %400 = load i32, ptr %12, align 4, !tbaa !16
  %401 = add nsw i32 %400, 1
  %402 = sext i32 %401 to i64
  %403 = getelementptr inbounds double, ptr %399, i64 %402
  store double %398, ptr %403, align 8, !tbaa !9
  br label %404

404:                                              ; preds = %218
  %405 = load i32, ptr %9, align 4, !tbaa !16
  %406 = add nsw i32 %405, 2
  store i32 %406, ptr %9, align 4, !tbaa !16
  br label %212, !llvm.loop !49

407:                                              ; preds = %212
  store i32 0, ptr %14, align 4, !tbaa !16
  %408 = load i32, ptr %16, align 4, !tbaa !16
  %409 = mul nsw i32 2, %408
  store i32 %409, ptr %17, align 4, !tbaa !16
  %410 = load i32, ptr %17, align 4, !tbaa !16
  store i32 %410, ptr %13, align 4, !tbaa !16
  br label %411

411:                                              ; preds = %916, %407
  %412 = load i32, ptr %13, align 4, !tbaa !16
  %413 = load i32, ptr %5, align 4, !tbaa !16
  %414 = icmp slt i32 %412, %413
  br i1 %414, label %415, label %920

415:                                              ; preds = %411
  %416 = load i32, ptr %14, align 4, !tbaa !16
  %417 = add nsw i32 %416, 2
  store i32 %417, ptr %14, align 4, !tbaa !16
  %418 = load i32, ptr %14, align 4, !tbaa !16
  %419 = mul nsw i32 2, %418
  store i32 %419, ptr %15, align 4, !tbaa !16
  %420 = load ptr, ptr %8, align 8, !tbaa !14
  %421 = load i32, ptr %14, align 4, !tbaa !16
  %422 = sext i32 %421 to i64
  %423 = getelementptr inbounds double, ptr %420, i64 %422
  %424 = load double, ptr %423, align 8, !tbaa !9
  store double %424, ptr %20, align 8, !tbaa !9
  %425 = load ptr, ptr %8, align 8, !tbaa !14
  %426 = load i32, ptr %14, align 4, !tbaa !16
  %427 = add nsw i32 %426, 1
  %428 = sext i32 %427 to i64
  %429 = getelementptr inbounds double, ptr %425, i64 %428
  %430 = load double, ptr %429, align 8, !tbaa !9
  store double %430, ptr %21, align 8, !tbaa !9
  %431 = load ptr, ptr %8, align 8, !tbaa !14
  %432 = load i32, ptr %15, align 4, !tbaa !16
  %433 = sext i32 %432 to i64
  %434 = getelementptr inbounds double, ptr %431, i64 %433
  %435 = load double, ptr %434, align 8, !tbaa !9
  store double %435, ptr %18, align 8, !tbaa !9
  %436 = load ptr, ptr %8, align 8, !tbaa !14
  %437 = load i32, ptr %15, align 4, !tbaa !16
  %438 = add nsw i32 %437, 1
  %439 = sext i32 %438 to i64
  %440 = getelementptr inbounds double, ptr %436, i64 %439
  %441 = load double, ptr %440, align 8, !tbaa !9
  store double %441, ptr %19, align 8, !tbaa !9
  %442 = load double, ptr %18, align 8, !tbaa !9
  %443 = load double, ptr %21, align 8, !tbaa !9
  %444 = fmul double 2.000000e+00, %443
  %445 = load double, ptr %19, align 8, !tbaa !9
  %446 = fneg double %444
  %447 = call double @llvm.fmuladd.f64(double %446, double %445, double %442)
  store double %447, ptr %22, align 8, !tbaa !9
  %448 = load double, ptr %21, align 8, !tbaa !9
  %449 = fmul double 2.000000e+00, %448
  %450 = load double, ptr %18, align 8, !tbaa !9
  %451 = load double, ptr %19, align 8, !tbaa !9
  %452 = fneg double %451
  %453 = call double @llvm.fmuladd.f64(double %449, double %450, double %452)
  store double %453, ptr %23, align 8, !tbaa !9
  %454 = load i32, ptr %13, align 4, !tbaa !16
  store i32 %454, ptr %9, align 4, !tbaa !16
  br label %455

455:                                              ; preds = %666, %415
  %456 = load i32, ptr %9, align 4, !tbaa !16
  %457 = load i32, ptr %6, align 4, !tbaa !16
  %458 = load i32, ptr %13, align 4, !tbaa !16
  %459 = add nsw i32 %457, %458
  %460 = icmp slt i32 %456, %459
  br i1 %460, label %461, label %669

461:                                              ; preds = %455
  %462 = load i32, ptr %9, align 4, !tbaa !16
  %463 = load i32, ptr %6, align 4, !tbaa !16
  %464 = add nsw i32 %462, %463
  store i32 %464, ptr %10, align 4, !tbaa !16
  %465 = load i32, ptr %10, align 4, !tbaa !16
  %466 = load i32, ptr %6, align 4, !tbaa !16
  %467 = add nsw i32 %465, %466
  store i32 %467, ptr %11, align 4, !tbaa !16
  %468 = load i32, ptr %11, align 4, !tbaa !16
  %469 = load i32, ptr %6, align 4, !tbaa !16
  %470 = add nsw i32 %468, %469
  store i32 %470, ptr %12, align 4, !tbaa !16
  %471 = load ptr, ptr %7, align 8, !tbaa !14
  %472 = load i32, ptr %9, align 4, !tbaa !16
  %473 = sext i32 %472 to i64
  %474 = getelementptr inbounds double, ptr %471, i64 %473
  %475 = load double, ptr %474, align 8, !tbaa !9
  %476 = load ptr, ptr %7, align 8, !tbaa !14
  %477 = load i32, ptr %10, align 4, !tbaa !16
  %478 = sext i32 %477 to i64
  %479 = getelementptr inbounds double, ptr %476, i64 %478
  %480 = load double, ptr %479, align 8, !tbaa !9
  %481 = fadd double %475, %480
  store double %481, ptr %24, align 8, !tbaa !9
  %482 = load ptr, ptr %7, align 8, !tbaa !14
  %483 = load i32, ptr %9, align 4, !tbaa !16
  %484 = add nsw i32 %483, 1
  %485 = sext i32 %484 to i64
  %486 = getelementptr inbounds double, ptr %482, i64 %485
  %487 = load double, ptr %486, align 8, !tbaa !9
  %488 = load ptr, ptr %7, align 8, !tbaa !14
  %489 = load i32, ptr %10, align 4, !tbaa !16
  %490 = add nsw i32 %489, 1
  %491 = sext i32 %490 to i64
  %492 = getelementptr inbounds double, ptr %488, i64 %491
  %493 = load double, ptr %492, align 8, !tbaa !9
  %494 = fadd double %487, %493
  store double %494, ptr %25, align 8, !tbaa !9
  %495 = load ptr, ptr %7, align 8, !tbaa !14
  %496 = load i32, ptr %9, align 4, !tbaa !16
  %497 = sext i32 %496 to i64
  %498 = getelementptr inbounds double, ptr %495, i64 %497
  %499 = load double, ptr %498, align 8, !tbaa !9
  %500 = load ptr, ptr %7, align 8, !tbaa !14
  %501 = load i32, ptr %10, align 4, !tbaa !16
  %502 = sext i32 %501 to i64
  %503 = getelementptr inbounds double, ptr %500, i64 %502
  %504 = load double, ptr %503, align 8, !tbaa !9
  %505 = fsub double %499, %504
  store double %505, ptr %26, align 8, !tbaa !9
  %506 = load ptr, ptr %7, align 8, !tbaa !14
  %507 = load i32, ptr %9, align 4, !tbaa !16
  %508 = add nsw i32 %507, 1
  %509 = sext i32 %508 to i64
  %510 = getelementptr inbounds double, ptr %506, i64 %509
  %511 = load double, ptr %510, align 8, !tbaa !9
  %512 = load ptr, ptr %7, align 8, !tbaa !14
  %513 = load i32, ptr %10, align 4, !tbaa !16
  %514 = add nsw i32 %513, 1
  %515 = sext i32 %514 to i64
  %516 = getelementptr inbounds double, ptr %512, i64 %515
  %517 = load double, ptr %516, align 8, !tbaa !9
  %518 = fsub double %511, %517
  store double %518, ptr %27, align 8, !tbaa !9
  %519 = load ptr, ptr %7, align 8, !tbaa !14
  %520 = load i32, ptr %11, align 4, !tbaa !16
  %521 = sext i32 %520 to i64
  %522 = getelementptr inbounds double, ptr %519, i64 %521
  %523 = load double, ptr %522, align 8, !tbaa !9
  %524 = load ptr, ptr %7, align 8, !tbaa !14
  %525 = load i32, ptr %12, align 4, !tbaa !16
  %526 = sext i32 %525 to i64
  %527 = getelementptr inbounds double, ptr %524, i64 %526
  %528 = load double, ptr %527, align 8, !tbaa !9
  %529 = fadd double %523, %528
  store double %529, ptr %28, align 8, !tbaa !9
  %530 = load ptr, ptr %7, align 8, !tbaa !14
  %531 = load i32, ptr %11, align 4, !tbaa !16
  %532 = add nsw i32 %531, 1
  %533 = sext i32 %532 to i64
  %534 = getelementptr inbounds double, ptr %530, i64 %533
  %535 = load double, ptr %534, align 8, !tbaa !9
  %536 = load ptr, ptr %7, align 8, !tbaa !14
  %537 = load i32, ptr %12, align 4, !tbaa !16
  %538 = add nsw i32 %537, 1
  %539 = sext i32 %538 to i64
  %540 = getelementptr inbounds double, ptr %536, i64 %539
  %541 = load double, ptr %540, align 8, !tbaa !9
  %542 = fadd double %535, %541
  store double %542, ptr %29, align 8, !tbaa !9
  %543 = load ptr, ptr %7, align 8, !tbaa !14
  %544 = load i32, ptr %11, align 4, !tbaa !16
  %545 = sext i32 %544 to i64
  %546 = getelementptr inbounds double, ptr %543, i64 %545
  %547 = load double, ptr %546, align 8, !tbaa !9
  %548 = load ptr, ptr %7, align 8, !tbaa !14
  %549 = load i32, ptr %12, align 4, !tbaa !16
  %550 = sext i32 %549 to i64
  %551 = getelementptr inbounds double, ptr %548, i64 %550
  %552 = load double, ptr %551, align 8, !tbaa !9
  %553 = fsub double %547, %552
  store double %553, ptr %30, align 8, !tbaa !9
  %554 = load ptr, ptr %7, align 8, !tbaa !14
  %555 = load i32, ptr %11, align 4, !tbaa !16
  %556 = add nsw i32 %555, 1
  %557 = sext i32 %556 to i64
  %558 = getelementptr inbounds double, ptr %554, i64 %557
  %559 = load double, ptr %558, align 8, !tbaa !9
  %560 = load ptr, ptr %7, align 8, !tbaa !14
  %561 = load i32, ptr %12, align 4, !tbaa !16
  %562 = add nsw i32 %561, 1
  %563 = sext i32 %562 to i64
  %564 = getelementptr inbounds double, ptr %560, i64 %563
  %565 = load double, ptr %564, align 8, !tbaa !9
  %566 = fsub double %559, %565
  store double %566, ptr %31, align 8, !tbaa !9
  %567 = load double, ptr %24, align 8, !tbaa !9
  %568 = load double, ptr %28, align 8, !tbaa !9
  %569 = fadd double %567, %568
  %570 = load ptr, ptr %7, align 8, !tbaa !14
  %571 = load i32, ptr %9, align 4, !tbaa !16
  %572 = sext i32 %571 to i64
  %573 = getelementptr inbounds double, ptr %570, i64 %572
  store double %569, ptr %573, align 8, !tbaa !9
  %574 = load double, ptr %25, align 8, !tbaa !9
  %575 = load double, ptr %29, align 8, !tbaa !9
  %576 = fadd double %574, %575
  %577 = load ptr, ptr %7, align 8, !tbaa !14
  %578 = load i32, ptr %9, align 4, !tbaa !16
  %579 = add nsw i32 %578, 1
  %580 = sext i32 %579 to i64
  %581 = getelementptr inbounds double, ptr %577, i64 %580
  store double %576, ptr %581, align 8, !tbaa !9
  %582 = load double, ptr %28, align 8, !tbaa !9
  %583 = load double, ptr %24, align 8, !tbaa !9
  %584 = fsub double %583, %582
  store double %584, ptr %24, align 8, !tbaa !9
  %585 = load double, ptr %29, align 8, !tbaa !9
  %586 = load double, ptr %25, align 8, !tbaa !9
  %587 = fsub double %586, %585
  store double %587, ptr %25, align 8, !tbaa !9
  %588 = load double, ptr %20, align 8, !tbaa !9
  %589 = load double, ptr %24, align 8, !tbaa !9
  %590 = load double, ptr %21, align 8, !tbaa !9
  %591 = load double, ptr %25, align 8, !tbaa !9
  %592 = fmul double %590, %591
  %593 = fneg double %592
  %594 = call double @llvm.fmuladd.f64(double %588, double %589, double %593)
  %595 = load ptr, ptr %7, align 8, !tbaa !14
  %596 = load i32, ptr %11, align 4, !tbaa !16
  %597 = sext i32 %596 to i64
  %598 = getelementptr inbounds double, ptr %595, i64 %597
  store double %594, ptr %598, align 8, !tbaa !9
  %599 = load double, ptr %20, align 8, !tbaa !9
  %600 = load double, ptr %25, align 8, !tbaa !9
  %601 = load double, ptr %21, align 8, !tbaa !9
  %602 = load double, ptr %24, align 8, !tbaa !9
  %603 = fmul double %601, %602
  %604 = call double @llvm.fmuladd.f64(double %599, double %600, double %603)
  %605 = load ptr, ptr %7, align 8, !tbaa !14
  %606 = load i32, ptr %11, align 4, !tbaa !16
  %607 = add nsw i32 %606, 1
  %608 = sext i32 %607 to i64
  %609 = getelementptr inbounds double, ptr %605, i64 %608
  store double %604, ptr %609, align 8, !tbaa !9
  %610 = load double, ptr %26, align 8, !tbaa !9
  %611 = load double, ptr %31, align 8, !tbaa !9
  %612 = fsub double %610, %611
  store double %612, ptr %24, align 8, !tbaa !9
  %613 = load double, ptr %27, align 8, !tbaa !9
  %614 = load double, ptr %30, align 8, !tbaa !9
  %615 = fadd double %613, %614
  store double %615, ptr %25, align 8, !tbaa !9
  %616 = load double, ptr %18, align 8, !tbaa !9
  %617 = load double, ptr %24, align 8, !tbaa !9
  %618 = load double, ptr %19, align 8, !tbaa !9
  %619 = load double, ptr %25, align 8, !tbaa !9
  %620 = fmul double %618, %619
  %621 = fneg double %620
  %622 = call double @llvm.fmuladd.f64(double %616, double %617, double %621)
  %623 = load ptr, ptr %7, align 8, !tbaa !14
  %624 = load i32, ptr %10, align 4, !tbaa !16
  %625 = sext i32 %624 to i64
  %626 = getelementptr inbounds double, ptr %623, i64 %625
  store double %622, ptr %626, align 8, !tbaa !9
  %627 = load double, ptr %18, align 8, !tbaa !9
  %628 = load double, ptr %25, align 8, !tbaa !9
  %629 = load double, ptr %19, align 8, !tbaa !9
  %630 = load double, ptr %24, align 8, !tbaa !9
  %631 = fmul double %629, %630
  %632 = call double @llvm.fmuladd.f64(double %627, double %628, double %631)
  %633 = load ptr, ptr %7, align 8, !tbaa !14
  %634 = load i32, ptr %10, align 4, !tbaa !16
  %635 = add nsw i32 %634, 1
  %636 = sext i32 %635 to i64
  %637 = getelementptr inbounds double, ptr %633, i64 %636
  store double %632, ptr %637, align 8, !tbaa !9
  %638 = load double, ptr %26, align 8, !tbaa !9
  %639 = load double, ptr %31, align 8, !tbaa !9
  %640 = fadd double %638, %639
  store double %640, ptr %24, align 8, !tbaa !9
  %641 = load double, ptr %27, align 8, !tbaa !9
  %642 = load double, ptr %30, align 8, !tbaa !9
  %643 = fsub double %641, %642
  store double %643, ptr %25, align 8, !tbaa !9
  %644 = load double, ptr %22, align 8, !tbaa !9
  %645 = load double, ptr %24, align 8, !tbaa !9
  %646 = load double, ptr %23, align 8, !tbaa !9
  %647 = load double, ptr %25, align 8, !tbaa !9
  %648 = fmul double %646, %647
  %649 = fneg double %648
  %650 = call double @llvm.fmuladd.f64(double %644, double %645, double %649)
  %651 = load ptr, ptr %7, align 8, !tbaa !14
  %652 = load i32, ptr %12, align 4, !tbaa !16
  %653 = sext i32 %652 to i64
  %654 = getelementptr inbounds double, ptr %651, i64 %653
  store double %650, ptr %654, align 8, !tbaa !9
  %655 = load double, ptr %22, align 8, !tbaa !9
  %656 = load double, ptr %25, align 8, !tbaa !9
  %657 = load double, ptr %23, align 8, !tbaa !9
  %658 = load double, ptr %24, align 8, !tbaa !9
  %659 = fmul double %657, %658
  %660 = call double @llvm.fmuladd.f64(double %655, double %656, double %659)
  %661 = load ptr, ptr %7, align 8, !tbaa !14
  %662 = load i32, ptr %12, align 4, !tbaa !16
  %663 = add nsw i32 %662, 1
  %664 = sext i32 %663 to i64
  %665 = getelementptr inbounds double, ptr %661, i64 %664
  store double %660, ptr %665, align 8, !tbaa !9
  br label %666

666:                                              ; preds = %461
  %667 = load i32, ptr %9, align 4, !tbaa !16
  %668 = add nsw i32 %667, 2
  store i32 %668, ptr %9, align 4, !tbaa !16
  br label %455, !llvm.loop !50

669:                                              ; preds = %455
  %670 = load ptr, ptr %8, align 8, !tbaa !14
  %671 = load i32, ptr %15, align 4, !tbaa !16
  %672 = add nsw i32 %671, 2
  %673 = sext i32 %672 to i64
  %674 = getelementptr inbounds double, ptr %670, i64 %673
  %675 = load double, ptr %674, align 8, !tbaa !9
  store double %675, ptr %18, align 8, !tbaa !9
  %676 = load ptr, ptr %8, align 8, !tbaa !14
  %677 = load i32, ptr %15, align 4, !tbaa !16
  %678 = add nsw i32 %677, 3
  %679 = sext i32 %678 to i64
  %680 = getelementptr inbounds double, ptr %676, i64 %679
  %681 = load double, ptr %680, align 8, !tbaa !9
  store double %681, ptr %19, align 8, !tbaa !9
  %682 = load double, ptr %18, align 8, !tbaa !9
  %683 = load double, ptr %20, align 8, !tbaa !9
  %684 = fmul double 2.000000e+00, %683
  %685 = load double, ptr %19, align 8, !tbaa !9
  %686 = fneg double %684
  %687 = call double @llvm.fmuladd.f64(double %686, double %685, double %682)
  store double %687, ptr %22, align 8, !tbaa !9
  %688 = load double, ptr %20, align 8, !tbaa !9
  %689 = fmul double 2.000000e+00, %688
  %690 = load double, ptr %18, align 8, !tbaa !9
  %691 = load double, ptr %19, align 8, !tbaa !9
  %692 = fneg double %691
  %693 = call double @llvm.fmuladd.f64(double %689, double %690, double %692)
  store double %693, ptr %23, align 8, !tbaa !9
  %694 = load i32, ptr %13, align 4, !tbaa !16
  %695 = load i32, ptr %16, align 4, !tbaa !16
  %696 = add nsw i32 %694, %695
  store i32 %696, ptr %9, align 4, !tbaa !16
  br label %697

697:                                              ; preds = %912, %669
  %698 = load i32, ptr %9, align 4, !tbaa !16
  %699 = load i32, ptr %6, align 4, !tbaa !16
  %700 = load i32, ptr %13, align 4, !tbaa !16
  %701 = load i32, ptr %16, align 4, !tbaa !16
  %702 = add nsw i32 %700, %701
  %703 = add nsw i32 %699, %702
  %704 = icmp slt i32 %698, %703
  br i1 %704, label %705, label %915

705:                                              ; preds = %697
  %706 = load i32, ptr %9, align 4, !tbaa !16
  %707 = load i32, ptr %6, align 4, !tbaa !16
  %708 = add nsw i32 %706, %707
  store i32 %708, ptr %10, align 4, !tbaa !16
  %709 = load i32, ptr %10, align 4, !tbaa !16
  %710 = load i32, ptr %6, align 4, !tbaa !16
  %711 = add nsw i32 %709, %710
  store i32 %711, ptr %11, align 4, !tbaa !16
  %712 = load i32, ptr %11, align 4, !tbaa !16
  %713 = load i32, ptr %6, align 4, !tbaa !16
  %714 = add nsw i32 %712, %713
  store i32 %714, ptr %12, align 4, !tbaa !16
  %715 = load ptr, ptr %7, align 8, !tbaa !14
  %716 = load i32, ptr %9, align 4, !tbaa !16
  %717 = sext i32 %716 to i64
  %718 = getelementptr inbounds double, ptr %715, i64 %717
  %719 = load double, ptr %718, align 8, !tbaa !9
  %720 = load ptr, ptr %7, align 8, !tbaa !14
  %721 = load i32, ptr %10, align 4, !tbaa !16
  %722 = sext i32 %721 to i64
  %723 = getelementptr inbounds double, ptr %720, i64 %722
  %724 = load double, ptr %723, align 8, !tbaa !9
  %725 = fadd double %719, %724
  store double %725, ptr %24, align 8, !tbaa !9
  %726 = load ptr, ptr %7, align 8, !tbaa !14
  %727 = load i32, ptr %9, align 4, !tbaa !16
  %728 = add nsw i32 %727, 1
  %729 = sext i32 %728 to i64
  %730 = getelementptr inbounds double, ptr %726, i64 %729
  %731 = load double, ptr %730, align 8, !tbaa !9
  %732 = load ptr, ptr %7, align 8, !tbaa !14
  %733 = load i32, ptr %10, align 4, !tbaa !16
  %734 = add nsw i32 %733, 1
  %735 = sext i32 %734 to i64
  %736 = getelementptr inbounds double, ptr %732, i64 %735
  %737 = load double, ptr %736, align 8, !tbaa !9
  %738 = fadd double %731, %737
  store double %738, ptr %25, align 8, !tbaa !9
  %739 = load ptr, ptr %7, align 8, !tbaa !14
  %740 = load i32, ptr %9, align 4, !tbaa !16
  %741 = sext i32 %740 to i64
  %742 = getelementptr inbounds double, ptr %739, i64 %741
  %743 = load double, ptr %742, align 8, !tbaa !9
  %744 = load ptr, ptr %7, align 8, !tbaa !14
  %745 = load i32, ptr %10, align 4, !tbaa !16
  %746 = sext i32 %745 to i64
  %747 = getelementptr inbounds double, ptr %744, i64 %746
  %748 = load double, ptr %747, align 8, !tbaa !9
  %749 = fsub double %743, %748
  store double %749, ptr %26, align 8, !tbaa !9
  %750 = load ptr, ptr %7, align 8, !tbaa !14
  %751 = load i32, ptr %9, align 4, !tbaa !16
  %752 = add nsw i32 %751, 1
  %753 = sext i32 %752 to i64
  %754 = getelementptr inbounds double, ptr %750, i64 %753
  %755 = load double, ptr %754, align 8, !tbaa !9
  %756 = load ptr, ptr %7, align 8, !tbaa !14
  %757 = load i32, ptr %10, align 4, !tbaa !16
  %758 = add nsw i32 %757, 1
  %759 = sext i32 %758 to i64
  %760 = getelementptr inbounds double, ptr %756, i64 %759
  %761 = load double, ptr %760, align 8, !tbaa !9
  %762 = fsub double %755, %761
  store double %762, ptr %27, align 8, !tbaa !9
  %763 = load ptr, ptr %7, align 8, !tbaa !14
  %764 = load i32, ptr %11, align 4, !tbaa !16
  %765 = sext i32 %764 to i64
  %766 = getelementptr inbounds double, ptr %763, i64 %765
  %767 = load double, ptr %766, align 8, !tbaa !9
  %768 = load ptr, ptr %7, align 8, !tbaa !14
  %769 = load i32, ptr %12, align 4, !tbaa !16
  %770 = sext i32 %769 to i64
  %771 = getelementptr inbounds double, ptr %768, i64 %770
  %772 = load double, ptr %771, align 8, !tbaa !9
  %773 = fadd double %767, %772
  store double %773, ptr %28, align 8, !tbaa !9
  %774 = load ptr, ptr %7, align 8, !tbaa !14
  %775 = load i32, ptr %11, align 4, !tbaa !16
  %776 = add nsw i32 %775, 1
  %777 = sext i32 %776 to i64
  %778 = getelementptr inbounds double, ptr %774, i64 %777
  %779 = load double, ptr %778, align 8, !tbaa !9
  %780 = load ptr, ptr %7, align 8, !tbaa !14
  %781 = load i32, ptr %12, align 4, !tbaa !16
  %782 = add nsw i32 %781, 1
  %783 = sext i32 %782 to i64
  %784 = getelementptr inbounds double, ptr %780, i64 %783
  %785 = load double, ptr %784, align 8, !tbaa !9
  %786 = fadd double %779, %785
  store double %786, ptr %29, align 8, !tbaa !9
  %787 = load ptr, ptr %7, align 8, !tbaa !14
  %788 = load i32, ptr %11, align 4, !tbaa !16
  %789 = sext i32 %788 to i64
  %790 = getelementptr inbounds double, ptr %787, i64 %789
  %791 = load double, ptr %790, align 8, !tbaa !9
  %792 = load ptr, ptr %7, align 8, !tbaa !14
  %793 = load i32, ptr %12, align 4, !tbaa !16
  %794 = sext i32 %793 to i64
  %795 = getelementptr inbounds double, ptr %792, i64 %794
  %796 = load double, ptr %795, align 8, !tbaa !9
  %797 = fsub double %791, %796
  store double %797, ptr %30, align 8, !tbaa !9
  %798 = load ptr, ptr %7, align 8, !tbaa !14
  %799 = load i32, ptr %11, align 4, !tbaa !16
  %800 = add nsw i32 %799, 1
  %801 = sext i32 %800 to i64
  %802 = getelementptr inbounds double, ptr %798, i64 %801
  %803 = load double, ptr %802, align 8, !tbaa !9
  %804 = load ptr, ptr %7, align 8, !tbaa !14
  %805 = load i32, ptr %12, align 4, !tbaa !16
  %806 = add nsw i32 %805, 1
  %807 = sext i32 %806 to i64
  %808 = getelementptr inbounds double, ptr %804, i64 %807
  %809 = load double, ptr %808, align 8, !tbaa !9
  %810 = fsub double %803, %809
  store double %810, ptr %31, align 8, !tbaa !9
  %811 = load double, ptr %24, align 8, !tbaa !9
  %812 = load double, ptr %28, align 8, !tbaa !9
  %813 = fadd double %811, %812
  %814 = load ptr, ptr %7, align 8, !tbaa !14
  %815 = load i32, ptr %9, align 4, !tbaa !16
  %816 = sext i32 %815 to i64
  %817 = getelementptr inbounds double, ptr %814, i64 %816
  store double %813, ptr %817, align 8, !tbaa !9
  %818 = load double, ptr %25, align 8, !tbaa !9
  %819 = load double, ptr %29, align 8, !tbaa !9
  %820 = fadd double %818, %819
  %821 = load ptr, ptr %7, align 8, !tbaa !14
  %822 = load i32, ptr %9, align 4, !tbaa !16
  %823 = add nsw i32 %822, 1
  %824 = sext i32 %823 to i64
  %825 = getelementptr inbounds double, ptr %821, i64 %824
  store double %820, ptr %825, align 8, !tbaa !9
  %826 = load double, ptr %28, align 8, !tbaa !9
  %827 = load double, ptr %24, align 8, !tbaa !9
  %828 = fsub double %827, %826
  store double %828, ptr %24, align 8, !tbaa !9
  %829 = load double, ptr %29, align 8, !tbaa !9
  %830 = load double, ptr %25, align 8, !tbaa !9
  %831 = fsub double %830, %829
  store double %831, ptr %25, align 8, !tbaa !9
  %832 = load double, ptr %21, align 8, !tbaa !9
  %833 = fneg double %832
  %834 = load double, ptr %24, align 8, !tbaa !9
  %835 = load double, ptr %20, align 8, !tbaa !9
  %836 = load double, ptr %25, align 8, !tbaa !9
  %837 = fmul double %835, %836
  %838 = fneg double %837
  %839 = call double @llvm.fmuladd.f64(double %833, double %834, double %838)
  %840 = load ptr, ptr %7, align 8, !tbaa !14
  %841 = load i32, ptr %11, align 4, !tbaa !16
  %842 = sext i32 %841 to i64
  %843 = getelementptr inbounds double, ptr %840, i64 %842
  store double %839, ptr %843, align 8, !tbaa !9
  %844 = load double, ptr %21, align 8, !tbaa !9
  %845 = fneg double %844
  %846 = load double, ptr %25, align 8, !tbaa !9
  %847 = load double, ptr %20, align 8, !tbaa !9
  %848 = load double, ptr %24, align 8, !tbaa !9
  %849 = fmul double %847, %848
  %850 = call double @llvm.fmuladd.f64(double %845, double %846, double %849)
  %851 = load ptr, ptr %7, align 8, !tbaa !14
  %852 = load i32, ptr %11, align 4, !tbaa !16
  %853 = add nsw i32 %852, 1
  %854 = sext i32 %853 to i64
  %855 = getelementptr inbounds double, ptr %851, i64 %854
  store double %850, ptr %855, align 8, !tbaa !9
  %856 = load double, ptr %26, align 8, !tbaa !9
  %857 = load double, ptr %31, align 8, !tbaa !9
  %858 = fsub double %856, %857
  store double %858, ptr %24, align 8, !tbaa !9
  %859 = load double, ptr %27, align 8, !tbaa !9
  %860 = load double, ptr %30, align 8, !tbaa !9
  %861 = fadd double %859, %860
  store double %861, ptr %25, align 8, !tbaa !9
  %862 = load double, ptr %18, align 8, !tbaa !9
  %863 = load double, ptr %24, align 8, !tbaa !9
  %864 = load double, ptr %19, align 8, !tbaa !9
  %865 = load double, ptr %25, align 8, !tbaa !9
  %866 = fmul double %864, %865
  %867 = fneg double %866
  %868 = call double @llvm.fmuladd.f64(double %862, double %863, double %867)
  %869 = load ptr, ptr %7, align 8, !tbaa !14
  %870 = load i32, ptr %10, align 4, !tbaa !16
  %871 = sext i32 %870 to i64
  %872 = getelementptr inbounds double, ptr %869, i64 %871
  store double %868, ptr %872, align 8, !tbaa !9
  %873 = load double, ptr %18, align 8, !tbaa !9
  %874 = load double, ptr %25, align 8, !tbaa !9
  %875 = load double, ptr %19, align 8, !tbaa !9
  %876 = load double, ptr %24, align 8, !tbaa !9
  %877 = fmul double %875, %876
  %878 = call double @llvm.fmuladd.f64(double %873, double %874, double %877)
  %879 = load ptr, ptr %7, align 8, !tbaa !14
  %880 = load i32, ptr %10, align 4, !tbaa !16
  %881 = add nsw i32 %880, 1
  %882 = sext i32 %881 to i64
  %883 = getelementptr inbounds double, ptr %879, i64 %882
  store double %878, ptr %883, align 8, !tbaa !9
  %884 = load double, ptr %26, align 8, !tbaa !9
  %885 = load double, ptr %31, align 8, !tbaa !9
  %886 = fadd double %884, %885
  store double %886, ptr %24, align 8, !tbaa !9
  %887 = load double, ptr %27, align 8, !tbaa !9
  %888 = load double, ptr %30, align 8, !tbaa !9
  %889 = fsub double %887, %888
  store double %889, ptr %25, align 8, !tbaa !9
  %890 = load double, ptr %22, align 8, !tbaa !9
  %891 = load double, ptr %24, align 8, !tbaa !9
  %892 = load double, ptr %23, align 8, !tbaa !9
  %893 = load double, ptr %25, align 8, !tbaa !9
  %894 = fmul double %892, %893
  %895 = fneg double %894
  %896 = call double @llvm.fmuladd.f64(double %890, double %891, double %895)
  %897 = load ptr, ptr %7, align 8, !tbaa !14
  %898 = load i32, ptr %12, align 4, !tbaa !16
  %899 = sext i32 %898 to i64
  %900 = getelementptr inbounds double, ptr %897, i64 %899
  store double %896, ptr %900, align 8, !tbaa !9
  %901 = load double, ptr %22, align 8, !tbaa !9
  %902 = load double, ptr %25, align 8, !tbaa !9
  %903 = load double, ptr %23, align 8, !tbaa !9
  %904 = load double, ptr %24, align 8, !tbaa !9
  %905 = fmul double %903, %904
  %906 = call double @llvm.fmuladd.f64(double %901, double %902, double %905)
  %907 = load ptr, ptr %7, align 8, !tbaa !14
  %908 = load i32, ptr %12, align 4, !tbaa !16
  %909 = add nsw i32 %908, 1
  %910 = sext i32 %909 to i64
  %911 = getelementptr inbounds double, ptr %907, i64 %910
  store double %906, ptr %911, align 8, !tbaa !9
  br label %912

912:                                              ; preds = %705
  %913 = load i32, ptr %9, align 4, !tbaa !16
  %914 = add nsw i32 %913, 2
  store i32 %914, ptr %9, align 4, !tbaa !16
  br label %697, !llvm.loop !51

915:                                              ; preds = %697
  br label %916

916:                                              ; preds = %915
  %917 = load i32, ptr %17, align 4, !tbaa !16
  %918 = load i32, ptr %13, align 4, !tbaa !16
  %919 = add nsw i32 %918, %917
  store i32 %919, ptr %13, align 4, !tbaa !16
  br label %411, !llvm.loop !52

920:                                              ; preds = %411
  call void @llvm.lifetime.end.p0(ptr %31) #9
  call void @llvm.lifetime.end.p0(ptr %30) #9
  call void @llvm.lifetime.end.p0(ptr %29) #9
  call void @llvm.lifetime.end.p0(ptr %28) #9
  call void @llvm.lifetime.end.p0(ptr %27) #9
  call void @llvm.lifetime.end.p0(ptr %26) #9
  call void @llvm.lifetime.end.p0(ptr %25) #9
  call void @llvm.lifetime.end.p0(ptr %24) #9
  call void @llvm.lifetime.end.p0(ptr %23) #9
  call void @llvm.lifetime.end.p0(ptr %22) #9
  call void @llvm.lifetime.end.p0(ptr %21) #9
  call void @llvm.lifetime.end.p0(ptr %20) #9
  call void @llvm.lifetime.end.p0(ptr %19) #9
  call void @llvm.lifetime.end.p0(ptr %18) #9
  call void @llvm.lifetime.end.p0(ptr %17) #9
  call void @llvm.lifetime.end.p0(ptr %16) #9
  call void @llvm.lifetime.end.p0(ptr %15) #9
  call void @llvm.lifetime.end.p0(ptr %14) #9
  call void @llvm.lifetime.end.p0(ptr %13) #9
  call void @llvm.lifetime.end.p0(ptr %12) #9
  call void @llvm.lifetime.end.p0(ptr %11) #9
  call void @llvm.lifetime.end.p0(ptr %10) #9
  call void @llvm.lifetime.end.p0(ptr %9) #9
  ret void
}

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind allocsize(1) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #5 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { cold noreturn nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #7 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #8 = { inlinehint nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #9 = { nounwind }
attributes #10 = { nounwind allocsize(1) }
attributes #11 = { cold noreturn nounwind }

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
!11 = !{!12, !12, i64 0}
!12 = !{!"p1 int", !13, i64 0}
!13 = !{!"any pointer", !7, i64 0}
!14 = !{!15, !15, i64 0}
!15 = !{!"p1 double", !13, i64 0}
!16 = !{!6, !6, i64 0}
!17 = distinct !{!17, !18}
!18 = !{!"llvm.loop.mustprogress"}
!19 = distinct !{!19, !18}
!20 = distinct !{!20, !18}
!21 = distinct !{!21, !18}
!22 = !{!23, !24, i64 0}
!23 = !{!"timeval", !24, i64 0, !24, i64 8}
!24 = !{!"long", !7, i64 0}
!25 = !{!23, !24, i64 8}
!26 = distinct !{!26, !18}
!27 = distinct !{!27, !18}
!28 = distinct !{!28, !18}
!29 = distinct !{!29, !18}
!30 = distinct !{!30, !18}
!31 = distinct !{!31, !18}
!32 = distinct !{!32, !18}
!33 = distinct !{!33, !18}
!34 = distinct !{!34, !18}
!35 = distinct !{!35, !18}
!36 = distinct !{!36, !18}
!37 = distinct !{!37, !18}
!38 = distinct !{!38, !18}
!39 = distinct !{!39, !18}
!40 = distinct !{!40, !18}
!41 = distinct !{!41, !18}
!42 = distinct !{!42, !18}
!43 = distinct !{!43, !18}
!44 = distinct !{!44, !18}
!45 = distinct !{!45, !18}
!46 = distinct !{!46, !18}
!47 = distinct !{!47, !18}
!48 = distinct !{!48, !18}
!49 = distinct !{!49, !18}
!50 = distinct !{!50, !18}
!51 = distinct !{!51, !18}
!52 = distinct !{!52, !18}
