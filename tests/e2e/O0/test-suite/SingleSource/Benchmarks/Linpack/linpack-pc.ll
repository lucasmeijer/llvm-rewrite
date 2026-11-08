; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Linpack/linpack-pc.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Linpack/linpack-pc.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Linpack/linpack-pc.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@main.aa = internal global [40000 x float] zeroinitializer, align 16
@main.a = internal global [40200 x float] zeroinitializer, align 16
@main.b = internal global [200 x float] zeroinitializer, align 16
@main.x = internal global [200 x float] zeroinitializer, align 16
@main.ipvt = internal global [200 x i32] zeroinitializer, align 16
@main.n = internal global i32 0, align 4
@main.i = internal global i32 0, align 4
@main.j = internal global i32 0, align 4
@main.ntimes = internal global i32 0, align 4
@main.info = internal global i32 0, align 4
@main.lda = internal global i32 0, align 4
@main.ldaa = internal global i32 0, align 4
@.str = private unnamed_addr constant [26 x i8] c"INSERT COMPILER NAME HERE\00", align 1
@.str.1 = private unnamed_addr constant [33 x i8] c"INSERT OPTIMISATION OPTIONS HERE\00", align 1
@stderr = external global ptr, align 8
@.str.2 = private unnamed_addr constant [8 x i8] c"Rolled \00", align 1
@.str.3 = private unnamed_addr constant [8 x i8] c"Single \00", align 1
@.str.4 = private unnamed_addr constant [54 x i8] c"Precision Linpack Benchmark - PC Version in 'C/C++'\0A\0A\00", align 1
@.str.5 = private unnamed_addr constant [17 x i8] c"Compiler     %s\0A\00", align 1
@.str.6 = private unnamed_addr constant [18 x i8] c"Optimisation %s\0A\0A\00", align 1
@atime = internal global [9 x [15 x float]] zeroinitializer, align 16
@.str.7 = private unnamed_addr constant [39 x i8] c"norm resid      resid           machep\00", align 1
@.str.8 = private unnamed_addr constant [35 x i8] c"         x[0]-1          x[n-1]-1\0A\00", align 1
@.str.9 = private unnamed_addr constant [33 x i8] c"%6.1f %17.8e%17.8e%17.8e%17.8e\0A\0A\00", align 1
@.str.10 = private unnamed_addr constant [53 x i8] c"Times are reported for matrices of order        %5d\0A\00", align 1
@.str.11 = private unnamed_addr constant [54 x i8] c"1 pass times for array with leading dimension of%5d\0A\0A\00", align 1
@.str.12 = private unnamed_addr constant [56 x i8] c"      dgefa      dgesl      total     Mflops       unit\00", align 1
@.str.13 = private unnamed_addr constant [13 x i8] c"      ratio\0A\00", align 1
@.str.14 = private unnamed_addr constant [30 x i8] c"\0ACalculating matgen overhead\0A\00", align 1
@.str.15 = private unnamed_addr constant [26 x i8] c"%10d times %6.2f seconds\0A\00", align 1
@.str.16 = private unnamed_addr constant [39 x i8] c"Overhead for 1 matgen %12.5f seconds\0A\0A\00", align 1
@.str.17 = private unnamed_addr constant [47 x i8] c"Calculating matgen/dgefa passes for 5 seconds\0A\00", align 1
@.str.18 = private unnamed_addr constant [20 x i8] c"Passes used %10d \0A\0A\00", align 1
@.str.19 = private unnamed_addr constant [47 x i8] c"Times for array with leading dimension of%4d\0A\0A\00", align 1
@.str.20 = private unnamed_addr constant [41 x i8] c"Average                          %11.2f\0A\00", align 1
@.str.21 = private unnamed_addr constant [31 x i8] c"\0ACalculating matgen2 overhead\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local float @second() #0 {
  %1 = alloca float, align 4
  %2 = alloca i64, align 8
  %3 = call i64 @clock() #4
  store i64 %3, ptr %2, align 8
  %4 = load i64, ptr %2, align 8
  %5 = sitofp i64 %4 to float
  %6 = fdiv float %5, 1.000000e+06
  store float %6, ptr %1, align 4
  %7 = load float, ptr %1, align 4
  ret float %7
}

; Function Attrs: nounwind
declare i64 @clock() #1

; Function Attrs: noinline nounwind uwtable
define dso_local void @what_date() #0 {
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca float, align 4
  %3 = alloca float, align 4
  %4 = alloca float, align 4
  %5 = alloca float, align 4
  %6 = alloca float, align 4
  %7 = alloca float, align 4
  %8 = alloca float, align 4
  %9 = alloca float, align 4
  %10 = alloca float, align 4
  %11 = alloca float, align 4
  %12 = alloca float, align 4
  %13 = alloca float, align 4
  %14 = alloca float, align 4
  %15 = alloca float, align 4
  %16 = alloca i32, align 4
  %17 = alloca i32, align 4
  %18 = alloca float, align 4
  %19 = alloca float, align 4
  %20 = alloca float, align 4
  %21 = alloca float, align 4
  %22 = alloca ptr, align 8
  %23 = alloca ptr, align 8
  %24 = alloca [9 x [80 x i8]], align 16
  store i32 0, ptr %1, align 4
  call void @llvm.memset.p0.i64(ptr align 16 %24, i8 0, i64 720, i1 false)
  %25 = getelementptr inbounds <{ [80 x i8], [8 x [80 x i8]] }>, ptr %24, i32 0, i32 0
  %26 = getelementptr inbounds [80 x i8], ptr %25, i32 0, i32 0
  store i8 32, ptr %26, align 16
  store ptr @.str, ptr %22, align 8
  store ptr @.str.1, ptr %23, align 8
  store i32 201, ptr @main.lda, align 4
  store i32 200, ptr @main.ldaa, align 4
  store float 5.600000e-02, ptr %2, align 4
  store i32 100, ptr @main.n, align 4
  %27 = load ptr, ptr @stderr, align 8
  %28 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %27, ptr noundef @.str.2) #4
  %29 = load ptr, ptr @stderr, align 8
  %30 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %29, ptr noundef @.str.3) #4
  %31 = load ptr, ptr @stderr, align 8
  %32 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %31, ptr noundef @.str.4) #4
  %33 = load ptr, ptr @stderr, align 8
  %34 = load ptr, ptr %22, align 8
  %35 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %33, ptr noundef @.str.5, ptr noundef %34) #4
  %36 = load ptr, ptr @stderr, align 8
  %37 = load ptr, ptr %23, align 8
  %38 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %36, ptr noundef @.str.6, ptr noundef %37) #4
  %39 = load i32, ptr @main.n, align 4
  %40 = load i32, ptr @main.n, align 4
  %41 = mul nsw i32 %39, %40
  %42 = load i32, ptr @main.n, align 4
  %43 = mul nsw i32 %41, %42
  %44 = sitofp i32 %43 to double
  %45 = fmul double 2.000000e+00, %44
  %46 = fdiv double %45, 3.000000e+00
  %47 = load i32, ptr @main.n, align 4
  %48 = load i32, ptr @main.n, align 4
  %49 = mul nsw i32 %47, %48
  %50 = sitofp i32 %49 to double
  %51 = call double @llvm.fmuladd.f64(double 2.000000e+00, double %50, double %46)
  %52 = fptrunc double %51 to float
  store float %52, ptr %3, align 4
  %53 = load i32, ptr @main.lda, align 4
  %54 = load i32, ptr @main.n, align 4
  call void @matgen(ptr noundef @main.a, i32 noundef %53, i32 noundef %54, ptr noundef @main.b, ptr noundef %5)
  %55 = call float @second()
  store float %55, ptr %10, align 4
  %56 = load i32, ptr @main.lda, align 4
  %57 = load i32, ptr @main.n, align 4
  call void @dgefa(ptr noundef @main.a, i32 noundef %56, i32 noundef %57, ptr noundef @main.ipvt, ptr noundef @main.info)
  %58 = call float @second()
  %59 = load float, ptr %10, align 4
  %60 = fsub float %58, %59
  store float %60, ptr @atime, align 16
  %61 = call float @second()
  store float %61, ptr %10, align 4
  %62 = load i32, ptr @main.lda, align 4
  %63 = load i32, ptr @main.n, align 4
  call void @dgesl(ptr noundef @main.a, i32 noundef %62, i32 noundef %63, ptr noundef @main.ipvt, ptr noundef @main.b, i32 noundef 0)
  %64 = call float @second()
  %65 = load float, ptr %10, align 4
  %66 = fsub float %64, %65
  store float %66, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 60), align 4
  %67 = load float, ptr @atime, align 16
  %68 = load float, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 60), align 4
  %69 = fadd float %67, %68
  store float %69, ptr %4, align 4
  store i32 0, ptr @main.i, align 4
  br label %70

70:                                               ; preds = %82, %0
  %71 = load i32, ptr @main.i, align 4
  %72 = load i32, ptr @main.n, align 4
  %73 = icmp slt i32 %71, %72
  br i1 %73, label %74, label %85

74:                                               ; preds = %70
  %75 = load i32, ptr @main.i, align 4
  %76 = sext i32 %75 to i64
  %77 = getelementptr inbounds [200 x float], ptr @main.b, i64 0, i64 %76
  %78 = load float, ptr %77, align 4
  %79 = load i32, ptr @main.i, align 4
  %80 = sext i32 %79 to i64
  %81 = getelementptr inbounds [200 x float], ptr @main.x, i64 0, i64 %80
  store float %78, ptr %81, align 4
  br label %82

82:                                               ; preds = %74
  %83 = load i32, ptr @main.i, align 4
  %84 = add nsw i32 %83, 1
  store i32 %84, ptr @main.i, align 4
  br label %70, !llvm.loop !5

85:                                               ; preds = %70
  %86 = load i32, ptr @main.lda, align 4
  %87 = load i32, ptr @main.n, align 4
  call void @matgen(ptr noundef @main.a, i32 noundef %86, i32 noundef %87, ptr noundef @main.b, ptr noundef %5)
  store i32 0, ptr @main.i, align 4
  br label %88

88:                                               ; preds = %101, %85
  %89 = load i32, ptr @main.i, align 4
  %90 = load i32, ptr @main.n, align 4
  %91 = icmp slt i32 %89, %90
  br i1 %91, label %92, label %104

92:                                               ; preds = %88
  %93 = load i32, ptr @main.i, align 4
  %94 = sext i32 %93 to i64
  %95 = getelementptr inbounds [200 x float], ptr @main.b, i64 0, i64 %94
  %96 = load float, ptr %95, align 4
  %97 = fneg float %96
  %98 = load i32, ptr @main.i, align 4
  %99 = sext i32 %98 to i64
  %100 = getelementptr inbounds [200 x float], ptr @main.b, i64 0, i64 %99
  store float %97, ptr %100, align 4
  br label %101

101:                                              ; preds = %92
  %102 = load i32, ptr @main.i, align 4
  %103 = add nsw i32 %102, 1
  store i32 %103, ptr @main.i, align 4
  br label %88, !llvm.loop !7

104:                                              ; preds = %88
  %105 = load i32, ptr @main.n, align 4
  %106 = load i32, ptr @main.n, align 4
  %107 = load i32, ptr @main.lda, align 4
  call void @dmxpy(i32 noundef %105, ptr noundef @main.b, i32 noundef %106, i32 noundef %107, ptr noundef @main.x, ptr noundef @main.a)
  store float 0.000000e+00, ptr %7, align 4
  store float 0.000000e+00, ptr %6, align 4
  store i32 0, ptr @main.i, align 4
  br label %108

108:                                              ; preds = %157, %104
  %109 = load i32, ptr @main.i, align 4
  %110 = load i32, ptr @main.n, align 4
  %111 = icmp slt i32 %109, %110
  br i1 %111, label %112, label %160

112:                                              ; preds = %108
  %113 = load float, ptr %7, align 4
  %114 = fpext float %113 to double
  %115 = load i32, ptr @main.i, align 4
  %116 = sext i32 %115 to i64
  %117 = getelementptr inbounds [200 x float], ptr @main.b, i64 0, i64 %116
  %118 = load float, ptr %117, align 4
  %119 = fpext float %118 to double
  %120 = call double @llvm.fabs.f64(double %119)
  %121 = fcmp ogt double %114, %120
  br i1 %121, label %122, label %125

122:                                              ; preds = %112
  %123 = load float, ptr %7, align 4
  %124 = fpext float %123 to double
  br label %132

125:                                              ; preds = %112
  %126 = load i32, ptr @main.i, align 4
  %127 = sext i32 %126 to i64
  %128 = getelementptr inbounds [200 x float], ptr @main.b, i64 0, i64 %127
  %129 = load float, ptr %128, align 4
  %130 = fpext float %129 to double
  %131 = call double @llvm.fabs.f64(double %130)
  br label %132

132:                                              ; preds = %125, %122
  %133 = phi double [ %124, %122 ], [ %131, %125 ]
  %134 = fptrunc double %133 to float
  store float %134, ptr %7, align 4
  %135 = load float, ptr %6, align 4
  %136 = fpext float %135 to double
  %137 = load i32, ptr @main.i, align 4
  %138 = sext i32 %137 to i64
  %139 = getelementptr inbounds [200 x float], ptr @main.x, i64 0, i64 %138
  %140 = load float, ptr %139, align 4
  %141 = fpext float %140 to double
  %142 = call double @llvm.fabs.f64(double %141)
  %143 = fcmp ogt double %136, %142
  br i1 %143, label %144, label %147

144:                                              ; preds = %132
  %145 = load float, ptr %6, align 4
  %146 = fpext float %145 to double
  br label %154

147:                                              ; preds = %132
  %148 = load i32, ptr @main.i, align 4
  %149 = sext i32 %148 to i64
  %150 = getelementptr inbounds [200 x float], ptr @main.x, i64 0, i64 %149
  %151 = load float, ptr %150, align 4
  %152 = fpext float %151 to double
  %153 = call double @llvm.fabs.f64(double %152)
  br label %154

154:                                              ; preds = %147, %144
  %155 = phi double [ %146, %144 ], [ %153, %147 ]
  %156 = fptrunc double %155 to float
  store float %156, ptr %6, align 4
  br label %157

157:                                              ; preds = %154
  %158 = load i32, ptr @main.i, align 4
  %159 = add nsw i32 %158, 1
  store i32 %159, ptr @main.i, align 4
  br label %108, !llvm.loop !8

160:                                              ; preds = %108
  %161 = call float @epslon(float noundef 1.000000e+00)
  store float %161, ptr %9, align 4
  %162 = load float, ptr %7, align 4
  %163 = load i32, ptr @main.n, align 4
  %164 = sitofp i32 %163 to float
  %165 = load float, ptr %5, align 4
  %166 = fmul float %164, %165
  %167 = load float, ptr %6, align 4
  %168 = fmul float %166, %167
  %169 = load float, ptr %9, align 4
  %170 = fmul float %168, %169
  %171 = fdiv float %162, %170
  store float %171, ptr %8, align 4
  %172 = load float, ptr %9, align 4
  store float %172, ptr %12, align 4
  %173 = load float, ptr @main.x, align 16
  %174 = fsub float %173, 1.000000e+00
  store float %174, ptr %13, align 4
  %175 = load i32, ptr @main.n, align 4
  %176 = sub nsw i32 %175, 1
  %177 = sext i32 %176 to i64
  %178 = getelementptr inbounds [200 x float], ptr @main.x, i64 0, i64 %177
  %179 = load float, ptr %178, align 4
  %180 = fsub float %179, 1.000000e+00
  store float %180, ptr %14, align 4
  %181 = load ptr, ptr @stderr, align 8
  %182 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %181, ptr noundef @.str.7) #4
  %183 = load ptr, ptr @stderr, align 8
  %184 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %183, ptr noundef @.str.8) #4
  %185 = load ptr, ptr @stderr, align 8
  %186 = load float, ptr %8, align 4
  %187 = fpext float %186 to double
  %188 = load float, ptr %7, align 4
  %189 = fpext float %188 to double
  %190 = load float, ptr %12, align 4
  %191 = fpext float %190 to double
  %192 = load float, ptr %13, align 4
  %193 = fpext float %192 to double
  %194 = load float, ptr %14, align 4
  %195 = fpext float %194 to double
  %196 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %185, ptr noundef @.str.9, double noundef %187, double noundef %189, double noundef %191, double noundef %193, double noundef %195) #4
  %197 = load ptr, ptr @stderr, align 8
  %198 = load i32, ptr @main.n, align 4
  %199 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %197, ptr noundef @.str.10, i32 noundef %198) #4
  %200 = load ptr, ptr @stderr, align 8
  %201 = load i32, ptr @main.lda, align 4
  %202 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %200, ptr noundef @.str.11, i32 noundef %201) #4
  %203 = load ptr, ptr @stderr, align 8
  %204 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %203, ptr noundef @.str.12) #4
  %205 = load ptr, ptr @stderr, align 8
  %206 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %205, ptr noundef @.str.13) #4
  %207 = load float, ptr %4, align 4
  store float %207, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 120), align 8
  %208 = load float, ptr %4, align 4
  %209 = fpext float %208 to double
  %210 = fcmp ogt double %209, 0.000000e+00
  br i1 %210, label %211, label %223

