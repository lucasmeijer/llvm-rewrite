; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/whetstone.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/whetstone.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/whetstone.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@stderr = external local_unnamed_addr global ptr, align 8
@.str.1 = private unnamed_addr constant [28 x i8] c"usage: whetdc [-c] [loops]\0A\00", align 1
@T = dso_local local_unnamed_addr global double 0.000000e+00, align 8
@T1 = dso_local local_unnamed_addr global double 0.000000e+00, align 8
@T2 = dso_local local_unnamed_addr global double 0.000000e+00, align 8
@E1 = dso_local local_unnamed_addr global [5 x double] zeroinitializer, align 16
@J = dso_local local_unnamed_addr global i32 0, align 4
@K = dso_local local_unnamed_addr global i32 0, align 4
@L = dso_local local_unnamed_addr global i32 0, align 4
@.str.3 = private unnamed_addr constant [44 x i8] c"%7ld %7ld %7ld %12.4e %12.4e %12.4e %12.4e\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local range(i32 0, 2) i32 @main(i32 noundef %0, ptr nofree noundef readonly captures(none) %1) local_unnamed_addr #0 {
  %3 = icmp sgt i32 %0, 1
  br i1 %3, label %4, label %8

4:                                                ; preds = %2
  %5 = zext nneg i32 %0 to i64
  br label %34

6:                                                ; preds = %51
  %7 = icmp eq i32 %53, 0
  br label %8

8:                                                ; preds = %6, %2
  %9 = phi i64 [ 100000, %2 ], [ %52, %6 ]
  %10 = phi i1 [ true, %2 ], [ %7, %6 ]
  %11 = mul i64 %9, 12
  %12 = mul i64 %9, 14
  %13 = mul i64 %9, 345
  %14 = mul i64 %9, 210
  %15 = shl i64 %9, 5
  %16 = mul nsw i64 %9, 899
  %17 = mul i64 %9, 616
  %18 = mul i64 %9, 93
  %19 = tail call i64 @llvm.smax.i64(i64 %11, i64 1)
  %20 = tail call i64 @llvm.smax.i64(i64 %12, i64 1)
  %21 = tail call i64 @llvm.smax.i64(i64 %13, i64 1)
  %22 = tail call i64 @llvm.smax.i64(i64 %15, i64 1)
  %23 = tail call i64 @llvm.smax.i64(i64 %17, i64 1)
  %24 = tail call i64 @llvm.smax.i64(i64 %18, i64 1)
  %25 = icmp slt i64 %13, 8
  %26 = and i64 %21, 9223372036854775800
  %27 = or disjoint i64 %26, 1
  %28 = icmp eq i64 %21, %26
  %29 = and i64 %23, 1
  %30 = icmp slt i64 %17, 8
  %31 = and i64 %23, 9223372036854775800
  %32 = icmp eq i64 %29, 0
  %33 = trunc i64 %23 to i1
  br label %56

34:                                               ; preds = %4, %51
  %35 = phi i64 [ 1, %4 ], [ %54, %51 ]
  %36 = phi i32 [ 0, %4 ], [ %53, %51 ]
  %37 = phi i64 [ 100000, %4 ], [ %52, %51 ]
  %38 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %35
  %39 = load ptr, ptr %38, align 8, !tbaa !9
  %40 = load i8, ptr %39, align 1
  switch i8 %40, label %45 [
    i8 45, label %41
    i8 99, label %51
  ]

41:                                               ; preds = %34
  %42 = getelementptr inbounds nuw i8, ptr %39, i64 1
  %43 = load i8, ptr %42, align 1
  %44 = icmp eq i8 %43, 99
  br i1 %44, label %51, label %45

45:                                               ; preds = %34, %41
  %46 = tail call i64 @strtol(ptr noundef nonnull captures(none) %39, ptr noundef null, i32 noundef 10) #12, !inline_history !12
  %47 = icmp sgt i64 %46, 0
  br i1 %47, label %51, label %48

48:                                               ; preds = %45
  %49 = load ptr, ptr @stderr, align 8, !tbaa !13
  %50 = tail call i64 @fwrite(ptr nonnull @.str.1, i64 27, i64 1, ptr %49) #13
  br label %314

