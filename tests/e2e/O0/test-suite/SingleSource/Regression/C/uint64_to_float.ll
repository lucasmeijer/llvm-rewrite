; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/uint64_to_float.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/uint64_to_float.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/uint64_to_float.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%union.float_bits = type { i32 }

@.str = private unnamed_addr constant [28 x i8] c"Error detected @ 0x%016llx\0A\00", align 1
@.str.1 = private unnamed_addr constant [31 x i8] c"\09Expected result: %a (0x%08x)\0A\00", align 1
@.str.2 = private unnamed_addr constant [31 x i8] c"\09Observed result: %a (0x%08x)\0A\00", align 1
@.str.3 = private unnamed_addr constant [11 x i8] c"to nearest\00", align 1
@.str.4 = private unnamed_addr constant [5 x i8] c"down\00", align 1
@.str.5 = private unnamed_addr constant [3 x i8] c"up\00", align 1
@.str.6 = private unnamed_addr constant [13 x i8] c"towards zero\00", align 1
@__const.main.modeNames = private unnamed_addr constant [4 x ptr] [ptr @.str.3, ptr @.str.4, ptr @.str.5, ptr @.str.6], align 16
@.str.7 = private unnamed_addr constant [55 x i8] c"Testing uint64_t --> float conversions in round %s...\0A\00", align 1
@.str.8 = private unnamed_addr constant [19 x i8] c"Finished Testing.\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local float @floatundisf(i64 noundef %0) #0 {
  %2 = alloca float, align 4
  %3 = alloca i64, align 8
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca %union.float_bits, align 4
  store i64 %0, ptr %3, align 8
  %8 = load i64, ptr %3, align 8
  %9 = icmp eq i64 %8, 0
  br i1 %9, label %10, label %11

10:                                               ; preds = %1
  store float 0.000000e+00, ptr %2, align 4
  br label %78

11:                                               ; preds = %1
  store i32 64, ptr %4, align 4
  %12 = load i64, ptr %3, align 8
  %13 = call i64 @llvm.ctlz.i64(i64 %12, i1 true)
  %14 = trunc i64 %13 to i32
  %15 = sub i32 64, %14
  store i32 %15, ptr %5, align 4
  %16 = load i32, ptr %5, align 4
  %17 = sub nsw i32 %16, 1
  store i32 %17, ptr %6, align 4
  %18 = load i32, ptr %5, align 4
  %19 = icmp sgt i32 %18, 24
  br i1 %19, label %20, label %63

20:                                               ; preds = %11
  %21 = load i32, ptr %5, align 4
  switch i32 %21, label %26 [
    i32 25, label %22
    i32 26, label %25
  ]

22:                                               ; preds = %20
  %23 = load i64, ptr %3, align 8
  %24 = shl i64 %23, 1
  store i64 %24, ptr %3, align 8
  br label %42

25:                                               ; preds = %20
  br label %42

26:                                               ; preds = %20
  %27 = load i64, ptr %3, align 8
  %28 = load i32, ptr %5, align 4
  %29 = sub nsw i32 %28, 26
  %30 = zext i32 %29 to i64
  %31 = lshr i64 %27, %30
  %32 = load i64, ptr %3, align 8
  %33 = load i32, ptr %5, align 4
  %34 = sub i32 90, %33
  %35 = zext i32 %34 to i64
  %36 = lshr i64 -1, %35
  %37 = and i64 %32, %36
  %38 = icmp ne i64 %37, 0
  %39 = zext i1 %38 to i32
  %40 = sext i32 %39 to i64
  %41 = or i64 %31, %40
  store i64 %41, ptr %3, align 8
  br label %42

