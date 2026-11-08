; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/whetstone.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/whetstone.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/whetstone.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [3 x i8] c"-c\00", align 1
@stderr = external global ptr, align 8
@.str.1 = private unnamed_addr constant [28 x i8] c"usage: whetdc [-c] [loops]\0A\00", align 1
@T = dso_local global double 0.000000e+00, align 8
@T1 = dso_local global double 0.000000e+00, align 8
@T2 = dso_local global double 0.000000e+00, align 8
@E1 = dso_local global [5 x double] zeroinitializer, align 16
@J = dso_local global i32 0, align 4
@K = dso_local global i32 0, align 4
@L = dso_local global i32 0, align 4
@.str.2 = private unnamed_addr constant [2 x i8] c"\0A\00", align 1
@.str.3 = private unnamed_addr constant [44 x i8] c"%7ld %7ld %7ld %12.4e %12.4e %12.4e %12.4e\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i64, align 8
  %7 = alloca i64, align 8
  %8 = alloca i64, align 8
  %9 = alloca i64, align 8
  %10 = alloca i64, align 8
  %11 = alloca i64, align 8
  %12 = alloca i64, align 8
  %13 = alloca i64, align 8
  %14 = alloca i64, align 8
  %15 = alloca i64, align 8
  %16 = alloca i64, align 8
  %17 = alloca double, align 8
  %18 = alloca double, align 8
  %19 = alloca double, align 8
  %20 = alloca double, align 8
  %21 = alloca double, align 8
  %22 = alloca double, align 8
  %23 = alloca double, align 8
  %24 = alloca i64, align 8
  %25 = alloca i32, align 4
  %26 = alloca i32, align 4
  %27 = alloca i64, align 8
  %28 = alloca i64, align 8
  %29 = alloca i64, align 8
  %30 = alloca float, align 4
  %31 = alloca i32, align 4
  %32 = alloca i32, align 4
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %6) #6
  call void @llvm.lifetime.start.p0(ptr %7) #6
  call void @llvm.lifetime.start.p0(ptr %8) #6
  call void @llvm.lifetime.start.p0(ptr %9) #6
  call void @llvm.lifetime.start.p0(ptr %10) #6
  call void @llvm.lifetime.start.p0(ptr %11) #6
  call void @llvm.lifetime.start.p0(ptr %12) #6
  call void @llvm.lifetime.start.p0(ptr %13) #6
  call void @llvm.lifetime.start.p0(ptr %14) #6
  call void @llvm.lifetime.start.p0(ptr %15) #6
  call void @llvm.lifetime.start.p0(ptr %16) #6
  call void @llvm.lifetime.start.p0(ptr %17) #6
  call void @llvm.lifetime.start.p0(ptr %18) #6
  call void @llvm.lifetime.start.p0(ptr %19) #6
  call void @llvm.lifetime.start.p0(ptr %20) #6
  call void @llvm.lifetime.start.p0(ptr %21) #6
  call void @llvm.lifetime.start.p0(ptr %22) #6
  call void @llvm.lifetime.start.p0(ptr %23) #6
  call void @llvm.lifetime.start.p0(ptr %24) #6
  call void @llvm.lifetime.start.p0(ptr %25) #6
  call void @llvm.lifetime.start.p0(ptr %26) #6
  call void @llvm.lifetime.start.p0(ptr %27) #6
  call void @llvm.lifetime.start.p0(ptr %28) #6
  call void @llvm.lifetime.start.p0(ptr %29) #6
  call void @llvm.lifetime.start.p0(ptr %30) #6
  call void @llvm.lifetime.start.p0(ptr %31) #6
  store i64 100000, ptr %27, align 8, !tbaa !14
  store i32 0, ptr %31, align 4, !tbaa !9
  store i32 1, ptr %25, align 4, !tbaa !9
  br label %33

33:                                               ; preds = %75, %2
  %34 = load i32, ptr %25, align 4, !tbaa !9
  %35 = load i32, ptr %4, align 4, !tbaa !9
  %36 = icmp slt i32 %34, %35
  br i1 %36, label %37, label %78

37:                                               ; preds = %33
  %38 = load ptr, ptr %5, align 8, !tbaa !10
  %39 = load i32, ptr %25, align 4, !tbaa !9
  %40 = sext i32 %39 to i64
  %41 = getelementptr inbounds ptr, ptr %38, i64 %40
  %42 = load ptr, ptr %41, align 8, !tbaa !16
  %43 = call i32 @strncmp(ptr noundef %42, ptr noundef @.str, i64 noundef 2) #7
  %44 = icmp eq i32 %43, 0
  br i1 %44, label %55, label %45

45:                                               ; preds = %37
  %46 = load ptr, ptr %5, align 8, !tbaa !10
  %47 = load i32, ptr %25, align 4, !tbaa !9
  %48 = sext i32 %47 to i64
  %49 = getelementptr inbounds ptr, ptr %46, i64 %48
  %50 = load ptr, ptr %49, align 8, !tbaa !16
  %51 = getelementptr inbounds i8, ptr %50, i64 0
  %52 = load i8, ptr %51, align 1, !tbaa !18
  %53 = sext i8 %52 to i32
  %54 = icmp eq i32 %53, 99
  br i1 %54, label %55, label %56

55:                                               ; preds = %45, %37
  store i32 1, ptr %31, align 4, !tbaa !9
  br label %75

56:                                               ; preds = %45
  %57 = load ptr, ptr %5, align 8, !tbaa !10
  %58 = load i32, ptr %25, align 4, !tbaa !9
  %59 = sext i32 %58 to i64
  %60 = getelementptr inbounds ptr, ptr %57, i64 %59
  %61 = load ptr, ptr %60, align 8, !tbaa !16
  %62 = call i64 @atol(ptr noundef %61) #7
  %63 = icmp sgt i64 %62, 0
  br i1 %63, label %64, label %71

64:                                               ; preds = %56
  %65 = load ptr, ptr %5, align 8, !tbaa !10
  %66 = load i32, ptr %25, align 4, !tbaa !9
  %67 = sext i32 %66 to i64
  %68 = getelementptr inbounds ptr, ptr %65, i64 %67
  %69 = load ptr, ptr %68, align 8, !tbaa !16
  %70 = call i64 @atol(ptr noundef %69) #7
  store i64 %70, ptr %27, align 8, !tbaa !14
  br label %74

71:                                               ; preds = %56
  %72 = load ptr, ptr @stderr, align 8, !tbaa !19
  %73 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %72, ptr noundef @.str.1) #6
  store i32 1, ptr %3, align 4
  store i32 1, ptr %32, align 4
  br label %533

74:                                               ; preds = %64
  br label %75

75:                                               ; preds = %74, %55
  %76 = load i32, ptr %25, align 4, !tbaa !9
  %77 = add nsw i32 %76, 1
  store i32 %77, ptr %25, align 4, !tbaa !9
  br label %33, !llvm.loop !21

78:                                               ; preds = %33
  br label %79