51:                                               ; preds = %34, %45, %41
  %52 = phi i64 [ %37, %41 ], [ %37, %34 ], [ %46, %45 ]
  %53 = phi i32 [ 1, %41 ], [ 1, %34 ], [ %36, %45 ]
  %54 = add nuw nsw i64 %35, 1
  %55 = icmp eq i64 %54, %5
  br i1 %55, label %6, label %34, !llvm.loop !15

56:                                               ; preds = %306, %8
  %57 = tail call i64 @time(ptr noundef null) #12
  store double 4.999750e-01, ptr @T, align 8, !tbaa !17
  store double 5.002500e-01, ptr @T1, align 8, !tbaa !17
  store double 2.000000e+00, ptr @T2, align 8, !tbaa !17
  %58 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.3, i64 noundef 0, i64 noundef 0, i64 noundef 0, double noundef 1.000000e+00, double noundef -1.000000e+00, double noundef -1.000000e+00, double noundef -1.000000e+00)
  %59 = load double, ptr @T, align 8, !tbaa !17
  br label %60

60:                                               ; preds = %56, %60
  %61 = phi i64 [ 1, %56 ], [ %82, %60 ]
  %62 = phi double [ 1.000000e+00, %56 ], [ %69, %60 ]
  %63 = phi double [ -1.000000e+00, %56 ], [ %73, %60 ]
  %64 = phi double [ -1.000000e+00, %56 ], [ %77, %60 ]
  %65 = phi double [ -1.000000e+00, %56 ], [ %81, %60 ]
  %66 = fadd double %62, %63
  %67 = fadd double %66, %64
  %68 = fsub double %67, %65
  %69 = fmul double %68, %59
  %70 = fadd double %63, %69
  %71 = fsub double %70, %64
  %72 = fadd double %65, %71
  %73 = fmul double %59, %72
  %74 = fsub double %69, %73
  %75 = fadd double %64, %74
  %76 = fadd double %65, %75
  %77 = fmul double %59, %76
  %78 = fsub double %73, %69
  %79 = fadd double %78, %77
  %80 = fadd double %65, %79
  %81 = fmul double %59, %80
  %82 = add nuw nsw i64 %61, 1
  %83 = icmp eq i64 %61, %19
  br i1 %83, label %84, label %60, !llvm.loop !19

84:                                               ; preds = %60
  store double %69, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 8), align 8, !tbaa !17
  store double %73, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 16), align 16, !tbaa !17
  store double %77, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 24), align 8, !tbaa !17
  store double %81, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 32), align 16, !tbaa !17
  %85 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.3, i64 noundef %11, i64 noundef %12, i64 noundef %11, double noundef %69, double noundef %73, double noundef %77, double noundef %81)
  %86 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 32), align 16
  %87 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 24), align 8
  %88 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 16), align 16
  %89 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 8), align 8
  %90 = load double, ptr @T, align 8, !tbaa !17
  %91 = load double, ptr @T2, align 8, !tbaa !17
  store i32 6, ptr @J, align 4, !tbaa !20
  br label %92