42:                                               ; preds = %26, %25, %22
  %43 = load i64, ptr %3, align 8
  %44 = and i64 %43, 4
  %45 = icmp ne i64 %44, 0
  %46 = zext i1 %45 to i32
  %47 = sext i32 %46 to i64
  %48 = load i64, ptr %3, align 8
  %49 = or i64 %48, %47
  store i64 %49, ptr %3, align 8
  %50 = load i64, ptr %3, align 8
  %51 = add i64 %50, 1
  store i64 %51, ptr %3, align 8
  %52 = load i64, ptr %3, align 8
  %53 = lshr i64 %52, 2
  store i64 %53, ptr %3, align 8
  %54 = load i64, ptr %3, align 8
  %55 = and i64 %54, 16777216
  %56 = icmp ne i64 %55, 0
  br i1 %56, label %57, label %62

57:                                               ; preds = %42
  %58 = load i64, ptr %3, align 8
  %59 = lshr i64 %58, 1
  store i64 %59, ptr %3, align 8
  %60 = load i32, ptr %6, align 4
  %61 = add nsw i32 %60, 1
  store i32 %61, ptr %6, align 4
  br label %62

62:                                               ; preds = %57, %42
  br label %69

63:                                               ; preds = %11
  %64 = load i32, ptr %5, align 4
  %65 = sub nsw i32 24, %64
  %66 = load i64, ptr %3, align 8
  %67 = zext i32 %65 to i64
  %68 = shl i64 %66, %67
  store i64 %68, ptr %3, align 8
  br label %69

69:                                               ; preds = %63, %62
  %70 = load i32, ptr %6, align 4
  %71 = add nsw i32 %70, 127
  %72 = shl i32 %71, 23
  %73 = load i64, ptr %3, align 8
  %74 = trunc i64 %73 to i32
  %75 = and i32 %74, 8388607
  %76 = or i32 %72, %75
  store i32 %76, ptr %7, align 4
  %77 = load float, ptr %7, align 4
  store float %77, ptr %2, align 4
  br label %78

78:                                               ; preds = %69, %10
  %79 = load float, ptr %2, align 4
  ret float %79
}

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.ctlz.i64(i64, i1 immarg) #1

; Function Attrs: noinline nounwind uwtable
define dso_local void @test(i64 noundef %0) #0 {
  %2 = alloca i64, align 8
  %3 = alloca %union.float_bits, align 4
  %4 = alloca %union.float_bits, align 4
  store i64 %0, ptr %2, align 8
  %5 = load i64, ptr %2, align 8
  %6 = call float @floatundisf(i64 noundef %5)
  store float %6, ptr %3, align 4
  %7 = load i64, ptr %2, align 8
  %8 = uitofp i64 %7 to float
  store float %8, ptr %4, align 4
  %9 = load i32, ptr %3, align 4
  %10 = load i32, ptr %4, align 4
  %11 = icmp ne i32 %9, %10
  br i1 %11, label %12, label %23

12:                                               ; preds = %1
  %13 = load i64, ptr %2, align 8
  %14 = call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef %13)
  %15 = load float, ptr %3, align 4
  %16 = fpext float %15 to double
  %17 = load i32, ptr %3, align 4
  %18 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, double noundef %16, i32 noundef %17)
  %19 = load float, ptr %4, align 4
  %20 = fpext float %19 to double
  %21 = load i32, ptr %4, align 4
  %22 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, double noundef %20, i32 noundef %21)
  br label %23

23:                                               ; preds = %12, %1
  ret void
}

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  %11 = alloca i64, align 8
  %12 = alloca i64, align 8
  %13 = alloca [4 x i32], align 16
  %14 = alloca [4 x ptr], align 16
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4
  store ptr %1, ptr %5, align 8
  store i64 1, ptr %11, align 8
  store i64 -1, ptr %12, align 8
  call void @llvm.memset.p0.i64(ptr align 16 %13, i8 0, i64 16, i1 false)
  call void @llvm.memcpy.p0.p0.i64(ptr align 16 %14, ptr align 16 @__const.main.modeNames, i64 32, i1 false)
  store i32 0, ptr %10, align 4
  br label %15

15:                                               ; preds = %424, %2
  %16 = load i32, ptr %10, align 4
  %17 = icmp slt i32 %16, 4
  br i1 %17, label %18, label %427