211:                                              ; preds = %160
  %212 = load float, ptr %3, align 4
  %213 = fpext float %212 to double
  %214 = load float, ptr %4, align 4
  %215 = fpext float %214 to double
  %216 = fmul double 1.000000e+06, %215
  %217 = fdiv double %213, %216
  %218 = fptrunc double %217 to float
  store float %218, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 180), align 4
  %219 = load float, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 180), align 4
  %220 = fpext float %219 to double
  %221 = fdiv double 2.000000e+00, %220
  %222 = fptrunc double %221 to float
  store float %222, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 240), align 16
  br label %224

223:                                              ; preds = %160
  store float 0.000000e+00, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 180), align 4
  store float 0.000000e+00, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 240), align 16
  br label %224

224:                                              ; preds = %223, %211
  %225 = load float, ptr %4, align 4
  %226 = load float, ptr %2, align 4
  %227 = fdiv float %225, %226
  store float %227, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 300), align 4
  call void @print_time(i32 noundef 0)
  %228 = load ptr, ptr @stderr, align 8
  %229 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %228, ptr noundef @.str.14) #4
  store i32 -3, ptr %16, align 4
  store i32 100, ptr %17, align 4
  br label %230

230:                                              ; preds = %258, %224
  %231 = call float @second()
  store float %231, ptr %20, align 4
  %232 = load i32, ptr %16, align 4
  %233 = add nsw i32 %232, 1
  store i32 %233, ptr %16, align 4
  store i32 0, ptr @main.i, align 4
  br label %234

234:                                              ; preds = %241, %230
  %235 = load i32, ptr @main.i, align 4
  %236 = load i32, ptr %17, align 4
  %237 = icmp slt i32 %235, %236
  br i1 %237, label %238, label %244

238:                                              ; preds = %234
  %239 = load i32, ptr @main.lda, align 4
  %240 = load i32, ptr @main.n, align 4
  call void @matgen(ptr noundef @main.a, i32 noundef %239, i32 noundef %240, ptr noundef @main.b, ptr noundef %5)
  br label %241

241:                                              ; preds = %238
  %242 = load i32, ptr @main.i, align 4
  %243 = add nsw i32 %242, 1
  store i32 %243, ptr @main.i, align 4
  br label %234, !llvm.loop !9

244:                                              ; preds = %234
  %245 = call float @second()
  store float %245, ptr %21, align 4
  %246 = load float, ptr %21, align 4
  %247 = load float, ptr %20, align 4
  %248 = fsub float %246, %247
  store float %248, ptr %18, align 4
  %249 = load ptr, ptr @stderr, align 8
  %250 = load i32, ptr %17, align 4
  %251 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %249, ptr noundef @.str.15, i32 noundef %250, double noundef 0.000000e+00) #4
  %252 = load i32, ptr %16, align 4
  %253 = icmp slt i32 %252, 0
  br i1 %253, label %254, label %257

254:                                              ; preds = %244
  %255 = load i32, ptr %17, align 4
  %256 = mul nsw i32 %255, 2
  store i32 %256, ptr %17, align 4
  br label %257

257:                                              ; preds = %254, %244
  br label %258

258:                                              ; preds = %257
  %259 = load i32, ptr %16, align 4
  %260 = icmp slt i32 %259, 0
  br i1 %260, label %230, label %261, !llvm.loop !10

261:                                              ; preds = %258
  %262 = load float, ptr %18, align 4
  %263 = fpext float %262 to double
  %264 = load i32, ptr %17, align 4
  %265 = sitofp i32 %264 to double
  %266 = fdiv double %263, %265
  %267 = fptrunc double %266 to float
  store float %267, ptr %18, align 4
  %268 = load ptr, ptr @stderr, align 8
  %269 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %268, ptr noundef @.str.16, double noundef 0.000000e+00) #4
  %270 = load ptr, ptr @stderr, align 8
  %271 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %270, ptr noundef @.str.17) #4
  store i32 -3, ptr %16, align 4
  store i32 100, ptr @main.ntimes, align 4
  br label %272

272:                                              ; preds = %301, %261
  %273 = call float @second()
  store float %273, ptr %20, align 4
  %274 = load i32, ptr %16, align 4
  %275 = add nsw i32 %274, 1
  store i32 %275, ptr %16, align 4
  store i32 0, ptr @main.i, align 4
  br label %276

276:                                              ; preds = %285, %272
  %277 = load i32, ptr @main.i, align 4
  %278 = load i32, ptr @main.ntimes, align 4
  %279 = icmp slt i32 %277, %278
  br i1 %279, label %280, label %288

280:                                              ; preds = %276
  %281 = load i32, ptr @main.lda, align 4
  %282 = load i32, ptr @main.n, align 4
  call void @matgen(ptr noundef @main.a, i32 noundef %281, i32 noundef %282, ptr noundef @main.b, ptr noundef %5)
  %283 = load i32, ptr @main.lda, align 4
  %284 = load i32, ptr @main.n, align 4
  call void @dgefa(ptr noundef @main.a, i32 noundef %283, i32 noundef %284, ptr noundef @main.ipvt, ptr noundef @main.info)
  br label %285

285:                                              ; preds = %280
  %286 = load i32, ptr @main.i, align 4
  %287 = add nsw i32 %286, 1
  store i32 %287, ptr @main.i, align 4
  br label %276, !llvm.loop !11

288:                                              ; preds = %276
  %289 = call float @second()
  %290 = load float, ptr %20, align 4
  %291 = fsub float %289, %290
  store float %291, ptr %21, align 4
  %292 = load ptr, ptr @stderr, align 8
  %293 = load i32, ptr @main.ntimes, align 4
  %294 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %292, ptr noundef @.str.15, i32 noundef %293, double noundef 0.000000e+00) #4
  %295 = load i32, ptr %16, align 4
  %296 = icmp slt i32 %295, 0
  br i1 %296, label %297, label %300

297:                                              ; preds = %288
  %298 = load i32, ptr @main.ntimes, align 4
  %299 = mul nsw i32 %298, 2
  store i32 %299, ptr @main.ntimes, align 4
  br label %300

300:                                              ; preds = %297, %288
  br label %301

301:                                              ; preds = %300
  %302 = load i32, ptr %16, align 4
  %303 = icmp slt i32 %302, 0
  br i1 %303, label %272, label %304, !llvm.loop !12

304:                                              ; preds = %301
  store i32 1000, ptr @main.ntimes, align 4
  %305 = load i32, ptr @main.ntimes, align 4
  %306 = icmp eq i32 %305, 0
  br i1 %306, label %307, label %308

307:                                              ; preds = %304
  store i32 1, ptr @main.ntimes, align 4
  br label %308

308:                                              ; preds = %307, %304
  %309 = load ptr, ptr @stderr, align 8
  %310 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %309, ptr noundef @.str.18, i32 noundef 0) #4
  %311 = load ptr, ptr @stderr, align 8
  %312 = load i32, ptr @main.lda, align 4
  %313 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %311, ptr noundef @.str.19, i32 noundef %312) #4
  %314 = load ptr, ptr @stderr, align 8
  %315 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %314, ptr noundef @.str.12) #4
  %316 = load ptr, ptr @stderr, align 8
  %317 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %316, ptr noundef @.str.13) #4
  %318 = load i32, ptr @main.ntimes, align 4
  %319 = sitofp i32 %318 to float
  %320 = load float, ptr %18, align 4
  %321 = fmul float %319, %320
  store float %321, ptr %11, align 4
  store float 0.000000e+00, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 204), align 4
  store i32 1, ptr @main.j, align 4
  br label %322

322:                                              ; preds = %418, %308
  %323 = load i32, ptr @main.j, align 4
  %324 = icmp slt i32 %323, 6
  br i1 %324, label %325, label %421

325:                                              ; preds = %322
  %326 = call float @second()
  store float %326, ptr %10, align 4
  store i32 0, ptr @main.i, align 4
  br label %327

327:                                              ; preds = %336, %325
  %328 = load i32, ptr @main.i, align 4
  %329 = load i32, ptr @main.ntimes, align 4
  %330 = icmp slt i32 %328, %329
  br i1 %330, label %331, label %339

331:                                              ; preds = %327
  %332 = load i32, ptr @main.lda, align 4
  %333 = load i32, ptr @main.n, align 4
  call void @matgen(ptr noundef @main.a, i32 noundef %332, i32 noundef %333, ptr noundef @main.b, ptr noundef %5)
  %334 = load i32, ptr @main.lda, align 4
  %335 = load i32, ptr @main.n, align 4
  call void @dgefa(ptr noundef @main.a, i32 noundef %334, i32 noundef %335, ptr noundef @main.ipvt, ptr noundef @main.info)
  br label %336

336:                                              ; preds = %331
  %337 = load i32, ptr @main.i, align 4
  %338 = add nsw i32 %337, 1
  store i32 %338, ptr @main.i, align 4
  br label %327, !llvm.loop !13

339:                                              ; preds = %327
  %340 = call float @second()
  %341 = load float, ptr %10, align 4
  %342 = fsub float %340, %341
  %343 = load float, ptr %11, align 4
  %344 = fsub float %342, %343
  %345 = load i32, ptr @main.ntimes, align 4
  %346 = sitofp i32 %345 to float
  %347 = fdiv float %344, %346
  %348 = load i32, ptr @main.j, align 4
  %349 = sext i32 %348 to i64
  %350 = getelementptr inbounds [15 x float], ptr @atime, i64 0, i64 %349
  store float %347, ptr %350, align 4
  %351 = call float @second()
  store float %351, ptr %10, align 4
  store i32 0, ptr @main.i, align 4
  br label %352

352:                                              ; preds = %359, %339
  %353 = load i32, ptr @main.i, align 4
  %354 = load i32, ptr @main.ntimes, align 4
  %355 = icmp slt i32 %353, %354
  br i1 %355, label %356, label %362

356:                                              ; preds = %352
  %357 = load i32, ptr @main.lda, align 4
  %358 = load i32, ptr @main.n, align 4
  call void @dgesl(ptr noundef @main.a, i32 noundef %357, i32 noundef %358, ptr noundef @main.ipvt, ptr noundef @main.b, i32 noundef 0)
  br label %359

359:                                              ; preds = %356
  %360 = load i32, ptr @main.i, align 4
  %361 = add nsw i32 %360, 1
  store i32 %361, ptr @main.i, align 4
  br label %352, !llvm.loop !14

362:                                              ; preds = %352
  %363 = call float @second()
  %364 = load float, ptr %10, align 4
  %365 = fsub float %363, %364
  %366 = load i32, ptr @main.ntimes, align 4
  %367 = sitofp i32 %366 to float
  %368 = fdiv float %365, %367
  %369 = load i32, ptr @main.j, align 4
  %370 = sext i32 %369 to i64
  %371 = getelementptr inbounds [15 x float], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 60), i64 0, i64 %370
  store float %368, ptr %371, align 4
  %372 = load i32, ptr @main.j, align 4
  %373 = sext i32 %372 to i64
  %374 = getelementptr inbounds [15 x float], ptr @atime, i64 0, i64 %373
  %375 = load float, ptr %374, align 4
  %376 = load i32, ptr @main.j, align 4
  %377 = sext i32 %376 to i64
  %378 = getelementptr inbounds [15 x float], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 60), i64 0, i64 %377
  %379 = load float, ptr %378, align 4
  %380 = fadd float %375, %379
  store float %380, ptr %4, align 4
  %381 = load float, ptr %4, align 4
  %382 = load i32, ptr @main.j, align 4
  %383 = sext i32 %382 to i64
  %384 = getelementptr inbounds [15 x float], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 120), i64 0, i64 %383
  store float %381, ptr %384, align 4
  %385 = load float, ptr %3, align 4
  %386 = fpext float %385 to double
  %387 = load float, ptr %4, align 4
  %388 = fpext float %387 to double
  %389 = fmul double 1.000000e+06, %388
  %390 = fdiv double %386, %389
  %391 = fptrunc double %390 to float
  %392 = load i32, ptr @main.j, align 4
  %393 = sext i32 %392 to i64
  %394 = getelementptr inbounds [15 x float], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 180), i64 0, i64 %393
  store float %391, ptr %394, align 4
  %395 = load i32, ptr @main.j, align 4
  %396 = sext i32 %395 to i64
  %397 = getelementptr inbounds [15 x float], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 180), i64 0, i64 %396
  %398 = load float, ptr %397, align 4
  %399 = fpext float %398 to double
  %400 = fdiv double 2.000000e+00, %399
  %401 = fptrunc double %400 to float
  %402 = load i32, ptr @main.j, align 4
  %403 = sext i32 %402 to i64
  %404 = getelementptr inbounds [15 x float], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 240), i64 0, i64 %403
  store float %401, ptr %404, align 4
  %405 = load float, ptr %4, align 4
  %406 = load float, ptr %2, align 4
  %407 = fdiv float %405, %406
  %408 = load i32, ptr @main.j, align 4
  %409 = sext i32 %408 to i64
  %410 = getelementptr inbounds [15 x float], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 300), i64 0, i64 %409
  store float %407, ptr %410, align 4
  %411 = load float, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 204), align 4
  %412 = load i32, ptr @main.j, align 4
  %413 = sext i32 %412 to i64
  %414 = getelementptr inbounds [15 x float], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 180), i64 0, i64 %413
  %415 = load float, ptr %414, align 4
  %416 = fadd float %411, %415
  store float %416, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 204), align 4
  %417 = load i32, ptr @main.j, align 4
  call void @print_time(i32 noundef %417)
  br label %418

418:                                              ; preds = %362
  %419 = load i32, ptr @main.j, align 4
  %420 = add nsw i32 %419, 1
  store i32 %420, ptr @main.j, align 4
  br label %322, !llvm.loop !15

421:                                              ; preds = %322
  %422 = load float, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 204), align 4
  %423 = fpext float %422 to double
  %424 = fdiv double %423, 5.000000e+00
  %425 = fptrunc double %424 to float
  store float %425, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 204), align 4
  %426 = load ptr, ptr @stderr, align 8
  %427 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %426, ptr noundef @.str.20, double noundef 0.000000e+00) #4
  %428 = load ptr, ptr @stderr, align 8
  %429 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %428, ptr noundef @.str.21) #4
  %430 = call float @second()
  store float %430, ptr %20, align 4
  store i32 0, ptr @main.i, align 4
  br label %431

431:                                              ; preds = %438, %421
  %432 = load i32, ptr @main.i, align 4
  %433 = load i32, ptr %17, align 4
  %434 = icmp slt i32 %432, %433
  br i1 %434, label %435, label %441

435:                                              ; preds = %431
  %436 = load i32, ptr @main.ldaa, align 4
  %437 = load i32, ptr @main.n, align 4
  call void @matgen(ptr noundef @main.aa, i32 noundef %436, i32 noundef %437, ptr noundef @main.b, ptr noundef %5)
  br label %438

438:                                              ; preds = %435
  %439 = load i32, ptr @main.i, align 4
  %440 = add nsw i32 %439, 1
  store i32 %440, ptr @main.i, align 4
  br label %431, !llvm.loop !16

441:                                              ; preds = %431
  %442 = call float @second()
  store float %442, ptr %21, align 4
  %443 = load float, ptr %21, align 4
  %444 = load float, ptr %20, align 4
  %445 = fsub float %443, %444
  store float %445, ptr %19, align 4
  %446 = load float, ptr %19, align 4
  %447 = fpext float %446 to double
  %448 = load i32, ptr %17, align 4
  %449 = sitofp i32 %448 to double
  %450 = fdiv double %447, %449
  %451 = fptrunc double %450 to float
  store float %451, ptr %19, align 4
  %452 = load ptr, ptr @stderr, align 8
  %453 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %452, ptr noundef @.str.16, double noundef 0.000000e+00) #4
  %454 = load ptr, ptr @stderr, align 8
  %455 = load i32, ptr @main.ldaa, align 4
  %456 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %454, ptr noundef @.str.19, i32 noundef %455) #4
  %457 = load ptr, ptr @stderr, align 8
  %458 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %457, ptr noundef @.str.12) #4
  %459 = load ptr, ptr @stderr, align 8
  %460 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %459, ptr noundef @.str.13) #4
  %461 = load i32, ptr @main.ntimes, align 4
  %462 = sitofp i32 %461 to float
  %463 = load float, ptr %19, align 4
  %464 = fmul float %462, %463
  store float %464, ptr %11, align 4
  store float 0.000000e+00, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 228), align 4
  store i32 7, ptr @main.j, align 4
  br label %465