92:                                               ; preds = %84, %92
  %93 = phi i64 [ 1, %84 ], [ %194, %92 ]
  %94 = phi double [ %89, %84 ], [ %181, %92 ]
  %95 = phi double [ %88, %84 ], [ %185, %92 ]
  %96 = phi double [ %87, %84 ], [ %189, %92 ]
  %97 = phi double [ %86, %84 ], [ %193, %92 ]
  %98 = fadd double %95, %94
  %99 = fadd double %96, %98
  %100 = fsub double %99, %97
  %101 = fmul double %90, %100
  %102 = fadd double %95, %101
  %103 = fsub double %102, %96
  %104 = fadd double %97, %103
  %105 = fmul double %90, %104
  %106 = fsub double %101, %105
  %107 = fadd double %96, %106
  %108 = fadd double %97, %107
  %109 = fmul double %90, %108
  %110 = fsub double %105, %101
  %111 = fadd double %110, %109
  %112 = fadd double %97, %111
  %113 = fdiv double %112, %91
  %114 = fadd double %105, %101
  %115 = fadd double %109, %114
  %116 = fsub double %115, %113
  %117 = fmul double %90, %116
  %118 = fadd double %105, %117
  %119 = fsub double %118, %109
  %120 = fadd double %113, %119
  %121 = fmul double %90, %120
  %122 = fsub double %117, %121
  %123 = fadd double %109, %122
  %124 = fadd double %113, %123
  %125 = fmul double %90, %124
  %126 = fsub double %121, %117
  %127 = fadd double %126, %125
  %128 = fadd double %113, %127
  %129 = fdiv double %128, %91
  %130 = fadd double %121, %117
  %131 = fadd double %125, %130
  %132 = fsub double %131, %129
  %133 = fmul double %90, %132
  %134 = fadd double %121, %133
  %135 = fsub double %134, %125
  %136 = fadd double %129, %135
  %137 = fmul double %90, %136
  %138 = fsub double %133, %137
  %139 = fadd double %125, %138
  %140 = fadd double %129, %139
  %141 = fmul double %90, %140
  %142 = fsub double %137, %133
  %143 = fadd double %142, %141
  %144 = fadd double %129, %143
  %145 = fdiv double %144, %91
  %146 = fadd double %137, %133
  %147 = fadd double %141, %146
  %148 = fsub double %147, %145
  %149 = fmul double %90, %148
  %150 = fadd double %137, %149
  %151 = fsub double %150, %141
  %152 = fadd double %145, %151
  %153 = fmul double %90, %152
  %154 = fsub double %149, %153
  %155 = fadd double %141, %154
  %156 = fadd double %145, %155
  %157 = fmul double %90, %156
  %158 = fsub double %153, %149
  %159 = fadd double %158, %157
  %160 = fadd double %145, %159
  %161 = fdiv double %160, %91
  %162 = fadd double %153, %149
  %163 = fadd double %157, %162
  %164 = fsub double %163, %161
  %165 = fmul double %90, %164
  %166 = fadd double %153, %165
  %167 = fsub double %166, %157
  %168 = fadd double %161, %167
  %169 = fmul double %90, %168
  %170 = fsub double %165, %169
  %171 = fadd double %157, %170
  %172 = fadd double %161, %171
  %173 = fmul double %90, %172
  %174 = fsub double %169, %165
  %175 = fadd double %174, %173
  %176 = fadd double %161, %175
  %177 = fdiv double %176, %91
  %178 = fadd double %169, %165
  %179 = fadd double %173, %178
  %180 = fsub double %179, %177
  %181 = fmul double %90, %180
  %182 = fadd double %169, %181
  %183 = fsub double %182, %173
  %184 = fadd double %177, %183
  %185 = fmul double %90, %184
  %186 = fsub double %181, %185
  %187 = fadd double %173, %186
  %188 = fadd double %177, %187
  %189 = fmul double %90, %188
  %190 = fsub double %185, %181
  %191 = fadd double %190, %189
  %192 = fadd double %177, %191
  %193 = fdiv double %192, %91
  %194 = add nuw nsw i64 %93, 1
  %195 = icmp eq i64 %93, %20
  br i1 %195, label %196, label %92, !llvm.loop !21

196:                                              ; preds = %92
  store double %181, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 8), align 8, !tbaa !17
  store double %185, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 16), align 16, !tbaa !17
  store double %189, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 24), align 8, !tbaa !17
  store double %193, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 32), align 16, !tbaa !17
  %197 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.3, i64 noundef %12, i64 noundef %11, i64 noundef %11, double noundef %181, double noundef %185, double noundef %189, double noundef %193)
  br i1 %25, label %209, label %198

198:                                              ; preds = %196, %198
  %199 = phi i64 [ %204, %198 ], [ 0, %196 ]
  %200 = phi <4 x i32> [ %202, %198 ], [ <i32 1, i32 0, i32 0, i32 0>, %196 ]
  %201 = phi <4 x i32> [ %203, %198 ], [ zeroinitializer, %196 ]
  %202 = xor <4 x i32> %200, splat (i32 1)
  %203 = xor <4 x i32> %201, splat (i32 1)
  %204 = add nuw i64 %199, 8
  %205 = icmp eq i64 %204, %26
  br i1 %205, label %206, label %198, !llvm.loop !22

206:                                              ; preds = %198
  %207 = xor <4 x i32> %201, %200
  %208 = tail call i32 @llvm.vector.reduce.xor.v4i32(<4 x i32> %207)
  br i1 %28, label %218, label %209

209:                                              ; preds = %196, %206
  %210 = phi i64 [ 1, %196 ], [ %27, %206 ]
  %211 = phi i32 [ 1, %196 ], [ %208, %206 ]
  br label %212