18:                                               ; preds = %15
  %19 = getelementptr inbounds [4 x i32], ptr %13, i64 0, i64 0
  %20 = load i32, ptr %19, align 16
  %21 = call i32 @fesetround(i32 noundef %20) #6
  %22 = load i32, ptr %10, align 4
  %23 = sext i32 %22 to i64
  %24 = getelementptr inbounds [4 x ptr], ptr %14, i64 0, i64 %23
  %25 = load ptr, ptr %24, align 8
  %26 = call i32 (ptr, ...) @printf(ptr noundef @.str.7, ptr noundef %25)
  call void @test(i64 noundef 0)
  store i32 0, ptr %6, align 4
  br label %27

27:                                               ; preds = %420, %18
  %28 = load i32, ptr %6, align 4
  %29 = icmp slt i32 %28, 64
  br i1 %29, label %30, label %423

30:                                               ; preds = %27
  %31 = load i32, ptr %6, align 4
  %32 = zext i32 %31 to i64
  %33 = shl i64 1, %32
  call void @test(i64 noundef %33)
  %34 = load i32, ptr %6, align 4
  %35 = zext i32 %34 to i64
  %36 = shl i64 -1, %35
  call void @test(i64 noundef %36)
  store i32 0, ptr %7, align 4
  br label %37

37:                                               ; preds = %416, %30
  %38 = load i32, ptr %7, align 4
  %39 = load i32, ptr %6, align 4
  %40 = icmp slt i32 %38, %39
  br i1 %40, label %41, label %419

41:                                               ; preds = %37
  %42 = load i32, ptr %6, align 4
  %43 = zext i32 %42 to i64
  %44 = shl i64 1, %43
  %45 = load i32, ptr %7, align 4
  %46 = zext i32 %45 to i64
  %47 = shl i64 1, %46
  %48 = add i64 %44, %47
  call void @test(i64 noundef %48)
  %49 = load i32, ptr %6, align 4
  %50 = zext i32 %49 to i64
  %51 = shl i64 1, %50
  %52 = load i32, ptr %7, align 4
  %53 = zext i32 %52 to i64
  %54 = shl i64 -1, %53
  %55 = add i64 %51, %54
  call void @test(i64 noundef %55)
  %56 = load i32, ptr %6, align 4
  %57 = zext i32 %56 to i64
  %58 = shl i64 -1, %57
  %59 = load i32, ptr %7, align 4
  %60 = zext i32 %59 to i64
  %61 = shl i64 1, %60
  %62 = add i64 %58, %61
  call void @test(i64 noundef %62)
  %63 = load i32, ptr %6, align 4
  %64 = zext i32 %63 to i64
  %65 = shl i64 -1, %64
  %66 = load i32, ptr %7, align 4
  %67 = zext i32 %66 to i64
  %68 = shl i64 -1, %67
  %69 = add i64 %65, %68
  call void @test(i64 noundef %69)
  store i32 0, ptr %8, align 4
  br label %70

70:                                               ; preds = %412, %41
  %71 = load i32, ptr %8, align 4
  %72 = load i32, ptr %7, align 4
  %73 = icmp slt i32 %71, %72
  br i1 %73, label %74, label %415