465:                                              ; preds = %561, %441
  %466 = load i32, ptr @main.j, align 4
  %467 = icmp slt i32 %466, 12
  br i1 %467, label %468, label %564

468:                                              ; preds = %465
  %469 = call float @second()
  store float %469, ptr %10, align 4
  store i32 0, ptr @main.i, align 4
  br label %470

470:                                              ; preds = %479, %468
  %471 = load i32, ptr @main.i, align 4
  %472 = load i32, ptr @main.ntimes, align 4
  %473 = icmp slt i32 %471, %472
  br i1 %473, label %474, label %482

474:                                              ; preds = %470
  %475 = load i32, ptr @main.ldaa, align 4
  %476 = load i32, ptr @main.n, align 4
  call void @matgen(ptr noundef @main.aa, i32 noundef %475, i32 noundef %476, ptr noundef @main.b, ptr noundef %5)
  %477 = load i32, ptr @main.ldaa, align 4
  %478 = load i32, ptr @main.n, align 4
  call void @dgefa(ptr noundef @main.aa, i32 noundef %477, i32 noundef %478, ptr noundef @main.ipvt, ptr noundef @main.info)
  br label %479

479:                                              ; preds = %474
  %480 = load i32, ptr @main.i, align 4
  %481 = add nsw i32 %480, 1
  store i32 %481, ptr @main.i, align 4
  br label %470, !llvm.loop !17

482:                                              ; preds = %470
  %483 = call float @second()
  %484 = load float, ptr %10, align 4
  %485 = fsub float %483, %484
  %486 = load float, ptr %11, align 4
  %487 = fsub float %485, %486
  %488 = load i32, ptr @main.ntimes, align 4
  %489 = sitofp i32 %488 to float
  %490 = fdiv float %487, %489
  %491 = load i32, ptr @main.j, align 4
  %492 = sext i32 %491 to i64
  %493 = getelementptr inbounds [15 x float], ptr @atime, i64 0, i64 %492
  store float %490, ptr %493, align 4
  %494 = call float @second()
  store float %494, ptr %10, align 4
  store i32 0, ptr @main.i, align 4
  br label %495

495:                                              ; preds = %502, %482
  %496 = load i32, ptr @main.i, align 4
  %497 = load i32, ptr @main.ntimes, align 4
  %498 = icmp slt i32 %496, %497
  br i1 %498, label %499, label %505

499:                                              ; preds = %495
  %500 = load i32, ptr @main.ldaa, align 4
  %501 = load i32, ptr @main.n, align 4
  call void @dgesl(ptr noundef @main.aa, i32 noundef %500, i32 noundef %501, ptr noundef @main.ipvt, ptr noundef @main.b, i32 noundef 0)
  br label %502

502:                                              ; preds = %499
  %503 = load i32, ptr @main.i, align 4
  %504 = add nsw i32 %503, 1
  store i32 %504, ptr @main.i, align 4
  br label %495, !llvm.loop !18

505:                                              ; preds = %495
  %506 = call float @second()
  %507 = load float, ptr %10, align 4
  %508 = fsub float %506, %507
  %509 = load i32, ptr @main.ntimes, align 4
  %510 = sitofp i32 %509 to float
  %511 = fdiv float %508, %510
  %512 = load i32, ptr @main.j, align 4
  %513 = sext i32 %512 to i64
  %514 = getelementptr inbounds [15 x float], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 60), i64 0, i64 %513
  store float %511, ptr %514, align 4
  %515 = load i32, ptr @main.j, align 4
  %516 = sext i32 %515 to i64
  %517 = getelementptr inbounds [15 x float], ptr @atime, i64 0, i64 %516
  %518 = load float, ptr %517, align 4
  %519 = load i32, ptr @main.j, align 4
  %520 = sext i32 %519 to i64
  %521 = getelementptr inbounds [15 x float], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 60), i64 0, i64 %520
  %522 = load float, ptr %521, align 4
  %523 = fadd float %518, %522
  store float %523, ptr %4, align 4
  %524 = load float, ptr %4, align 4
  %525 = load i32, ptr @main.j, align 4
  %526 = sext i32 %525 to i64
  %527 = getelementptr inbounds [15 x float], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 120), i64 0, i64 %526
  store float %524, ptr %527, align 4
  %528 = load float, ptr %3, align 4
  %529 = fpext float %528 to double
  %530 = load float, ptr %4, align 4
  %531 = fpext float %530 to double
  %532 = fmul double 1.000000e+06, %531
  %533 = fdiv double %529, %532
  %534 = fptrunc double %533 to float
  %535 = load i32, ptr @main.j, align 4
  %536 = sext i32 %535 to i64
  %537 = getelementptr inbounds [15 x float], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 180), i64 0, i64 %536
  store float %534, ptr %537, align 4
  %538 = load i32, ptr @main.j, align 4
  %539 = sext i32 %538 to i64
  %540 = getelementptr inbounds [15 x float], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 180), i64 0, i64 %539
  %541 = load float, ptr %540, align 4
  %542 = fpext float %541 to double
  %543 = fdiv double 2.000000e+00, %542
  %544 = fptrunc double %543 to float
  %545 = load i32, ptr @main.j, align 4
  %546 = sext i32 %545 to i64
  %547 = getelementptr inbounds [15 x float], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 240), i64 0, i64 %546
  store float %544, ptr %547, align 4
  %548 = load float, ptr %4, align 4
  %549 = load float, ptr %2, align 4
  %550 = fdiv float %548, %549
  %551 = load i32, ptr @main.j, align 4
  %552 = sext i32 %551 to i64
  %553 = getelementptr inbounds [15 x float], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 300), i64 0, i64 %552
  store float %550, ptr %553, align 4
  %554 = load float, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 228), align 4
  %555 = load i32, ptr @main.j, align 4
  %556 = sext i32 %555 to i64
  %557 = getelementptr inbounds [15 x float], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 180), i64 0, i64 %556
  %558 = load float, ptr %557, align 4
  %559 = fadd float %554, %558
  store float %559, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 228), align 4
  %560 = load i32, ptr @main.j, align 4
  call void @print_time(i32 noundef %560)
  br label %561

561:                                              ; preds = %505
  %562 = load i32, ptr @main.j, align 4
  %563 = add nsw i32 %562, 1
  store i32 %563, ptr @main.j, align 4
  br label %465, !llvm.loop !19

564:                                              ; preds = %465
  %565 = load float, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 228), align 4
  %566 = fpext float %565 to double
  %567 = fdiv double %566, 5.000000e+00
  %568 = fptrunc double %567 to float
  store float %568, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 228), align 4
  %569 = load ptr, ptr @stderr, align 8
  %570 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %569, ptr noundef @.str.20, double noundef 0.000000e+00) #4
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #2

; Function Attrs: nounwind
declare i32 @fprintf(ptr noundef, ptr noundef, ...) #1

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #3

; Function Attrs: noinline nounwind uwtable
define dso_local void @matgen(ptr noundef %0, i32 noundef %1, i32 noundef %2, ptr noundef %3, ptr noundef %4) #0 {
  %6 = alloca ptr, align 8
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca ptr, align 8
  %10 = alloca ptr, align 8
  %11 = alloca i32, align 4
  %12 = alloca i32, align 4
  %13 = alloca i32, align 4
  store ptr %0, ptr %6, align 8
  store i32 %1, ptr %7, align 4
  store i32 %2, ptr %8, align 4
  store ptr %3, ptr %9, align 8
  store ptr %4, ptr %10, align 8
  store i32 1325, ptr %11, align 4
  %14 = load ptr, ptr %10, align 8
  store float 0.000000e+00, ptr %14, align 4
  store i32 0, ptr %13, align 4
  br label %15

15:                                               ; preds = %73, %5
  %16 = load i32, ptr %13, align 4
  %17 = load i32, ptr %8, align 4
  %18 = icmp slt i32 %16, %17
  br i1 %18, label %19, label %76

19:                                               ; preds = %15
  store i32 0, ptr %12, align 4
  br label %20

20:                                               ; preds = %69, %19
  %21 = load i32, ptr %12, align 4
  %22 = load i32, ptr %8, align 4
  %23 = icmp slt i32 %21, %22
  br i1 %23, label %24, label %72

24:                                               ; preds = %20
  %25 = load i32, ptr %11, align 4
  %26 = mul nsw i32 3125, %25
  %27 = srem i32 %26, 65536
  store i32 %27, ptr %11, align 4
  %28 = load i32, ptr %11, align 4
  %29 = sitofp i32 %28 to double
  %30 = fsub double %29, 3.276800e+04
  %31 = fdiv double %30, 1.638400e+04
  %32 = fptrunc double %31 to float
  %33 = load ptr, ptr %6, align 8
  %34 = load i32, ptr %7, align 4
  %35 = load i32, ptr %13, align 4
  %36 = mul nsw i32 %34, %35
  %37 = load i32, ptr %12, align 4
  %38 = add nsw i32 %36, %37
  %39 = sext i32 %38 to i64
  %40 = getelementptr inbounds float, ptr %33, i64 %39
  store float %32, ptr %40, align 4
  %41 = load ptr, ptr %6, align 8
  %42 = load i32, ptr %7, align 4
  %43 = load i32, ptr %13, align 4
  %44 = mul nsw i32 %42, %43
  %45 = load i32, ptr %12, align 4
  %46 = add nsw i32 %44, %45
  %47 = sext i32 %46 to i64
  %48 = getelementptr inbounds float, ptr %41, i64 %47
  %49 = load float, ptr %48, align 4
  %50 = load ptr, ptr %10, align 8
  %51 = load float, ptr %50, align 4
  %52 = fcmp ogt float %49, %51
  br i1 %52, label %53, label %63

53:                                               ; preds = %24
  %54 = load ptr, ptr %6, align 8
  %55 = load i32, ptr %7, align 4
  %56 = load i32, ptr %13, align 4
  %57 = mul nsw i32 %55, %56
  %58 = load i32, ptr %12, align 4
  %59 = add nsw i32 %57, %58
  %60 = sext i32 %59 to i64
  %61 = getelementptr inbounds float, ptr %54, i64 %60
  %62 = load float, ptr %61, align 4
  br label %66

63:                                               ; preds = %24
  %64 = load ptr, ptr %10, align 8
  %65 = load float, ptr %64, align 4
  br label %66

66:                                               ; preds = %63, %53
  %67 = phi float [ %62, %53 ], [ %65, %63 ]
  %68 = load ptr, ptr %10, align 8
  store float %67, ptr %68, align 4
  br label %69

69:                                               ; preds = %66
  %70 = load i32, ptr %12, align 4
  %71 = add nsw i32 %70, 1
  store i32 %71, ptr %12, align 4
  br label %20, !llvm.loop !20

72:                                               ; preds = %20
  br label %73

73:                                               ; preds = %72
  %74 = load i32, ptr %13, align 4
  %75 = add nsw i32 %74, 1
  store i32 %75, ptr %13, align 4
  br label %15, !llvm.loop !21

76:                                               ; preds = %15
  store i32 0, ptr %12, align 4
  br label %77

77:                                               ; preds = %86, %76
  %78 = load i32, ptr %12, align 4
  %79 = load i32, ptr %8, align 4
  %80 = icmp slt i32 %78, %79
  br i1 %80, label %81, label %89

81:                                               ; preds = %77
  %82 = load ptr, ptr %9, align 8
  %83 = load i32, ptr %12, align 4
  %84 = sext i32 %83 to i64
  %85 = getelementptr inbounds float, ptr %82, i64 %84
  store float 0.000000e+00, ptr %85, align 4
  br label %86

86:                                               ; preds = %81
  %87 = load i32, ptr %12, align 4
  %88 = add nsw i32 %87, 1
  store i32 %88, ptr %12, align 4
  br label %77, !llvm.loop !22

89:                                               ; preds = %77
  store i32 0, ptr %13, align 4
  br label %90

90:                                               ; preds = %123, %89
  %91 = load i32, ptr %13, align 4
  %92 = load i32, ptr %8, align 4
  %93 = icmp slt i32 %91, %92
  br i1 %93, label %94, label %126

94:                                               ; preds = %90
  store i32 0, ptr %12, align 4
  br label %95

95:                                               ; preds = %119, %94
  %96 = load i32, ptr %12, align 4
  %97 = load i32, ptr %8, align 4
  %98 = icmp slt i32 %96, %97
  br i1 %98, label %99, label %122

99:                                               ; preds = %95
  %100 = load ptr, ptr %9, align 8
  %101 = load i32, ptr %12, align 4
  %102 = sext i32 %101 to i64
  %103 = getelementptr inbounds float, ptr %100, i64 %102
  %104 = load float, ptr %103, align 4
  %105 = load ptr, ptr %6, align 8
  %106 = load i32, ptr %7, align 4
  %107 = load i32, ptr %13, align 4
  %108 = mul nsw i32 %106, %107
  %109 = load i32, ptr %12, align 4
  %110 = add nsw i32 %108, %109
  %111 = sext i32 %110 to i64
  %112 = getelementptr inbounds float, ptr %105, i64 %111
  %113 = load float, ptr %112, align 4
  %114 = fadd float %104, %113
  %115 = load ptr, ptr %9, align 8
  %116 = load i32, ptr %12, align 4
  %117 = sext i32 %116 to i64
  %118 = getelementptr inbounds float, ptr %115, i64 %117
  store float %114, ptr %118, align 4
  br label %119

119:                                              ; preds = %99
  %120 = load i32, ptr %12, align 4
  %121 = add nsw i32 %120, 1
  store i32 %121, ptr %12, align 4
  br label %95, !llvm.loop !23

122:                                              ; preds = %95
  br label %123

123:                                              ; preds = %122
  %124 = load i32, ptr %13, align 4
  %125 = add nsw i32 %124, 1
  store i32 %125, ptr %13, align 4
  br label %90, !llvm.loop !24

126:                                              ; preds = %90
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local void @dgefa(ptr noundef %0, i32 noundef %1, i32 noundef %2, ptr noundef %3, ptr noundef %4) #0 {
  %6 = alloca ptr, align 8
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca ptr, align 8
  %10 = alloca ptr, align 8
  %11 = alloca float, align 4
  %12 = alloca i32, align 4
  %13 = alloca i32, align 4
  %14 = alloca i32, align 4
  %15 = alloca i32, align 4
  %16 = alloca i32, align 4
  store ptr %0, ptr %6, align 8
  store i32 %1, ptr %7, align 4
  store i32 %2, ptr %8, align 4
  store ptr %3, ptr %9, align 8
  store ptr %4, ptr %10, align 8
  %17 = load ptr, ptr %10, align 8
  store i32 0, ptr %17, align 4
  %18 = load i32, ptr %8, align 4
  %19 = sub nsw i32 %18, 1
  store i32 %19, ptr %16, align 4
  %20 = load i32, ptr %16, align 4
  %21 = icmp sge i32 %20, 0
  br i1 %21, label %22, label %208

22:                                               ; preds = %5
  store i32 0, ptr %13, align 4
  br label %23

23:                                               ; preds = %204, %22
  %24 = load i32, ptr %13, align 4
  %25 = load i32, ptr %16, align 4
  %26 = icmp slt i32 %24, %25
  br i1 %26, label %27, label %207

27:                                               ; preds = %23
  %28 = load i32, ptr %13, align 4
  %29 = add nsw i32 %28, 1
  store i32 %29, ptr %14, align 4
  %30 = load i32, ptr %8, align 4
  %31 = load i32, ptr %13, align 4
  %32 = sub nsw i32 %30, %31
  %33 = load ptr, ptr %6, align 8
  %34 = load i32, ptr %7, align 4
  %35 = load i32, ptr %13, align 4
  %36 = mul nsw i32 %34, %35
  %37 = load i32, ptr %13, align 4
  %38 = add nsw i32 %36, %37
  %39 = sext i32 %38 to i64
  %40 = getelementptr inbounds float, ptr %33, i64 %39
  %41 = call i32 @idamax(i32 noundef %32, ptr noundef %40, i32 noundef 1)
  %42 = load i32, ptr %13, align 4
  %43 = add nsw i32 %41, %42
  store i32 %43, ptr %15, align 4
  %44 = load i32, ptr %15, align 4
  %45 = load ptr, ptr %9, align 8
  %46 = load i32, ptr %13, align 4
  %47 = sext i32 %46 to i64
  %48 = getelementptr inbounds i32, ptr %45, i64 %47
  store i32 %44, ptr %48, align 4
  %49 = load ptr, ptr %6, align 8
  %50 = load i32, ptr %7, align 4
  %51 = load i32, ptr %13, align 4
  %52 = mul nsw i32 %50, %51
  %53 = load i32, ptr %15, align 4
  %54 = add nsw i32 %52, %53
  %55 = sext i32 %54 to i64
  %56 = getelementptr inbounds float, ptr %49, i64 %55
  %57 = load float, ptr %56, align 4
  %58 = fpext float %57 to double
  %59 = fcmp une double %58, 0.000000e+00
  br i1 %59, label %60, label %200