212:                                              ; preds = %209, %212
  %213 = phi i64 [ %216, %212 ], [ %210, %209 ]
  %214 = phi i32 [ %215, %212 ], [ %211, %209 ]
  %215 = xor i32 %214, 1
  %216 = add nuw i64 %213, 1
  %217 = icmp eq i64 %213, %21
  br i1 %217, label %218, label %212, !llvm.loop !25

218:                                              ; preds = %212, %206
  %219 = phi i32 [ %208, %206 ], [ %215, %212 ]
  store i32 %219, ptr @J, align 4, !tbaa !20
  %220 = zext nneg i32 %219 to i64
  %221 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.3, i64 noundef %13, i64 noundef %220, i64 noundef %220, double noundef 1.000000e+00, double noundef -1.000000e+00, double noundef -1.000000e+00, double noundef -1.000000e+00)
  store <2 x double> splat (double 6.000000e+00), ptr getelementptr inbounds nuw (i8, ptr @E1, i64 8), align 8, !tbaa !17
  store i32 1, ptr @J, align 4, !tbaa !20
  store i32 2, ptr @K, align 4, !tbaa !20
  store i32 3, ptr @L, align 4, !tbaa !20
  %222 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 16), align 16, !tbaa !17
  %223 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 24), align 8, !tbaa !17
  %224 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 32), align 16, !tbaa !17
  %225 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.3, i64 noundef %14, i64 noundef 1, i64 noundef 2, double noundef 6.000000e+00, double noundef %222, double noundef %223, double noundef %224)
  %226 = load double, ptr @T, align 8, !tbaa !17
  %227 = load double, ptr @T2, align 8, !tbaa !17
  br label %228

228:                                              ; preds = %218, %228
  %229 = phi i64 [ 1, %218 ], [ %258, %228 ]
  %230 = phi double [ 5.000000e-01, %218 ], [ %257, %228 ]
  %231 = phi double [ 5.000000e-01, %218 ], [ %244, %228 ]
  %232 = tail call double @sin(double noundef %231) #12
  %233 = fmul double %227, %232
  %234 = tail call double @cos(double noundef %231) #12
  %235 = fmul double %233, %234
  %236 = fadd double %231, %230
  %237 = tail call double @cos(double noundef %236) #12
  %238 = fsub double %231, %230
  %239 = tail call double @cos(double noundef %238) #12
  %240 = fadd double %237, %239
  %241 = fadd double %240, -1.000000e+00
  %242 = fdiv double %235, %241
  %243 = tail call double @atan(double noundef %242) #12
  %244 = fmul double %226, %243
  %245 = tail call double @sin(double noundef %230) #12
  %246 = fmul double %227, %245
  %247 = tail call double @cos(double noundef %230) #12
  %248 = fmul double %246, %247
  %249 = fadd double %230, %244
  %250 = tail call double @cos(double noundef %249) #12
  %251 = fsub double %244, %230
  %252 = tail call double @cos(double noundef %251) #12
  %253 = fadd double %250, %252
  %254 = fadd double %253, -1.000000e+00
  %255 = fdiv double %248, %254
  %256 = tail call double @atan(double noundef %255) #12
  %257 = fmul double %226, %256
  %258 = add nuw nsw i64 %229, 1
  %259 = icmp eq i64 %229, %22
  br i1 %259, label %260, label %228, !llvm.loop !26

260:                                              ; preds = %228
  %261 = load i32, ptr @J, align 4, !tbaa !20
  %262 = sext i32 %261 to i64
  %263 = load i32, ptr @K, align 4, !tbaa !20
  %264 = sext i32 %263 to i64
  %265 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.3, i64 noundef %15, i64 noundef %262, i64 noundef %264, double noundef %244, double noundef %244, double noundef %257, double noundef %257)
  %266 = load double, ptr @T, align 8, !tbaa !17
  %267 = fmul double %266, 2.000000e+00
  %268 = fadd double %267, 1.000000e+00
  %269 = fmul double %266, %268
  %270 = fadd double %267, %269
  %271 = load double, ptr @T2, align 8, !tbaa !17
  %272 = fdiv double %270, %271
  %273 = load i32, ptr @J, align 4, !tbaa !20
  %274 = sext i32 %273 to i64
  %275 = load i32, ptr @K, align 4, !tbaa !20
  %276 = sext i32 %275 to i64
  %277 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.3, i64 noundef %16, i64 noundef %274, i64 noundef %276, double noundef 1.000000e+00, double noundef 1.000000e+00, double noundef %272, double noundef %272)
  store i32 1, ptr @J, align 4, !tbaa !20
  store i32 2, ptr @K, align 4, !tbaa !20
  store i32 3, ptr @L, align 4, !tbaa !20
  br i1 %30, label %283, label %278