79:                                               ; preds = %531, %78
  %80 = call i64 @time(ptr noundef null) #6
  store i64 %80, ptr %28, align 8, !tbaa !14
  store double 4.999750e-01, ptr @T, align 8, !tbaa !23
  store double 5.002500e-01, ptr @T1, align 8, !tbaa !23
  store double 2.000000e+00, ptr @T2, align 8, !tbaa !23
  %81 = load i64, ptr %27, align 8, !tbaa !14
  store i64 %81, ptr %24, align 8, !tbaa !14
  store i32 1, ptr %25, align 4, !tbaa !9
  store i32 1, ptr %26, align 4, !tbaa !9
  br label %82

82:                                               ; preds = %525, %79
  store i64 0, ptr %7, align 8, !tbaa !14
  %83 = load i64, ptr %24, align 8, !tbaa !14
  %84 = mul nsw i64 12, %83
  store i64 %84, ptr %8, align 8, !tbaa !14
  %85 = load i64, ptr %24, align 8, !tbaa !14
  %86 = mul nsw i64 14, %85
  store i64 %86, ptr %9, align 8, !tbaa !14
  %87 = load i64, ptr %24, align 8, !tbaa !14
  %88 = mul nsw i64 345, %87
  store i64 %88, ptr %10, align 8, !tbaa !14
  %89 = load i64, ptr %24, align 8, !tbaa !14
  %90 = mul nsw i64 210, %89
  store i64 %90, ptr %11, align 8, !tbaa !14
  %91 = load i64, ptr %24, align 8, !tbaa !14
  %92 = mul nsw i64 32, %91
  store i64 %92, ptr %12, align 8, !tbaa !14
  %93 = load i64, ptr %24, align 8, !tbaa !14
  %94 = mul nsw i64 899, %93
  store i64 %94, ptr %13, align 8, !tbaa !14
  %95 = load i64, ptr %24, align 8, !tbaa !14
  %96 = mul nsw i64 616, %95
  store i64 %96, ptr %14, align 8, !tbaa !14
  store i64 0, ptr %15, align 8, !tbaa !14
  %97 = load i64, ptr %24, align 8, !tbaa !14
  %98 = mul nsw i64 93, %97
  store i64 %98, ptr %16, align 8, !tbaa !14
  store double 1.000000e+00, ptr %17, align 8, !tbaa !23
  store double -1.000000e+00, ptr %18, align 8, !tbaa !23
  store double -1.000000e+00, ptr %19, align 8, !tbaa !23
  store double -1.000000e+00, ptr %20, align 8, !tbaa !23
  store i64 1, ptr %6, align 8, !tbaa !14
  br label %99

99:                                               ; preds = %141, %82
  %100 = load i64, ptr %6, align 8, !tbaa !14
  %101 = load i64, ptr %7, align 8, !tbaa !14
  %102 = icmp sle i64 %100, %101
  br i1 %102, label %103, label %144

103:                                              ; preds = %99
  %104 = load double, ptr %17, align 8, !tbaa !23
  %105 = load double, ptr %18, align 8, !tbaa !23
  %106 = fadd double %104, %105
  %107 = load double, ptr %19, align 8, !tbaa !23
  %108 = fadd double %106, %107
  %109 = load double, ptr %20, align 8, !tbaa !23
  %110 = fsub double %108, %109
  %111 = load double, ptr @T, align 8, !tbaa !23
  %112 = fmul double %110, %111
  store double %112, ptr %17, align 8, !tbaa !23
  %113 = load double, ptr %17, align 8, !tbaa !23
  %114 = load double, ptr %18, align 8, !tbaa !23
  %115 = fadd double %113, %114
  %116 = load double, ptr %19, align 8, !tbaa !23
  %117 = fsub double %115, %116
  %118 = load double, ptr %20, align 8, !tbaa !23
  %119 = fadd double %117, %118
  %120 = load double, ptr @T, align 8, !tbaa !23
  %121 = fmul double %119, %120
  store double %121, ptr %18, align 8, !tbaa !23
  %122 = load double, ptr %17, align 8, !tbaa !23
  %123 = load double, ptr %18, align 8, !tbaa !23
  %124 = fsub double %122, %123
  %125 = load double, ptr %19, align 8, !tbaa !23
  %126 = fadd double %124, %125
  %127 = load double, ptr %20, align 8, !tbaa !23
  %128 = fadd double %126, %127
  %129 = load double, ptr @T, align 8, !tbaa !23
  %130 = fmul double %128, %129
  store double %130, ptr %19, align 8, !tbaa !23
  %131 = load double, ptr %17, align 8, !tbaa !23
  %132 = fneg double %131
  %133 = load double, ptr %18, align 8, !tbaa !23
  %134 = fadd double %132, %133
  %135 = load double, ptr %19, align 8, !tbaa !23
  %136 = fadd double %134, %135
  %137 = load double, ptr %20, align 8, !tbaa !23
  %138 = fadd double %136, %137
  %139 = load double, ptr @T, align 8, !tbaa !23
  %140 = fmul double %138, %139
  store double %140, ptr %20, align 8, !tbaa !23
  br label %141

141:                                              ; preds = %103
  %142 = load i64, ptr %6, align 8, !tbaa !14
  %143 = add nsw i64 %142, 1
  store i64 %143, ptr %6, align 8, !tbaa !14
  br label %99, !llvm.loop !25

144:                                              ; preds = %99
  %145 = load i32, ptr %26, align 4, !tbaa !9
  %146 = load i32, ptr %25, align 4, !tbaa !9
  %147 = icmp eq i32 %145, %146
  br i1 %147, label %148, label %156

148:                                              ; preds = %144
  %149 = load i64, ptr %7, align 8, !tbaa !14
  %150 = load i64, ptr %7, align 8, !tbaa !14
  %151 = load i64, ptr %7, align 8, !tbaa !14
  %152 = load double, ptr %17, align 8, !tbaa !23
  %153 = load double, ptr %18, align 8, !tbaa !23
  %154 = load double, ptr %19, align 8, !tbaa !23
  %155 = load double, ptr %20, align 8, !tbaa !23
  call void @POUT(i64 noundef %149, i64 noundef %150, i64 noundef %151, double noundef %152, double noundef %153, double noundef %154, double noundef %155)
  br label %156

156:                                              ; preds = %148, %144
  store double 1.000000e+00, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 8), align 8, !tbaa !23
  store double -1.000000e+00, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 16), align 16, !tbaa !23
  store double -1.000000e+00, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 24), align 8, !tbaa !23
  store double -1.000000e+00, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 32), align 16, !tbaa !23
  store i64 1, ptr %6, align 8, !tbaa !14
  br label %157

157:                                              ; preds = %199, %156
  %158 = load i64, ptr %6, align 8, !tbaa !14
  %159 = load i64, ptr %8, align 8, !tbaa !14
  %160 = icmp sle i64 %158, %159
  br i1 %160, label %161, label %202

