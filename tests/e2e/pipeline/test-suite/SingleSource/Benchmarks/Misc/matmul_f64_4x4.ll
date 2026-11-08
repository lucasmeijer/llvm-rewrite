; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/matmul_f64_4x4.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/matmul_f64_4x4.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/matmul_f64_4x4.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@__const.main.A = private unnamed_addr constant [4 x [4 x double]] [[4 x double] [double 4.500000e+00, double 1.300000e+00, double 6.000000e+00, double 4.100000e+00], [4 x double] [double 2.500000e+00, double 7.200000e+00, double 7.700000e+00, double 1.700000e+00], [4 x double] [double 6.700000e+00, double 1.300000e+00, double 9.400000e+00, double 1.300000e+00], [4 x double] [double 1.100000e+00, double 2.200000e+00, double 3.000000e+00, double 2.100000e+00]], align 16
@__const.main.B = private unnamed_addr constant [4 x [4 x double]] [[4 x double] [double 1.000000e+00, double 7.900000e+00, double 5.100000e+00, double 3.400000e+00], [4 x double] [double 6.600000e+00, double 2.800000e+00, double 5.400000e+00, double f0x4022666666666666], [4 x double] [double 5.000000e+00, double 4.100000e+00, double 4.100000e+00, double 9.900000e+00], [4 x double] [double 8.400000e+00, double 3.700000e+00, double 9.500000e+00, double 6.400000e+00]], align 16
@.str = private unnamed_addr constant [6 x i8] c"%8.2f\00", align 1
@.str.1 = private unnamed_addr constant [1 x i8] zeroinitializer, align 1

; Function Attrs: noinline nounwind uwtable
define dso_local void @wrap_mul4(ptr noundef %0, ptr noundef %1, ptr noundef %2) #0 {
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  store ptr %0, ptr %4, align 8, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !9
  store ptr %2, ptr %6, align 8, !tbaa !9
  %7 = load ptr, ptr %4, align 8, !tbaa !9
  %8 = load ptr, ptr %5, align 8, !tbaa !9
  %9 = load ptr, ptr %6, align 8, !tbaa !9
  call void @mul4(ptr noundef %7, ptr noundef %8, ptr noundef %9)
  ret void
}