60:                                               ; preds = %27
  %61 = load i32, ptr %15, align 4
  %62 = load i32, ptr %13, align 4
  %63 = icmp ne i32 %61, %62
  br i1 %63, label %64, label %100

64:                                               ; preds = %60
  %65 = load ptr, ptr %6, align 8
  %66 = load i32, ptr %7, align 4
  %67 = load i32, ptr %13, align 4
  %68 = mul nsw i32 %66, %67
  %69 = load i32, ptr %15, align 4
  %70 = add nsw i32 %68, %69
  %71 = sext i32 %70 to i64
  %72 = getelementptr inbounds float, ptr %65, i64 %71
  %73 = load float, ptr %72, align 4
  store float %73, ptr %11, align 4
  %74 = load ptr, ptr %6, align 8
  %75 = load i32, ptr %7, align 4
  %76 = load i32, ptr %13, align 4
  %77 = mul nsw i32 %75, %76
  %78 = load i32, ptr %13, align 4
  %79 = add nsw i32 %77, %78
  %80 = sext i32 %79 to i64
  %81 = getelementptr inbounds float, ptr %74, i64 %80
  %82 = load float, ptr %81, align 4
  %83 = load ptr, ptr %6, align 8
  %84 = load i32, ptr %7, align 4
  %85 = load i32, ptr %13, align 4
  %86 = mul nsw i32 %84, %85
  %87 = load i32, ptr %15, align 4
  %88 = add nsw i32 %86, %87
  %89 = sext i32 %88 to i64
  %90 = getelementptr inbounds float, ptr %83, i64 %89
  store float %82, ptr %90, align 4
  %91 = load float, ptr %11, align 4
  %92 = load ptr, ptr %6, align 8
  %93 = load i32, ptr %7, align 4
  %94 = load i32, ptr %13, align 4
  %95 = mul nsw i32 %93, %94
  %96 = load i32, ptr %13, align 4
  %97 = add nsw i32 %95, %96
  %98 = sext i32 %97 to i64
  %99 = getelementptr inbounds float, ptr %92, i64 %98
  store float %91, ptr %99, align 4
  br label %100

100:                                              ; preds = %64, %60
  %101 = load ptr, ptr %6, align 8
  %102 = load i32, ptr %7, align 4
  %103 = load i32, ptr %13, align 4
  %104 = mul nsw i32 %102, %103
  %105 = load i32, ptr %13, align 4
  %106 = add nsw i32 %104, %105
  %107 = sext i32 %106 to i64
  %108 = getelementptr inbounds float, ptr %101, i64 %107
  %109 = load float, ptr %108, align 4
  %110 = fpext float %109 to double
  %111 = fdiv double -1.000000e+00, %110
  %112 = fptrunc double %111 to float
  store float %112, ptr %11, align 4
  %113 = load i32, ptr %8, align 4
  %114 = load i32, ptr %13, align 4
  %115 = add nsw i32 %114, 1
  %116 = sub nsw i32 %113, %115
  %117 = load float, ptr %11, align 4
  %118 = load ptr, ptr %6, align 8
  %119 = load i32, ptr %7, align 4
  %120 = load i32, ptr %13, align 4
  %121 = mul nsw i32 %119, %120
  %122 = load i32, ptr %13, align 4
  %123 = add nsw i32 %121, %122
  %124 = add nsw i32 %123, 1
  %125 = sext i32 %124 to i64
  %126 = getelementptr inbounds float, ptr %118, i64 %125
  call void @dscal(i32 noundef %116, float noundef %117, ptr noundef %126, i32 noundef 1)
  %127 = load i32, ptr %14, align 4
  store i32 %127, ptr %12, align 4
  br label %128

128:                                              ; preds = %196, %100
  %129 = load i32, ptr %12, align 4
  %130 = load i32, ptr %8, align 4
  %131 = icmp slt i32 %129, %130
  br i1 %131, label %132, label %199

132:                                              ; preds = %128
  %133 = load ptr, ptr %6, align 8
  %134 = load i32, ptr %7, align 4
  %135 = load i32, ptr %12, align 4
  %136 = mul nsw i32 %134, %135
  %137 = load i32, ptr %15, align 4
  %138 = add nsw i32 %136, %137
  %139 = sext i32 %138 to i64
  %140 = getelementptr inbounds float, ptr %133, i64 %139
  %141 = load float, ptr %140, align 4
  store float %141, ptr %11, align 4
  %142 = load i32, ptr %15, align 4
  %143 = load i32, ptr %13, align 4
  %144 = icmp ne i32 %142, %143
  br i1 %144, label %145, label %172

145:                                              ; preds = %132
  %146 = load ptr, ptr %6, align 8
  %147 = load i32, ptr %7, align 4
  %148 = load i32, ptr %12, align 4
  %149 = mul nsw i32 %147, %148
  %150 = load i32, ptr %13, align 4
  %151 = add nsw i32 %149, %150
  %152 = sext i32 %151 to i64
  %153 = getelementptr inbounds float, ptr %146, i64 %152
  %154 = load float, ptr %153, align 4
  %155 = load ptr, ptr %6, align 8
  %156 = load i32, ptr %7, align 4
  %157 = load i32, ptr %12, align 4
  %158 = mul nsw i32 %156, %157
  %159 = load i32, ptr %15, align 4
  %160 = add nsw i32 %158, %159
  %161 = sext i32 %160 to i64
  %162 = getelementptr inbounds float, ptr %155, i64 %161
  store float %154, ptr %162, align 4
  %163 = load float, ptr %11, align 4
  %164 = load ptr, ptr %6, align 8
  %165 = load i32, ptr %7, align 4
  %166 = load i32, ptr %12, align 4
  %167 = mul nsw i32 %165, %166
  %168 = load i32, ptr %13, align 4
  %169 = add nsw i32 %167, %168
  %170 = sext i32 %169 to i64
  %171 = getelementptr inbounds float, ptr %164, i64 %170
  store float %163, ptr %171, align 4
  br label %172

172:                                              ; preds = %145, %132
  %173 = load i32, ptr %8, align 4
  %174 = load i32, ptr %13, align 4
  %175 = add nsw i32 %174, 1
  %176 = sub nsw i32 %173, %175
  %177 = load float, ptr %11, align 4
  %178 = load ptr, ptr %6, align 8
  %179 = load i32, ptr %7, align 4
  %180 = load i32, ptr %13, align 4
  %181 = mul nsw i32 %179, %180
  %182 = load i32, ptr %13, align 4
  %183 = add nsw i32 %181, %182
  %184 = add nsw i32 %183, 1
  %185 = sext i32 %184 to i64
  %186 = getelementptr inbounds float, ptr %178, i64 %185
  %187 = load ptr, ptr %6, align 8
  %188 = load i32, ptr %7, align 4
  %189 = load i32, ptr %12, align 4
  %190 = mul nsw i32 %188, %189
  %191 = load i32, ptr %13, align 4
  %192 = add nsw i32 %190, %191
  %193 = add nsw i32 %192, 1
  %194 = sext i32 %193 to i64
  %195 = getelementptr inbounds float, ptr %187, i64 %194
  call void @daxpy(i32 noundef %176, float noundef %177, ptr noundef %186, i32 noundef 1, ptr noundef %195, i32 noundef 1)
  br label %196

196:                                              ; preds = %172
  %197 = load i32, ptr %12, align 4
  %198 = add nsw i32 %197, 1
  store i32 %198, ptr %12, align 4
  br label %128, !llvm.loop !25

199:                                              ; preds = %128
  br label %203

200:                                              ; preds = %27
  %201 = load i32, ptr %13, align 4
  %202 = load ptr, ptr %10, align 8
  store i32 %201, ptr %202, align 4
  br label %203

203:                                              ; preds = %200, %199
  br label %204

204:                                              ; preds = %203
  %205 = load i32, ptr %13, align 4
  %206 = add nsw i32 %205, 1
  store i32 %206, ptr %13, align 4
  br label %23, !llvm.loop !26

207:                                              ; preds = %23
  br label %208

208:                                              ; preds = %207, %5
  %209 = load i32, ptr %8, align 4
  %210 = sub nsw i32 %209, 1
  %211 = load ptr, ptr %9, align 8
  %212 = load i32, ptr %8, align 4
  %213 = sub nsw i32 %212, 1
  %214 = sext i32 %213 to i64
  %215 = getelementptr inbounds i32, ptr %211, i64 %214
  store i32 %210, ptr %215, align 4
  %216 = load ptr, ptr %6, align 8
  %217 = load i32, ptr %7, align 4
  %218 = load i32, ptr %8, align 4
  %219 = sub nsw i32 %218, 1
  %220 = mul nsw i32 %217, %219
  %221 = load i32, ptr %8, align 4
  %222 = sub nsw i32 %221, 1
  %223 = add nsw i32 %220, %222
  %224 = sext i32 %223 to i64
  %225 = getelementptr inbounds float, ptr %216, i64 %224
  %226 = load float, ptr %225, align 4
  %227 = fpext float %226 to double
  %228 = fcmp oeq double %227, 0.000000e+00
  br i1 %228, label %229, label %233

229:                                              ; preds = %208
  %230 = load i32, ptr %8, align 4
  %231 = sub nsw i32 %230, 1
  %232 = load ptr, ptr %10, align 8
  store i32 %231, ptr %232, align 4
  br label %233

233:                                              ; preds = %229, %208
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local void @dgesl(ptr noundef %0, i32 noundef %1, i32 noundef %2, ptr noundef %3, ptr noundef %4, i32 noundef %5) #0 {
  %7 = alloca ptr, align 8
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  %10 = alloca ptr, align 8
  %11 = alloca ptr, align 8
  %12 = alloca i32, align 4
  %13 = alloca float, align 4
  %14 = alloca i32, align 4
  %15 = alloca i32, align 4
  %16 = alloca i32, align 4
  %17 = alloca i32, align 4
  store ptr %0, ptr %7, align 8
  store i32 %1, ptr %8, align 4
  store i32 %2, ptr %9, align 4
  store ptr %3, ptr %10, align 8
  store ptr %4, ptr %11, align 8
  store i32 %5, ptr %12, align 4
  %18 = load i32, ptr %9, align 4
  %19 = sub nsw i32 %18, 1
  store i32 %19, ptr %17, align 4
  %20 = load i32, ptr %12, align 4
  %21 = icmp eq i32 %20, 0
  br i1 %21, label %22, label %133

22:                                               ; preds = %6
  %23 = load i32, ptr %17, align 4
  %24 = icmp sge i32 %23, 1
  br i1 %24, label %25, label %83

25:                                               ; preds = %22
  store i32 0, ptr %14, align 4
  br label %26

26:                                               ; preds = %79, %25
  %27 = load i32, ptr %14, align 4
  %28 = load i32, ptr %17, align 4
  %29 = icmp slt i32 %27, %28
  br i1 %29, label %30, label %82

30:                                               ; preds = %26
  %31 = load ptr, ptr %10, align 8
  %32 = load i32, ptr %14, align 4
  %33 = sext i32 %32 to i64
  %34 = getelementptr inbounds i32, ptr %31, i64 %33
  %35 = load i32, ptr %34, align 4
  store i32 %35, ptr %16, align 4
  %36 = load ptr, ptr %11, align 8
  %37 = load i32, ptr %16, align 4
  %38 = sext i32 %37 to i64
  %39 = getelementptr inbounds float, ptr %36, i64 %38
  %40 = load float, ptr %39, align 4
  store float %40, ptr %13, align 4
  %41 = load i32, ptr %16, align 4
  %42 = load i32, ptr %14, align 4
  %43 = icmp ne i32 %41, %42
  br i1 %43, label %44, label %59

44:                                               ; preds = %30
  %45 = load ptr, ptr %11, align 8
  %46 = load i32, ptr %14, align 4
  %47 = sext i32 %46 to i64
  %48 = getelementptr inbounds float, ptr %45, i64 %47
  %49 = load float, ptr %48, align 4
  %50 = load ptr, ptr %11, align 8
  %51 = load i32, ptr %16, align 4
  %52 = sext i32 %51 to i64
  %53 = getelementptr inbounds float, ptr %50, i64 %52
  store float %49, ptr %53, align 4
  %54 = load float, ptr %13, align 4
  %55 = load ptr, ptr %11, align 8
  %56 = load i32, ptr %14, align 4
  %57 = sext i32 %56 to i64
  %58 = getelementptr inbounds float, ptr %55, i64 %57
  store float %54, ptr %58, align 4
  br label %59

59:                                               ; preds = %44, %30
  %60 = load i32, ptr %9, align 4
  %61 = load i32, ptr %14, align 4
  %62 = add nsw i32 %61, 1
  %63 = sub nsw i32 %60, %62
  %64 = load float, ptr %13, align 4
  %65 = load ptr, ptr %7, align 8
  %66 = load i32, ptr %8, align 4
  %67 = load i32, ptr %14, align 4
  %68 = mul nsw i32 %66, %67
  %69 = load i32, ptr %14, align 4
  %70 = add nsw i32 %68, %69
  %71 = add nsw i32 %70, 1
  %72 = sext i32 %71 to i64
  %73 = getelementptr inbounds float, ptr %65, i64 %72
  %74 = load ptr, ptr %11, align 8
  %75 = load i32, ptr %14, align 4
  %76 = add nsw i32 %75, 1
  %77 = sext i32 %76 to i64
  %78 = getelementptr inbounds float, ptr %74, i64 %77
  call void @daxpy(i32 noundef %63, float noundef %64, ptr noundef %73, i32 noundef 1, ptr noundef %78, i32 noundef 1)
  br label %79

79:                                               ; preds = %59
  %80 = load i32, ptr %14, align 4
  %81 = add nsw i32 %80, 1
  store i32 %81, ptr %14, align 4
  br label %26, !llvm.loop !27

82:                                               ; preds = %26
  br label %83

83:                                               ; preds = %82, %22
  store i32 0, ptr %15, align 4
  br label %84

84:                                               ; preds = %129, %83
  %85 = load i32, ptr %15, align 4
  %86 = load i32, ptr %9, align 4
  %87 = icmp slt i32 %85, %86
  br i1 %87, label %88, label %132

88:                                               ; preds = %84
  %89 = load i32, ptr %9, align 4
  %90 = load i32, ptr %15, align 4
  %91 = add nsw i32 %90, 1
  %92 = sub nsw i32 %89, %91
  store i32 %92, ptr %14, align 4
  %93 = load ptr, ptr %11, align 8
  %94 = load i32, ptr %14, align 4
  %95 = sext i32 %94 to i64
  %96 = getelementptr inbounds float, ptr %93, i64 %95
  %97 = load float, ptr %96, align 4
  %98 = load ptr, ptr %7, align 8
  %99 = load i32, ptr %8, align 4
  %100 = load i32, ptr %14, align 4
  %101 = mul nsw i32 %99, %100
  %102 = load i32, ptr %14, align 4
  %103 = add nsw i32 %101, %102
  %104 = sext i32 %103 to i64
  %105 = getelementptr inbounds float, ptr %98, i64 %104
  %106 = load float, ptr %105, align 4
  %107 = fdiv float %97, %106
  %108 = load ptr, ptr %11, align 8
  %109 = load i32, ptr %14, align 4
  %110 = sext i32 %109 to i64
  %111 = getelementptr inbounds float, ptr %108, i64 %110
  store float %107, ptr %111, align 4
  %112 = load ptr, ptr %11, align 8
  %113 = load i32, ptr %14, align 4
  %114 = sext i32 %113 to i64
  %115 = getelementptr inbounds float, ptr %112, i64 %114
  %116 = load float, ptr %115, align 4
  %117 = fneg float %116
  store float %117, ptr %13, align 4
  %118 = load i32, ptr %14, align 4
  %119 = load float, ptr %13, align 4
  %120 = load ptr, ptr %7, align 8
  %121 = load i32, ptr %8, align 4
  %122 = load i32, ptr %14, align 4
  %123 = mul nsw i32 %121, %122
  %124 = add nsw i32 %123, 0
  %125 = sext i32 %124 to i64
  %126 = getelementptr inbounds float, ptr %120, i64 %125
  %127 = load ptr, ptr %11, align 8
  %128 = getelementptr inbounds float, ptr %127, i64 0
  call void @daxpy(i32 noundef %118, float noundef %119, ptr noundef %126, i32 noundef 1, ptr noundef %128, i32 noundef 1)
  br label %129