161:                                              ; preds = %157
  %162 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 8), align 8, !tbaa !23
  %163 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 16), align 16, !tbaa !23
  %164 = fadd double %162, %163
  %165 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 24), align 8, !tbaa !23
  %166 = fadd double %164, %165
  %167 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 32), align 16, !tbaa !23
  %168 = fsub double %166, %167
  %169 = load double, ptr @T, align 8, !tbaa !23
  %170 = fmul double %168, %169
  store double %170, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 8), align 8, !tbaa !23
  %171 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 8), align 8, !tbaa !23
  %172 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 16), align 16, !tbaa !23
  %173 = fadd double %171, %172
  %174 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 24), align 8, !tbaa !23
  %175 = fsub double %173, %174
  %176 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 32), align 16, !tbaa !23
  %177 = fadd double %175, %176
  %178 = load double, ptr @T, align 8, !tbaa !23
  %179 = fmul double %177, %178
  store double %179, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 16), align 16, !tbaa !23
  %180 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 8), align 8, !tbaa !23
  %181 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 16), align 16, !tbaa !23
  %182 = fsub double %180, %181
  %183 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 24), align 8, !tbaa !23
  %184 = fadd double %182, %183
  %185 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 32), align 16, !tbaa !23
  %186 = fadd double %184, %185
  %187 = load double, ptr @T, align 8, !tbaa !23
  %188 = fmul double %186, %187
  store double %188, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 24), align 8, !tbaa !23
  %189 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 8), align 8, !tbaa !23
  %190 = fneg double %189
  %191 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 16), align 16, !tbaa !23
  %192 = fadd double %190, %191
  %193 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 24), align 8, !tbaa !23
  %194 = fadd double %192, %193
  %195 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 32), align 16, !tbaa !23
  %196 = fadd double %194, %195
  %197 = load double, ptr @T, align 8, !tbaa !23
  %198 = fmul double %196, %197
  store double %198, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 32), align 16, !tbaa !23
  br label %199

199:                                              ; preds = %161
  %200 = load i64, ptr %6, align 8, !tbaa !14
  %201 = add nsw i64 %200, 1
  store i64 %201, ptr %6, align 8, !tbaa !14
  br label %157, !llvm.loop !26

202:                                              ; preds = %157
  %203 = load i32, ptr %26, align 4, !tbaa !9
  %204 = load i32, ptr %25, align 4, !tbaa !9
  %205 = icmp eq i32 %203, %204
  br i1 %205, label %206, label %214

206:                                              ; preds = %202
  %207 = load i64, ptr %8, align 8, !tbaa !14
  %208 = load i64, ptr %9, align 8, !tbaa !14
  %209 = load i64, ptr %8, align 8, !tbaa !14
  %210 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 8), align 8, !tbaa !23
  %211 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 16), align 16, !tbaa !23
  %212 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 24), align 8, !tbaa !23
  %213 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 32), align 16, !tbaa !23
  call void @POUT(i64 noundef %207, i64 noundef %208, i64 noundef %209, double noundef %210, double noundef %211, double noundef %212, double noundef %213)
  br label %214

214:                                              ; preds = %206, %202
  store i64 1, ptr %6, align 8, !tbaa !14
  br label %215

215:                                              ; preds = %220, %214
  %216 = load i64, ptr %6, align 8, !tbaa !14
  %217 = load i64, ptr %9, align 8, !tbaa !14
  %218 = icmp sle i64 %216, %217
  br i1 %218, label %219, label %223

219:                                              ; preds = %215
  call void @PA(ptr noundef @E1)
  br label %220

220:                                              ; preds = %219
  %221 = load i64, ptr %6, align 8, !tbaa !14
  %222 = add nsw i64 %221, 1
  store i64 %222, ptr %6, align 8, !tbaa !14
  br label %215, !llvm.loop !27

223:                                              ; preds = %215
  %224 = load i32, ptr %26, align 4, !tbaa !9
  %225 = load i32, ptr %25, align 4, !tbaa !9
  %226 = icmp eq i32 %224, %225
  br i1 %226, label %227, label %235

227:                                              ; preds = %223
  %228 = load i64, ptr %9, align 8, !tbaa !14
  %229 = load i64, ptr %8, align 8, !tbaa !14
  %230 = load i64, ptr %8, align 8, !tbaa !14
  %231 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 8), align 8, !tbaa !23
  %232 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 16), align 16, !tbaa !23
  %233 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 24), align 8, !tbaa !23
  %234 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 32), align 16, !tbaa !23
  call void @POUT(i64 noundef %228, i64 noundef %229, i64 noundef %230, double noundef %231, double noundef %232, double noundef %233, double noundef %234)
  br label %235

235:                                              ; preds = %227, %223
  store i32 1, ptr @J, align 4, !tbaa !9
  store i64 1, ptr %6, align 8, !tbaa !14
  br label %236

236:                                              ; preds = %256, %235
  %237 = load i64, ptr %6, align 8, !tbaa !14
  %238 = load i64, ptr %10, align 8, !tbaa !14
  %239 = icmp sle i64 %237, %238
  br i1 %239, label %240, label %259

240:                                              ; preds = %236
  %241 = load i32, ptr @J, align 4, !tbaa !9
  %242 = icmp eq i32 %241, 1
  br i1 %242, label %243, label %244

243:                                              ; preds = %240
  store i32 2, ptr @J, align 4, !tbaa !9
  br label %245

244:                                              ; preds = %240
  store i32 3, ptr @J, align 4, !tbaa !9
  br label %245

245:                                              ; preds = %244, %243
  %246 = load i32, ptr @J, align 4, !tbaa !9
  %247 = icmp sgt i32 %246, 2
  br i1 %247, label %248, label %249

248:                                              ; preds = %245
  store i32 0, ptr @J, align 4, !tbaa !9
  br label %250

249:                                              ; preds = %245
  store i32 1, ptr @J, align 4, !tbaa !9
  br label %250

250:                                              ; preds = %249, %248
  %251 = load i32, ptr @J, align 4, !tbaa !9
  %252 = icmp slt i32 %251, 1
  br i1 %252, label %253, label %254

253:                                              ; preds = %250
  store i32 1, ptr @J, align 4, !tbaa !9
  br label %255

254:                                              ; preds = %250
  store i32 0, ptr @J, align 4, !tbaa !9
  br label %255

255:                                              ; preds = %254, %253
  br label %256

256:                                              ; preds = %255
  %257 = load i64, ptr %6, align 8, !tbaa !14
  %258 = add nsw i64 %257, 1
  store i64 %258, ptr %6, align 8, !tbaa !14
  br label %236, !llvm.loop !28

259:                                              ; preds = %236
  %260 = load i32, ptr %26, align 4, !tbaa !9
  %261 = load i32, ptr %25, align 4, !tbaa !9
  %262 = icmp eq i32 %260, %261
  br i1 %262, label %263, label %273