; Function Attrs: nounwind uwtable
define internal void @mul4(ptr noundef %0, ptr noundef %1, ptr noundef %2) #1 {
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca i32, align 4
  %8 = alloca [16 x double], align 16
  store ptr %0, ptr %4, align 8, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !9
  store ptr %2, ptr %6, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %7) #5
  call void @llvm.lifetime.start.p0(ptr %8) #5
  %9 = load ptr, ptr %5, align 8, !tbaa !9
  %10 = getelementptr inbounds [4 x double], ptr %9, i64 0
  %11 = getelementptr inbounds [4 x double], ptr %10, i64 0, i64 0
  %12 = load double, ptr %11, align 8, !tbaa !12
  %13 = load ptr, ptr %6, align 8, !tbaa !9
  %14 = getelementptr inbounds [4 x double], ptr %13, i64 0
  %15 = getelementptr inbounds [4 x double], ptr %14, i64 0, i64 0
  %16 = load double, ptr %15, align 8, !tbaa !12
  %17 = load ptr, ptr %5, align 8, !tbaa !9
  %18 = getelementptr inbounds [4 x double], ptr %17, i64 0
  %19 = getelementptr inbounds [4 x double], ptr %18, i64 0, i64 1
  %20 = load double, ptr %19, align 8, !tbaa !12
  %21 = load ptr, ptr %6, align 8, !tbaa !9
  %22 = getelementptr inbounds [4 x double], ptr %21, i64 1
  %23 = getelementptr inbounds [4 x double], ptr %22, i64 0, i64 0
  %24 = load double, ptr %23, align 8, !tbaa !12
  %25 = fmul double %20, %24
  %26 = call double @llvm.fmuladd.f64(double %12, double %16, double %25)
  %27 = load ptr, ptr %5, align 8, !tbaa !9
  %28 = getelementptr inbounds [4 x double], ptr %27, i64 0
  %29 = getelementptr inbounds [4 x double], ptr %28, i64 0, i64 2
  %30 = load double, ptr %29, align 8, !tbaa !12
  %31 = load ptr, ptr %6, align 8, !tbaa !9
  %32 = getelementptr inbounds [4 x double], ptr %31, i64 2
  %33 = getelementptr inbounds [4 x double], ptr %32, i64 0, i64 0
  %34 = load double, ptr %33, align 8, !tbaa !12
  %35 = call double @llvm.fmuladd.f64(double %30, double %34, double %26)
  %36 = load ptr, ptr %5, align 8, !tbaa !9
  %37 = getelementptr inbounds [4 x double], ptr %36, i64 0
  %38 = getelementptr inbounds [4 x double], ptr %37, i64 0, i64 3
  %39 = load double, ptr %38, align 8, !tbaa !12
  %40 = load ptr, ptr %6, align 8, !tbaa !9
  %41 = getelementptr inbounds [4 x double], ptr %40, i64 3
  %42 = getelementptr inbounds [4 x double], ptr %41, i64 0, i64 0
  %43 = load double, ptr %42, align 8, !tbaa !12
  %44 = call double @llvm.fmuladd.f64(double %39, double %43, double %35)
  %45 = getelementptr inbounds [16 x double], ptr %8, i64 0, i64 0
  store double %44, ptr %45, align 16, !tbaa !12
  %46 = load ptr, ptr %5, align 8, !tbaa !9
  %47 = getelementptr inbounds [4 x double], ptr %46, i64 0
  %48 = getelementptr inbounds [4 x double], ptr %47, i64 0, i64 0
  %49 = load double, ptr %48, align 8, !tbaa !12
  %50 = load ptr, ptr %6, align 8, !tbaa !9
  %51 = getelementptr inbounds [4 x double], ptr %50, i64 0
  %52 = getelementptr inbounds [4 x double], ptr %51, i64 0, i64 1
  %53 = load double, ptr %52, align 8, !tbaa !12
  %54 = load ptr, ptr %5, align 8, !tbaa !9
  %55 = getelementptr inbounds [4 x double], ptr %54, i64 0
  %56 = getelementptr inbounds [4 x double], ptr %55, i64 0, i64 1
  %57 = load double, ptr %56, align 8, !tbaa !12
  %58 = load ptr, ptr %6, align 8, !tbaa !9
  %59 = getelementptr inbounds [4 x double], ptr %58, i64 1
  %60 = getelementptr inbounds [4 x double], ptr %59, i64 0, i64 1
  %61 = load double, ptr %60, align 8, !tbaa !12
  %62 = fmul double %57, %61
  %63 = call double @llvm.fmuladd.f64(double %49, double %53, double %62)
  %64 = load ptr, ptr %5, align 8, !tbaa !9
  %65 = getelementptr inbounds [4 x double], ptr %64, i64 0
  %66 = getelementptr inbounds [4 x double], ptr %65, i64 0, i64 2
  %67 = load double, ptr %66, align 8, !tbaa !12
  %68 = load ptr, ptr %6, align 8, !tbaa !9
  %69 = getelementptr inbounds [4 x double], ptr %68, i64 2
  %70 = getelementptr inbounds [4 x double], ptr %69, i64 0, i64 1
  %71 = load double, ptr %70, align 8, !tbaa !12
  %72 = call double @llvm.fmuladd.f64(double %67, double %71, double %63)
  %73 = load ptr, ptr %5, align 8, !tbaa !9
  %74 = getelementptr inbounds [4 x double], ptr %73, i64 0
  %75 = getelementptr inbounds [4 x double], ptr %74, i64 0, i64 3
  %76 = load double, ptr %75, align 8, !tbaa !12
  %77 = load ptr, ptr %6, align 8, !tbaa !9
  %78 = getelementptr inbounds [4 x double], ptr %77, i64 3
  %79 = getelementptr inbounds [4 x double], ptr %78, i64 0, i64 1
  %80 = load double, ptr %79, align 8, !tbaa !12
  %81 = call double @llvm.fmuladd.f64(double %76, double %80, double %72)
  %82 = getelementptr inbounds [16 x double], ptr %8, i64 0, i64 1
  store double %81, ptr %82, align 8, !tbaa !12
  %83 = load ptr, ptr %5, align 8, !tbaa !9
  %84 = getelementptr inbounds [4 x double], ptr %83, i64 0
  %85 = getelementptr inbounds [4 x double], ptr %84, i64 0, i64 0
  %86 = load double, ptr %85, align 8, !tbaa !12
  %87 = load ptr, ptr %6, align 8, !tbaa !9
  %88 = getelementptr inbounds [4 x double], ptr %87, i64 0
  %89 = getelementptr inbounds [4 x double], ptr %88, i64 0, i64 2
  %90 = load double, ptr %89, align 8, !tbaa !12
  %91 = load ptr, ptr %5, align 8, !tbaa !9
  %92 = getelementptr inbounds [4 x double], ptr %91, i64 0
  %93 = getelementptr inbounds [4 x double], ptr %92, i64 0, i64 1
  %94 = load double, ptr %93, align 8, !tbaa !12
  %95 = load ptr, ptr %6, align 8, !tbaa !9
  %96 = getelementptr inbounds [4 x double], ptr %95, i64 1
  %97 = getelementptr inbounds [4 x double], ptr %96, i64 0, i64 2
  %98 = load double, ptr %97, align 8, !tbaa !12
  %99 = fmul double %94, %98
  %100 = call double @llvm.fmuladd.f64(double %86, double %90, double %99)
  %101 = load ptr, ptr %5, align 8, !tbaa !9
  %102 = getelementptr inbounds [4 x double], ptr %101, i64 0
  %103 = getelementptr inbounds [4 x double], ptr %102, i64 0, i64 2
  %104 = load double, ptr %103, align 8, !tbaa !12
  %105 = load ptr, ptr %6, align 8, !tbaa !9
  %106 = getelementptr inbounds [4 x double], ptr %105, i64 2
  %107 = getelementptr inbounds [4 x double], ptr %106, i64 0, i64 2
  %108 = load double, ptr %107, align 8, !tbaa !12
  %109 = call double @llvm.fmuladd.f64(double %104, double %108, double %100)
  %110 = load ptr, ptr %5, align 8, !tbaa !9
  %111 = getelementptr inbounds [4 x double], ptr %110, i64 0
  %112 = getelementptr inbounds [4 x double], ptr %111, i64 0, i64 3
  %113 = load double, ptr %112, align 8, !tbaa !12
  %114 = load ptr, ptr %6, align 8, !tbaa !9
  %115 = getelementptr inbounds [4 x double], ptr %114, i64 3
  %116 = getelementptr inbounds [4 x double], ptr %115, i64 0, i64 2
  %117 = load double, ptr %116, align 8, !tbaa !12
  %118 = call double @llvm.fmuladd.f64(double %113, double %117, double %109)
  %119 = getelementptr inbounds [16 x double], ptr %8, i64 0, i64 2
  store double %118, ptr %119, align 16, !tbaa !12
  %120 = load ptr, ptr %5, align 8, !tbaa !9
  %121 = getelementptr inbounds [4 x double], ptr %120, i64 0
  %122 = getelementptr inbounds [4 x double], ptr %121, i64 0, i64 0
  %123 = load double, ptr %122, align 8, !tbaa !12
  %124 = load ptr, ptr %6, align 8, !tbaa !9
  %125 = getelementptr inbounds [4 x double], ptr %124, i64 0
  %126 = getelementptr inbounds [4 x double], ptr %125, i64 0, i64 3
  %127 = load double, ptr %126, align 8, !tbaa !12
  %128 = load ptr, ptr %5, align 8, !tbaa !9
  %129 = getelementptr inbounds [4 x double], ptr %128, i64 0
  %130 = getelementptr inbounds [4 x double], ptr %129, i64 0, i64 1
  %131 = load double, ptr %130, align 8, !tbaa !12
  %132 = load ptr, ptr %6, align 8, !tbaa !9
  %133 = getelementptr inbounds [4 x double], ptr %132, i64 1
  %134 = getelementptr inbounds [4 x double], ptr %133, i64 0, i64 3
  %135 = load double, ptr %134, align 8, !tbaa !12
  %136 = fmul double %131, %135
  %137 = call double @llvm.fmuladd.f64(double %123, double %127, double %136)
  %138 = load ptr, ptr %5, align 8, !tbaa !9
  %139 = getelementptr inbounds [4 x double], ptr %138, i64 0
  %140 = getelementptr inbounds [4 x double], ptr %139, i64 0, i64 2
  %141 = load double, ptr %140, align 8, !tbaa !12
  %142 = load ptr, ptr %6, align 8, !tbaa !9
  %143 = getelementptr inbounds [4 x double], ptr %142, i64 2
  %144 = getelementptr inbounds [4 x double], ptr %143, i64 0, i64 3
  %145 = load double, ptr %144, align 8, !tbaa !12
  %146 = call double @llvm.fmuladd.f64(double %141, double %145, double %137)
  %147 = load ptr, ptr %5, align 8, !tbaa !9
  %148 = getelementptr inbounds [4 x double], ptr %147, i64 0
  %149 = getelementptr inbounds [4 x double], ptr %148, i64 0, i64 3
  %150 = load double, ptr %149, align 8, !tbaa !12
  %151 = load ptr, ptr %6, align 8, !tbaa !9
  %152 = getelementptr inbounds [4 x double], ptr %151, i64 3
  %153 = getelementptr inbounds [4 x double], ptr %152, i64 0, i64 3
  %154 = load double, ptr %153, align 8, !tbaa !12
  %155 = call double @llvm.fmuladd.f64(double %150, double %154, double %146)
  %156 = getelementptr inbounds [16 x double], ptr %8, i64 0, i64 3
  store double %155, ptr %156, align 8, !tbaa !12
  %157 = load ptr, ptr %5, align 8, !tbaa !9
  %158 = getelementptr inbounds [4 x double], ptr %157, i64 1
  %159 = getelementptr inbounds [4 x double], ptr %158, i64 0, i64 0
  %160 = load double, ptr %159, align 8, !tbaa !12
  %161 = load ptr, ptr %6, align 8, !tbaa !9
  %162 = getelementptr inbounds [4 x double], ptr %161, i64 0
  %163 = getelementptr inbounds [4 x double], ptr %162, i64 0, i64 0
  %164 = load double, ptr %163, align 8, !tbaa !12
  %165 = load ptr, ptr %5, align 8, !tbaa !9
  %166 = getelementptr inbounds [4 x double], ptr %165, i64 1
  %167 = getelementptr inbounds [4 x double], ptr %166, i64 0, i64 1
  %168 = load double, ptr %167, align 8, !tbaa !12
  %169 = load ptr, ptr %6, align 8, !tbaa !9
  %170 = getelementptr inbounds [4 x double], ptr %169, i64 1
  %171 = getelementptr inbounds [4 x double], ptr %170, i64 0, i64 0
  %172 = load double, ptr %171, align 8, !tbaa !12
  %173 = fmul double %168, %172
  %174 = call double @llvm.fmuladd.f64(double %160, double %164, double %173)
  %175 = load ptr, ptr %5, align 8, !tbaa !9
  %176 = getelementptr inbounds [4 x double], ptr %175, i64 1
  %177 = getelementptr inbounds [4 x double], ptr %176, i64 0, i64 2
  %178 = load double, ptr %177, align 8, !tbaa !12
  %179 = load ptr, ptr %6, align 8, !tbaa !9
  %180 = getelementptr inbounds [4 x double], ptr %179, i64 2
  %181 = getelementptr inbounds [4 x double], ptr %180, i64 0, i64 0
  %182 = load double, ptr %181, align 8, !tbaa !12
  %183 = call double @llvm.fmuladd.f64(double %178, double %182, double %174)
  %184 = load ptr, ptr %5, align 8, !tbaa !9
  %185 = getelementptr inbounds [4 x double], ptr %184, i64 1
  %186 = getelementptr inbounds [4 x double], ptr %185, i64 0, i64 3
  %187 = load double, ptr %186, align 8, !tbaa !12
  %188 = load ptr, ptr %6, align 8, !tbaa !9
  %189 = getelementptr inbounds [4 x double], ptr %188, i64 3
  %190 = getelementptr inbounds [4 x double], ptr %189, i64 0, i64 0
  %191 = load double, ptr %190, align 8, !tbaa !12
  %192 = call double @llvm.fmuladd.f64(double %187, double %191, double %183)
  %193 = getelementptr inbounds [16 x double], ptr %8, i64 0, i64 4
  store double %192, ptr %193, align 16, !tbaa !12
  %194 = load ptr, ptr %5, align 8, !tbaa !9
  %195 = getelementptr inbounds [4 x double], ptr %194, i64 1
  %196 = getelementptr inbounds [4 x double], ptr %195, i64 0, i64 0
  %197 = load double, ptr %196, align 8, !tbaa !12
  %198 = load ptr, ptr %6, align 8, !tbaa !9
  %199 = getelementptr inbounds [4 x double], ptr %198, i64 0
  %200 = getelementptr inbounds [4 x double], ptr %199, i64 0, i64 1
  %201 = load double, ptr %200, align 8, !tbaa !12
  %202 = load ptr, ptr %5, align 8, !tbaa !9
  %203 = getelementptr inbounds [4 x double], ptr %202, i64 1
  %204 = getelementptr inbounds [4 x double], ptr %203, i64 0, i64 1
  %205 = load double, ptr %204, align 8, !tbaa !12
  %206 = load ptr, ptr %6, align 8, !tbaa !9
  %207 = getelementptr inbounds [4 x double], ptr %206, i64 1
  %208 = getelementptr inbounds [4 x double], ptr %207, i64 0, i64 1
  %209 = load double, ptr %208, align 8, !tbaa !12
  %210 = fmul double %205, %209
  %211 = call double @llvm.fmuladd.f64(double %197, double %201, double %210)
  %212 = load ptr, ptr %5, align 8, !tbaa !9
  %213 = getelementptr inbounds [4 x double], ptr %212, i64 1
  %214 = getelementptr inbounds [4 x double], ptr %213, i64 0, i64 2
  %215 = load double, ptr %214, align 8, !tbaa !12
  %216 = load ptr, ptr %6, align 8, !tbaa !9
  %217 = getelementptr inbounds [4 x double], ptr %216, i64 2
  %218 = getelementptr inbounds [4 x double], ptr %217, i64 0, i64 1
  %219 = load double, ptr %218, align 8, !tbaa !12
  %220 = call double @llvm.fmuladd.f64(double %215, double %219, double %211)
  %221 = load ptr, ptr %5, align 8, !tbaa !9
  %222 = getelementptr inbounds [4 x double], ptr %221, i64 1
  %223 = getelementptr inbounds [4 x double], ptr %222, i64 0, i64 3
  %224 = load double, ptr %223, align 8, !tbaa !12
  %225 = load ptr, ptr %6, align 8, !tbaa !9
  %226 = getelementptr inbounds [4 x double], ptr %225, i64 3
  %227 = getelementptr inbounds [4 x double], ptr %226, i64 0, i64 1
  %228 = load double, ptr %227, align 8, !tbaa !12
  %229 = call double @llvm.fmuladd.f64(double %224, double %228, double %220)
  %230 = getelementptr inbounds [16 x double], ptr %8, i64 0, i64 5
  store double %229, ptr %230, align 8, !tbaa !12
  %231 = load ptr, ptr %5, align 8, !tbaa !9
  %232 = getelementptr inbounds [4 x double], ptr %231, i64 1
  %233 = getelementptr inbounds [4 x double], ptr %232, i64 0, i64 0
  %234 = load double, ptr %233, align 8, !tbaa !12
  %235 = load ptr, ptr %6, align 8, !tbaa !9
  %236 = getelementptr inbounds [4 x double], ptr %235, i64 0
  %237 = getelementptr inbounds [4 x double], ptr %236, i64 0, i64 2
  %238 = load double, ptr %237, align 8, !tbaa !12
  %239 = load ptr, ptr %5, align 8, !tbaa !9
  %240 = getelementptr inbounds [4 x double], ptr %239, i64 1
  %241 = getelementptr inbounds [4 x double], ptr %240, i64 0, i64 1
  %242 = load double, ptr %241, align 8, !tbaa !12
  %243 = load ptr, ptr %6, align 8, !tbaa !9
  %244 = getelementptr inbounds [4 x double], ptr %243, i64 1
  %245 = getelementptr inbounds [4 x double], ptr %244, i64 0, i64 2
  %246 = load double, ptr %245, align 8, !tbaa !12
  %247 = fmul double %242, %246
  %248 = call double @llvm.fmuladd.f64(double %234, double %238, double %247)
  %249 = load ptr, ptr %5, align 8, !tbaa !9
  %250 = getelementptr inbounds [4 x double], ptr %249, i64 1
  %251 = getelementptr inbounds [4 x double], ptr %250, i64 0, i64 2
  %252 = load double, ptr %251, align 8, !tbaa !12
  %253 = load ptr, ptr %6, align 8, !tbaa !9
  %254 = getelementptr inbounds [4 x double], ptr %253, i64 2
  %255 = getelementptr inbounds [4 x double], ptr %254, i64 0, i64 2
  %256 = load double, ptr %255, align 8, !tbaa !12
  %257 = call double @llvm.fmuladd.f64(double %252, double %256, double %248)
  %258 = load ptr, ptr %5, align 8, !tbaa !9
  %259 = getelementptr inbounds [4 x double], ptr %258, i64 1
  %260 = getelementptr inbounds [4 x double], ptr %259, i64 0, i64 3
  %261 = load double, ptr %260, align 8, !tbaa !12
  %262 = load ptr, ptr %6, align 8, !tbaa !9
  %263 = getelementptr inbounds [4 x double], ptr %262, i64 3
  %264 = getelementptr inbounds [4 x double], ptr %263, i64 0, i64 2
  %265 = load double, ptr %264, align 8, !tbaa !12
  %266 = call double @llvm.fmuladd.f64(double %261, double %265, double %257)
  %267 = getelementptr inbounds [16 x double], ptr %8, i64 0, i64 6
  store double %266, ptr %267, align 16, !tbaa !12
  %268 = load ptr, ptr %5, align 8, !tbaa !9
  %269 = getelementptr inbounds [4 x double], ptr %268, i64 1
  %270 = getelementptr inbounds [4 x double], ptr %269, i64 0, i64 0
  %271 = load double, ptr %270, align 8, !tbaa !12
  %272 = load ptr, ptr %6, align 8, !tbaa !9
  %273 = getelementptr inbounds [4 x double], ptr %272, i64 0
  %274 = getelementptr inbounds [4 x double], ptr %273, i64 0, i64 3
  %275 = load double, ptr %274, align 8, !tbaa !12
  %276 = load ptr, ptr %5, align 8, !tbaa !9
  %277 = getelementptr inbounds [4 x double], ptr %276, i64 1
  %278 = getelementptr inbounds [4 x double], ptr %277, i64 0, i64 1
  %279 = load double, ptr %278, align 8, !tbaa !12
  %280 = load ptr, ptr %6, align 8, !tbaa !9
  %281 = getelementptr inbounds [4 x double], ptr %280, i64 1
  %282 = getelementptr inbounds [4 x double], ptr %281, i64 0, i64 3
  %283 = load double, ptr %282, align 8, !tbaa !12
  %284 = fmul double %279, %283
  %285 = call double @llvm.fmuladd.f64(double %271, double %275, double %284)
  %286 = load ptr, ptr %5, align 8, !tbaa !9
  %287 = getelementptr inbounds [4 x double], ptr %286, i64 1
  %288 = getelementptr inbounds [4 x double], ptr %287, i64 0, i64 2
  %289 = load double, ptr %288, align 8, !tbaa !12
  %290 = load ptr, ptr %6, align 8, !tbaa !9
  %291 = getelementptr inbounds [4 x double], ptr %290, i64 2
  %292 = getelementptr inbounds [4 x double], ptr %291, i64 0, i64 3
  %293 = load double, ptr %292, align 8, !tbaa !12
  %294 = call double @llvm.fmuladd.f64(double %289, double %293, double %285)
  %295 = load ptr, ptr %5, align 8, !tbaa !9
  %296 = getelementptr inbounds [4 x double], ptr %295, i64 1
  %297 = getelementptr inbounds [4 x double], ptr %296, i64 0, i64 3
  %298 = load double, ptr %297, align 8, !tbaa !12
  %299 = load ptr, ptr %6, align 8, !tbaa !9
  %300 = getelementptr inbounds [4 x double], ptr %299, i64 3
  %301 = getelementptr inbounds [4 x double], ptr %300, i64 0, i64 3
  %302 = load double, ptr %301, align 8, !tbaa !12
  %303 = call double @llvm.fmuladd.f64(double %298, double %302, double %294)
  %304 = getelementptr inbounds [16 x double], ptr %8, i64 0, i64 7
  store double %303, ptr %304, align 8, !tbaa !12
  %305 = load ptr, ptr %5, align 8, !tbaa !9
  %306 = getelementptr inbounds [4 x double], ptr %305, i64 2
  %307 = getelementptr inbounds [4 x double], ptr %306, i64 0, i64 0
  %308 = load double, ptr %307, align 8, !tbaa !12
  %309 = load ptr, ptr %6, align 8, !tbaa !9
  %310 = getelementptr inbounds [4 x double], ptr %309, i64 0
  %311 = getelementptr inbounds [4 x double], ptr %310, i64 0, i64 0
  %312 = load double, ptr %311, align 8, !tbaa !12
  %313 = load ptr, ptr %5, align 8, !tbaa !9
  %314 = getelementptr inbounds [4 x double], ptr %313, i64 2
  %315 = getelementptr inbounds [4 x double], ptr %314, i64 0, i64 1
  %316 = load double, ptr %315, align 8, !tbaa !12
  %317 = load ptr, ptr %6, align 8, !tbaa !9
  %318 = getelementptr inbounds [4 x double], ptr %317, i64 1
  %319 = getelementptr inbounds [4 x double], ptr %318, i64 0, i64 0
  %320 = load double, ptr %319, align 8, !tbaa !12
  %321 = fmul double %316, %320
  %322 = call double @llvm.fmuladd.f64(double %308, double %312, double %321)
  %323 = load ptr, ptr %5, align 8, !tbaa !9
  %324 = getelementptr inbounds [4 x double], ptr %323, i64 2
  %325 = getelementptr inbounds [4 x double], ptr %324, i64 0, i64 2
  %326 = load double, ptr %325, align 8, !tbaa !12
  %327 = load ptr, ptr %6, align 8, !tbaa !9
  %328 = getelementptr inbounds [4 x double], ptr %327, i64 2
  %329 = getelementptr inbounds [4 x double], ptr %328, i64 0, i64 0
  %330 = load double, ptr %329, align 8, !tbaa !12
  %331 = call double @llvm.fmuladd.f64(double %326, double %330, double %322)
  %332 = load ptr, ptr %5, align 8, !tbaa !9
  %333 = getelementptr inbounds [4 x double], ptr %332, i64 2
  %334 = getelementptr inbounds [4 x double], ptr %333, i64 0, i64 3
  %335 = load double, ptr %334, align 8, !tbaa !12
  %336 = load ptr, ptr %6, align 8, !tbaa !9
  %337 = getelementptr inbounds [4 x double], ptr %336, i64 3
  %338 = getelementptr inbounds [4 x double], ptr %337, i64 0, i64 0
  %339 = load double, ptr %338, align 8, !tbaa !12
  %340 = call double @llvm.fmuladd.f64(double %335, double %339, double %331)
  %341 = getelementptr inbounds [16 x double], ptr %8, i64 0, i64 8
  store double %340, ptr %341, align 16, !tbaa !12
  %342 = load ptr, ptr %5, align 8, !tbaa !9
  %343 = getelementptr inbounds [4 x double], ptr %342, i64 2
  %344 = getelementptr inbounds [4 x double], ptr %343, i64 0, i64 0
  %345 = load double, ptr %344, align 8, !tbaa !12
  %346 = load ptr, ptr %6, align 8, !tbaa !9
  %347 = getelementptr inbounds [4 x double], ptr %346, i64 0
  %348 = getelementptr inbounds [4 x double], ptr %347, i64 0, i64 1
  %349 = load double, ptr %348, align 8, !tbaa !12
  %350 = load ptr, ptr %5, align 8, !tbaa !9
  %351 = getelementptr inbounds [4 x double], ptr %350, i64 2
  %352 = getelementptr inbounds [4 x double], ptr %351, i64 0, i64 1
  %353 = load double, ptr %352, align 8, !tbaa !12
  %354 = load ptr, ptr %6, align 8, !tbaa !9
  %355 = getelementptr inbounds [4 x double], ptr %354, i64 1
  %356 = getelementptr inbounds [4 x double], ptr %355, i64 0, i64 1
  %357 = load double, ptr %356, align 8, !tbaa !12
  %358 = fmul double %353, %357
  %359 = call double @llvm.fmuladd.f64(double %345, double %349, double %358)
  %360 = load ptr, ptr %5, align 8, !tbaa !9
  %361 = getelementptr inbounds [4 x double], ptr %360, i64 2
  %362 = getelementptr inbounds [4 x double], ptr %361, i64 0, i64 2
  %363 = load double, ptr %362, align 8, !tbaa !12
  %364 = load ptr, ptr %6, align 8, !tbaa !9
  %365 = getelementptr inbounds [4 x double], ptr %364, i64 2
  %366 = getelementptr inbounds [4 x double], ptr %365, i64 0, i64 1
  %367 = load double, ptr %366, align 8, !tbaa !12
  %368 = call double @llvm.fmuladd.f64(double %363, double %367, double %359)
  %369 = load ptr, ptr %5, align 8, !tbaa !9
  %370 = getelementptr inbounds [4 x double], ptr %369, i64 2
  %371 = getelementptr inbounds [4 x double], ptr %370, i64 0, i64 3
  %372 = load double, ptr %371, align 8, !tbaa !12
  %373 = load ptr, ptr %6, align 8, !tbaa !9
  %374 = getelementptr inbounds [4 x double], ptr %373, i64 3
  %375 = getelementptr inbounds [4 x double], ptr %374, i64 0, i64 1
  %376 = load double, ptr %375, align 8, !tbaa !12
  %377 = call double @llvm.fmuladd.f64(double %372, double %376, double %368)
  %378 = getelementptr inbounds [16 x double], ptr %8, i64 0, i64 9
  store double %377, ptr %378, align 8, !tbaa !12
  %379 = load ptr, ptr %5, align 8, !tbaa !9
  %380 = getelementptr inbounds [4 x double], ptr %379, i64 2
  %381 = getelementptr inbounds [4 x double], ptr %380, i64 0, i64 0
  %382 = load double, ptr %381, align 8, !tbaa !12
  %383 = load ptr, ptr %6, align 8, !tbaa !9
  %384 = getelementptr inbounds [4 x double], ptr %383, i64 0
  %385 = getelementptr inbounds [4 x double], ptr %384, i64 0, i64 2
  %386 = load double, ptr %385, align 8, !tbaa !12
  %387 = load ptr, ptr %5, align 8, !tbaa !9
  %388 = getelementptr inbounds [4 x double], ptr %387, i64 2
  %389 = getelementptr inbounds [4 x double], ptr %388, i64 0, i64 1
  %390 = load double, ptr %389, align 8, !tbaa !12
  %391 = load ptr, ptr %6, align 8, !tbaa !9
  %392 = getelementptr inbounds [4 x double], ptr %391, i64 1
  %393 = getelementptr inbounds [4 x double], ptr %392, i64 0, i64 2
  %394 = load double, ptr %393, align 8, !tbaa !12
  %395 = fmul double %390, %394
  %396 = call double @llvm.fmuladd.f64(double %382, double %386, double %395)
  %397 = load ptr, ptr %5, align 8, !tbaa !9
  %398 = getelementptr inbounds [4 x double], ptr %397, i64 2
  %399 = getelementptr inbounds [4 x double], ptr %398, i64 0, i64 2
  %400 = load double, ptr %399, align 8, !tbaa !12
  %401 = load ptr, ptr %6, align 8, !tbaa !9
  %402 = getelementptr inbounds [4 x double], ptr %401, i64 2
  %403 = getelementptr inbounds [4 x double], ptr %402, i64 0, i64 2
  %404 = load double, ptr %403, align 8, !tbaa !12
  %405 = call double @llvm.fmuladd.f64(double %400, double %404, double %396)
  %406 = load ptr, ptr %5, align 8, !tbaa !9
  %407 = getelementptr inbounds [4 x double], ptr %406, i64 2
  %408 = getelementptr inbounds [4 x double], ptr %407, i64 0, i64 3
  %409 = load double, ptr %408, align 8, !tbaa !12
  %410 = load ptr, ptr %6, align 8, !tbaa !9
  %411 = getelementptr inbounds [4 x double], ptr %410, i64 3
  %412 = getelementptr inbounds [4 x double], ptr %411, i64 0, i64 2
  %413 = load double, ptr %412, align 8, !tbaa !12
  %414 = call double @llvm.fmuladd.f64(double %409, double %413, double %405)
  %415 = getelementptr inbounds [16 x double], ptr %8, i64 0, i64 10
  store double %414, ptr %415, align 16, !tbaa !12
  %416 = load ptr, ptr %5, align 8, !tbaa !9
  %417 = getelementptr inbounds [4 x double], ptr %416, i64 2
  %418 = getelementptr inbounds [4 x double], ptr %417, i64 0, i64 0
  %419 = load double, ptr %418, align 8, !tbaa !12
  %420 = load ptr, ptr %6, align 8, !tbaa !9
  %421 = getelementptr inbounds [4 x double], ptr %420, i64 0
  %422 = getelementptr inbounds [4 x double], ptr %421, i64 0, i64 3
  %423 = load double, ptr %422, align 8, !tbaa !12
  %424 = load ptr, ptr %5, align 8, !tbaa !9
  %425 = getelementptr inbounds [4 x double], ptr %424, i64 2
  %426 = getelementptr inbounds [4 x double], ptr %425, i64 0, i64 1
  %427 = load double, ptr %426, align 8, !tbaa !12
  %428 = load ptr, ptr %6, align 8, !tbaa !9
  %429 = getelementptr inbounds [4 x double], ptr %428, i64 1
  %430 = getelementptr inbounds [4 x double], ptr %429, i64 0, i64 3
  %431 = load double, ptr %430, align 8, !tbaa !12
  %432 = fmul double %427, %431
  %433 = call double @llvm.fmuladd.f64(double %419, double %423, double %432)
  %434 = load ptr, ptr %5, align 8, !tbaa !9
  %435 = getelementptr inbounds [4 x double], ptr %434, i64 2
  %436 = getelementptr inbounds [4 x double], ptr %435, i64 0, i64 2
  %437 = load double, ptr %436, align 8, !tbaa !12
  %438 = load ptr, ptr %6, align 8, !tbaa !9
  %439 = getelementptr inbounds [4 x double], ptr %438, i64 2
  %440 = getelementptr inbounds [4 x double], ptr %439, i64 0, i64 3
  %441 = load double, ptr %440, align 8, !tbaa !12
  %442 = call double @llvm.fmuladd.f64(double %437, double %441, double %433)
  %443 = load ptr, ptr %5, align 8, !tbaa !9
  %444 = getelementptr inbounds [4 x double], ptr %443, i64 2
  %445 = getelementptr inbounds [4 x double], ptr %444, i64 0, i64 3
  %446 = load double, ptr %445, align 8, !tbaa !12
  %447 = load ptr, ptr %6, align 8, !tbaa !9
  %448 = getelementptr inbounds [4 x double], ptr %447, i64 3
  %449 = getelementptr inbounds [4 x double], ptr %448, i64 0, i64 3
  %450 = load double, ptr %449, align 8, !tbaa !12
  %451 = call double @llvm.fmuladd.f64(double %446, double %450, double %442)
  %452 = getelementptr inbounds [16 x double], ptr %8, i64 0, i64 11
  store double %451, ptr %452, align 8, !tbaa !12
  %453 = load ptr, ptr %5, align 8, !tbaa !9
  %454 = getelementptr inbounds [4 x double], ptr %453, i64 3
  %455 = getelementptr inbounds [4 x double], ptr %454, i64 0, i64 0
  %456 = load double, ptr %455, align 8, !tbaa !12
  %457 = load ptr, ptr %6, align 8, !tbaa !9
  %458 = getelementptr inbounds [4 x double], ptr %457, i64 0
  %459 = getelementptr inbounds [4 x double], ptr %458, i64 0, i64 0
  %460 = load double, ptr %459, align 8, !tbaa !12
  %461 = load ptr, ptr %5, align 8, !tbaa !9
  %462 = getelementptr inbounds [4 x double], ptr %461, i64 3
  %463 = getelementptr inbounds [4 x double], ptr %462, i64 0, i64 1
  %464 = load double, ptr %463, align 8, !tbaa !12
  %465 = load ptr, ptr %6, align 8, !tbaa !9
  %466 = getelementptr inbounds [4 x double], ptr %465, i64 1
  %467 = getelementptr inbounds [4 x double], ptr %466, i64 0, i64 0
  %468 = load double, ptr %467, align 8, !tbaa !12
  %469 = fmul double %464, %468
  %470 = call double @llvm.fmuladd.f64(double %456, double %460, double %469)
  %471 = load ptr, ptr %5, align 8, !tbaa !9
  %472 = getelementptr inbounds [4 x double], ptr %471, i64 3
  %473 = getelementptr inbounds [4 x double], ptr %472, i64 0, i64 2
  %474 = load double, ptr %473, align 8, !tbaa !12
  %475 = load ptr, ptr %6, align 8, !tbaa !9
  %476 = getelementptr inbounds [4 x double], ptr %475, i64 2
  %477 = getelementptr inbounds [4 x double], ptr %476, i64 0, i64 0
  %478 = load double, ptr %477, align 8, !tbaa !12
  %479 = call double @llvm.fmuladd.f64(double %474, double %478, double %470)
  %480 = load ptr, ptr %5, align 8, !tbaa !9
  %481 = getelementptr inbounds [4 x double], ptr %480, i64 3
  %482 = getelementptr inbounds [4 x double], ptr %481, i64 0, i64 3
  %483 = load double, ptr %482, align 8, !tbaa !12
  %484 = load ptr, ptr %6, align 8, !tbaa !9
  %485 = getelementptr inbounds [4 x double], ptr %484, i64 3
  %486 = getelementptr inbounds [4 x double], ptr %485, i64 0, i64 0
  %487 = load double, ptr %486, align 8, !tbaa !12
  %488 = call double @llvm.fmuladd.f64(double %483, double %487, double %479)
  %489 = getelementptr inbounds [16 x double], ptr %8, i64 0, i64 12
  store double %488, ptr %489, align 16, !tbaa !12
  %490 = load ptr, ptr %5, align 8, !tbaa !9
  %491 = getelementptr inbounds [4 x double], ptr %490, i64 3
  %492 = getelementptr inbounds [4 x double], ptr %491, i64 0, i64 0
  %493 = load double, ptr %492, align 8, !tbaa !12
  %494 = load ptr, ptr %6, align 8, !tbaa !9
  %495 = getelementptr inbounds [4 x double], ptr %494, i64 0
  %496 = getelementptr inbounds [4 x double], ptr %495, i64 0, i64 1
  %497 = load double, ptr %496, align 8, !tbaa !12
  %498 = load ptr, ptr %5, align 8, !tbaa !9
  %499 = getelementptr inbounds [4 x double], ptr %498, i64 3
  %500 = getelementptr inbounds [4 x double], ptr %499, i64 0, i64 1
  %501 = load double, ptr %500, align 8, !tbaa !12
  %502 = load ptr, ptr %6, align 8, !tbaa !9
  %503 = getelementptr inbounds [4 x double], ptr %502, i64 1
  %504 = getelementptr inbounds [4 x double], ptr %503, i64 0, i64 1
  %505 = load double, ptr %504, align 8, !tbaa !12
  %506 = fmul double %501, %505
  %507 = call double @llvm.fmuladd.f64(double %493, double %497, double %506)
  %508 = load ptr, ptr %5, align 8, !tbaa !9
  %509 = getelementptr inbounds [4 x double], ptr %508, i64 3
  %510 = getelementptr inbounds [4 x double], ptr %509, i64 0, i64 2
  %511 = load double, ptr %510, align 8, !tbaa !12
  %512 = load ptr, ptr %6, align 8, !tbaa !9
  %513 = getelementptr inbounds [4 x double], ptr %512, i64 2
  %514 = getelementptr inbounds [4 x double], ptr %513, i64 0, i64 1
  %515 = load double, ptr %514, align 8, !tbaa !12
  %516 = call double @llvm.fmuladd.f64(double %511, double %515, double %507)
  %517 = load ptr, ptr %5, align 8, !tbaa !9
  %518 = getelementptr inbounds [4 x double], ptr %517, i64 3
  %519 = getelementptr inbounds [4 x double], ptr %518, i64 0, i64 3
  %520 = load double, ptr %519, align 8, !tbaa !12
  %521 = load ptr, ptr %6, align 8, !tbaa !9
  %522 = getelementptr inbounds [4 x double], ptr %521, i64 3
  %523 = getelementptr inbounds [4 x double], ptr %522, i64 0, i64 1
  %524 = load double, ptr %523, align 8, !tbaa !12
  %525 = call double @llvm.fmuladd.f64(double %520, double %524, double %516)
  %526 = getelementptr inbounds [16 x double], ptr %8, i64 0, i64 13
  store double %525, ptr %526, align 8, !tbaa !12
  %527 = load ptr, ptr %5, align 8, !tbaa !9
  %528 = getelementptr inbounds [4 x double], ptr %527, i64 3
  %529 = getelementptr inbounds [4 x double], ptr %528, i64 0, i64 0
  %530 = load double, ptr %529, align 8, !tbaa !12
  %531 = load ptr, ptr %6, align 8, !tbaa !9
  %532 = getelementptr inbounds [4 x double], ptr %531, i64 0
  %533 = getelementptr inbounds [4 x double], ptr %532, i64 0, i64 2
  %534 = load double, ptr %533, align 8, !tbaa !12
  %535 = load ptr, ptr %5, align 8, !tbaa !9
  %536 = getelementptr inbounds [4 x double], ptr %535, i64 3
  %537 = getelementptr inbounds [4 x double], ptr %536, i64 0, i64 1
  %538 = load double, ptr %537, align 8, !tbaa !12
  %539 = load ptr, ptr %6, align 8, !tbaa !9
  %540 = getelementptr inbounds [4 x double], ptr %539, i64 1
  %541 = getelementptr inbounds [4 x double], ptr %540, i64 0, i64 2
  %542 = load double, ptr %541, align 8, !tbaa !12
  %543 = fmul double %538, %542
  %544 = call double @llvm.fmuladd.f64(double %530, double %534, double %543)
  %545 = load ptr, ptr %5, align 8, !tbaa !9
  %546 = getelementptr inbounds [4 x double], ptr %545, i64 3
  %547 = getelementptr inbounds [4 x double], ptr %546, i64 0, i64 2
  %548 = load double, ptr %547, align 8, !tbaa !12
  %549 = load ptr, ptr %6, align 8, !tbaa !9
  %550 = getelementptr inbounds [4 x double], ptr %549, i64 2
  %551 = getelementptr inbounds [4 x double], ptr %550, i64 0, i64 2
  %552 = load double, ptr %551, align 8, !tbaa !12
  %553 = call double @llvm.fmuladd.f64(double %548, double %552, double %544)
  %554 = load ptr, ptr %5, align 8, !tbaa !9
  %555 = getelementptr inbounds [4 x double], ptr %554, i64 3
  %556 = getelementptr inbounds [4 x double], ptr %555, i64 0, i64 3
  %557 = load double, ptr %556, align 8, !tbaa !12
  %558 = load ptr, ptr %6, align 8, !tbaa !9
  %559 = getelementptr inbounds [4 x double], ptr %558, i64 3
  %560 = getelementptr inbounds [4 x double], ptr %559, i64 0, i64 2
  %561 = load double, ptr %560, align 8, !tbaa !12
  %562 = call double @llvm.fmuladd.f64(double %557, double %561, double %553)
  %563 = getelementptr inbounds [16 x double], ptr %8, i64 0, i64 14
  store double %562, ptr %563, align 16, !tbaa !12
  %564 = load ptr, ptr %5, align 8, !tbaa !9
  %565 = getelementptr inbounds [4 x double], ptr %564, i64 3
  %566 = getelementptr inbounds [4 x double], ptr %565, i64 0, i64 0
  %567 = load double, ptr %566, align 8, !tbaa !12
  %568 = load ptr, ptr %6, align 8, !tbaa !9
  %569 = getelementptr inbounds [4 x double], ptr %568, i64 0
  %570 = getelementptr inbounds [4 x double], ptr %569, i64 0, i64 3
  %571 = load double, ptr %570, align 8, !tbaa !12
  %572 = load ptr, ptr %5, align 8, !tbaa !9
  %573 = getelementptr inbounds [4 x double], ptr %572, i64 3
  %574 = getelementptr inbounds [4 x double], ptr %573, i64 0, i64 1
  %575 = load double, ptr %574, align 8, !tbaa !12
  %576 = load ptr, ptr %6, align 8, !tbaa !9
  %577 = getelementptr inbounds [4 x double], ptr %576, i64 1
  %578 = getelementptr inbounds [4 x double], ptr %577, i64 0, i64 3
  %579 = load double, ptr %578, align 8, !tbaa !12
  %580 = fmul double %575, %579
  %581 = call double @llvm.fmuladd.f64(double %567, double %571, double %580)
  %582 = load ptr, ptr %5, align 8, !tbaa !9
  %583 = getelementptr inbounds [4 x double], ptr %582, i64 3
  %584 = getelementptr inbounds [4 x double], ptr %583, i64 0, i64 2
  %585 = load double, ptr %584, align 8, !tbaa !12
  %586 = load ptr, ptr %6, align 8, !tbaa !9
  %587 = getelementptr inbounds [4 x double], ptr %586, i64 2
  %588 = getelementptr inbounds [4 x double], ptr %587, i64 0, i64 3
  %589 = load double, ptr %588, align 8, !tbaa !12
  %590 = call double @llvm.fmuladd.f64(double %585, double %589, double %581)
  %591 = load ptr, ptr %5, align 8, !tbaa !9
  %592 = getelementptr inbounds [4 x double], ptr %591, i64 3
  %593 = getelementptr inbounds [4 x double], ptr %592, i64 0, i64 3
  %594 = load double, ptr %593, align 8, !tbaa !12
  %595 = load ptr, ptr %6, align 8, !tbaa !9
  %596 = getelementptr inbounds [4 x double], ptr %595, i64 3
  %597 = getelementptr inbounds [4 x double], ptr %596, i64 0, i64 3
  %598 = load double, ptr %597, align 8, !tbaa !12
  %599 = call double @llvm.fmuladd.f64(double %594, double %598, double %590)
  %600 = getelementptr inbounds [16 x double], ptr %8, i64 0, i64 15
  store double %599, ptr %600, align 8, !tbaa !12
  store i32 0, ptr %7, align 4, !tbaa !14
  br label %601