129:                                              ; preds = %88
  %130 = load i32, ptr %15, align 4
  %131 = add nsw i32 %130, 1
  store i32 %131, ptr %15, align 4
  br label %84, !llvm.loop !28

132:                                              ; preds = %84
  br label %250

133:                                              ; preds = %6
  store i32 0, ptr %14, align 4
  br label %134

134:                                              ; preds = %171, %133
  %135 = load i32, ptr %14, align 4
  %136 = load i32, ptr %9, align 4
  %137 = icmp slt i32 %135, %136
  br i1 %137, label %138, label %174

138:                                              ; preds = %134
  %139 = load i32, ptr %14, align 4
  %140 = load ptr, ptr %7, align 8
  %141 = load i32, ptr %8, align 4
  %142 = load i32, ptr %14, align 4
  %143 = mul nsw i32 %141, %142
  %144 = add nsw i32 %143, 0
  %145 = sext i32 %144 to i64
  %146 = getelementptr inbounds float, ptr %140, i64 %145
  %147 = load ptr, ptr %11, align 8
  %148 = getelementptr inbounds float, ptr %147, i64 0
  %149 = call float @ddot(i32 noundef %139, ptr noundef %146, i32 noundef 1, ptr noundef %148, i32 noundef 1)
  store float %149, ptr %13, align 4
  %150 = load ptr, ptr %11, align 8
  %151 = load i32, ptr %14, align 4
  %152 = sext i32 %151 to i64
  %153 = getelementptr inbounds float, ptr %150, i64 %152
  %154 = load float, ptr %153, align 4
  %155 = load float, ptr %13, align 4
  %156 = fsub float %154, %155
  %157 = load ptr, ptr %7, align 8
  %158 = load i32, ptr %8, align 4
  %159 = load i32, ptr %14, align 4
  %160 = mul nsw i32 %158, %159
  %161 = load i32, ptr %14, align 4
  %162 = add nsw i32 %160, %161
  %163 = sext i32 %162 to i64
  %164 = getelementptr inbounds float, ptr %157, i64 %163
  %165 = load float, ptr %164, align 4
  %166 = fdiv float %156, %165
  %167 = load ptr, ptr %11, align 8
  %168 = load i32, ptr %14, align 4
  %169 = sext i32 %168 to i64
  %170 = getelementptr inbounds float, ptr %167, i64 %169
  store float %166, ptr %170, align 4
  br label %171

171:                                              ; preds = %138
  %172 = load i32, ptr %14, align 4
  %173 = add nsw i32 %172, 1
  store i32 %173, ptr %14, align 4
  br label %134, !llvm.loop !29

174:                                              ; preds = %134
  %175 = load i32, ptr %17, align 4
  %176 = icmp sge i32 %175, 1
  br i1 %176, label %177, label %249

177:                                              ; preds = %174
  store i32 1, ptr %15, align 4
  br label %178

178:                                              ; preds = %245, %177
  %179 = load i32, ptr %15, align 4
  %180 = load i32, ptr %17, align 4
  %181 = icmp slt i32 %179, %180
  br i1 %181, label %182, label %248

182:                                              ; preds = %178
  %183 = load i32, ptr %9, align 4
  %184 = load i32, ptr %15, align 4
  %185 = add nsw i32 %184, 1
  %186 = sub nsw i32 %183, %185
  store i32 %186, ptr %14, align 4
  %187 = load ptr, ptr %11, align 8
  %188 = load i32, ptr %14, align 4
  %189 = sext i32 %188 to i64
  %190 = getelementptr inbounds float, ptr %187, i64 %189
  %191 = load float, ptr %190, align 4
  %192 = load i32, ptr %9, align 4
  %193 = load i32, ptr %14, align 4
  %194 = add nsw i32 %193, 1
  %195 = sub nsw i32 %192, %194
  %196 = load ptr, ptr %7, align 8
  %197 = load i32, ptr %8, align 4
  %198 = load i32, ptr %14, align 4
  %199 = mul nsw i32 %197, %198
  %200 = load i32, ptr %14, align 4
  %201 = add nsw i32 %199, %200
  %202 = add nsw i32 %201, 1
  %203 = sext i32 %202 to i64
  %204 = getelementptr inbounds float, ptr %196, i64 %203
  %205 = load ptr, ptr %11, align 8
  %206 = load i32, ptr %14, align 4
  %207 = add nsw i32 %206, 1
  %208 = sext i32 %207 to i64
  %209 = getelementptr inbounds float, ptr %205, i64 %208
  %210 = call float @ddot(i32 noundef %195, ptr noundef %204, i32 noundef 1, ptr noundef %209, i32 noundef 1)
  %211 = fadd float %191, %210
  %212 = load ptr, ptr %11, align 8
  %213 = load i32, ptr %14, align 4
  %214 = sext i32 %213 to i64
  %215 = getelementptr inbounds float, ptr %212, i64 %214
  store float %211, ptr %215, align 4
  %216 = load ptr, ptr %10, align 8
  %217 = load i32, ptr %14, align 4
  %218 = sext i32 %217 to i64
  %219 = getelementptr inbounds i32, ptr %216, i64 %218
  %220 = load i32, ptr %219, align 4
  store i32 %220, ptr %16, align 4
  %221 = load i32, ptr %16, align 4
  %222 = load i32, ptr %14, align 4
  %223 = icmp ne i32 %221, %222
  br i1 %223, label %224, label %244

224:                                              ; preds = %182
  %225 = load ptr, ptr %11, align 8
  %226 = load i32, ptr %16, align 4
  %227 = sext i32 %226 to i64
  %228 = getelementptr inbounds float, ptr %225, i64 %227
  %229 = load float, ptr %228, align 4
  store float %229, ptr %13, align 4
  %230 = load ptr, ptr %11, align 8
  %231 = load i32, ptr %14, align 4
  %232 = sext i32 %231 to i64
  %233 = getelementptr inbounds float, ptr %230, i64 %232
  %234 = load float, ptr %233, align 4
  %235 = load ptr, ptr %11, align 8
  %236 = load i32, ptr %16, align 4
  %237 = sext i32 %236 to i64
  %238 = getelementptr inbounds float, ptr %235, i64 %237
  store float %234, ptr %238, align 4
  %239 = load float, ptr %13, align 4
  %240 = load ptr, ptr %11, align 8
  %241 = load i32, ptr %14, align 4
  %242 = sext i32 %241 to i64
  %243 = getelementptr inbounds float, ptr %240, i64 %242
  store float %239, ptr %243, align 4
  br label %244

244:                                              ; preds = %224, %182
  br label %245

245:                                              ; preds = %244
  %246 = load i32, ptr %15, align 4
  %247 = add nsw i32 %246, 1
  store i32 %247, ptr %15, align 4
  br label %178, !llvm.loop !30

248:                                              ; preds = %178
  br label %249

249:                                              ; preds = %248, %174
  br label %250

250:                                              ; preds = %249, %132
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local void @dmxpy(i32 noundef %0, ptr noundef %1, i32 noundef %2, i32 noundef %3, ptr noundef %4, ptr noundef %5) #0 {
  %7 = alloca i32, align 4
  %8 = alloca ptr, align 8
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  %11 = alloca ptr, align 8
  %12 = alloca ptr, align 8
  %13 = alloca i32, align 4
  %14 = alloca i32, align 4
  %15 = alloca i32, align 4
  store i32 %0, ptr %7, align 4
  store ptr %1, ptr %8, align 8
  store i32 %2, ptr %9, align 4
  store i32 %3, ptr %10, align 4
  store ptr %4, ptr %11, align 8
  store ptr %5, ptr %12, align 8
  %16 = load i32, ptr %9, align 4
  %17 = srem i32 %16, 2
  store i32 %17, ptr %13, align 4
  %18 = load i32, ptr %13, align 4
  %19 = icmp sge i32 %18, 1
  br i1 %19, label %20, label %56

20:                                               ; preds = %6
  %21 = load i32, ptr %13, align 4
  %22 = sub nsw i32 %21, 1
  store i32 %22, ptr %13, align 4
  store i32 0, ptr %14, align 4
  br label %23

23:                                               ; preds = %52, %20
  %24 = load i32, ptr %14, align 4
  %25 = load i32, ptr %7, align 4
  %26 = icmp slt i32 %24, %25
  br i1 %26, label %27, label %55

27:                                               ; preds = %23
  %28 = load ptr, ptr %8, align 8
  %29 = load i32, ptr %14, align 4
  %30 = sext i32 %29 to i64
  %31 = getelementptr inbounds float, ptr %28, i64 %30
  %32 = load float, ptr %31, align 4
  %33 = load ptr, ptr %11, align 8
  %34 = load i32, ptr %13, align 4
  %35 = sext i32 %34 to i64
  %36 = getelementptr inbounds float, ptr %33, i64 %35
  %37 = load float, ptr %36, align 4
  %38 = load ptr, ptr %12, align 8
  %39 = load i32, ptr %10, align 4
  %40 = load i32, ptr %13, align 4
  %41 = mul nsw i32 %39, %40
  %42 = load i32, ptr %14, align 4
  %43 = add nsw i32 %41, %42
  %44 = sext i32 %43 to i64
  %45 = getelementptr inbounds float, ptr %38, i64 %44
  %46 = load float, ptr %45, align 4
  %47 = call float @llvm.fmuladd.f32(float %37, float %46, float %32)
  %48 = load ptr, ptr %8, align 8
  %49 = load i32, ptr %14, align 4
  %50 = sext i32 %49 to i64
  %51 = getelementptr inbounds float, ptr %48, i64 %50
  store float %47, ptr %51, align 4
  br label %52

52:                                               ; preds = %27
  %53 = load i32, ptr %14, align 4
  %54 = add nsw i32 %53, 1
  store i32 %54, ptr %14, align 4
  br label %23, !llvm.loop !31

55:                                               ; preds = %23
  br label %56

56:                                               ; preds = %55, %6
  %57 = load i32, ptr %9, align 4
  %58 = srem i32 %57, 4
  store i32 %58, ptr %13, align 4
  %59 = load i32, ptr %13, align 4
  %60 = icmp sge i32 %59, 2
  br i1 %60, label %61, label %114

61:                                               ; preds = %56
  %62 = load i32, ptr %13, align 4
  %63 = sub nsw i32 %62, 1
  store i32 %63, ptr %13, align 4
  store i32 0, ptr %14, align 4
  br label %64

64:                                               ; preds = %110, %61
  %65 = load i32, ptr %14, align 4
  %66 = load i32, ptr %7, align 4
  %67 = icmp slt i32 %65, %66
  br i1 %67, label %68, label %113

68:                                               ; preds = %64
  %69 = load ptr, ptr %8, align 8
  %70 = load i32, ptr %14, align 4
  %71 = sext i32 %70 to i64
  %72 = getelementptr inbounds float, ptr %69, i64 %71
  %73 = load float, ptr %72, align 4
  %74 = load ptr, ptr %11, align 8
  %75 = load i32, ptr %13, align 4
  %76 = sub nsw i32 %75, 1
  %77 = sext i32 %76 to i64
  %78 = getelementptr inbounds float, ptr %74, i64 %77
  %79 = load float, ptr %78, align 4
  %80 = load ptr, ptr %12, align 8
  %81 = load i32, ptr %10, align 4
  %82 = load i32, ptr %13, align 4
  %83 = sub nsw i32 %82, 1
  %84 = mul nsw i32 %81, %83
  %85 = load i32, ptr %14, align 4
  %86 = add nsw i32 %84, %85
  %87 = sext i32 %86 to i64
  %88 = getelementptr inbounds float, ptr %80, i64 %87
  %89 = load float, ptr %88, align 4
  %90 = call float @llvm.fmuladd.f32(float %79, float %89, float %73)
  %91 = load ptr, ptr %11, align 8
  %92 = load i32, ptr %13, align 4
  %93 = sext i32 %92 to i64
  %94 = getelementptr inbounds float, ptr %91, i64 %93
  %95 = load float, ptr %94, align 4
  %96 = load ptr, ptr %12, align 8
  %97 = load i32, ptr %10, align 4
  %98 = load i32, ptr %13, align 4
  %99 = mul nsw i32 %97, %98
  %100 = load i32, ptr %14, align 4
  %101 = add nsw i32 %99, %100
  %102 = sext i32 %101 to i64
  %103 = getelementptr inbounds float, ptr %96, i64 %102
  %104 = load float, ptr %103, align 4
  %105 = call float @llvm.fmuladd.f32(float %95, float %104, float %90)
  %106 = load ptr, ptr %8, align 8
  %107 = load i32, ptr %14, align 4
  %108 = sext i32 %107 to i64
  %109 = getelementptr inbounds float, ptr %106, i64 %108
  store float %105, ptr %109, align 4
  br label %110

110:                                              ; preds = %68
  %111 = load i32, ptr %14, align 4
  %112 = add nsw i32 %111, 1
  store i32 %112, ptr %14, align 4
  br label %64, !llvm.loop !32

113:                                              ; preds = %64
  br label %114

114:                                              ; preds = %113, %56
  %115 = load i32, ptr %9, align 4
  %116 = srem i32 %115, 8
  store i32 %116, ptr %13, align 4
  %117 = load i32, ptr %13, align 4
  %118 = icmp sge i32 %117, 4
  br i1 %118, label %119, label %206

119:                                              ; preds = %114
  %120 = load i32, ptr %13, align 4
  %121 = sub nsw i32 %120, 1
  store i32 %121, ptr %13, align 4
  store i32 0, ptr %14, align 4
  br label %122

122:                                              ; preds = %202, %119
  %123 = load i32, ptr %14, align 4
  %124 = load i32, ptr %7, align 4
  %125 = icmp slt i32 %123, %124
  br i1 %125, label %126, label %205

126:                                              ; preds = %122
  %127 = load ptr, ptr %8, align 8
  %128 = load i32, ptr %14, align 4
  %129 = sext i32 %128 to i64
  %130 = getelementptr inbounds float, ptr %127, i64 %129
  %131 = load float, ptr %130, align 4
  %132 = load ptr, ptr %11, align 8
  %133 = load i32, ptr %13, align 4
  %134 = sub nsw i32 %133, 3
  %135 = sext i32 %134 to i64
  %136 = getelementptr inbounds float, ptr %132, i64 %135
  %137 = load float, ptr %136, align 4
  %138 = load ptr, ptr %12, align 8
  %139 = load i32, ptr %10, align 4
  %140 = load i32, ptr %13, align 4
  %141 = sub nsw i32 %140, 3
  %142 = mul nsw i32 %139, %141
  %143 = load i32, ptr %14, align 4
  %144 = add nsw i32 %142, %143
  %145 = sext i32 %144 to i64
  %146 = getelementptr inbounds float, ptr %138, i64 %145
  %147 = load float, ptr %146, align 4
  %148 = call float @llvm.fmuladd.f32(float %137, float %147, float %131)
  %149 = load ptr, ptr %11, align 8
  %150 = load i32, ptr %13, align 4
  %151 = sub nsw i32 %150, 2
  %152 = sext i32 %151 to i64
  %153 = getelementptr inbounds float, ptr %149, i64 %152
  %154 = load float, ptr %153, align 4
  %155 = load ptr, ptr %12, align 8
  %156 = load i32, ptr %10, align 4
  %157 = load i32, ptr %13, align 4
  %158 = sub nsw i32 %157, 2
  %159 = mul nsw i32 %156, %158
  %160 = load i32, ptr %14, align 4
  %161 = add nsw i32 %159, %160
  %162 = sext i32 %161 to i64
  %163 = getelementptr inbounds float, ptr %155, i64 %162
  %164 = load float, ptr %163, align 4
  %165 = call float @llvm.fmuladd.f32(float %154, float %164, float %148)
  %166 = load ptr, ptr %11, align 8
  %167 = load i32, ptr %13, align 4
  %168 = sub nsw i32 %167, 1
  %169 = sext i32 %168 to i64
  %170 = getelementptr inbounds float, ptr %166, i64 %169
  %171 = load float, ptr %170, align 4
  %172 = load ptr, ptr %12, align 8
  %173 = load i32, ptr %10, align 4
  %174 = load i32, ptr %13, align 4
  %175 = sub nsw i32 %174, 1
  %176 = mul nsw i32 %173, %175
  %177 = load i32, ptr %14, align 4
  %178 = add nsw i32 %176, %177
  %179 = sext i32 %178 to i64
  %180 = getelementptr inbounds float, ptr %172, i64 %179
  %181 = load float, ptr %180, align 4
  %182 = call float @llvm.fmuladd.f32(float %171, float %181, float %165)
  %183 = load ptr, ptr %11, align 8
  %184 = load i32, ptr %13, align 4
  %185 = sext i32 %184 to i64
  %186 = getelementptr inbounds float, ptr %183, i64 %185
  %187 = load float, ptr %186, align 4
  %188 = load ptr, ptr %12, align 8
  %189 = load i32, ptr %10, align 4
  %190 = load i32, ptr %13, align 4
  %191 = mul nsw i32 %189, %190
  %192 = load i32, ptr %14, align 4
  %193 = add nsw i32 %191, %192
  %194 = sext i32 %193 to i64
  %195 = getelementptr inbounds float, ptr %188, i64 %194
  %196 = load float, ptr %195, align 4
  %197 = call float @llvm.fmuladd.f32(float %187, float %196, float %182)
  %198 = load ptr, ptr %8, align 8
  %199 = load i32, ptr %14, align 4
  %200 = sext i32 %199 to i64
  %201 = getelementptr inbounds float, ptr %198, i64 %200
  store float %197, ptr %201, align 4
  br label %202