263:                                              ; preds = %259
  %264 = load i64, ptr %10, align 8, !tbaa !14
  %265 = load i32, ptr @J, align 4, !tbaa !9
  %266 = sext i32 %265 to i64
  %267 = load i32, ptr @J, align 4, !tbaa !9
  %268 = sext i32 %267 to i64
  %269 = load double, ptr %17, align 8, !tbaa !23
  %270 = load double, ptr %18, align 8, !tbaa !23
  %271 = load double, ptr %19, align 8, !tbaa !23
  %272 = load double, ptr %20, align 8, !tbaa !23
  call void @POUT(i64 noundef %264, i64 noundef %266, i64 noundef %268, double noundef %269, double noundef %270, double noundef %271, double noundef %272)
  br label %273

273:                                              ; preds = %263, %259
  store i32 1, ptr @J, align 4, !tbaa !9
  store i32 2, ptr @K, align 4, !tbaa !9
  store i32 3, ptr @L, align 4, !tbaa !9
  store i64 1, ptr %6, align 8, !tbaa !14
  br label %274

274:                                              ; preds = %324, %273
  %275 = load i64, ptr %6, align 8, !tbaa !14
  %276 = load i64, ptr %11, align 8, !tbaa !14
  %277 = icmp sle i64 %275, %276
  br i1 %277, label %278, label %327

278:                                              ; preds = %274
  %279 = load i32, ptr @J, align 4, !tbaa !9
  %280 = load i32, ptr @K, align 4, !tbaa !9
  %281 = load i32, ptr @J, align 4, !tbaa !9
  %282 = sub nsw i32 %280, %281
  %283 = mul nsw i32 %279, %282
  %284 = load i32, ptr @L, align 4, !tbaa !9
  %285 = load i32, ptr @K, align 4, !tbaa !9
  %286 = sub nsw i32 %284, %285
  %287 = mul nsw i32 %283, %286
  store i32 %287, ptr @J, align 4, !tbaa !9
  %288 = load i32, ptr @L, align 4, !tbaa !9
  %289 = load i32, ptr @K, align 4, !tbaa !9
  %290 = mul nsw i32 %288, %289
  %291 = load i32, ptr @L, align 4, !tbaa !9
  %292 = load i32, ptr @J, align 4, !tbaa !9
  %293 = sub nsw i32 %291, %292
  %294 = load i32, ptr @K, align 4, !tbaa !9
  %295 = mul nsw i32 %293, %294
  %296 = sub nsw i32 %290, %295
  store i32 %296, ptr @K, align 4, !tbaa !9
  %297 = load i32, ptr @L, align 4, !tbaa !9
  %298 = load i32, ptr @K, align 4, !tbaa !9
  %299 = sub nsw i32 %297, %298
  %300 = load i32, ptr @K, align 4, !tbaa !9
  %301 = load i32, ptr @J, align 4, !tbaa !9
  %302 = add nsw i32 %300, %301
  %303 = mul nsw i32 %299, %302
  store i32 %303, ptr @L, align 4, !tbaa !9
  %304 = load i32, ptr @J, align 4, !tbaa !9
  %305 = load i32, ptr @K, align 4, !tbaa !9
  %306 = add nsw i32 %304, %305
  %307 = load i32, ptr @L, align 4, !tbaa !9
  %308 = add nsw i32 %306, %307
  %309 = sitofp i32 %308 to double
  %310 = load i32, ptr @L, align 4, !tbaa !9
  %311 = sub nsw i32 %310, 1
  %312 = sext i32 %311 to i64
  %313 = getelementptr inbounds [5 x double], ptr @E1, i64 0, i64 %312
  store double %309, ptr %313, align 8, !tbaa !23
  %314 = load i32, ptr @J, align 4, !tbaa !9
  %315 = load i32, ptr @K, align 4, !tbaa !9
  %316 = mul nsw i32 %314, %315
  %317 = load i32, ptr @L, align 4, !tbaa !9
  %318 = mul nsw i32 %316, %317
  %319 = sitofp i32 %318 to double
  %320 = load i32, ptr @K, align 4, !tbaa !9
  %321 = sub nsw i32 %320, 1
  %322 = sext i32 %321 to i64
  %323 = getelementptr inbounds [5 x double], ptr @E1, i64 0, i64 %322
  store double %319, ptr %323, align 8, !tbaa !23
  br label %324

324:                                              ; preds = %278
  %325 = load i64, ptr %6, align 8, !tbaa !14
  %326 = add nsw i64 %325, 1
  store i64 %326, ptr %6, align 8, !tbaa !14
  br label %274, !llvm.loop !29

327:                                              ; preds = %274
  %328 = load i32, ptr %26, align 4, !tbaa !9
  %329 = load i32, ptr %25, align 4, !tbaa !9
  %330 = icmp eq i32 %328, %329
  br i1 %330, label %331, label %341

331:                                              ; preds = %327
  %332 = load i64, ptr %11, align 8, !tbaa !14
  %333 = load i32, ptr @J, align 4, !tbaa !9
  %334 = sext i32 %333 to i64
  %335 = load i32, ptr @K, align 4, !tbaa !9
  %336 = sext i32 %335 to i64
  %337 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 8), align 8, !tbaa !23
  %338 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 16), align 16, !tbaa !23
  %339 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 24), align 8, !tbaa !23
  %340 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 32), align 16, !tbaa !23
  call void @POUT(i64 noundef %332, i64 noundef %334, i64 noundef %336, double noundef %337, double noundef %338, double noundef %339, double noundef %340)
  br label %341

341:                                              ; preds = %331, %327
  store double 5.000000e-01, ptr %21, align 8, !tbaa !23
  store double 5.000000e-01, ptr %22, align 8, !tbaa !23
  store i64 1, ptr %6, align 8, !tbaa !14
  br label %342

342:                                              ; preds = %389, %341
  %343 = load i64, ptr %6, align 8, !tbaa !14
  %344 = load i64, ptr %12, align 8, !tbaa !14
  %345 = icmp sle i64 %343, %344
  br i1 %345, label %346, label %392