601:                                              ; preds = %613, %3
  %602 = load i32, ptr %7, align 4, !tbaa !14
  %603 = icmp ult i32 %602, 16
  br i1 %603, label %604, label %616

604:                                              ; preds = %601
  %605 = load i32, ptr %7, align 4, !tbaa !14
  %606 = zext i32 %605 to i64
  %607 = getelementptr inbounds nuw [16 x double], ptr %8, i64 0, i64 %606
  %608 = load double, ptr %607, align 8, !tbaa !12
  %609 = load ptr, ptr %4, align 8, !tbaa !9
  %610 = load i32, ptr %7, align 4, !tbaa !14
  %611 = zext i32 %610 to i64
  %612 = getelementptr inbounds nuw double, ptr %609, i64 %611
  store double %608, ptr %612, align 8, !tbaa !12
  br label %613

613:                                              ; preds = %604
  %614 = load i32, ptr %7, align 4, !tbaa !14
  %615 = add i32 %614, 1
  store i32 %615, ptr %7, align 4, !tbaa !14
  br label %601, !llvm.loop !15

616:                                              ; preds = %601
  call void @llvm.lifetime.end.p0(ptr %8) #5
  call void @llvm.lifetime.end.p0(ptr %7) #5
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #1 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca [4 x [4 x double]], align 16
  %4 = alloca [4 x [4 x double]], align 16
  %5 = alloca [4 x [4 x double]], align 16
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #5
  store i32 50000000, ptr %2, align 4, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %3) #5
  call void @llvm.memcpy.p0.p0.i64(ptr align 16 %3, ptr align 16 @__const.main.A, i64 128, i1 false)
  call void @llvm.lifetime.start.p0(ptr %4) #5
  call void @llvm.memcpy.p0.p0.i64(ptr align 16 %4, ptr align 16 @__const.main.B, i64 128, i1 false)
  call void @llvm.lifetime.start.p0(ptr %5) #5
  call void @llvm.lifetime.start.p0(ptr %6) #5
  call void @llvm.lifetime.start.p0(ptr %7) #5
  store i32 0, ptr %6, align 4, !tbaa !14
  br label %8