278:                                              ; preds = %260, %278
  %279 = phi i64 [ %280, %278 ], [ 0, %260 ]
  %280 = add i64 %279, 8
  %281 = icmp eq i64 %280, %31
  br i1 %281, label %282, label %278, !llvm.loop !27

282:                                              ; preds = %278
  br i1 %32, label %290, label %283

283:                                              ; preds = %282, %260
  tail call void @llvm.assume(i1 %33)
  br label %284

284:                                              ; preds = %284, %283
  %285 = phi double [ %286, %284 ], [ 2.000000e+00, %283 ]
  %286 = phi double [ %285, %284 ], [ 3.000000e+00, %283 ]
  %287 = phi i64 [ %288, %284 ], [ 0, %283 ]
  %288 = add i64 %287, 1
  %289 = icmp eq i64 %287, 0
  br i1 %289, label %290, label %284, !llvm.loop !28

290:                                              ; preds = %284, %282
  %291 = phi double [ 3.000000e+00, %282 ], [ %285, %284 ]
  %292 = phi double [ 2.000000e+00, %282 ], [ %286, %284 ]
  store double %291, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 8), align 8, !tbaa !17
  store double %292, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 16), align 16, !tbaa !17
  store double %291, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 24), align 8, !tbaa !17
  %293 = load double, ptr getelementptr inbounds nuw (i8, ptr @E1, i64 32), align 16, !tbaa !17
  %294 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.3, i64 noundef %17, i64 noundef 1, i64 noundef 2, double noundef %291, double noundef %292, double noundef %291, double noundef %293)
  store i32 2, ptr @J, align 4, !tbaa !20
  store i32 3, ptr @K, align 4, !tbaa !20
  %295 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.3, i64 noundef 0, i64 noundef 2, i64 noundef 3, double noundef 1.000000e+00, double noundef -1.000000e+00, double noundef -1.000000e+00, double noundef -1.000000e+00)
  %296 = load double, ptr @T1, align 8, !tbaa !17
  br label %297

297:                                              ; preds = %290, %297
  %298 = phi i64 [ 1, %290 ], [ %304, %297 ]
  %299 = phi double [ 7.500000e-01, %290 ], [ %303, %297 ]
  %300 = tail call double @log(double noundef %299) #12
  %301 = fdiv double %300, %296
  %302 = tail call double @exp(double noundef %301) #12
  %303 = tail call double @sqrt(double noundef %302) #12
  %304 = add nuw i64 %298, 1
  %305 = icmp eq i64 %298, %24
  br i1 %305, label %306, label %297, !llvm.loop !30

306:                                              ; preds = %297
  %307 = load i32, ptr @J, align 4, !tbaa !20
  %308 = sext i32 %307 to i64
  %309 = load i32, ptr @K, align 4, !tbaa !20
  %310 = sext i32 %309 to i64
  %311 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.3, i64 noundef %18, i64 noundef %308, i64 noundef %310, double noundef %303, double noundef %303, double noundef %303, double noundef %303)
  %312 = tail call i64 @time(ptr noundef null) #12
  %313 = tail call i32 @putchar(i32 10)
  br i1 %10, label %314, label %56

314:                                              ; preds = %306, %48
  %315 = phi i32 [ 1, %48 ], [ 0, %306 ]
  ret i32 %315
}

; Function Attrs: nounwind
declare i64 @time(ptr noundef) local_unnamed_addr #1