346:                                              ; preds = %342
  %347 = load double, ptr @T, align 8, !tbaa !23
  %348 = load double, ptr @T2, align 8, !tbaa !23
  %349 = load double, ptr %21, align 8, !tbaa !23
  %350 = call double @sin(double noundef %349) #6
  %351 = fmul double %348, %350
  %352 = load double, ptr %21, align 8, !tbaa !23
  %353 = call double @cos(double noundef %352) #6
  %354 = fmul double %351, %353
  %355 = load double, ptr %21, align 8, !tbaa !23
  %356 = load double, ptr %22, align 8, !tbaa !23
  %357 = fadd double %355, %356
  %358 = call double @cos(double noundef %357) #6
  %359 = load double, ptr %21, align 8, !tbaa !23
  %360 = load double, ptr %22, align 8, !tbaa !23
  %361 = fsub double %359, %360
  %362 = call double @cos(double noundef %361) #6
  %363 = fadd double %358, %362
  %364 = fsub double %363, 1.000000e+00
  %365 = fdiv double %354, %364
  %366 = call double @atan(double noundef %365) #6
  %367 = fmul double %347, %366
  store double %367, ptr %21, align 8, !tbaa !23
  %368 = load double, ptr @T, align 8, !tbaa !23
  %369 = load double, ptr @T2, align 8, !tbaa !23
  %370 = load double, ptr %22, align 8, !tbaa !23
  %371 = call double @sin(double noundef %370) #6
  %372 = fmul double %369, %371
  %373 = load double, ptr %22, align 8, !tbaa !23
  %374 = call double @cos(double noundef %373) #6
  %375 = fmul double %372, %374
  %376 = load double, ptr %21, align 8, !tbaa !23
  %377 = load double, ptr %22, align 8, !tbaa !23
  %378 = fadd double %376, %377
  %379 = call double @cos(double noundef %378) #6
  %380 = load double, ptr %21, align 8, !tbaa !23
  %381 = load double, ptr %22, align 8, !tbaa !23
  %382 = fsub double %380, %381
  %383 = call double @cos(double noundef %382) #6
  %384 = fadd double %379, %383
  %385 = fsub double %384, 1.000000e+00
  %386 = fdiv double %375, %385
  %387 = call double @atan(double noundef %386) #6
  %388 = fmul double %368, %387
  store double %388, ptr %22, align 8, !tbaa !23
  br label %389

389:                                              ; preds = %346
  %390 = load i64, ptr %6, align 8, !tbaa !14
  %391 = add nsw i64 %390, 1
  store i64 %391, ptr %6, align 8, !tbaa !14
  br label %342, !llvm.loop !30

392:                                              ; preds = %342
  %393 = load i32, ptr %26, align 4, !tbaa !9
  %394 = load i32, ptr %25, align 4, !tbaa !9
  %395 = icmp eq i32 %393, %394
  br i1 %395, label %396, label %406

396:                                              ; preds = %392
  %397 = load i64, ptr %12, align 8, !tbaa !14
  %398 = load i32, ptr @J, align 4, !tbaa !9
  %399 = sext i32 %398 to i64
  %400 = load i32, ptr @K, align 4, !tbaa !9
  %401 = sext i32 %400 to i64
  %402 = load double, ptr %21, align 8, !tbaa !23
  %403 = load double, ptr %21, align 8, !tbaa !23
  %404 = load double, ptr %22, align 8, !tbaa !23
  %405 = load double, ptr %22, align 8, !tbaa !23
  call void @POUT(i64 noundef %397, i64 noundef %399, i64 noundef %401, double noundef %402, double noundef %403, double noundef %404, double noundef %405)
  br label %406

406:                                              ; preds = %396, %392
  store double 1.000000e+00, ptr %21, align 8, !tbaa !23
  store double 1.000000e+00, ptr %22, align 8, !tbaa !23
  store double 1.000000e+00, ptr %23, align 8, !tbaa !23
  store i64 1, ptr %6, align 8, !tbaa !14
  br label %407

407:                                              ; preds = %414, %406
  %408 = load i64, ptr %6, align 8, !tbaa !14
  %409 = load i64, ptr %13, align 8, !tbaa !14
  %410 = icmp sle i64 %408, %409
  br i1 %410, label %411, label %417

411:                                              ; preds = %407
  %412 = load double, ptr %21, align 8, !tbaa !23
  %413 = load double, ptr %22, align 8, !tbaa !23
  call void @P3(double noundef %412, double noundef %413, ptr noundef %23)
  br label %414

414:                                              ; preds = %411
  %415 = load i64, ptr %6, align 8, !tbaa !14
  %416 = add nsw i64 %415, 1
  store i64 %416, ptr %6, align 8, !tbaa !14
  br label %407, !llvm.loop !31

417:                                              ; preds = %407
  %418 = load i32, ptr %26, align 4, !tbaa !9
  %419 = load i32, ptr %25, align 4, !tbaa !9
  %420 = icmp eq i32 %418, %419
  br i1 %420, label %421, label %431

421:                                              ; preds = %417
  %422 = load i64, ptr %13, align 8, !tbaa !14
  %423 = load i32, ptr @J, align 4, !tbaa !9
  %424 = sext i32 %423 to i64
  %425 = load i32, ptr @K, align 4, !tbaa !9
  %426 = sext i32 %425 to i64
  %427 = load double, ptr %21, align 8, !tbaa !23
  %428 = load double, ptr %22, align 8, !tbaa !23
  %429 = load double, ptr %23, align 8, !tbaa !23
  %430 = load double, ptr %23, align 8, !tbaa !23
  call void @POUT(i64 noundef %422, i64 noundef %424, i64 noundef %426, double noundef %427, double noundef %428, double noundef %429, double noundef %430)
  br label %431

431:                                              ; preds = %421, %417
  store i32 1, ptr @J, align 4, !tbaa !9
  store i32 2, ptr @K, align 4, !tbaa !9
  store i32 3, ptr @L, align 4, !tbaa !9
  store double 1.000000e+00, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 8), align 8, !tbaa !23
  store double 2.000000e+00, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 16), align 16, !tbaa !23
  store double 3.000000e+00, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 24), align 8, !tbaa !23
  store i64 1, ptr %6, align 8, !tbaa !14
  br label %432

432:                                              ; preds = %437, %431
  %433 = load i64, ptr %6, align 8, !tbaa !14
  %434 = load i64, ptr %14, align 8, !tbaa !14
  %435 = icmp sle i64 %433, %434
  br i1 %435, label %436, label %440

436:                                              ; preds = %432
  call void @P0()
  br label %437

437:                                              ; preds = %436
  %438 = load i64, ptr %6, align 8, !tbaa !14
  %439 = add nsw i64 %438, 1
  store i64 %439, ptr %6, align 8, !tbaa !14
  br label %432, !llvm.loop !32

440:                                              ; preds = %432
  %441 = load i32, ptr %26, align 4, !tbaa !9
  %442 = load i32, ptr %25, align 4, !tbaa !9
  %443 = icmp eq i32 %441, %442
  br i1 %443, label %444, label %454

444:                                              ; preds = %440
  %445 = load i64, ptr %14, align 8, !tbaa !14
  %446 = load i32, ptr @J, align 4, !tbaa !9
  %447 = sext i32 %446 to i64
  %448 = load i32, ptr @K, align 4, !tbaa !9
  %449 = sext i32 %448 to i64
  %450 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 8), align 8, !tbaa !23
  %451 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 16), align 16, !tbaa !23
  %452 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 24), align 8, !tbaa !23
  %453 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 32), align 16, !tbaa !23
  call void @POUT(i64 noundef %445, i64 noundef %447, i64 noundef %449, double noundef %450, double noundef %451, double noundef %452, double noundef %453)
  br label %454

454:                                              ; preds = %444, %440
  store i32 2, ptr @J, align 4, !tbaa !9
  store i32 3, ptr @K, align 4, !tbaa !9
  store i64 1, ptr %6, align 8, !tbaa !14
  br label %455