202:                                              ; preds = %126
  %203 = load i32, ptr %14, align 4
  %204 = add nsw i32 %203, 1
  store i32 %204, ptr %14, align 4
  br label %122, !llvm.loop !33

205:                                              ; preds = %122
  br label %206

206:                                              ; preds = %205, %114
  %207 = load i32, ptr %9, align 4
  %208 = srem i32 %207, 16
  store i32 %208, ptr %13, align 4
  %209 = load i32, ptr %13, align 4
  %210 = icmp sge i32 %209, 8
  br i1 %210, label %211, label %366

211:                                              ; preds = %206
  %212 = load i32, ptr %13, align 4
  %213 = sub nsw i32 %212, 1
  store i32 %213, ptr %13, align 4
  store i32 0, ptr %14, align 4
  br label %214

214:                                              ; preds = %362, %211
  %215 = load i32, ptr %14, align 4
  %216 = load i32, ptr %7, align 4
  %217 = icmp slt i32 %215, %216
  br i1 %217, label %218, label %365

218:                                              ; preds = %214
  %219 = load ptr, ptr %8, align 8
  %220 = load i32, ptr %14, align 4
  %221 = sext i32 %220 to i64
  %222 = getelementptr inbounds float, ptr %219, i64 %221
  %223 = load float, ptr %222, align 4
  %224 = load ptr, ptr %11, align 8
  %225 = load i32, ptr %13, align 4
  %226 = sub nsw i32 %225, 7
  %227 = sext i32 %226 to i64
  %228 = getelementptr inbounds float, ptr %224, i64 %227
  %229 = load float, ptr %228, align 4
  %230 = load ptr, ptr %12, align 8
  %231 = load i32, ptr %10, align 4
  %232 = load i32, ptr %13, align 4
  %233 = sub nsw i32 %232, 7
  %234 = mul nsw i32 %231, %233
  %235 = load i32, ptr %14, align 4
  %236 = add nsw i32 %234, %235
  %237 = sext i32 %236 to i64
  %238 = getelementptr inbounds float, ptr %230, i64 %237
  %239 = load float, ptr %238, align 4
  %240 = call float @llvm.fmuladd.f32(float %229, float %239, float %223)
  %241 = load ptr, ptr %11, align 8
  %242 = load i32, ptr %13, align 4
  %243 = sub nsw i32 %242, 6
  %244 = sext i32 %243 to i64
  %245 = getelementptr inbounds float, ptr %241, i64 %244
  %246 = load float, ptr %245, align 4
  %247 = load ptr, ptr %12, align 8
  %248 = load i32, ptr %10, align 4
  %249 = load i32, ptr %13, align 4
  %250 = sub nsw i32 %249, 6
  %251 = mul nsw i32 %248, %250
  %252 = load i32, ptr %14, align 4
  %253 = add nsw i32 %251, %252
  %254 = sext i32 %253 to i64
  %255 = getelementptr inbounds float, ptr %247, i64 %254
  %256 = load float, ptr %255, align 4
  %257 = call float @llvm.fmuladd.f32(float %246, float %256, float %240)
  %258 = load ptr, ptr %11, align 8
  %259 = load i32, ptr %13, align 4
  %260 = sub nsw i32 %259, 5
  %261 = sext i32 %260 to i64
  %262 = getelementptr inbounds float, ptr %258, i64 %261
  %263 = load float, ptr %262, align 4
  %264 = load ptr, ptr %12, align 8
  %265 = load i32, ptr %10, align 4
  %266 = load i32, ptr %13, align 4
  %267 = sub nsw i32 %266, 5
  %268 = mul nsw i32 %265, %267
  %269 = load i32, ptr %14, align 4
  %270 = add nsw i32 %268, %269
  %271 = sext i32 %270 to i64
  %272 = getelementptr inbounds float, ptr %264, i64 %271
  %273 = load float, ptr %272, align 4
  %274 = call float @llvm.fmuladd.f32(float %263, float %273, float %257)
  %275 = load ptr, ptr %11, align 8
  %276 = load i32, ptr %13, align 4
  %277 = sub nsw i32 %276, 4
  %278 = sext i32 %277 to i64
  %279 = getelementptr inbounds float, ptr %275, i64 %278
  %280 = load float, ptr %279, align 4
  %281 = load ptr, ptr %12, align 8
  %282 = load i32, ptr %10, align 4
  %283 = load i32, ptr %13, align 4
  %284 = sub nsw i32 %283, 4
  %285 = mul nsw i32 %282, %284
  %286 = load i32, ptr %14, align 4
  %287 = add nsw i32 %285, %286
  %288 = sext i32 %287 to i64
  %289 = getelementptr inbounds float, ptr %281, i64 %288
  %290 = load float, ptr %289, align 4
  %291 = call float @llvm.fmuladd.f32(float %280, float %290, float %274)
  %292 = load ptr, ptr %11, align 8
  %293 = load i32, ptr %13, align 4
  %294 = sub nsw i32 %293, 3
  %295 = sext i32 %294 to i64
  %296 = getelementptr inbounds float, ptr %292, i64 %295
  %297 = load float, ptr %296, align 4
  %298 = load ptr, ptr %12, align 8
  %299 = load i32, ptr %10, align 4
  %300 = load i32, ptr %13, align 4
  %301 = sub nsw i32 %300, 3
  %302 = mul nsw i32 %299, %301
  %303 = load i32, ptr %14, align 4
  %304 = add nsw i32 %302, %303
  %305 = sext i32 %304 to i64
  %306 = getelementptr inbounds float, ptr %298, i64 %305
  %307 = load float, ptr %306, align 4
  %308 = call float @llvm.fmuladd.f32(float %297, float %307, float %291)
  %309 = load ptr, ptr %11, align 8
  %310 = load i32, ptr %13, align 4
  %311 = sub nsw i32 %310, 2
  %312 = sext i32 %311 to i64
  %313 = getelementptr inbounds float, ptr %309, i64 %312
  %314 = load float, ptr %313, align 4
  %315 = load ptr, ptr %12, align 8
  %316 = load i32, ptr %10, align 4
  %317 = load i32, ptr %13, align 4
  %318 = sub nsw i32 %317, 2
  %319 = mul nsw i32 %316, %318
  %320 = load i32, ptr %14, align 4
  %321 = add nsw i32 %319, %320
  %322 = sext i32 %321 to i64
  %323 = getelementptr inbounds float, ptr %315, i64 %322
  %324 = load float, ptr %323, align 4
  %325 = call float @llvm.fmuladd.f32(float %314, float %324, float %308)
  %326 = load ptr, ptr %11, align 8
  %327 = load i32, ptr %13, align 4
  %328 = sub nsw i32 %327, 1
  %329 = sext i32 %328 to i64
  %330 = getelementptr inbounds float, ptr %326, i64 %329
  %331 = load float, ptr %330, align 4
  %332 = load ptr, ptr %12, align 8
  %333 = load i32, ptr %10, align 4
  %334 = load i32, ptr %13, align 4
  %335 = sub nsw i32 %334, 1
  %336 = mul nsw i32 %333, %335
  %337 = load i32, ptr %14, align 4
  %338 = add nsw i32 %336, %337
  %339 = sext i32 %338 to i64
  %340 = getelementptr inbounds float, ptr %332, i64 %339
  %341 = load float, ptr %340, align 4
  %342 = call float @llvm.fmuladd.f32(float %331, float %341, float %325)
  %343 = load ptr, ptr %11, align 8
  %344 = load i32, ptr %13, align 4
  %345 = sext i32 %344 to i64
  %346 = getelementptr inbounds float, ptr %343, i64 %345
  %347 = load float, ptr %346, align 4
  %348 = load ptr, ptr %12, align 8
  %349 = load i32, ptr %10, align 4
  %350 = load i32, ptr %13, align 4
  %351 = mul nsw i32 %349, %350
  %352 = load i32, ptr %14, align 4
  %353 = add nsw i32 %351, %352
  %354 = sext i32 %353 to i64
  %355 = getelementptr inbounds float, ptr %348, i64 %354
  %356 = load float, ptr %355, align 4
  %357 = call float @llvm.fmuladd.f32(float %347, float %356, float %342)
  %358 = load ptr, ptr %8, align 8
  %359 = load i32, ptr %14, align 4
  %360 = sext i32 %359 to i64
  %361 = getelementptr inbounds float, ptr %358, i64 %360
  store float %357, ptr %361, align 4
  br label %362

362:                                              ; preds = %218
  %363 = load i32, ptr %14, align 4
  %364 = add nsw i32 %363, 1
  store i32 %364, ptr %14, align 4
  br label %214, !llvm.loop !34

365:                                              ; preds = %214
  br label %366

366:                                              ; preds = %365, %206
  %367 = load i32, ptr %9, align 4
  %368 = srem i32 %367, 16
  %369 = add nsw i32 %368, 16
  store i32 %369, ptr %15, align 4
  %370 = load i32, ptr %15, align 4
  %371 = sub nsw i32 %370, 1
  store i32 %371, ptr %13, align 4
  br label %372

372:                                              ; preds = %665, %366
  %373 = load i32, ptr %13, align 4
  %374 = load i32, ptr %9, align 4
  %375 = icmp slt i32 %373, %374
  br i1 %375, label %376, label %668

376:                                              ; preds = %372
  store i32 0, ptr %14, align 4
  br label %377

377:                                              ; preds = %661, %376
  %378 = load i32, ptr %14, align 4
  %379 = load i32, ptr %7, align 4
  %380 = icmp slt i32 %378, %379
  br i1 %380, label %381, label %664