8:                                                ; preds = %16, %0
  %9 = load i32, ptr %6, align 4, !tbaa !14
  %10 = icmp ne i32 %9, 50000000
  br i1 %10, label %11, label %19

11:                                               ; preds = %8
  %12 = getelementptr inbounds [4 x [4 x double]], ptr %5, i64 0, i64 0
  %13 = getelementptr inbounds [4 x double], ptr %12, i64 0, i64 0
  %14 = getelementptr inbounds [4 x [4 x double]], ptr %3, i64 0, i64 0
  %15 = getelementptr inbounds [4 x [4 x double]], ptr %4, i64 0, i64 0
  call void @wrap_mul4(ptr noundef %13, ptr noundef %14, ptr noundef %15)
  br label %16

16:                                               ; preds = %11
  %17 = load i32, ptr %6, align 4, !tbaa !14
  %18 = add i32 %17, 1
  store i32 %18, ptr %6, align 4, !tbaa !14
  br label %8, !llvm.loop !17

19:                                               ; preds = %8
  store i32 0, ptr %6, align 4, !tbaa !14
  br label %20

20:                                               ; preds = %41, %19
  %21 = load i32, ptr %6, align 4, !tbaa !14
  %22 = icmp ne i32 %21, 4
  br i1 %22, label %23, label %44