455:                                              ; preds = %474, %454
  %456 = load i64, ptr %6, align 8, !tbaa !14
  %457 = load i64, ptr %15, align 8, !tbaa !14
  %458 = icmp sle i64 %456, %457
  br i1 %458, label %459, label %477

459:                                              ; preds = %455
  %460 = load i32, ptr @J, align 4, !tbaa !9
  %461 = load i32, ptr @K, align 4, !tbaa !9
  %462 = add nsw i32 %460, %461
  store i32 %462, ptr @J, align 4, !tbaa !9
  %463 = load i32, ptr @J, align 4, !tbaa !9
  %464 = load i32, ptr @K, align 4, !tbaa !9
  %465 = add nsw i32 %463, %464
  store i32 %465, ptr @K, align 4, !tbaa !9
  %466 = load i32, ptr @K, align 4, !tbaa !9
  %467 = load i32, ptr @J, align 4, !tbaa !9
  %468 = sub nsw i32 %466, %467
  store i32 %468, ptr @J, align 4, !tbaa !9
  %469 = load i32, ptr @K, align 4, !tbaa !9
  %470 = load i32, ptr @J, align 4, !tbaa !9
  %471 = sub nsw i32 %469, %470
  %472 = load i32, ptr @J, align 4, !tbaa !9
  %473 = sub nsw i32 %471, %472
  store i32 %473, ptr @K, align 4, !tbaa !9
  br label %474

474:                                              ; preds = %459
  %475 = load i64, ptr %6, align 8, !tbaa !14
  %476 = add nsw i64 %475, 1
  store i64 %476, ptr %6, align 8, !tbaa !14
  br label %455, !llvm.loop !33

477:                                              ; preds = %455
  %478 = load i32, ptr %26, align 4, !tbaa !9
  %479 = load i32, ptr %25, align 4, !tbaa !9
  %480 = icmp eq i32 %478, %479
  br i1 %480, label %481, label %491

481:                                              ; preds = %477
  %482 = load i64, ptr %15, align 8, !tbaa !14
  %483 = load i32, ptr @J, align 4, !tbaa !9
  %484 = sext i32 %483 to i64
  %485 = load i32, ptr @K, align 4, !tbaa !9
  %486 = sext i32 %485 to i64
  %487 = load double, ptr %17, align 8, !tbaa !23
  %488 = load double, ptr %18, align 8, !tbaa !23
  %489 = load double, ptr %19, align 8, !tbaa !23
  %490 = load double, ptr %20, align 8, !tbaa !23
  call void @POUT(i64 noundef %482, i64 noundef %484, i64 noundef %486, double noundef %487, double noundef %488, double noundef %489, double noundef %490)
  br label %491

491:                                              ; preds = %481, %477
  store double 7.500000e-01, ptr %21, align 8, !tbaa !23
  store i64 1, ptr %6, align 8, !tbaa !14
  br label %492

492:                                              ; preds = %503, %491
  %493 = load i64, ptr %6, align 8, !tbaa !14
  %494 = load i64, ptr %16, align 8, !tbaa !14
  %495 = icmp sle i64 %493, %494
  br i1 %495, label %496, label %506

496:                                              ; preds = %492
  %497 = load double, ptr %21, align 8, !tbaa !23
  %498 = call double @log(double noundef %497) #6
  %499 = load double, ptr @T1, align 8, !tbaa !23
  %500 = fdiv double %498, %499
  %501 = call double @exp(double noundef %500) #6
  %502 = call double @sqrt(double noundef %501) #6
  store double %502, ptr %21, align 8, !tbaa !23
  br label %503

503:                                              ; preds = %496
  %504 = load i64, ptr %6, align 8, !tbaa !14
  %505 = add nsw i64 %504, 1
  store i64 %505, ptr %6, align 8, !tbaa !14
  br label %492, !llvm.loop !34

506:                                              ; preds = %492
  %507 = load i32, ptr %26, align 4, !tbaa !9
  %508 = load i32, ptr %25, align 4, !tbaa !9
  %509 = icmp eq i32 %507, %508
  br i1 %509, label %510, label %520

510:                                              ; preds = %506
  %511 = load i64, ptr %16, align 8, !tbaa !14
  %512 = load i32, ptr @J, align 4, !tbaa !9
  %513 = sext i32 %512 to i64
  %514 = load i32, ptr @K, align 4, !tbaa !9
  %515 = sext i32 %514 to i64
  %516 = load double, ptr %21, align 8, !tbaa !23
  %517 = load double, ptr %21, align 8, !tbaa !23
  %518 = load double, ptr %21, align 8, !tbaa !23
  %519 = load double, ptr %21, align 8, !tbaa !23
  call void @POUT(i64 noundef %511, i64 noundef %513, i64 noundef %515, double noundef %516, double noundef %517, double noundef %518, double noundef %519)
  br label %520

520:                                              ; preds = %510, %506
  %521 = load i32, ptr %26, align 4, !tbaa !9
  %522 = add nsw i32 %521, 1
  store i32 %522, ptr %26, align 4, !tbaa !9
  %523 = load i32, ptr %25, align 4, !tbaa !9
  %524 = icmp sle i32 %522, %523
  br i1 %524, label %525, label %526

525:                                              ; preds = %520
  br label %82

526:                                              ; preds = %520
  %527 = call i64 @time(ptr noundef null) #6
  store i64 %527, ptr %29, align 8, !tbaa !14
  %528 = call i32 (ptr, ...) @printf(ptr noundef @.str.2)
  %529 = load i32, ptr %31, align 4, !tbaa !9
  %530 = icmp ne i32 %529, 0
  br i1 %530, label %531, label %532

531:                                              ; preds = %526
  br label %79

532:                                              ; preds = %526
  store i32 0, ptr %3, align 4
  store i32 1, ptr %32, align 4
  br label %533

533:                                              ; preds = %532, %71
  call void @llvm.lifetime.end.p0(ptr %31) #6
  call void @llvm.lifetime.end.p0(ptr %30) #6
  call void @llvm.lifetime.end.p0(ptr %29) #6
  call void @llvm.lifetime.end.p0(ptr %28) #6
  call void @llvm.lifetime.end.p0(ptr %27) #6
  call void @llvm.lifetime.end.p0(ptr %26) #6
  call void @llvm.lifetime.end.p0(ptr %25) #6
  call void @llvm.lifetime.end.p0(ptr %24) #6
  call void @llvm.lifetime.end.p0(ptr %23) #6
  call void @llvm.lifetime.end.p0(ptr %22) #6
  call void @llvm.lifetime.end.p0(ptr %21) #6
  call void @llvm.lifetime.end.p0(ptr %20) #6
  call void @llvm.lifetime.end.p0(ptr %19) #6
  call void @llvm.lifetime.end.p0(ptr %18) #6
  call void @llvm.lifetime.end.p0(ptr %17) #6
  call void @llvm.lifetime.end.p0(ptr %16) #6
  call void @llvm.lifetime.end.p0(ptr %15) #6
  call void @llvm.lifetime.end.p0(ptr %14) #6
  call void @llvm.lifetime.end.p0(ptr %13) #6
  call void @llvm.lifetime.end.p0(ptr %12) #6
  call void @llvm.lifetime.end.p0(ptr %11) #6
  call void @llvm.lifetime.end.p0(ptr %10) #6
  call void @llvm.lifetime.end.p0(ptr %9) #6
  call void @llvm.lifetime.end.p0(ptr %8) #6
  call void @llvm.lifetime.end.p0(ptr %7) #6
  call void @llvm.lifetime.end.p0(ptr %6) #6
  %534 = load i32, ptr %3, align 4
  ret i32 %534
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nounwind willreturn memory(read)
declare i32 @strncmp(ptr noundef, ptr noundef, i64 noundef) #2