381:                                              ; preds = %377
  %382 = load ptr, ptr %8, align 8
  %383 = load i32, ptr %14, align 4
  %384 = sext i32 %383 to i64
  %385 = getelementptr inbounds float, ptr %382, i64 %384
  %386 = load float, ptr %385, align 4
  %387 = load ptr, ptr %11, align 8
  %388 = load i32, ptr %13, align 4
  %389 = sub nsw i32 %388, 15
  %390 = sext i32 %389 to i64
  %391 = getelementptr inbounds float, ptr %387, i64 %390
  %392 = load float, ptr %391, align 4
  %393 = load ptr, ptr %12, align 8
  %394 = load i32, ptr %10, align 4
  %395 = load i32, ptr %13, align 4
  %396 = sub nsw i32 %395, 15
  %397 = mul nsw i32 %394, %396
  %398 = load i32, ptr %14, align 4
  %399 = add nsw i32 %397, %398
  %400 = sext i32 %399 to i64
  %401 = getelementptr inbounds float, ptr %393, i64 %400
  %402 = load float, ptr %401, align 4
  %403 = call float @llvm.fmuladd.f32(float %392, float %402, float %386)
  %404 = load ptr, ptr %11, align 8
  %405 = load i32, ptr %13, align 4
  %406 = sub nsw i32 %405, 14
  %407 = sext i32 %406 to i64
  %408 = getelementptr inbounds float, ptr %404, i64 %407
  %409 = load float, ptr %408, align 4
  %410 = load ptr, ptr %12, align 8
  %411 = load i32, ptr %10, align 4
  %412 = load i32, ptr %13, align 4
  %413 = sub nsw i32 %412, 14
  %414 = mul nsw i32 %411, %413
  %415 = load i32, ptr %14, align 4
  %416 = add nsw i32 %414, %415
  %417 = sext i32 %416 to i64
  %418 = getelementptr inbounds float, ptr %410, i64 %417
  %419 = load float, ptr %418, align 4
  %420 = call float @llvm.fmuladd.f32(float %409, float %419, float %403)
  %421 = load ptr, ptr %11, align 8
  %422 = load i32, ptr %13, align 4
  %423 = sub nsw i32 %422, 13
  %424 = sext i32 %423 to i64
  %425 = getelementptr inbounds float, ptr %421, i64 %424
  %426 = load float, ptr %425, align 4
  %427 = load ptr, ptr %12, align 8
  %428 = load i32, ptr %10, align 4
  %429 = load i32, ptr %13, align 4
  %430 = sub nsw i32 %429, 13
  %431 = mul nsw i32 %428, %430
  %432 = load i32, ptr %14, align 4
  %433 = add nsw i32 %431, %432
  %434 = sext i32 %433 to i64
  %435 = getelementptr inbounds float, ptr %427, i64 %434
  %436 = load float, ptr %435, align 4
  %437 = call float @llvm.fmuladd.f32(float %426, float %436, float %420)
  %438 = load ptr, ptr %11, align 8
  %439 = load i32, ptr %13, align 4
  %440 = sub nsw i32 %439, 12
  %441 = sext i32 %440 to i64
  %442 = getelementptr inbounds float, ptr %438, i64 %441
  %443 = load float, ptr %442, align 4
  %444 = load ptr, ptr %12, align 8
  %445 = load i32, ptr %10, align 4
  %446 = load i32, ptr %13, align 4
  %447 = sub nsw i32 %446, 12
  %448 = mul nsw i32 %445, %447
  %449 = load i32, ptr %14, align 4
  %450 = add nsw i32 %448, %449
  %451 = sext i32 %450 to i64
  %452 = getelementptr inbounds float, ptr %444, i64 %451
  %453 = load float, ptr %452, align 4
  %454 = call float @llvm.fmuladd.f32(float %443, float %453, float %437)
  %455 = load ptr, ptr %11, align 8
  %456 = load i32, ptr %13, align 4
  %457 = sub nsw i32 %456, 11
  %458 = sext i32 %457 to i64
  %459 = getelementptr inbounds float, ptr %455, i64 %458
  %460 = load float, ptr %459, align 4
  %461 = load ptr, ptr %12, align 8
  %462 = load i32, ptr %10, align 4
  %463 = load i32, ptr %13, align 4
  %464 = sub nsw i32 %463, 11
  %465 = mul nsw i32 %462, %464
  %466 = load i32, ptr %14, align 4
  %467 = add nsw i32 %465, %466
  %468 = sext i32 %467 to i64
  %469 = getelementptr inbounds float, ptr %461, i64 %468
  %470 = load float, ptr %469, align 4
  %471 = call float @llvm.fmuladd.f32(float %460, float %470, float %454)
  %472 = load ptr, ptr %11, align 8
  %473 = load i32, ptr %13, align 4
  %474 = sub nsw i32 %473, 10
  %475 = sext i32 %474 to i64
  %476 = getelementptr inbounds float, ptr %472, i64 %475
  %477 = load float, ptr %476, align 4
  %478 = load ptr, ptr %12, align 8
  %479 = load i32, ptr %10, align 4
  %480 = load i32, ptr %13, align 4
  %481 = sub nsw i32 %480, 10
  %482 = mul nsw i32 %479, %481
  %483 = load i32, ptr %14, align 4
  %484 = add nsw i32 %482, %483
  %485 = sext i32 %484 to i64
  %486 = getelementptr inbounds float, ptr %478, i64 %485
  %487 = load float, ptr %486, align 4
  %488 = call float @llvm.fmuladd.f32(float %477, float %487, float %471)
  %489 = load ptr, ptr %11, align 8
  %490 = load i32, ptr %13, align 4
  %491 = sub nsw i32 %490, 9
  %492 = sext i32 %491 to i64
  %493 = getelementptr inbounds float, ptr %489, i64 %492
  %494 = load float, ptr %493, align 4
  %495 = load ptr, ptr %12, align 8
  %496 = load i32, ptr %10, align 4
  %497 = load i32, ptr %13, align 4
  %498 = sub nsw i32 %497, 9
  %499 = mul nsw i32 %496, %498
  %500 = load i32, ptr %14, align 4
  %501 = add nsw i32 %499, %500
  %502 = sext i32 %501 to i64
  %503 = getelementptr inbounds float, ptr %495, i64 %502
  %504 = load float, ptr %503, align 4
  %505 = call float @llvm.fmuladd.f32(float %494, float %504, float %488)
  %506 = load ptr, ptr %11, align 8
  %507 = load i32, ptr %13, align 4
  %508 = sub nsw i32 %507, 8
  %509 = sext i32 %508 to i64
  %510 = getelementptr inbounds float, ptr %506, i64 %509
  %511 = load float, ptr %510, align 4
  %512 = load ptr, ptr %12, align 8
  %513 = load i32, ptr %10, align 4
  %514 = load i32, ptr %13, align 4
  %515 = sub nsw i32 %514, 8
  %516 = mul nsw i32 %513, %515
  %517 = load i32, ptr %14, align 4
  %518 = add nsw i32 %516, %517
  %519 = sext i32 %518 to i64
  %520 = getelementptr inbounds float, ptr %512, i64 %519
  %521 = load float, ptr %520, align 4
  %522 = call float @llvm.fmuladd.f32(float %511, float %521, float %505)
  %523 = load ptr, ptr %11, align 8
  %524 = load i32, ptr %13, align 4
  %525 = sub nsw i32 %524, 7
  %526 = sext i32 %525 to i64
  %527 = getelementptr inbounds float, ptr %523, i64 %526
  %528 = load float, ptr %527, align 4
  %529 = load ptr, ptr %12, align 8
  %530 = load i32, ptr %10, align 4
  %531 = load i32, ptr %13, align 4
  %532 = sub nsw i32 %531, 7
  %533 = mul nsw i32 %530, %532
  %534 = load i32, ptr %14, align 4
  %535 = add nsw i32 %533, %534
  %536 = sext i32 %535 to i64
  %537 = getelementptr inbounds float, ptr %529, i64 %536
  %538 = load float, ptr %537, align 4
  %539 = call float @llvm.fmuladd.f32(float %528, float %538, float %522)
  %540 = load ptr, ptr %11, align 8
  %541 = load i32, ptr %13, align 4
  %542 = sub nsw i32 %541, 6
  %543 = sext i32 %542 to i64
  %544 = getelementptr inbounds float, ptr %540, i64 %543
  %545 = load float, ptr %544, align 4
  %546 = load ptr, ptr %12, align 8
  %547 = load i32, ptr %10, align 4
  %548 = load i32, ptr %13, align 4
  %549 = sub nsw i32 %548, 6
  %550 = mul nsw i32 %547, %549
  %551 = load i32, ptr %14, align 4
  %552 = add nsw i32 %550, %551
  %553 = sext i32 %552 to i64
  %554 = getelementptr inbounds float, ptr %546, i64 %553
  %555 = load float, ptr %554, align 4
  %556 = call float @llvm.fmuladd.f32(float %545, float %555, float %539)
  %557 = load ptr, ptr %11, align 8
  %558 = load i32, ptr %13, align 4
  %559 = sub nsw i32 %558, 5
  %560 = sext i32 %559 to i64
  %561 = getelementptr inbounds float, ptr %557, i64 %560
  %562 = load float, ptr %561, align 4
  %563 = load ptr, ptr %12, align 8
  %564 = load i32, ptr %10, align 4
  %565 = load i32, ptr %13, align 4
  %566 = sub nsw i32 %565, 5
  %567 = mul nsw i32 %564, %566
  %568 = load i32, ptr %14, align 4
  %569 = add nsw i32 %567, %568
  %570 = sext i32 %569 to i64
  %571 = getelementptr inbounds float, ptr %563, i64 %570
  %572 = load float, ptr %571, align 4
  %573 = call float @llvm.fmuladd.f32(float %562, float %572, float %556)
  %574 = load ptr, ptr %11, align 8
  %575 = load i32, ptr %13, align 4
  %576 = sub nsw i32 %575, 4
  %577 = sext i32 %576 to i64
  %578 = getelementptr inbounds float, ptr %574, i64 %577
  %579 = load float, ptr %578, align 4
  %580 = load ptr, ptr %12, align 8
  %581 = load i32, ptr %10, align 4
  %582 = load i32, ptr %13, align 4
  %583 = sub nsw i32 %582, 4
  %584 = mul nsw i32 %581, %583
  %585 = load i32, ptr %14, align 4
  %586 = add nsw i32 %584, %585
  %587 = sext i32 %586 to i64
  %588 = getelementptr inbounds float, ptr %580, i64 %587
  %589 = load float, ptr %588, align 4
  %590 = call float @llvm.fmuladd.f32(float %579, float %589, float %573)
  %591 = load ptr, ptr %11, align 8
  %592 = load i32, ptr %13, align 4
  %593 = sub nsw i32 %592, 3
  %594 = sext i32 %593 to i64
  %595 = getelementptr inbounds float, ptr %591, i64 %594
  %596 = load float, ptr %595, align 4
  %597 = load ptr, ptr %12, align 8
  %598 = load i32, ptr %10, align 4
  %599 = load i32, ptr %13, align 4
  %600 = sub nsw i32 %599, 3
  %601 = mul nsw i32 %598, %600
  %602 = load i32, ptr %14, align 4
  %603 = add nsw i32 %601, %602
  %604 = sext i32 %603 to i64
  %605 = getelementptr inbounds float, ptr %597, i64 %604
  %606 = load float, ptr %605, align 4
  %607 = call float @llvm.fmuladd.f32(float %596, float %606, float %590)
  %608 = load ptr, ptr %11, align 8
  %609 = load i32, ptr %13, align 4
  %610 = sub nsw i32 %609, 2
  %611 = sext i32 %610 to i64
  %612 = getelementptr inbounds float, ptr %608, i64 %611
  %613 = load float, ptr %612, align 4
  %614 = load ptr, ptr %12, align 8
  %615 = load i32, ptr %10, align 4
  %616 = load i32, ptr %13, align 4
  %617 = sub nsw i32 %616, 2
  %618 = mul nsw i32 %615, %617
  %619 = load i32, ptr %14, align 4
  %620 = add nsw i32 %618, %619
  %621 = sext i32 %620 to i64
  %622 = getelementptr inbounds float, ptr %614, i64 %621
  %623 = load float, ptr %622, align 4
  %624 = call float @llvm.fmuladd.f32(float %613, float %623, float %607)
  %625 = load ptr, ptr %11, align 8
  %626 = load i32, ptr %13, align 4
  %627 = sub nsw i32 %626, 1
  %628 = sext i32 %627 to i64
  %629 = getelementptr inbounds float, ptr %625, i64 %628
  %630 = load float, ptr %629, align 4
  %631 = load ptr, ptr %12, align 8
  %632 = load i32, ptr %10, align 4
  %633 = load i32, ptr %13, align 4
  %634 = sub nsw i32 %633, 1
  %635 = mul nsw i32 %632, %634
  %636 = load i32, ptr %14, align 4
  %637 = add nsw i32 %635, %636
  %638 = sext i32 %637 to i64
  %639 = getelementptr inbounds float, ptr %631, i64 %638
  %640 = load float, ptr %639, align 4
  %641 = call float @llvm.fmuladd.f32(float %630, float %640, float %624)
  %642 = load ptr, ptr %11, align 8
  %643 = load i32, ptr %13, align 4
  %644 = sext i32 %643 to i64
  %645 = getelementptr inbounds float, ptr %642, i64 %644
  %646 = load float, ptr %645, align 4
  %647 = load ptr, ptr %12, align 8
  %648 = load i32, ptr %10, align 4
  %649 = load i32, ptr %13, align 4
  %650 = mul nsw i32 %648, %649
  %651 = load i32, ptr %14, align 4
  %652 = add nsw i32 %650, %651
  %653 = sext i32 %652 to i64
  %654 = getelementptr inbounds float, ptr %647, i64 %653
  %655 = load float, ptr %654, align 4
  %656 = call float @llvm.fmuladd.f32(float %646, float %655, float %641)
  %657 = load ptr, ptr %8, align 8
  %658 = load i32, ptr %14, align 4
  %659 = sext i32 %658 to i64
  %660 = getelementptr inbounds float, ptr %657, i64 %659
  store float %656, ptr %660, align 4
  br label %661

661:                                              ; preds = %381
  %662 = load i32, ptr %14, align 4
  %663 = add nsw i32 %662, 1
  store i32 %663, ptr %14, align 4
  br label %377, !llvm.loop !35

664:                                              ; preds = %377
  br label %665

665:                                              ; preds = %664
  %666 = load i32, ptr %13, align 4
  %667 = add nsw i32 %666, 16
  store i32 %667, ptr %13, align 4
  br label %372, !llvm.loop !36

668:                                              ; preds = %372
  ret void
}

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fabs.f64(double) #3

; Function Attrs: noinline nounwind uwtable
define dso_local float @epslon(float noundef %0) #0 {
  %2 = alloca float, align 4
  %3 = alloca float, align 4
  %4 = alloca float, align 4
  %5 = alloca float, align 4
  %6 = alloca float, align 4
  store float %0, ptr %2, align 4
  store float f0x3FAAAAAB, ptr %3, align 4
  store float 0.000000e+00, ptr %6, align 4
  br label %7

7:                                                ; preds = %11, %1
  %8 = load float, ptr %6, align 4
  %9 = fpext float %8 to double
  %10 = fcmp oeq double %9, 0.000000e+00
  br i1 %10, label %11, label %26

11:                                               ; preds = %7
  %12 = load float, ptr %3, align 4
  %13 = fpext float %12 to double
  %14 = fsub double %13, 1.000000e+00
  %15 = fptrunc double %14 to float
  store float %15, ptr %4, align 4
  %16 = load float, ptr %4, align 4
  %17 = load float, ptr %4, align 4
  %18 = fadd float %16, %17
  %19 = load float, ptr %4, align 4
  %20 = fadd float %18, %19
  store float %20, ptr %5, align 4
  %21 = load float, ptr %5, align 4
  %22 = fpext float %21 to double
  %23 = fsub double %22, 1.000000e+00
  %24 = call double @llvm.fabs.f64(double %23)
  %25 = fptrunc double %24 to float
  store float %25, ptr %6, align 4
  br label %7, !llvm.loop !37

26:                                               ; preds = %7
  %27 = load float, ptr %6, align 4
  %28 = fpext float %27 to double
  %29 = load float, ptr %2, align 4
  %30 = fpext float %29 to double
  %31 = call double @llvm.fabs.f64(double %30)
  %32 = fmul double %28, %31
  %33 = fptrunc double %32 to float
  ret float %33
}

; Function Attrs: noinline nounwind uwtable
define dso_local void @print_time(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @idamax(i32 noundef %0, ptr noundef %1, i32 noundef %2) #0 {
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca ptr, align 8
  %7 = alloca i32, align 4
  %8 = alloca float, align 4
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  %11 = alloca i32, align 4
  store i32 %0, ptr %5, align 4
  store ptr %1, ptr %6, align 8
  store i32 %2, ptr %7, align 4
  %12 = load i32, ptr %5, align 4
  %13 = icmp slt i32 %12, 1
  br i1 %13, label %14, label %15

14:                                               ; preds = %3
  store i32 -1, ptr %4, align 4
  br label %104

15:                                               ; preds = %3
  %16 = load i32, ptr %5, align 4
  %17 = icmp eq i32 %16, 1
  br i1 %17, label %18, label %19

18:                                               ; preds = %15
  store i32 0, ptr %4, align 4
  br label %104

19:                                               ; preds = %15
  %20 = load i32, ptr %7, align 4
  %21 = icmp ne i32 %20, 1
  br i1 %21, label %22, label %65

22:                                               ; preds = %19
  store i32 1, ptr %10, align 4
  %23 = load ptr, ptr %6, align 8
  %24 = getelementptr inbounds float, ptr %23, i64 0
  %25 = load float, ptr %24, align 4
  %26 = fpext float %25 to double
  %27 = call double @llvm.fabs.f64(double %26)
  %28 = fptrunc double %27 to float
  store float %28, ptr %8, align 4
  %29 = load i32, ptr %10, align 4
  %30 = load i32, ptr %7, align 4
  %31 = add nsw i32 %29, %30
  store i32 %31, ptr %10, align 4
  store i32 1, ptr %9, align 4
  br label %32

32:                                               ; preds = %61, %22
  %33 = load i32, ptr %9, align 4
  %34 = load i32, ptr %5, align 4
  %35 = icmp slt i32 %33, %34
  br i1 %35, label %36, label %64

36:                                               ; preds = %32
  %37 = load ptr, ptr %6, align 8
  %38 = load i32, ptr %10, align 4
  %39 = sext i32 %38 to i64
  %40 = getelementptr inbounds float, ptr %37, i64 %39
  %41 = load float, ptr %40, align 4
  %42 = fpext float %41 to double
  %43 = call double @llvm.fabs.f64(double %42)
  %44 = load float, ptr %8, align 4
  %45 = fpext float %44 to double
  %46 = fcmp ogt double %43, %45
  br i1 %46, label %47, label %57

47:                                               ; preds = %36
  %48 = load i32, ptr %9, align 4
  store i32 %48, ptr %11, align 4
  %49 = load ptr, ptr %6, align 8
  %50 = load i32, ptr %10, align 4
  %51 = sext i32 %50 to i64
  %52 = getelementptr inbounds float, ptr %49, i64 %51
  %53 = load float, ptr %52, align 4
  %54 = fpext float %53 to double
  %55 = call double @llvm.fabs.f64(double %54)
  %56 = fptrunc double %55 to float
  store float %56, ptr %8, align 4
  br label %57

57:                                               ; preds = %47, %36
  %58 = load i32, ptr %10, align 4
  %59 = load i32, ptr %7, align 4
  %60 = add nsw i32 %58, %59
  store i32 %60, ptr %10, align 4
  br label %61

61:                                               ; preds = %57
  %62 = load i32, ptr %9, align 4
  %63 = add nsw i32 %62, 1
  store i32 %63, ptr %9, align 4
  br label %32, !llvm.loop !38

64:                                               ; preds = %32
  br label %102

65:                                               ; preds = %19
  store i32 0, ptr %11, align 4
  %66 = load ptr, ptr %6, align 8
  %67 = getelementptr inbounds float, ptr %66, i64 0
  %68 = load float, ptr %67, align 4
  %69 = fpext float %68 to double
  %70 = call double @llvm.fabs.f64(double %69)
  %71 = fptrunc double %70 to float
  store float %71, ptr %8, align 4
  store i32 1, ptr %9, align 4
  br label %72

72:                                               ; preds = %98, %65
  %73 = load i32, ptr %9, align 4
  %74 = load i32, ptr %5, align 4
  %75 = icmp slt i32 %73, %74
  br i1 %75, label %76, label %101

76:                                               ; preds = %72
  %77 = load ptr, ptr %6, align 8
  %78 = load i32, ptr %9, align 4
  %79 = sext i32 %78 to i64
  %80 = getelementptr inbounds float, ptr %77, i64 %79
  %81 = load float, ptr %80, align 4
  %82 = fpext float %81 to double
  %83 = call double @llvm.fabs.f64(double %82)
  %84 = load float, ptr %8, align 4
  %85 = fpext float %84 to double
  %86 = fcmp ogt double %83, %85
  br i1 %86, label %87, label %97

87:                                               ; preds = %76
  %88 = load i32, ptr %9, align 4
  store i32 %88, ptr %11, align 4
  %89 = load ptr, ptr %6, align 8
  %90 = load i32, ptr %9, align 4
  %91 = sext i32 %90 to i64
  %92 = getelementptr inbounds float, ptr %89, i64 %91
  %93 = load float, ptr %92, align 4
  %94 = fpext float %93 to double
  %95 = call double @llvm.fabs.f64(double %94)
  %96 = fptrunc double %95 to float
  store float %96, ptr %8, align 4
  br label %97

97:                                               ; preds = %87, %76
  br label %98

98:                                               ; preds = %97
  %99 = load i32, ptr %9, align 4
  %100 = add nsw i32 %99, 1
  store i32 %100, ptr %9, align 4
  br label %72, !llvm.loop !39

101:                                              ; preds = %72
  br label %102

102:                                              ; preds = %101, %64
  %103 = load i32, ptr %11, align 4
  store i32 %103, ptr %4, align 4
  br label %104

104:                                              ; preds = %102, %18, %14
  %105 = load i32, ptr %4, align 4
  ret i32 %105
}