74:                                               ; preds = %70
  %75 = load i32, ptr %6, align 4
  %76 = zext i32 %75 to i64
  %77 = shl i64 1, %76
  %78 = load i32, ptr %7, align 4
  %79 = zext i32 %78 to i64
  %80 = shl i64 1, %79
  %81 = add i64 %77, %80
  %82 = load i32, ptr %8, align 4
  %83 = zext i32 %82 to i64
  %84 = shl i64 1, %83
  %85 = add i64 %81, %84
  call void @test(i64 noundef %85)
  %86 = load i32, ptr %6, align 4
  %87 = zext i32 %86 to i64
  %88 = shl i64 1, %87
  %89 = load i32, ptr %7, align 4
  %90 = zext i32 %89 to i64
  %91 = shl i64 1, %90
  %92 = add i64 %88, %91
  %93 = load i32, ptr %8, align 4
  %94 = zext i32 %93 to i64
  %95 = shl i64 -1, %94
  %96 = add i64 %92, %95
  call void @test(i64 noundef %96)
  %97 = load i32, ptr %6, align 4
  %98 = zext i32 %97 to i64
  %99 = shl i64 1, %98
  %100 = load i32, ptr %7, align 4
  %101 = zext i32 %100 to i64
  %102 = shl i64 -1, %101
  %103 = add i64 %99, %102
  %104 = load i32, ptr %8, align 4
  %105 = zext i32 %104 to i64
  %106 = shl i64 1, %105
  %107 = add i64 %103, %106
  call void @test(i64 noundef %107)
  %108 = load i32, ptr %6, align 4
  %109 = zext i32 %108 to i64
  %110 = shl i64 1, %109
  %111 = load i32, ptr %7, align 4
  %112 = zext i32 %111 to i64
  %113 = shl i64 -1, %112
  %114 = add i64 %110, %113
  %115 = load i32, ptr %8, align 4
  %116 = zext i32 %115 to i64
  %117 = shl i64 -1, %116
  %118 = add i64 %114, %117
  call void @test(i64 noundef %118)
  %119 = load i32, ptr %6, align 4
  %120 = zext i32 %119 to i64
  %121 = shl i64 -1, %120
  %122 = load i32, ptr %7, align 4
  %123 = zext i32 %122 to i64
  %124 = shl i64 1, %123
  %125 = add i64 %121, %124
  %126 = load i32, ptr %8, align 4
  %127 = zext i32 %126 to i64
  %128 = shl i64 1, %127
  %129 = add i64 %125, %128
  call void @test(i64 noundef %129)
  %130 = load i32, ptr %6, align 4
  %131 = zext i32 %130 to i64
  %132 = shl i64 -1, %131
  %133 = load i32, ptr %7, align 4
  %134 = zext i32 %133 to i64
  %135 = shl i64 1, %134
  %136 = add i64 %132, %135
  %137 = load i32, ptr %8, align 4
  %138 = zext i32 %137 to i64
  %139 = shl i64 -1, %138
  %140 = add i64 %136, %139
  call void @test(i64 noundef %140)
  %141 = load i32, ptr %6, align 4
  %142 = zext i32 %141 to i64
  %143 = shl i64 -1, %142
  %144 = load i32, ptr %7, align 4
  %145 = zext i32 %144 to i64
  %146 = shl i64 -1, %145
  %147 = add i64 %143, %146
  %148 = load i32, ptr %8, align 4
  %149 = zext i32 %148 to i64
  %150 = shl i64 1, %149
  %151 = add i64 %147, %150
  call void @test(i64 noundef %151)
  %152 = load i32, ptr %6, align 4
  %153 = zext i32 %152 to i64
  %154 = shl i64 -1, %153
  %155 = load i32, ptr %7, align 4
  %156 = zext i32 %155 to i64
  %157 = shl i64 -1, %156
  %158 = add i64 %154, %157
  %159 = load i32, ptr %8, align 4
  %160 = zext i32 %159 to i64
  %161 = shl i64 -1, %160
  %162 = add i64 %158, %161
  call void @test(i64 noundef %162)
  store i32 0, ptr %9, align 4
  br label %163

163:                                              ; preds = %408, %74
  %164 = load i32, ptr %9, align 4
  %165 = load i32, ptr %8, align 4
  %166 = icmp slt i32 %164, %165
  br i1 %166, label %167, label %411