; Function Attrs: inlinehint nounwind willreturn memory(read) uwtable
define available_externally i64 @atol(ptr noundef nonnull %0) #3 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !16
  %3 = load ptr, ptr %2, align 8, !tbaa !16
  %4 = call i64 @strtol(ptr noundef %3, ptr noundef null, i32 noundef 10) #6
  ret i64 %4
}

; Function Attrs: nounwind
declare i32 @fprintf(ptr noundef, ptr noundef, ...) #4

; Function Attrs: nounwind
declare i64 @time(ptr noundef) #4

; Function Attrs: nounwind uwtable
define dso_local void @POUT(i64 noundef %0, i64 noundef %1, i64 noundef %2, double noundef %3, double noundef %4, double noundef %5, double noundef %6) #0 {
  %8 = alloca i64, align 8
  %9 = alloca i64, align 8
  %10 = alloca i64, align 8
  %11 = alloca double, align 8
  %12 = alloca double, align 8
  %13 = alloca double, align 8
  %14 = alloca double, align 8
  store i64 %0, ptr %8, align 8, !tbaa !14
  store i64 %1, ptr %9, align 8, !tbaa !14
  store i64 %2, ptr %10, align 8, !tbaa !14
  store double %3, ptr %11, align 8, !tbaa !23
  store double %4, ptr %12, align 8, !tbaa !23
  store double %5, ptr %13, align 8, !tbaa !23
  store double %6, ptr %14, align 8, !tbaa !23
  %15 = load i64, ptr %8, align 8, !tbaa !14
  %16 = load i64, ptr %9, align 8, !tbaa !14
  %17 = load i64, ptr %10, align 8, !tbaa !14
  %18 = load double, ptr %11, align 8, !tbaa !23
  %19 = load double, ptr %12, align 8, !tbaa !23
  %20 = load double, ptr %13, align 8, !tbaa !23
  %21 = load double, ptr %14, align 8, !tbaa !23
  %22 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i64 noundef %15, i64 noundef %16, i64 noundef %17, double noundef %18, double noundef %19, double noundef %20, double noundef %21)
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local void @PA(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !35
  store i32 0, ptr @J, align 4, !tbaa !9
  br label %3

3:                                                ; preds = %85, %1
  %4 = load ptr, ptr %2, align 8, !tbaa !35
  %5 = getelementptr inbounds double, ptr %4, i64 1
  %6 = load double, ptr %5, align 8, !tbaa !23
  %7 = load ptr, ptr %2, align 8, !tbaa !35
  %8 = getelementptr inbounds double, ptr %7, i64 2
  %9 = load double, ptr %8, align 8, !tbaa !23
  %10 = fadd double %6, %9
  %11 = load ptr, ptr %2, align 8, !tbaa !35
  %12 = getelementptr inbounds double, ptr %11, i64 3
  %13 = load double, ptr %12, align 8, !tbaa !23
  %14 = fadd double %10, %13
  %15 = load ptr, ptr %2, align 8, !tbaa !35
  %16 = getelementptr inbounds double, ptr %15, i64 4
  %17 = load double, ptr %16, align 8, !tbaa !23
  %18 = fsub double %14, %17
  %19 = load double, ptr @T, align 8, !tbaa !23
  %20 = fmul double %18, %19
  %21 = load ptr, ptr %2, align 8, !tbaa !35
  %22 = getelementptr inbounds double, ptr %21, i64 1
  store double %20, ptr %22, align 8, !tbaa !23
  %23 = load ptr, ptr %2, align 8, !tbaa !35
  %24 = getelementptr inbounds double, ptr %23, i64 1
  %25 = load double, ptr %24, align 8, !tbaa !23
  %26 = load ptr, ptr %2, align 8, !tbaa !35
  %27 = getelementptr inbounds double, ptr %26, i64 2
  %28 = load double, ptr %27, align 8, !tbaa !23
  %29 = fadd double %25, %28
  %30 = load ptr, ptr %2, align 8, !tbaa !35
  %31 = getelementptr inbounds double, ptr %30, i64 3
  %32 = load double, ptr %31, align 8, !tbaa !23
  %33 = fsub double %29, %32
  %34 = load ptr, ptr %2, align 8, !tbaa !35
  %35 = getelementptr inbounds double, ptr %34, i64 4
  %36 = load double, ptr %35, align 8, !tbaa !23
  %37 = fadd double %33, %36
  %38 = load double, ptr @T, align 8, !tbaa !23
  %39 = fmul double %37, %38
  %40 = load ptr, ptr %2, align 8, !tbaa !35
  %41 = getelementptr inbounds double, ptr %40, i64 2
  store double %39, ptr %41, align 8, !tbaa !23
  %42 = load ptr, ptr %2, align 8, !tbaa !35
  %43 = getelementptr inbounds double, ptr %42, i64 1
  %44 = load double, ptr %43, align 8, !tbaa !23
  %45 = load ptr, ptr %2, align 8, !tbaa !35
  %46 = getelementptr inbounds double, ptr %45, i64 2
  %47 = load double, ptr %46, align 8, !tbaa !23
  %48 = fsub double %44, %47
  %49 = load ptr, ptr %2, align 8, !tbaa !35
  %50 = getelementptr inbounds double, ptr %49, i64 3
  %51 = load double, ptr %50, align 8, !tbaa !23
  %52 = fadd double %48, %51
  %53 = load ptr, ptr %2, align 8, !tbaa !35
  %54 = getelementptr inbounds double, ptr %53, i64 4
  %55 = load double, ptr %54, align 8, !tbaa !23
  %56 = fadd double %52, %55
  %57 = load double, ptr @T, align 8, !tbaa !23
  %58 = fmul double %56, %57
  %59 = load ptr, ptr %2, align 8, !tbaa !35
  %60 = getelementptr inbounds double, ptr %59, i64 3
  store double %58, ptr %60, align 8, !tbaa !23
  %61 = load ptr, ptr %2, align 8, !tbaa !35
  %62 = getelementptr inbounds double, ptr %61, i64 1
  %63 = load double, ptr %62, align 8, !tbaa !23
  %64 = fneg double %63
  %65 = load ptr, ptr %2, align 8, !tbaa !35
  %66 = getelementptr inbounds double, ptr %65, i64 2
  %67 = load double, ptr %66, align 8, !tbaa !23
  %68 = fadd double %64, %67
  %69 = load ptr, ptr %2, align 8, !tbaa !35
  %70 = getelementptr inbounds double, ptr %69, i64 3
  %71 = load double, ptr %70, align 8, !tbaa !23
  %72 = fadd double %68, %71
  %73 = load ptr, ptr %2, align 8, !tbaa !35
  %74 = getelementptr inbounds double, ptr %73, i64 4
  %75 = load double, ptr %74, align 8, !tbaa !23
  %76 = fadd double %72, %75
  %77 = load double, ptr @T2, align 8, !tbaa !23
  %78 = fdiv double %76, %77
  %79 = load ptr, ptr %2, align 8, !tbaa !35
  %80 = getelementptr inbounds double, ptr %79, i64 4
  store double %78, ptr %80, align 8, !tbaa !23
  %81 = load i32, ptr @J, align 4, !tbaa !9
  %82 = add nsw i32 %81, 1
  store i32 %82, ptr @J, align 4, !tbaa !9
  %83 = load i32, ptr @J, align 4, !tbaa !9
  %84 = icmp slt i32 %83, 6
  br i1 %84, label %85, label %86

85:                                               ; preds = %3
  br label %3

86:                                               ; preds = %3
  ret void
}