; Function Attrs: noinline nounwind uwtable
define dso_local void @dscal(i32 noundef %0, float noundef %1, ptr noundef %2, i32 noundef %3) #0 {
  %5 = alloca i32, align 4
  %6 = alloca float, align 4
  %7 = alloca ptr, align 8
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  %11 = alloca i32, align 4
  %12 = alloca i32, align 4
  store i32 %0, ptr %5, align 4
  store float %1, ptr %6, align 4
  store ptr %2, ptr %7, align 8
  store i32 %3, ptr %8, align 4
  store i32 0, ptr %11, align 4
  store i32 0, ptr %10, align 4
  %13 = load i32, ptr %5, align 4
  %14 = icmp sle i32 %13, 0
  br i1 %14, label %15, label %16

15:                                               ; preds = %4
  br label %64

16:                                               ; preds = %4
  %17 = load i32, ptr %8, align 4
  %18 = icmp ne i32 %17, 1
  br i1 %18, label %19, label %44

19:                                               ; preds = %16
  %20 = load i32, ptr %5, align 4
  %21 = load i32, ptr %8, align 4
  %22 = mul nsw i32 %20, %21
  store i32 %22, ptr %12, align 4
  store i32 0, ptr %9, align 4
  br label %23

23:                                               ; preds = %39, %19
  %24 = load i32, ptr %9, align 4
  %25 = load i32, ptr %12, align 4
  %26 = icmp slt i32 %24, %25
  br i1 %26, label %27, label %43

27:                                               ; preds = %23
  %28 = load float, ptr %6, align 4
  %29 = load ptr, ptr %7, align 8
  %30 = load i32, ptr %9, align 4
  %31 = sext i32 %30 to i64
  %32 = getelementptr inbounds float, ptr %29, i64 %31
  %33 = load float, ptr %32, align 4
  %34 = fmul float %28, %33
  %35 = load ptr, ptr %7, align 8
  %36 = load i32, ptr %9, align 4
  %37 = sext i32 %36 to i64
  %38 = getelementptr inbounds float, ptr %35, i64 %37
  store float %34, ptr %38, align 4
  br label %39

39:                                               ; preds = %27
  %40 = load i32, ptr %9, align 4
  %41 = load i32, ptr %8, align 4
  %42 = add nsw i32 %40, %41
  store i32 %42, ptr %9, align 4
  br label %23, !llvm.loop !40

43:                                               ; preds = %23
  br label %64

44:                                               ; preds = %16
  store i32 0, ptr %9, align 4
  br label %45

45:                                               ; preds = %61, %44
  %46 = load i32, ptr %9, align 4
  %47 = load i32, ptr %5, align 4
  %48 = icmp slt i32 %46, %47
  br i1 %48, label %49, label %64

49:                                               ; preds = %45
  %50 = load float, ptr %6, align 4
  %51 = load ptr, ptr %7, align 8
  %52 = load i32, ptr %9, align 4
  %53 = sext i32 %52 to i64
  %54 = getelementptr inbounds float, ptr %51, i64 %53
  %55 = load float, ptr %54, align 4
  %56 = fmul float %50, %55
  %57 = load ptr, ptr %7, align 8
  %58 = load i32, ptr %9, align 4
  %59 = sext i32 %58 to i64
  %60 = getelementptr inbounds float, ptr %57, i64 %59
  store float %56, ptr %60, align 4
  br label %61

61:                                               ; preds = %49
  %62 = load i32, ptr %9, align 4
  %63 = add nsw i32 %62, 1
  store i32 %63, ptr %9, align 4
  br label %45, !llvm.loop !41

64:                                               ; preds = %15, %43, %45
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local void @daxpy(i32 noundef %0, float noundef %1, ptr noundef %2, i32 noundef %3, ptr noundef %4, i32 noundef %5) #0 {
  %7 = alloca i32, align 4
  %8 = alloca float, align 4
  %9 = alloca ptr, align 8
  %10 = alloca i32, align 4
  %11 = alloca ptr, align 8
  %12 = alloca i32, align 4
  %13 = alloca i32, align 4
  %14 = alloca i32, align 4
  %15 = alloca i32, align 4
  %16 = alloca i32, align 4
  %17 = alloca i32, align 4
  store i32 %0, ptr %7, align 4
  store float %1, ptr %8, align 4
  store ptr %2, ptr %9, align 8
  store i32 %3, ptr %10, align 4
  store ptr %4, ptr %11, align 8
  store i32 %5, ptr %12, align 4
  store i32 0, ptr %17, align 4
  store i32 0, ptr %16, align 4
  %18 = load i32, ptr %7, align 4
  %19 = icmp sle i32 %18, 0
  br i1 %19, label %20, label %21

20:                                               ; preds = %6
  br label %108

21:                                               ; preds = %6
  %22 = load float, ptr %8, align 4
  %23 = fpext float %22 to double
  %24 = fcmp oeq double %23, 0.000000e+00
  br i1 %24, label %25, label %26

25:                                               ; preds = %21
  br label %108

26:                                               ; preds = %21
  %27 = load i32, ptr %10, align 4
  %28 = icmp ne i32 %27, 1
  br i1 %28, label %32, label %29

29:                                               ; preds = %26
  %30 = load i32, ptr %12, align 4
  %31 = icmp ne i32 %30, 1
  br i1 %31, label %32, label %82

32:                                               ; preds = %29, %26
  store i32 0, ptr %14, align 4
  store i32 0, ptr %15, align 4
  %33 = load i32, ptr %10, align 4
  %34 = icmp slt i32 %33, 0
  br i1 %34, label %35, label %41

35:                                               ; preds = %32
  %36 = load i32, ptr %7, align 4
  %37 = sub nsw i32 0, %36
  %38 = add nsw i32 %37, 1
  %39 = load i32, ptr %10, align 4
  %40 = mul nsw i32 %38, %39
  store i32 %40, ptr %14, align 4
  br label %41

41:                                               ; preds = %35, %32
  %42 = load i32, ptr %12, align 4
  %43 = icmp slt i32 %42, 0
  br i1 %43, label %44, label %50

44:                                               ; preds = %41
  %45 = load i32, ptr %7, align 4
  %46 = sub nsw i32 0, %45
  %47 = add nsw i32 %46, 1
  %48 = load i32, ptr %12, align 4
  %49 = mul nsw i32 %47, %48
  store i32 %49, ptr %15, align 4
  br label %50

50:                                               ; preds = %44, %41
  store i32 0, ptr %13, align 4
  br label %51

51:                                               ; preds = %78, %50
  %52 = load i32, ptr %13, align 4
  %53 = load i32, ptr %7, align 4
  %54 = icmp slt i32 %52, %53
  br i1 %54, label %55, label %81

55:                                               ; preds = %51
  %56 = load ptr, ptr %11, align 8
  %57 = load i32, ptr %15, align 4
  %58 = sext i32 %57 to i64
  %59 = getelementptr inbounds float, ptr %56, i64 %58
  %60 = load float, ptr %59, align 4
  %61 = load float, ptr %8, align 4
  %62 = load ptr, ptr %9, align 8
  %63 = load i32, ptr %14, align 4
  %64 = sext i32 %63 to i64
  %65 = getelementptr inbounds float, ptr %62, i64 %64
  %66 = load float, ptr %65, align 4
  %67 = call float @llvm.fmuladd.f32(float %61, float %66, float %60)
  %68 = load ptr, ptr %11, align 8
  %69 = load i32, ptr %15, align 4
  %70 = sext i32 %69 to i64
  %71 = getelementptr inbounds float, ptr %68, i64 %70
  store float %67, ptr %71, align 4
  %72 = load i32, ptr %14, align 4
  %73 = load i32, ptr %10, align 4
  %74 = add nsw i32 %72, %73
  store i32 %74, ptr %14, align 4
  %75 = load i32, ptr %15, align 4
  %76 = load i32, ptr %12, align 4
  %77 = add nsw i32 %75, %76
  store i32 %77, ptr %15, align 4
  br label %78

78:                                               ; preds = %55
  %79 = load i32, ptr %13, align 4
  %80 = add nsw i32 %79, 1
  store i32 %80, ptr %13, align 4
  br label %51, !llvm.loop !42

81:                                               ; preds = %51
  br label %108

82:                                               ; preds = %29
  store i32 0, ptr %13, align 4
  br label %83

83:                                               ; preds = %104, %82
  %84 = load i32, ptr %13, align 4
  %85 = load i32, ptr %7, align 4
  %86 = icmp slt i32 %84, %85
  br i1 %86, label %87, label %107

87:                                               ; preds = %83
  %88 = load ptr, ptr %11, align 8
  %89 = load i32, ptr %13, align 4
  %90 = sext i32 %89 to i64
  %91 = getelementptr inbounds float, ptr %88, i64 %90
  %92 = load float, ptr %91, align 4
  %93 = load float, ptr %8, align 4
  %94 = load ptr, ptr %9, align 8
  %95 = load i32, ptr %13, align 4
  %96 = sext i32 %95 to i64
  %97 = getelementptr inbounds float, ptr %94, i64 %96
  %98 = load float, ptr %97, align 4
  %99 = call float @llvm.fmuladd.f32(float %93, float %98, float %92)
  %100 = load ptr, ptr %11, align 8
  %101 = load i32, ptr %13, align 4
  %102 = sext i32 %101 to i64
  %103 = getelementptr inbounds float, ptr %100, i64 %102
  store float %99, ptr %103, align 4
  br label %104

104:                                              ; preds = %87
  %105 = load i32, ptr %13, align 4
  %106 = add nsw i32 %105, 1
  store i32 %106, ptr %13, align 4
  br label %83, !llvm.loop !43

107:                                              ; preds = %83
  br label %108

108:                                              ; preds = %107, %81, %25, %20
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local float @ddot(i32 noundef %0, ptr noundef %1, i32 noundef %2, ptr noundef %3, i32 noundef %4) #0 {
  %6 = alloca float, align 4
  %7 = alloca i32, align 4
  %8 = alloca ptr, align 8
  %9 = alloca i32, align 4
  %10 = alloca ptr, align 8
  %11 = alloca i32, align 4
  %12 = alloca float, align 4
  %13 = alloca i32, align 4
  %14 = alloca i32, align 4
  %15 = alloca i32, align 4
  %16 = alloca i32, align 4
  %17 = alloca i32, align 4
  store i32 %0, ptr %7, align 4
  store ptr %1, ptr %8, align 8
  store i32 %2, ptr %9, align 4
  store ptr %3, ptr %10, align 8
  store i32 %4, ptr %11, align 4
  store i32 0, ptr %17, align 4
  store i32 0, ptr %16, align 4
  store float 0.000000e+00, ptr %12, align 4
  %18 = load i32, ptr %7, align 4
  %19 = icmp sle i32 %18, 0
  br i1 %19, label %20, label %21

20:                                               ; preds = %5
  store float 0.000000e+00, ptr %6, align 4
  br label %97

21:                                               ; preds = %5
  %22 = load i32, ptr %9, align 4
  %23 = icmp ne i32 %22, 1
  br i1 %23, label %27, label %24

24:                                               ; preds = %21
  %25 = load i32, ptr %11, align 4
  %26 = icmp ne i32 %25, 1
  br i1 %26, label %27, label %74

27:                                               ; preds = %24, %21
  store i32 0, ptr %14, align 4
  store i32 0, ptr %15, align 4
  %28 = load i32, ptr %9, align 4
  %29 = icmp slt i32 %28, 0
  br i1 %29, label %30, label %36

30:                                               ; preds = %27
  %31 = load i32, ptr %7, align 4
  %32 = sub nsw i32 0, %31
  %33 = add nsw i32 %32, 1
  %34 = load i32, ptr %9, align 4
  %35 = mul nsw i32 %33, %34
  store i32 %35, ptr %14, align 4
  br label %36

36:                                               ; preds = %30, %27
  %37 = load i32, ptr %11, align 4
  %38 = icmp slt i32 %37, 0
  br i1 %38, label %39, label %45

39:                                               ; preds = %36
  %40 = load i32, ptr %7, align 4
  %41 = sub nsw i32 0, %40
  %42 = add nsw i32 %41, 1
  %43 = load i32, ptr %11, align 4
  %44 = mul nsw i32 %42, %43
  store i32 %44, ptr %15, align 4
  br label %45

45:                                               ; preds = %39, %36
  store i32 0, ptr %13, align 4
  br label %46

46:                                               ; preds = %69, %45
  %47 = load i32, ptr %13, align 4
  %48 = load i32, ptr %7, align 4
  %49 = icmp slt i32 %47, %48
  br i1 %49, label %50, label %72

50:                                               ; preds = %46
  %51 = load float, ptr %12, align 4
  %52 = load ptr, ptr %8, align 8
  %53 = load i32, ptr %14, align 4
  %54 = sext i32 %53 to i64
  %55 = getelementptr inbounds float, ptr %52, i64 %54
  %56 = load float, ptr %55, align 4
  %57 = load ptr, ptr %10, align 8
  %58 = load i32, ptr %15, align 4
  %59 = sext i32 %58 to i64
  %60 = getelementptr inbounds float, ptr %57, i64 %59
  %61 = load float, ptr %60, align 4
  %62 = call float @llvm.fmuladd.f32(float %56, float %61, float %51)
  store float %62, ptr %12, align 4
  %63 = load i32, ptr %14, align 4
  %64 = load i32, ptr %9, align 4
  %65 = add nsw i32 %63, %64
  store i32 %65, ptr %14, align 4
  %66 = load i32, ptr %15, align 4
  %67 = load i32, ptr %11, align 4
  %68 = add nsw i32 %66, %67
  store i32 %68, ptr %15, align 4
  br label %69

69:                                               ; preds = %50
  %70 = load i32, ptr %13, align 4
  %71 = add nsw i32 %70, 1
  store i32 %71, ptr %13, align 4
  br label %46, !llvm.loop !44

72:                                               ; preds = %46
  %73 = load float, ptr %12, align 4
  store float %73, ptr %6, align 4
  br label %97

74:                                               ; preds = %24
  store i32 0, ptr %13, align 4
  br label %75

75:                                               ; preds = %92, %74
  %76 = load i32, ptr %13, align 4
  %77 = load i32, ptr %7, align 4
  %78 = icmp slt i32 %76, %77
  br i1 %78, label %79, label %95

79:                                               ; preds = %75
  %80 = load float, ptr %12, align 4
  %81 = load ptr, ptr %8, align 8
  %82 = load i32, ptr %13, align 4
  %83 = sext i32 %82 to i64
  %84 = getelementptr inbounds float, ptr %81, i64 %83
  %85 = load float, ptr %84, align 4
  %86 = load ptr, ptr %10, align 8
  %87 = load i32, ptr %13, align 4
  %88 = sext i32 %87 to i64
  %89 = getelementptr inbounds float, ptr %86, i64 %88
  %90 = load float, ptr %89, align 4
  %91 = call float @llvm.fmuladd.f32(float %85, float %90, float %80)
  store float %91, ptr %12, align 4
  br label %92

92:                                               ; preds = %79
  %93 = load i32, ptr %13, align 4
  %94 = add nsw i32 %93, 1
  store i32 %94, ptr %13, align 4
  br label %75, !llvm.loop !45

95:                                               ; preds = %75
  %96 = load float, ptr %12, align 4
  store float %96, ptr %6, align 4
  br label %97

97:                                               ; preds = %95, %72, %20
  %98 = load float, ptr %6, align 4
  ret float %98
}

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare float @llvm.fmuladd.f32(float, float, float) #3

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nounwind "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #3 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #4 = { nounwind }

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
!13 = distinct !{!13, !6}
!14 = distinct !{!14, !6}
!15 = distinct !{!15, !6}
!16 = distinct !{!16, !6}
!17 = distinct !{!17, !6}
!18 = distinct !{!18, !6}
!19 = distinct !{!19, !6}
!20 = distinct !{!20, !6}
!21 = distinct !{!21, !6}
!22 = distinct !{!22, !6}
!23 = distinct !{!23, !6}
!24 = distinct !{!24, !6}
!25 = distinct !{!25, !6}
!26 = distinct !{!26, !6}
!27 = distinct !{!27, !6}
!28 = distinct !{!28, !6}
!29 = distinct !{!29, !6}
!30 = distinct !{!30, !6}
!31 = distinct !{!31, !6}
!32 = distinct !{!32, !6}
!33 = distinct !{!33, !6}
!34 = distinct !{!34, !6}
!35 = distinct !{!35, !6}
!36 = distinct !{!36, !6}
!37 = distinct !{!37, !6}
!38 = distinct !{!38, !6}
!39 = distinct !{!39, !6}
!40 = distinct !{!40, !6}
!41 = distinct !{!41, !6}
!42 = distinct !{!42, !6}
!43 = distinct !{!43, !6}
!44 = distinct !{!44, !6}
!45 = distinct !{!45, !6}