167:                                              ; preds = %163
  %168 = load i32, ptr %6, align 4
  %169 = zext i32 %168 to i64
  %170 = shl i64 1, %169
  %171 = load i32, ptr %7, align 4
  %172 = zext i32 %171 to i64
  %173 = shl i64 1, %172
  %174 = add i64 %170, %173
  %175 = load i32, ptr %8, align 4
  %176 = zext i32 %175 to i64
  %177 = shl i64 1, %176
  %178 = add i64 %174, %177
  %179 = load i32, ptr %9, align 4
  %180 = zext i32 %179 to i64
  %181 = shl i64 1, %180
  %182 = add i64 %178, %181
  call void @test(i64 noundef %182)
  %183 = load i32, ptr %6, align 4
  %184 = zext i32 %183 to i64
  %185 = shl i64 1, %184
  %186 = load i32, ptr %7, align 4
  %187 = zext i32 %186 to i64
  %188 = shl i64 1, %187
  %189 = add i64 %185, %188
  %190 = load i32, ptr %8, align 4
  %191 = zext i32 %190 to i64
  %192 = shl i64 1, %191
  %193 = add i64 %189, %192
  %194 = load i32, ptr %9, align 4
  %195 = zext i32 %194 to i64
  %196 = shl i64 -1, %195
  %197 = add i64 %193, %196
  call void @test(i64 noundef %197)
  %198 = load i32, ptr %6, align 4
  %199 = zext i32 %198 to i64
  %200 = shl i64 1, %199
  %201 = load i32, ptr %7, align 4
  %202 = zext i32 %201 to i64
  %203 = shl i64 1, %202
  %204 = add i64 %200, %203
  %205 = load i32, ptr %8, align 4
  %206 = zext i32 %205 to i64
  %207 = shl i64 -1, %206
  %208 = add i64 %204, %207
  %209 = load i32, ptr %9, align 4
  %210 = zext i32 %209 to i64
  %211 = shl i64 1, %210
  %212 = add i64 %208, %211
  call void @test(i64 noundef %212)
  %213 = load i32, ptr %6, align 4
  %214 = zext i32 %213 to i64
  %215 = shl i64 1, %214
  %216 = load i32, ptr %7, align 4
  %217 = zext i32 %216 to i64
  %218 = shl i64 1, %217
  %219 = add i64 %215, %218
  %220 = load i32, ptr %8, align 4
  %221 = zext i32 %220 to i64
  %222 = shl i64 -1, %221
  %223 = add i64 %219, %222
  %224 = load i32, ptr %9, align 4
  %225 = zext i32 %224 to i64
  %226 = shl i64 -1, %225
  %227 = add i64 %223, %226
  call void @test(i64 noundef %227)
  %228 = load i32, ptr %6, align 4
  %229 = zext i32 %228 to i64
  %230 = shl i64 1, %229
  %231 = load i32, ptr %7, align 4
  %232 = zext i32 %231 to i64
  %233 = shl i64 -1, %232
  %234 = add i64 %230, %233
  %235 = load i32, ptr %8, align 4
  %236 = zext i32 %235 to i64
  %237 = shl i64 1, %236
  %238 = add i64 %234, %237
  %239 = load i32, ptr %9, align 4
  %240 = zext i32 %239 to i64
  %241 = shl i64 1, %240
  %242 = add i64 %238, %241
  call void @test(i64 noundef %242)
  %243 = load i32, ptr %6, align 4
  %244 = zext i32 %243 to i64
  %245 = shl i64 1, %244
  %246 = load i32, ptr %7, align 4
  %247 = zext i32 %246 to i64
  %248 = shl i64 -1, %247
  %249 = add i64 %245, %248
  %250 = load i32, ptr %8, align 4
  %251 = zext i32 %250 to i64
  %252 = shl i64 1, %251
  %253 = add i64 %249, %252
  %254 = load i32, ptr %9, align 4
  %255 = zext i32 %254 to i64
  %256 = shl i64 -1, %255
  %257 = add i64 %253, %256
  call void @test(i64 noundef %257)
  %258 = load i32, ptr %6, align 4
  %259 = zext i32 %258 to i64
  %260 = shl i64 1, %259
  %261 = load i32, ptr %7, align 4
  %262 = zext i32 %261 to i64
  %263 = shl i64 -1, %262
  %264 = add i64 %260, %263
  %265 = load i32, ptr %8, align 4
  %266 = zext i32 %265 to i64
  %267 = shl i64 -1, %266
  %268 = add i64 %264, %267
  %269 = load i32, ptr %9, align 4
  %270 = zext i32 %269 to i64
  %271 = shl i64 1, %270
  %272 = add i64 %268, %271
  call void @test(i64 noundef %272)
  %273 = load i32, ptr %6, align 4
  %274 = zext i32 %273 to i64
  %275 = shl i64 1, %274
  %276 = load i32, ptr %7, align 4
  %277 = zext i32 %276 to i64
  %278 = shl i64 -1, %277
  %279 = add i64 %275, %278
  %280 = load i32, ptr %8, align 4
  %281 = zext i32 %280 to i64
  %282 = shl i64 -1, %281
  %283 = add i64 %279, %282
  %284 = load i32, ptr %9, align 4
  %285 = zext i32 %284 to i64
  %286 = shl i64 -1, %285
  %287 = add i64 %283, %286
  call void @test(i64 noundef %287)
  %288 = load i32, ptr %6, align 4
  %289 = zext i32 %288 to i64
  %290 = shl i64 -1, %289
  %291 = load i32, ptr %7, align 4
  %292 = zext i32 %291 to i64
  %293 = shl i64 1, %292
  %294 = add i64 %290, %293
  %295 = load i32, ptr %8, align 4
  %296 = zext i32 %295 to i64
  %297 = shl i64 1, %296
  %298 = add i64 %294, %297
  %299 = load i32, ptr %9, align 4
  %300 = zext i32 %299 to i64
  %301 = shl i64 1, %300
  %302 = add i64 %298, %301
  call void @test(i64 noundef %302)
  %303 = load i32, ptr %6, align 4
  %304 = zext i32 %303 to i64
  %305 = shl i64 -1, %304
  %306 = load i32, ptr %7, align 4
  %307 = zext i32 %306 to i64
  %308 = shl i64 1, %307
  %309 = add i64 %305, %308
  %310 = load i32, ptr %8, align 4
  %311 = zext i32 %310 to i64
  %312 = shl i64 1, %311
  %313 = add i64 %309, %312
  %314 = load i32, ptr %9, align 4
  %315 = zext i32 %314 to i64
  %316 = shl i64 -1, %315
  %317 = add i64 %313, %316
  call void @test(i64 noundef %317)
  %318 = load i32, ptr %6, align 4
  %319 = zext i32 %318 to i64
  %320 = shl i64 -1, %319
  %321 = load i32, ptr %7, align 4
  %322 = zext i32 %321 to i64
  %323 = shl i64 1, %322
  %324 = add i64 %320, %323
  %325 = load i32, ptr %8, align 4
  %326 = zext i32 %325 to i64
  %327 = shl i64 -1, %326
  %328 = add i64 %324, %327
  %329 = load i32, ptr %9, align 4
  %330 = zext i32 %329 to i64
  %331 = shl i64 1, %330
  %332 = add i64 %328, %331
  call void @test(i64 noundef %332)
  %333 = load i32, ptr %6, align 4
  %334 = zext i32 %333 to i64
  %335 = shl i64 -1, %334
  %336 = load i32, ptr %7, align 4
  %337 = zext i32 %336 to i64
  %338 = shl i64 1, %337
  %339 = add i64 %335, %338
  %340 = load i32, ptr %8, align 4
  %341 = zext i32 %340 to i64
  %342 = shl i64 -1, %341
  %343 = add i64 %339, %342
  %344 = load i32, ptr %9, align 4
  %345 = zext i32 %344 to i64
  %346 = shl i64 -1, %345
  %347 = add i64 %343, %346
  call void @test(i64 noundef %347)
  %348 = load i32, ptr %6, align 4
  %349 = zext i32 %348 to i64
  %350 = shl i64 -1, %349
  %351 = load i32, ptr %7, align 4
  %352 = zext i32 %351 to i64
  %353 = shl i64 -1, %352
  %354 = add i64 %350, %353
  %355 = load i32, ptr %8, align 4
  %356 = zext i32 %355 to i64
  %357 = shl i64 1, %356
  %358 = add i64 %354, %357
  %359 = load i32, ptr %9, align 4
  %360 = zext i32 %359 to i64
  %361 = shl i64 1, %360
  %362 = add i64 %358, %361
  call void @test(i64 noundef %362)
  %363 = load i32, ptr %6, align 4
  %364 = zext i32 %363 to i64
  %365 = shl i64 -1, %364
  %366 = load i32, ptr %7, align 4
  %367 = zext i32 %366 to i64
  %368 = shl i64 -1, %367
  %369 = add i64 %365, %368
  %370 = load i32, ptr %8, align 4
  %371 = zext i32 %370 to i64
  %372 = shl i64 1, %371
  %373 = add i64 %369, %372
  %374 = load i32, ptr %9, align 4
  %375 = zext i32 %374 to i64
  %376 = shl i64 -1, %375
  %377 = add i64 %373, %376
  call void @test(i64 noundef %377)
  %378 = load i32, ptr %6, align 4
  %379 = zext i32 %378 to i64
  %380 = shl i64 -1, %379
  %381 = load i32, ptr %7, align 4
  %382 = zext i32 %381 to i64
  %383 = shl i64 -1, %382
  %384 = add i64 %380, %383
  %385 = load i32, ptr %8, align 4
  %386 = zext i32 %385 to i64
  %387 = shl i64 -1, %386
  %388 = add i64 %384, %387
  %389 = load i32, ptr %9, align 4
  %390 = zext i32 %389 to i64
  %391 = shl i64 1, %390
  %392 = add i64 %388, %391
  call void @test(i64 noundef %392)
  %393 = load i32, ptr %6, align 4
  %394 = zext i32 %393 to i64
  %395 = shl i64 -1, %394
  %396 = load i32, ptr %7, align 4
  %397 = zext i32 %396 to i64
  %398 = shl i64 -1, %397
  %399 = add i64 %395, %398
  %400 = load i32, ptr %8, align 4
  %401 = zext i32 %400 to i64
  %402 = shl i64 -1, %401
  %403 = add i64 %399, %402
  %404 = load i32, ptr %9, align 4
  %405 = zext i32 %404 to i64
  %406 = shl i64 -1, %405
  %407 = add i64 %403, %406
  call void @test(i64 noundef %407)
  br label %408