; Function Attrs: nofree nounwind uwtable
define dso_local void @POUT(i64 noundef %0, i64 noundef %1, i64 noundef %2, double noundef %3, double noundef %4, double noundef %5, double noundef %6) local_unnamed_addr #2 {
  %8 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.3, i64 noundef %0, i64 noundef %1, i64 noundef %2, double noundef %3, double noundef %4, double noundef %5, double noundef %6)
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @PA(ptr nofree noundef captures(none) %0) local_unnamed_addr #3 {
  %2 = getelementptr inbounds nuw i8, ptr %0, i64 32
  %3 = load double, ptr %2, align 8, !tbaa !17
  %4 = getelementptr inbounds nuw i8, ptr %0, i64 24
  %5 = load double, ptr %4, align 8, !tbaa !17
  %6 = getelementptr inbounds nuw i8, ptr %0, i64 16
  %7 = load double, ptr %6, align 8, !tbaa !17
  %8 = getelementptr inbounds nuw i8, ptr %0, i64 8
  %9 = load double, ptr %8, align 8, !tbaa !17
  %10 = load double, ptr @T2, align 8, !tbaa !17
  %11 = load double, ptr @T, align 8, !tbaa !17
  %12 = fadd double %9, %7
  %13 = fadd double %12, %5
  %14 = fsub double %13, %3
  %15 = fmul double %14, %11
  %16 = fadd double %7, %15
  %17 = fsub double %16, %5
  %18 = fadd double %3, %17
  %19 = fmul double %11, %18
  %20 = fsub double %15, %19
  %21 = fadd double %5, %20
  %22 = fadd double %3, %21
  %23 = fmul double %11, %22
  %24 = fsub double %19, %15
  %25 = fadd double %24, %23
  %26 = fadd double %3, %25
  %27 = fdiv double %26, %10
  %28 = fadd double %15, %19
  %29 = fadd double %28, %23
  %30 = fsub double %29, %27
  %31 = fmul double %30, %11
  %32 = fadd double %19, %31
  %33 = fsub double %32, %23
  %34 = fadd double %27, %33
  %35 = fmul double %11, %34
  %36 = fsub double %31, %35
  %37 = fadd double %23, %36
  %38 = fadd double %27, %37
  %39 = fmul double %11, %38
  %40 = fsub double %35, %31
  %41 = fadd double %40, %39
  %42 = fadd double %27, %41
  %43 = fdiv double %42, %10
  %44 = fadd double %31, %35
  %45 = fadd double %44, %39
  %46 = fsub double %45, %43
  %47 = fmul double %46, %11
  %48 = fadd double %35, %47
  %49 = fsub double %48, %39
  %50 = fadd double %43, %49
  %51 = fmul double %11, %50
  %52 = fsub double %47, %51
  %53 = fadd double %39, %52
  %54 = fadd double %43, %53
  %55 = fmul double %11, %54
  %56 = fsub double %51, %47
  %57 = fadd double %56, %55
  %58 = fadd double %43, %57
  %59 = fdiv double %58, %10
  %60 = fadd double %47, %51
  %61 = fadd double %60, %55
  %62 = fsub double %61, %59
  %63 = fmul double %62, %11
  %64 = fadd double %51, %63
  %65 = fsub double %64, %55
  %66 = fadd double %59, %65
  %67 = fmul double %11, %66
  %68 = fsub double %63, %67
  %69 = fadd double %55, %68
  %70 = fadd double %59, %69
  %71 = fmul double %11, %70
  %72 = fsub double %67, %63
  %73 = fadd double %72, %71
  %74 = fadd double %59, %73
  %75 = fdiv double %74, %10
  %76 = fadd double %63, %67
  %77 = fadd double %76, %71
  %78 = fsub double %77, %75
  %79 = fmul double %78, %11
  %80 = fadd double %67, %79
  %81 = fsub double %80, %71
  %82 = fadd double %75, %81
  %83 = fmul double %11, %82
  %84 = fsub double %79, %83
  %85 = fadd double %71, %84
  %86 = fadd double %75, %85
  %87 = fmul double %11, %86
  %88 = fsub double %83, %79
  %89 = fadd double %88, %87
  %90 = fadd double %75, %89
  %91 = fdiv double %90, %10
  %92 = fadd double %79, %83
  %93 = fadd double %92, %87
  %94 = fsub double %93, %91
  %95 = fmul double %94, %11
  %96 = fadd double %83, %95
  %97 = fsub double %96, %87
  %98 = fadd double %91, %97
  %99 = fmul double %11, %98
  %100 = fsub double %95, %99
  %101 = fadd double %87, %100
  %102 = fadd double %91, %101
  %103 = fmul double %11, %102
  %104 = fsub double %99, %95
  %105 = fadd double %104, %103
  %106 = fadd double %91, %105
  %107 = fdiv double %106, %10
  store double %95, ptr %8, align 8, !tbaa !17
  store double %99, ptr %6, align 8, !tbaa !17
  store double %103, ptr %4, align 8, !tbaa !17
  store double %107, ptr %2, align 8, !tbaa !17
  store i32 6, ptr @J, align 4, !tbaa !20
  ret void
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @atan(double noundef) local_unnamed_addr #4

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @sin(double noundef) local_unnamed_addr #4

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @cos(double noundef) local_unnamed_addr #4

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(read, argmem: write, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @P3(double noundef %0, double noundef %1, ptr nofree noundef writeonly captures(none) initializes((0, 8)) %2) local_unnamed_addr #5 {
  %4 = load double, ptr @T, align 8, !tbaa !17
  %5 = fadd double %0, %1
  %6 = fmul double %5, %4
  %7 = fadd double %1, %6
  %8 = fmul double %4, %7
  %9 = fadd double %6, %8
  %10 = load double, ptr @T2, align 8, !tbaa !17
  %11 = fdiv double %9, %10
  store double %11, ptr %2, align 8, !tbaa !17
  ret void
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @P0() local_unnamed_addr #6 {
  %1 = load i32, ptr @K, align 4, !tbaa !20
  %2 = sext i32 %1 to i64
  %3 = getelementptr inbounds [8 x i8], ptr @E1, i64 %2
  %4 = load double, ptr %3, align 8, !tbaa !17
  %5 = load i32, ptr @J, align 4, !tbaa !20
  %6 = sext i32 %5 to i64
  %7 = getelementptr inbounds [8 x i8], ptr @E1, i64 %6
  store double %4, ptr %7, align 8, !tbaa !17
  %8 = load i32, ptr @L, align 4, !tbaa !20
  %9 = sext i32 %8 to i64
  %10 = getelementptr inbounds [8 x i8], ptr @E1, i64 %9
  %11 = load double, ptr %10, align 8, !tbaa !17
  store double %11, ptr %3, align 8, !tbaa !17
  %12 = load double, ptr %7, align 8, !tbaa !17
  store double %12, ptr %10, align 8, !tbaa !17
  ret void
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @sqrt(double noundef) local_unnamed_addr #4

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @exp(double noundef) local_unnamed_addr #4

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @log(double noundef) local_unnamed_addr #4

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #7

; Function Attrs: mustprogress nocallback nofree nounwind willreturn
declare i64 @strtol(ptr noundef readonly, ptr noundef captures(none), i32 noundef) local_unnamed_addr #8

; Function Attrs: nofree nounwind
declare noundef i32 @putchar(i32 noundef) local_unnamed_addr #9

; Function Attrs: nofree nounwind
declare noundef i64 @fwrite(ptr noundef readonly captures(none), i64 noundef, i64 noundef, ptr noundef captures(none)) local_unnamed_addr #9

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.smax.i64(i64, i64) #10

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.vector.reduce.xor.v4i32(<4 x i32>) #10

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write)
declare void @llvm.assume(i1 noundef) #11

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nofree norecurse nosync nounwind memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { mustprogress nofree norecurse nosync nounwind willreturn memory(read, argmem: write, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #7 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #8 = { mustprogress nocallback nofree nounwind willreturn "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #9 = { nofree nounwind }
attributes #10 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #11 = { nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write) }
attributes #12 = { nounwind }
attributes #13 = { cold }

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
!10 = !{!"p1 omnipotent char", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = distinct !{null}
!13 = !{!14, !14, i64 0}
!14 = !{!"p1 _ZTS8_IO_FILE", !11, i64 0}
!15 = distinct !{!15, !16}
!16 = !{!"llvm.loop.mustprogress"}
!17 = !{!18, !18, i64 0}
!18 = !{!"double", !7, i64 0}
!19 = distinct !{!19, !16}
!20 = !{!6, !6, i64 0}
!21 = distinct !{!21, !16}
!22 = distinct !{!22, !16, !23, !24}
!23 = !{!"llvm.loop.isvectorized", i32 1}
!24 = !{!"llvm.loop.unroll.runtime.disable"}
!25 = distinct !{!25, !16, !24, !23}
!26 = distinct !{!26, !16}
!27 = distinct !{!27, !16}
!28 = distinct !{!28, !29}
!29 = !{!"llvm.loop.unroll.disable"}
!30 = distinct !{!30, !16}