; Function Attrs: nounwind
declare double @atan(double noundef) #4

; Function Attrs: nounwind
declare double @sin(double noundef) #4

; Function Attrs: nounwind
declare double @cos(double noundef) #4

; Function Attrs: nounwind uwtable
define dso_local void @P3(double noundef %0, double noundef %1, ptr noundef %2) #0 {
  %4 = alloca double, align 8
  %5 = alloca double, align 8
  %6 = alloca ptr, align 8
  %7 = alloca double, align 8
  %8 = alloca double, align 8
  store double %0, ptr %4, align 8, !tbaa !23
  store double %1, ptr %5, align 8, !tbaa !23
  store ptr %2, ptr %6, align 8, !tbaa !35
  call void @llvm.lifetime.start.p0(ptr %7) #6
  call void @llvm.lifetime.start.p0(ptr %8) #6
  %9 = load double, ptr %4, align 8, !tbaa !23
  store double %9, ptr %7, align 8, !tbaa !23
  %10 = load double, ptr %5, align 8, !tbaa !23
  store double %10, ptr %8, align 8, !tbaa !23
  %11 = load double, ptr @T, align 8, !tbaa !23
  %12 = load double, ptr %7, align 8, !tbaa !23
  %13 = load double, ptr %8, align 8, !tbaa !23
  %14 = fadd double %12, %13
  %15 = fmul double %11, %14
  store double %15, ptr %7, align 8, !tbaa !23
  %16 = load double, ptr @T, align 8, !tbaa !23
  %17 = load double, ptr %7, align 8, !tbaa !23
  %18 = load double, ptr %8, align 8, !tbaa !23
  %19 = fadd double %17, %18
  %20 = fmul double %16, %19
  store double %20, ptr %8, align 8, !tbaa !23
  %21 = load double, ptr %7, align 8, !tbaa !23
  %22 = load double, ptr %8, align 8, !tbaa !23
  %23 = fadd double %21, %22
  %24 = load double, ptr @T2, align 8, !tbaa !23
  %25 = fdiv double %23, %24
  %26 = load ptr, ptr %6, align 8, !tbaa !35
  store double %25, ptr %26, align 8, !tbaa !23
  call void @llvm.lifetime.end.p0(ptr %8) #6
  call void @llvm.lifetime.end.p0(ptr %7) #6
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local void @P0() #0 {
  %1 = load i32, ptr @K, align 4, !tbaa !9
  %2 = sext i32 %1 to i64
  %3 = getelementptr inbounds [5 x double], ptr @E1, i64 0, i64 %2
  %4 = load double, ptr %3, align 8, !tbaa !23
  %5 = load i32, ptr @J, align 4, !tbaa !9
  %6 = sext i32 %5 to i64
  %7 = getelementptr inbounds [5 x double], ptr @E1, i64 0, i64 %6
  store double %4, ptr %7, align 8, !tbaa !23
  %8 = load i32, ptr @L, align 4, !tbaa !9
  %9 = sext i32 %8 to i64
  %10 = getelementptr inbounds [5 x double], ptr @E1, i64 0, i64 %9
  %11 = load double, ptr %10, align 8, !tbaa !23
  %12 = load i32, ptr @K, align 4, !tbaa !9
  %13 = sext i32 %12 to i64
  %14 = getelementptr inbounds [5 x double], ptr @E1, i64 0, i64 %13
  store double %11, ptr %14, align 8, !tbaa !23
  %15 = load i32, ptr @J, align 4, !tbaa !9
  %16 = sext i32 %15 to i64
  %17 = getelementptr inbounds [5 x double], ptr @E1, i64 0, i64 %16
  %18 = load double, ptr %17, align 8, !tbaa !23
  %19 = load i32, ptr @L, align 4, !tbaa !9
  %20 = sext i32 %19 to i64
  %21 = getelementptr inbounds [5 x double], ptr @E1, i64 0, i64 %20
  store double %18, ptr %21, align 8, !tbaa !23
  ret void
}

; Function Attrs: nounwind
declare double @sqrt(double noundef) #4

; Function Attrs: nounwind
declare double @exp(double noundef) #4

; Function Attrs: nounwind
declare double @log(double noundef) #4

declare i32 @printf(ptr noundef, ...) #5

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind
declare i64 @strtol(ptr noundef, ptr noundef, i32 noundef) #4

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind willreturn memory(read) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { inlinehint nounwind willreturn memory(read) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!15 = !{!"long", !7, i64 0}
!16 = !{!17, !17, i64 0}
!17 = !{!"p1 omnipotent char", !13, i64 0}
!18 = !{!7, !7, i64 0}
!19 = !{!20, !20, i64 0}
!20 = !{!"p1 _ZTS8_IO_FILE", !13, i64 0}
!21 = distinct !{!21, !22}
!22 = !{!"llvm.loop.mustprogress"}
!23 = !{!24, !24, i64 0}
!24 = !{!"double", !7, i64 0}
!25 = distinct !{!25, !22}
!26 = distinct !{!26, !22}
!27 = distinct !{!27, !22}
!28 = distinct !{!28, !22}
!29 = distinct !{!29, !22}
!30 = distinct !{!30, !22}
!31 = distinct !{!31, !22}
!32 = distinct !{!32, !22}
!33 = distinct !{!33, !22}
!34 = distinct !{!34, !22}
!35 = !{!36, !36, i64 0}
!36 = !{!"p1 double", !13, i64 0}