408:                                              ; preds = %167
  %409 = load i32, ptr %9, align 4
  %410 = add nsw i32 %409, 1
  store i32 %410, ptr %9, align 4
  br label %163, !llvm.loop !5

411:                                              ; preds = %163
  br label %412

412:                                              ; preds = %411
  %413 = load i32, ptr %8, align 4
  %414 = add nsw i32 %413, 1
  store i32 %414, ptr %8, align 4
  br label %70, !llvm.loop !7

415:                                              ; preds = %70
  br label %416

416:                                              ; preds = %415
  %417 = load i32, ptr %7, align 4
  %418 = add nsw i32 %417, 1
  store i32 %418, ptr %7, align 4
  br label %37, !llvm.loop !8

419:                                              ; preds = %37
  br label %420

420:                                              ; preds = %419
  %421 = load i32, ptr %6, align 4
  %422 = add nsw i32 %421, 1
  store i32 %422, ptr %6, align 4
  br label %27, !llvm.loop !9

423:                                              ; preds = %27
  br label %424

424:                                              ; preds = %423
  %425 = load i32, ptr %10, align 4
  %426 = add nsw i32 %425, 1
  store i32 %426, ptr %10, align 4
  br label %15, !llvm.loop !10

427:                                              ; preds = %15
  %428 = call i32 (ptr, ...) @printf(ptr noundef @.str.8)
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #4

; Function Attrs: nounwind
declare i32 @fesetround(i32 noundef) #5

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind speculatable willreturn memory(none) }
attributes #2 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #4 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #5 = { nounwind "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { nounwind }

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