23:                                               ; preds = %20
  store i32 0, ptr %7, align 4, !tbaa !14
  br label %24

24:                                               ; preds = %36, %23
  %25 = load i32, ptr %7, align 4, !tbaa !14
  %26 = icmp ne i32 %25, 4
  br i1 %26, label %27, label %39

27:                                               ; preds = %24
  %28 = load i32, ptr %6, align 4, !tbaa !14
  %29 = zext i32 %28 to i64
  %30 = getelementptr inbounds nuw [4 x [4 x double]], ptr %5, i64 0, i64 %29
  %31 = load i32, ptr %7, align 4, !tbaa !14
  %32 = zext i32 %31 to i64
  %33 = getelementptr inbounds nuw [4 x double], ptr %30, i64 0, i64 %32
  %34 = load double, ptr %33, align 8, !tbaa !12
  %35 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %34)
  br label %36

36:                                               ; preds = %27
  %37 = load i32, ptr %7, align 4, !tbaa !14
  %38 = add i32 %37, 1
  store i32 %38, ptr %7, align 4, !tbaa !14
  br label %24, !llvm.loop !18

39:                                               ; preds = %24
  %40 = call i32 @puts(ptr noundef @.str.1)
  br label %41

41:                                               ; preds = %39
  %42 = load i32, ptr %6, align 4, !tbaa !14
  %43 = add i32 %42, 1
  store i32 %43, ptr %6, align 4, !tbaa !14
  br label %20, !llvm.loop !19

44:                                               ; preds = %20
  call void @llvm.lifetime.end.p0(ptr %7) #5
  call void @llvm.lifetime.end.p0(ptr %6) #5
  call void @llvm.lifetime.end.p0(ptr %5) #5
  call void @llvm.lifetime.end.p0(ptr %4) #5
  call void @llvm.lifetime.end.p0(ptr %3) #5
  call void @llvm.lifetime.end.p0(ptr %2) #5
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #2

declare i32 @printf(ptr noundef, ...) #3

declare i32 @puts(ptr noundef) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #2

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #4

attributes #0 = { noinline nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #3 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
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
!9 = !{!10, !10, i64 0}
!10 = !{!"p1 double", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!13, !13, i64 0}
!13 = !{!"double", !7, i64 0}
!14 = !{!6, !6, i64 0}
!15 = distinct !{!15, !16}
!16 = !{!"llvm.loop.mustprogress"}
!17 = distinct !{!17, !16}
!18 = distinct !{!18, !16}
!19 = distinct !{!19, !16}
