; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Linpack/linpack-pc.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Linpack/linpack-pc.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Linpack/linpack-pc.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@main.aa = internal global [40000 x float] zeroinitializer, align 16
@main.a = internal global [40200 x float] zeroinitializer, align 16
@main.b = internal global [200 x float] zeroinitializer, align 16
@main.x = internal global [200 x float] zeroinitializer, align 16
@main.ipvt = internal global [200 x i32] zeroinitializer, align 16
@main.j = internal unnamed_addr global i32 0, align 4
@main.ntimes = internal unnamed_addr global i32 0, align 4
@main.info = internal global i32 0, align 4
@.str = private unnamed_addr constant [26 x i8] c"INSERT COMPILER NAME HERE\00", align 1
@.str.1 = private unnamed_addr constant [33 x i8] c"INSERT OPTIMISATION OPTIONS HERE\00", align 1
@stderr = external local_unnamed_addr global ptr, align 8
@.str.2 = private unnamed_addr constant [8 x i8] c"Rolled \00", align 1
@.str.3 = private unnamed_addr constant [8 x i8] c"Single \00", align 1
@.str.4 = private unnamed_addr constant [54 x i8] c"Precision Linpack Benchmark - PC Version in 'C/C++'\0A\0A\00", align 1
@.str.5 = private unnamed_addr constant [17 x i8] c"Compiler     %s\0A\00", align 1
@.str.6 = private unnamed_addr constant [18 x i8] c"Optimisation %s\0A\0A\00", align 1
@atime = internal unnamed_addr global [9 x [15 x float]] zeroinitializer, align 16
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

; Function Attrs: nounwind uwtable
define dso_local float @second() local_unnamed_addr #0 {
  %1 = tail call i64 @clock() #13
  %2 = sitofp i64 %1 to float
  %3 = fdiv float %2, 1.000000e+06
  ret float %3
}

; Function Attrs: nounwind
declare i64 @clock() local_unnamed_addr #1

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local void @what_date() local_unnamed_addr #2 {
  ret void
}

; Function Attrs: cold nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #3 {
  %1 = load ptr, ptr @stderr, align 8, !tbaa !9
  %2 = tail call i64 @fwrite(ptr nonnull @.str.2, i64 7, i64 1, ptr %1) #14
  %3 = load ptr, ptr @stderr, align 8, !tbaa !9
  %4 = tail call i64 @fwrite(ptr nonnull @.str.3, i64 7, i64 1, ptr %3) #14
  %5 = load ptr, ptr @stderr, align 8, !tbaa !9
  %6 = tail call i64 @fwrite(ptr nonnull @.str.4, i64 53, i64 1, ptr %5) #14
  %7 = load ptr, ptr @stderr, align 8, !tbaa !9
  %8 = tail call i32 (ptr, ptr, ...) @fprintf(ptr noundef %7, ptr noundef nonnull @.str.5, ptr noundef nonnull @.str) #15
  %9 = load ptr, ptr @stderr, align 8, !tbaa !9
  %10 = tail call i32 (ptr, ptr, ...) @fprintf(ptr noundef %9, ptr noundef nonnull @.str.6, ptr noundef nonnull @.str.1) #15
  br label %11

11:                                               ; preds = %63, %0
  %12 = phi i64 [ 0, %0 ], [ %64, %63 ]
  %13 = phi i32 [ 1325, %0 ], [ %55, %63 ]
  %14 = mul nuw nsw i64 %12, 804
  %15 = getelementptr i8, ptr @main.a, i64 %14
  br label %45

16:                                               ; preds = %63
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(400) @main.b, i8 0, i64 400, i1 false), !tbaa !12
  %17 = load <4 x float>, ptr @main.b, align 16, !tbaa !12
  %18 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 16), align 16, !tbaa !12
  %19 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 32), align 16, !tbaa !12
  %20 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 48), align 16, !tbaa !12
  %21 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 64), align 16, !tbaa !12
  %22 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 80), align 16, !tbaa !12
  %23 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 96), align 16, !tbaa !12
  %24 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 112), align 16, !tbaa !12
  %25 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 128), align 16, !tbaa !12
  %26 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 144), align 16, !tbaa !12
  %27 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 160), align 16, !tbaa !12
  %28 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 176), align 16, !tbaa !12
  %29 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 192), align 16, !tbaa !12
  %30 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 208), align 16, !tbaa !12
  %31 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 224), align 16, !tbaa !12
  %32 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 240), align 16, !tbaa !12
  %33 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 256), align 16, !tbaa !12
  %34 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 272), align 16, !tbaa !12
  %35 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 288), align 16, !tbaa !12
  %36 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 304), align 16, !tbaa !12
  %37 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 320), align 16, !tbaa !12
  %38 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 336), align 16, !tbaa !12
  %39 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 352), align 16, !tbaa !12
  %40 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 368), align 16, !tbaa !12
  %41 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 384), align 16, !tbaa !12
  %42 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 388), align 4, !tbaa !12
  %43 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 392), align 8, !tbaa !12
  %44 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 396), align 4, !tbaa !12
  br label %66

45:                                               ; preds = %45, %11
  %46 = phi i64 [ 0, %11 ], [ %61, %45 ]
  %47 = phi i32 [ %13, %11 ], [ %55, %45 ]
  %48 = mul nuw nsw i32 %47, 3125
  %49 = and i32 %48, 65535
  %50 = add nsw i32 %49, -32768
  %51 = sitofp i32 %50 to float
  %52 = fmul nnan float %51, f0x38800000
  %53 = getelementptr [4 x i8], ptr %15, i64 %46
  store float %52, ptr %53, align 4, !tbaa !12
  %54 = mul nsw i32 %47, 761
  %55 = and i32 %54, 65535
  %56 = add nsw i32 %55, -32768
  %57 = sitofp i32 %56 to float
  %58 = fmul nnan float %57, f0x38800000
  %59 = getelementptr [4 x i8], ptr %15, i64 %46
  %60 = getelementptr i8, ptr %59, i64 4
  store float %58, ptr %60, align 4, !tbaa !12
  %61 = add nuw nsw i64 %46, 2
  %62 = icmp eq i64 %61, 100
  br i1 %62, label %63, label %45, !llvm.loop !14

63:                                               ; preds = %45
  %64 = add nuw nsw i64 %12, 1
  %65 = icmp eq i64 %64, 100
  br i1 %65, label %16, label %11, !llvm.loop !16

66:                                               ; preds = %66, %16
  %67 = phi float [ %44, %16 ], [ %180, %66 ]
  %68 = phi float [ %43, %16 ], [ %177, %66 ]
  %69 = phi float [ %42, %16 ], [ %174, %66 ]
  %70 = phi float [ %41, %16 ], [ %171, %66 ]
  %71 = phi <4 x float> [ %40, %16 ], [ %168, %66 ]
  %72 = phi <4 x float> [ %39, %16 ], [ %167, %66 ]
  %73 = phi <4 x float> [ %38, %16 ], [ %162, %66 ]
  %74 = phi <4 x float> [ %37, %16 ], [ %161, %66 ]
  %75 = phi <4 x float> [ %36, %16 ], [ %156, %66 ]
  %76 = phi <4 x float> [ %35, %16 ], [ %155, %66 ]
  %77 = phi <4 x float> [ %34, %16 ], [ %150, %66 ]
  %78 = phi <4 x float> [ %33, %16 ], [ %149, %66 ]
  %79 = phi <4 x float> [ %32, %16 ], [ %144, %66 ]
  %80 = phi <4 x float> [ %31, %16 ], [ %143, %66 ]
  %81 = phi <4 x float> [ %30, %16 ], [ %138, %66 ]
  %82 = phi <4 x float> [ %29, %16 ], [ %137, %66 ]
  %83 = phi <4 x float> [ %28, %16 ], [ %132, %66 ]
  %84 = phi <4 x float> [ %27, %16 ], [ %131, %66 ]
  %85 = phi <4 x float> [ %26, %16 ], [ %126, %66 ]
  %86 = phi <4 x float> [ %25, %16 ], [ %125, %66 ]
  %87 = phi <4 x float> [ %24, %16 ], [ %120, %66 ]
  %88 = phi <4 x float> [ %23, %16 ], [ %119, %66 ]
  %89 = phi <4 x float> [ %22, %16 ], [ %114, %66 ]
  %90 = phi <4 x float> [ %21, %16 ], [ %113, %66 ]
  %91 = phi <4 x float> [ %20, %16 ], [ %108, %66 ]
  %92 = phi <4 x float> [ %19, %16 ], [ %107, %66 ]
  %93 = phi <4 x float> [ %18, %16 ], [ %102, %66 ]
  %94 = phi <4 x float> [ %17, %16 ], [ %101, %66 ]
  %95 = phi i64 [ 0, %16 ], [ %181, %66 ]
  %96 = mul nuw nsw i64 %95, 804
  %97 = getelementptr i8, ptr @main.a, i64 %96
  %98 = getelementptr i8, ptr %97, i64 16
  %99 = load <4 x float>, ptr %97, align 4, !tbaa !12
  %100 = load <4 x float>, ptr %98, align 4, !tbaa !12
  %101 = fadd <4 x float> %94, %99
  %102 = fadd <4 x float> %93, %100
  %103 = getelementptr i8, ptr %97, i64 32
  %104 = getelementptr i8, ptr %97, i64 48
  %105 = load <4 x float>, ptr %103, align 4, !tbaa !12
  %106 = load <4 x float>, ptr %104, align 4, !tbaa !12
  %107 = fadd <4 x float> %92, %105
  %108 = fadd <4 x float> %91, %106
  %109 = getelementptr i8, ptr %97, i64 64
  %110 = getelementptr i8, ptr %97, i64 80
  %111 = load <4 x float>, ptr %109, align 4, !tbaa !12
  %112 = load <4 x float>, ptr %110, align 4, !tbaa !12
  %113 = fadd <4 x float> %90, %111
  %114 = fadd <4 x float> %89, %112
  %115 = getelementptr i8, ptr %97, i64 96
  %116 = getelementptr i8, ptr %97, i64 112
  %117 = load <4 x float>, ptr %115, align 4, !tbaa !12
  %118 = load <4 x float>, ptr %116, align 4, !tbaa !12
  %119 = fadd <4 x float> %88, %117
  %120 = fadd <4 x float> %87, %118
  %121 = getelementptr i8, ptr %97, i64 128
  %122 = getelementptr i8, ptr %97, i64 144
  %123 = load <4 x float>, ptr %121, align 4, !tbaa !12
  %124 = load <4 x float>, ptr %122, align 4, !tbaa !12
  %125 = fadd <4 x float> %86, %123
  %126 = fadd <4 x float> %85, %124
  %127 = getelementptr i8, ptr %97, i64 160
  %128 = getelementptr i8, ptr %97, i64 176
  %129 = load <4 x float>, ptr %127, align 4, !tbaa !12
  %130 = load <4 x float>, ptr %128, align 4, !tbaa !12
  %131 = fadd <4 x float> %84, %129
  %132 = fadd <4 x float> %83, %130
  %133 = getelementptr i8, ptr %97, i64 192
  %134 = getelementptr i8, ptr %97, i64 208
  %135 = load <4 x float>, ptr %133, align 4, !tbaa !12
  %136 = load <4 x float>, ptr %134, align 4, !tbaa !12
  %137 = fadd <4 x float> %82, %135
  %138 = fadd <4 x float> %81, %136
  %139 = getelementptr i8, ptr %97, i64 224
  %140 = getelementptr i8, ptr %97, i64 240
  %141 = load <4 x float>, ptr %139, align 4, !tbaa !12
  %142 = load <4 x float>, ptr %140, align 4, !tbaa !12
  %143 = fadd <4 x float> %80, %141
  %144 = fadd <4 x float> %79, %142
  %145 = getelementptr i8, ptr %97, i64 256
  %146 = getelementptr i8, ptr %97, i64 272
  %147 = load <4 x float>, ptr %145, align 4, !tbaa !12
  %148 = load <4 x float>, ptr %146, align 4, !tbaa !12
  %149 = fadd <4 x float> %78, %147
  %150 = fadd <4 x float> %77, %148
  %151 = getelementptr i8, ptr %97, i64 288
  %152 = getelementptr i8, ptr %97, i64 304
  %153 = load <4 x float>, ptr %151, align 4, !tbaa !12
  %154 = load <4 x float>, ptr %152, align 4, !tbaa !12
  %155 = fadd <4 x float> %76, %153
  %156 = fadd <4 x float> %75, %154
  %157 = getelementptr i8, ptr %97, i64 320
  %158 = getelementptr i8, ptr %97, i64 336
  %159 = load <4 x float>, ptr %157, align 4, !tbaa !12
  %160 = load <4 x float>, ptr %158, align 4, !tbaa !12
  %161 = fadd <4 x float> %74, %159
  %162 = fadd <4 x float> %73, %160
  %163 = getelementptr i8, ptr %97, i64 352
  %164 = getelementptr i8, ptr %97, i64 368
  %165 = load <4 x float>, ptr %163, align 4, !tbaa !12
  %166 = load <4 x float>, ptr %164, align 4, !tbaa !12
  %167 = fadd <4 x float> %72, %165
  %168 = fadd <4 x float> %71, %166
  %169 = getelementptr i8, ptr %97, i64 384
  %170 = load float, ptr %169, align 4, !tbaa !12
  %171 = fadd float %70, %170
  %172 = getelementptr i8, ptr %97, i64 388
  %173 = load float, ptr %172, align 4, !tbaa !12
  %174 = fadd float %69, %173
  %175 = getelementptr i8, ptr %97, i64 392
  %176 = load float, ptr %175, align 4, !tbaa !12
  %177 = fadd float %68, %176
  %178 = getelementptr i8, ptr %97, i64 396
  %179 = load float, ptr %178, align 4, !tbaa !12
  %180 = fadd float %67, %179
  %181 = add nuw nsw i64 %95, 1
  %182 = icmp eq i64 %181, 100
  br i1 %182, label %183, label %66, !llvm.loop !17

183:                                              ; preds = %66
  store <4 x float> %101, ptr @main.b, align 16, !tbaa !12
  store <4 x float> %102, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 16), align 16, !tbaa !12
  store <4 x float> %107, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 32), align 16, !tbaa !12
  store <4 x float> %108, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 48), align 16, !tbaa !12
  store <4 x float> %113, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 64), align 16, !tbaa !12
  store <4 x float> %114, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 80), align 16, !tbaa !12
  store <4 x float> %119, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 96), align 16, !tbaa !12
  store <4 x float> %120, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 112), align 16, !tbaa !12
  store <4 x float> %125, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 128), align 16, !tbaa !12
  store <4 x float> %126, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 144), align 16, !tbaa !12
  store <4 x float> %131, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 160), align 16, !tbaa !12
  store <4 x float> %132, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 176), align 16, !tbaa !12
  store <4 x float> %137, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 192), align 16, !tbaa !12
  store <4 x float> %138, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 208), align 16, !tbaa !12
  store <4 x float> %143, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 224), align 16, !tbaa !12
  store <4 x float> %144, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 240), align 16, !tbaa !12
  store <4 x float> %149, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 256), align 16, !tbaa !12
  store <4 x float> %150, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 272), align 16, !tbaa !12
  store <4 x float> %155, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 288), align 16, !tbaa !12
  store <4 x float> %156, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 304), align 16, !tbaa !12
  store <4 x float> %161, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 320), align 16, !tbaa !12
  store <4 x float> %162, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 336), align 16, !tbaa !12
  store <4 x float> %167, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 352), align 16, !tbaa !12
  store <4 x float> %168, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 368), align 16, !tbaa !12
  store float %171, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 384), align 16, !tbaa !12
  store float %174, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 388), align 4, !tbaa !12
  store float %177, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 392), align 8, !tbaa !12
  store float %180, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 396), align 4, !tbaa !12
  %184 = tail call i64 @clock() #13
  tail call void @dgefa(ptr noundef nonnull @main.a, i32 noundef 201, i32 noundef 100, ptr noundef nonnull @main.ipvt, ptr noundef nonnull @main.info)
  %185 = tail call i64 @clock() #13
  %186 = sitofp i64 %184 to float
  %187 = sitofp i64 %185 to float
  %188 = insertelement <2 x float> poison, float %187, i64 0
  %189 = insertelement <2 x float> %188, float %186, i64 1
  %190 = fdiv <2 x float> %189, splat (float 1.000000e+06)
  %191 = shufflevector <2 x float> %190, <2 x float> poison, <2 x i32> <i32 1, i32 poison>
  %192 = fsub <2 x float> %190, %191
  %193 = extractelement <2 x float> %192, i64 0
  store float %193, ptr @atime, align 16, !tbaa !12
  %194 = tail call i64 @clock() #13
  br label %195

195:                                              ; preds = %248, %183
  %196 = phi i64 [ 0, %183 ], [ %208, %248 ]
  %197 = getelementptr inbounds nuw [4 x i8], ptr @main.ipvt, i64 %196
  %198 = load i32, ptr %197, align 4, !tbaa !18
  %199 = sext i32 %198 to i64
  %200 = getelementptr inbounds [4 x i8], ptr @main.b, i64 %199
  %201 = load float, ptr %200, align 4, !tbaa !12
  %202 = zext i32 %198 to i64
  %203 = icmp eq i64 %196, %202
  br i1 %203, label %207, label %204

204:                                              ; preds = %195
  %205 = getelementptr inbounds nuw [4 x i8], ptr @main.b, i64 %196
  %206 = load float, ptr %205, align 4, !tbaa !12
  store float %206, ptr %200, align 4, !tbaa !12
  store float %201, ptr %205, align 4, !tbaa !12
  br label %207

207:                                              ; preds = %204, %195
  %208 = add nuw nsw i64 %196, 1
  %209 = mul nuw nsw i64 %196, 808
  %210 = getelementptr i8, ptr @main.a, i64 %209
  %211 = getelementptr i8, ptr %210, i64 4
  %212 = getelementptr inbounds nuw [4 x i8], ptr @main.b, i64 %208
  %213 = fcmp oeq float %201, 0.000000e+00
  br i1 %213, label %248, label %214

214:                                              ; preds = %207
  %215 = sub nuw nsw i64 99, %196
  %216 = icmp samesign ugt i64 %196, 91
  br i1 %216, label %237, label %217

217:                                              ; preds = %214
  %218 = and i64 %215, 120
  %219 = insertelement <4 x float> poison, float %201, i64 0
  %220 = shufflevector <4 x float> %219, <4 x float> poison, <4 x i32> zeroinitializer
  br label %221

221:                                              ; preds = %221, %217
  %222 = phi i64 [ 0, %217 ], [ %233, %221 ]
  %223 = getelementptr inbounds nuw [4 x i8], ptr %212, i64 %222
  %224 = getelementptr inbounds nuw i8, ptr %223, i64 16
  %225 = load <4 x float>, ptr %223, align 4, !tbaa !12
  %226 = load <4 x float>, ptr %224, align 4, !tbaa !12
  %227 = getelementptr inbounds nuw [4 x i8], ptr %211, i64 %222
  %228 = getelementptr inbounds nuw i8, ptr %227, i64 16
  %229 = load <4 x float>, ptr %227, align 4, !tbaa !12
  %230 = load <4 x float>, ptr %228, align 4, !tbaa !12
  %231 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %220, <4 x float> %229, <4 x float> %225)
  %232 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %220, <4 x float> %230, <4 x float> %226)
  store <4 x float> %231, ptr %223, align 4, !tbaa !12
  store <4 x float> %232, ptr %224, align 4, !tbaa !12
  %233 = add nuw i64 %222, 8
  %234 = icmp eq i64 %233, %218
  br i1 %234, label %235, label %221, !llvm.loop !19

235:                                              ; preds = %221
  %236 = icmp eq i64 %215, %218
  br i1 %236, label %248, label %237

237:                                              ; preds = %214, %235
  %238 = phi i64 [ 0, %214 ], [ %218, %235 ]
  br label %239

239:                                              ; preds = %237, %239
  %240 = phi i64 [ %246, %239 ], [ %238, %237 ]
  %241 = getelementptr inbounds nuw [4 x i8], ptr %212, i64 %240
  %242 = load float, ptr %241, align 4, !tbaa !12
  %243 = getelementptr inbounds nuw [4 x i8], ptr %211, i64 %240
  %244 = load float, ptr %243, align 4, !tbaa !12
  %245 = tail call float @llvm.fmuladd.f32(float %201, float %244, float %242)
  store float %245, ptr %241, align 4, !tbaa !12
  %246 = add nuw nsw i64 %240, 1
  %247 = icmp eq i64 %246, %215
  br i1 %247, label %248, label %239, !llvm.loop !22

248:                                              ; preds = %239, %235, %207
  %249 = icmp eq i64 %208, 99
  br i1 %249, label %250, label %195, !llvm.loop !23

250:                                              ; preds = %248, %300
  %251 = phi i64 [ %252, %300 ], [ 0, %248 ]
  %252 = add nuw nsw i64 %251, 1
  %253 = sub nuw nsw i64 99, %251
  %254 = getelementptr inbounds nuw [4 x i8], ptr @main.b, i64 %253
  %255 = load float, ptr %254, align 4, !tbaa !12
  %256 = getelementptr [4 x i8], ptr @main.a, i64 %253
  %257 = mul nuw nsw i64 %253, 804
  %258 = getelementptr i8, ptr %256, i64 %257
  %259 = load float, ptr %258, align 4, !tbaa !12
  %260 = fdiv float %255, %259
  store float %260, ptr %254, align 4, !tbaa !12
  %261 = fneg float %260
  %262 = mul nuw nsw i64 %253, 804
  %263 = getelementptr inbounds nuw i8, ptr @main.a, i64 %262
  %264 = icmp samesign ugt i64 %251, 98
  %265 = fcmp oeq float %260, 0.000000e+00
  %266 = or i1 %264, %265
  br i1 %266, label %300, label %267

267:                                              ; preds = %250
  %268 = icmp samesign ugt i64 %251, 91
  br i1 %268, label %289, label %269

269:                                              ; preds = %267
  %270 = and i64 %253, 120
  %271 = insertelement <4 x float> poison, float %261, i64 0
  %272 = shufflevector <4 x float> %271, <4 x float> poison, <4 x i32> zeroinitializer
  br label %273

273:                                              ; preds = %273, %269
  %274 = phi i64 [ 0, %269 ], [ %285, %273 ]
  %275 = getelementptr inbounds nuw [4 x i8], ptr @main.b, i64 %274
  %276 = getelementptr inbounds nuw i8, ptr %275, i64 16
  %277 = load <4 x float>, ptr %275, align 16, !tbaa !12
  %278 = load <4 x float>, ptr %276, align 16, !tbaa !12
  %279 = getelementptr inbounds nuw [4 x i8], ptr %263, i64 %274
  %280 = getelementptr inbounds nuw i8, ptr %279, i64 16
  %281 = load <4 x float>, ptr %279, align 4, !tbaa !12
  %282 = load <4 x float>, ptr %280, align 4, !tbaa !12
  %283 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %272, <4 x float> %281, <4 x float> %277)
  %284 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %272, <4 x float> %282, <4 x float> %278)
  store <4 x float> %283, ptr %275, align 16, !tbaa !12
  store <4 x float> %284, ptr %276, align 16, !tbaa !12
  %285 = add nuw i64 %274, 8
  %286 = icmp eq i64 %285, %270
  br i1 %286, label %287, label %273, !llvm.loop !24

287:                                              ; preds = %273
  %288 = icmp eq i64 %253, %270
  br i1 %288, label %300, label %289

289:                                              ; preds = %267, %287
  %290 = phi i64 [ 0, %267 ], [ %270, %287 ]
  br label %291

291:                                              ; preds = %289, %291
  %292 = phi i64 [ %298, %291 ], [ %290, %289 ]
  %293 = getelementptr inbounds nuw [4 x i8], ptr @main.b, i64 %292
  %294 = load float, ptr %293, align 4, !tbaa !12
  %295 = getelementptr inbounds nuw [4 x i8], ptr %263, i64 %292
  %296 = load float, ptr %295, align 4, !tbaa !12
  %297 = tail call float @llvm.fmuladd.f32(float %261, float %296, float %294)
  store float %297, ptr %293, align 4, !tbaa !12
  %298 = add nuw nsw i64 %292, 1
  %299 = icmp eq i64 %298, %253
  br i1 %299, label %300, label %291, !llvm.loop !25

300:                                              ; preds = %291, %287, %250
  %301 = icmp eq i64 %252, 100
  br i1 %301, label %302, label %250, !llvm.loop !26

302:                                              ; preds = %300
  %303 = tail call i64 @clock() #13
  %304 = sitofp i64 %303 to float
  %305 = sitofp i64 %194 to float
  %306 = insertelement <2 x float> poison, float %305, i64 0
  %307 = insertelement <2 x float> %306, float %304, i64 1
  %308 = fdiv <2 x float> %307, splat (float 1.000000e+06)
  %309 = shufflevector <2 x float> %308, <2 x float> poison, <2 x i32> <i32 1, i32 poison>
  %310 = fsub <2 x float> %309, %308
  %311 = extractelement <2 x float> %310, i64 0
  store float %311, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 60), align 4, !tbaa !12
  %312 = load float, ptr @atime, align 16, !tbaa !12
  tail call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 16 dereferenceable(400) @main.x, ptr noundef nonnull align 16 dereferenceable(400) @main.b, i64 400, i1 false), !tbaa !12
  br label %313

313:                                              ; preds = %302, %371
  %314 = phi float [ %368, %371 ], [ 0.000000e+00, %302 ]
  %315 = phi i64 [ %372, %371 ], [ 0, %302 ]
  %316 = phi i32 [ %361, %371 ], [ 1325, %302 ]
  %317 = mul nuw nsw i64 %315, 804
  %318 = getelementptr i8, ptr @main.a, i64 %317
  br label %348

319:                                              ; preds = %371
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(400) @main.b, i8 0, i64 400, i1 false), !tbaa !12
  %320 = load <4 x float>, ptr @main.b, align 16, !tbaa !12
  %321 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 16), align 16, !tbaa !12
  %322 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 32), align 16, !tbaa !12
  %323 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 48), align 16, !tbaa !12
  %324 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 64), align 16, !tbaa !12
  %325 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 80), align 16, !tbaa !12
  %326 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 96), align 16, !tbaa !12
  %327 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 112), align 16, !tbaa !12
  %328 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 128), align 16, !tbaa !12
  %329 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 144), align 16, !tbaa !12
  %330 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 160), align 16, !tbaa !12
  %331 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 176), align 16, !tbaa !12
  %332 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 192), align 16, !tbaa !12
  %333 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 208), align 16, !tbaa !12
  %334 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 224), align 16, !tbaa !12
  %335 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 240), align 16, !tbaa !12
  %336 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 256), align 16, !tbaa !12
  %337 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 272), align 16, !tbaa !12
  %338 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 288), align 16, !tbaa !12
  %339 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 304), align 16, !tbaa !12
  %340 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 320), align 16, !tbaa !12
  %341 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 336), align 16, !tbaa !12
  %342 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 352), align 16, !tbaa !12
  %343 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 368), align 16, !tbaa !12
  %344 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 384), align 16, !tbaa !12
  %345 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 388), align 4, !tbaa !12
  %346 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 392), align 8, !tbaa !12
  %347 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 396), align 4, !tbaa !12
  br label %374

348:                                              ; preds = %348, %313
  %349 = phi float [ %314, %313 ], [ %368, %348 ]
  %350 = phi i64 [ 0, %313 ], [ %369, %348 ]
  %351 = phi i32 [ %316, %313 ], [ %361, %348 ]
  %352 = mul nuw nsw i32 %351, 3125
  %353 = and i32 %352, 65535
  %354 = add nsw i32 %353, -32768
  %355 = sitofp i32 %354 to float
  %356 = fmul nnan float %355, f0x38800000
  %357 = getelementptr [4 x i8], ptr %318, i64 %350
  store float %356, ptr %357, align 4, !tbaa !12
  %358 = fcmp ogt float %356, %349
  %359 = select i1 %358, float %356, float %349
  %360 = mul nsw i32 %351, 761
  %361 = and i32 %360, 65535
  %362 = add nsw i32 %361, -32768
  %363 = sitofp i32 %362 to float
  %364 = fmul nnan float %363, f0x38800000
  %365 = getelementptr [4 x i8], ptr %318, i64 %350
  %366 = getelementptr i8, ptr %365, i64 4
  store float %364, ptr %366, align 4, !tbaa !12
  %367 = fcmp ogt float %364, %359
  %368 = select i1 %367, float %364, float %359
  %369 = add nuw nsw i64 %350, 2
  %370 = icmp eq i64 %369, 100
  br i1 %370, label %371, label %348, !llvm.loop !14

371:                                              ; preds = %348
  %372 = add nuw nsw i64 %315, 1
  %373 = icmp eq i64 %372, 100
  br i1 %373, label %319, label %313, !llvm.loop !16

374:                                              ; preds = %374, %319
  %375 = phi float [ %347, %319 ], [ %488, %374 ]
  %376 = phi float [ %346, %319 ], [ %485, %374 ]
  %377 = phi float [ %345, %319 ], [ %482, %374 ]
  %378 = phi float [ %344, %319 ], [ %479, %374 ]
  %379 = phi <4 x float> [ %343, %319 ], [ %476, %374 ]
  %380 = phi <4 x float> [ %342, %319 ], [ %475, %374 ]
  %381 = phi <4 x float> [ %341, %319 ], [ %470, %374 ]
  %382 = phi <4 x float> [ %340, %319 ], [ %469, %374 ]
  %383 = phi <4 x float> [ %339, %319 ], [ %464, %374 ]
  %384 = phi <4 x float> [ %338, %319 ], [ %463, %374 ]
  %385 = phi <4 x float> [ %337, %319 ], [ %458, %374 ]
  %386 = phi <4 x float> [ %336, %319 ], [ %457, %374 ]
  %387 = phi <4 x float> [ %335, %319 ], [ %452, %374 ]
  %388 = phi <4 x float> [ %334, %319 ], [ %451, %374 ]
  %389 = phi <4 x float> [ %333, %319 ], [ %446, %374 ]
  %390 = phi <4 x float> [ %332, %319 ], [ %445, %374 ]
  %391 = phi <4 x float> [ %331, %319 ], [ %440, %374 ]
  %392 = phi <4 x float> [ %330, %319 ], [ %439, %374 ]
  %393 = phi <4 x float> [ %329, %319 ], [ %434, %374 ]
  %394 = phi <4 x float> [ %328, %319 ], [ %433, %374 ]
  %395 = phi <4 x float> [ %327, %319 ], [ %428, %374 ]
  %396 = phi <4 x float> [ %326, %319 ], [ %427, %374 ]
  %397 = phi <4 x float> [ %325, %319 ], [ %422, %374 ]
  %398 = phi <4 x float> [ %324, %319 ], [ %421, %374 ]
  %399 = phi <4 x float> [ %323, %319 ], [ %416, %374 ]
  %400 = phi <4 x float> [ %322, %319 ], [ %415, %374 ]
  %401 = phi <4 x float> [ %321, %319 ], [ %410, %374 ]
  %402 = phi <4 x float> [ %320, %319 ], [ %409, %374 ]
  %403 = phi i64 [ 0, %319 ], [ %489, %374 ]
  %404 = mul nuw nsw i64 %403, 804
  %405 = getelementptr i8, ptr @main.a, i64 %404
  %406 = getelementptr i8, ptr %405, i64 16
  %407 = load <4 x float>, ptr %405, align 4, !tbaa !12
  %408 = load <4 x float>, ptr %406, align 4, !tbaa !12
  %409 = fadd <4 x float> %402, %407
  %410 = fadd <4 x float> %401, %408
  %411 = getelementptr i8, ptr %405, i64 32
  %412 = getelementptr i8, ptr %405, i64 48
  %413 = load <4 x float>, ptr %411, align 4, !tbaa !12
  %414 = load <4 x float>, ptr %412, align 4, !tbaa !12
  %415 = fadd <4 x float> %400, %413
  %416 = fadd <4 x float> %399, %414
  %417 = getelementptr i8, ptr %405, i64 64
  %418 = getelementptr i8, ptr %405, i64 80
  %419 = load <4 x float>, ptr %417, align 4, !tbaa !12
  %420 = load <4 x float>, ptr %418, align 4, !tbaa !12
  %421 = fadd <4 x float> %398, %419
  %422 = fadd <4 x float> %397, %420
  %423 = getelementptr i8, ptr %405, i64 96
  %424 = getelementptr i8, ptr %405, i64 112
  %425 = load <4 x float>, ptr %423, align 4, !tbaa !12
  %426 = load <4 x float>, ptr %424, align 4, !tbaa !12
  %427 = fadd <4 x float> %396, %425
  %428 = fadd <4 x float> %395, %426
  %429 = getelementptr i8, ptr %405, i64 128
  %430 = getelementptr i8, ptr %405, i64 144
  %431 = load <4 x float>, ptr %429, align 4, !tbaa !12
  %432 = load <4 x float>, ptr %430, align 4, !tbaa !12
  %433 = fadd <4 x float> %394, %431
  %434 = fadd <4 x float> %393, %432
  %435 = getelementptr i8, ptr %405, i64 160
  %436 = getelementptr i8, ptr %405, i64 176
  %437 = load <4 x float>, ptr %435, align 4, !tbaa !12
  %438 = load <4 x float>, ptr %436, align 4, !tbaa !12
  %439 = fadd <4 x float> %392, %437
  %440 = fadd <4 x float> %391, %438
  %441 = getelementptr i8, ptr %405, i64 192
  %442 = getelementptr i8, ptr %405, i64 208
  %443 = load <4 x float>, ptr %441, align 4, !tbaa !12
  %444 = load <4 x float>, ptr %442, align 4, !tbaa !12
  %445 = fadd <4 x float> %390, %443
  %446 = fadd <4 x float> %389, %444
  %447 = getelementptr i8, ptr %405, i64 224
  %448 = getelementptr i8, ptr %405, i64 240
  %449 = load <4 x float>, ptr %447, align 4, !tbaa !12
  %450 = load <4 x float>, ptr %448, align 4, !tbaa !12
  %451 = fadd <4 x float> %388, %449
  %452 = fadd <4 x float> %387, %450
  %453 = getelementptr i8, ptr %405, i64 256
  %454 = getelementptr i8, ptr %405, i64 272
  %455 = load <4 x float>, ptr %453, align 4, !tbaa !12
  %456 = load <4 x float>, ptr %454, align 4, !tbaa !12
  %457 = fadd <4 x float> %386, %455
  %458 = fadd <4 x float> %385, %456
  %459 = getelementptr i8, ptr %405, i64 288
  %460 = getelementptr i8, ptr %405, i64 304
  %461 = load <4 x float>, ptr %459, align 4, !tbaa !12
  %462 = load <4 x float>, ptr %460, align 4, !tbaa !12
  %463 = fadd <4 x float> %384, %461
  %464 = fadd <4 x float> %383, %462
  %465 = getelementptr i8, ptr %405, i64 320
  %466 = getelementptr i8, ptr %405, i64 336
  %467 = load <4 x float>, ptr %465, align 4, !tbaa !12
  %468 = load <4 x float>, ptr %466, align 4, !tbaa !12
  %469 = fadd <4 x float> %382, %467
  %470 = fadd <4 x float> %381, %468
  %471 = getelementptr i8, ptr %405, i64 352
  %472 = getelementptr i8, ptr %405, i64 368
  %473 = load <4 x float>, ptr %471, align 4, !tbaa !12
  %474 = load <4 x float>, ptr %472, align 4, !tbaa !12
  %475 = fadd <4 x float> %380, %473
  %476 = fadd <4 x float> %379, %474
  %477 = getelementptr i8, ptr %405, i64 384
  %478 = load float, ptr %477, align 4, !tbaa !12
  %479 = fadd float %378, %478
  %480 = getelementptr i8, ptr %405, i64 388
  %481 = load float, ptr %480, align 4, !tbaa !12
  %482 = fadd float %377, %481
  %483 = getelementptr i8, ptr %405, i64 392
  %484 = load float, ptr %483, align 4, !tbaa !12
  %485 = fadd float %376, %484
  %486 = getelementptr i8, ptr %405, i64 396
  %487 = load float, ptr %486, align 4, !tbaa !12
  %488 = fadd float %375, %487
  %489 = add nuw nsw i64 %403, 1
  %490 = icmp eq i64 %489, 100
  br i1 %490, label %491, label %374, !llvm.loop !17

491:                                              ; preds = %374
  store <4 x float> %409, ptr @main.b, align 16, !tbaa !12
  store <4 x float> %410, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 16), align 16, !tbaa !12
  store <4 x float> %415, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 32), align 16, !tbaa !12
  store <4 x float> %416, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 48), align 16, !tbaa !12
  store <4 x float> %421, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 64), align 16, !tbaa !12
  store <4 x float> %422, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 80), align 16, !tbaa !12
  store <4 x float> %427, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 96), align 16, !tbaa !12
  store <4 x float> %428, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 112), align 16, !tbaa !12
  store <4 x float> %433, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 128), align 16, !tbaa !12
  store <4 x float> %434, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 144), align 16, !tbaa !12
  store <4 x float> %439, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 160), align 16, !tbaa !12
  store <4 x float> %440, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 176), align 16, !tbaa !12
  store <4 x float> %445, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 192), align 16, !tbaa !12
  store <4 x float> %446, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 208), align 16, !tbaa !12
  store <4 x float> %451, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 224), align 16, !tbaa !12
  store <4 x float> %452, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 240), align 16, !tbaa !12
  store <4 x float> %457, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 256), align 16, !tbaa !12
  store <4 x float> %458, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 272), align 16, !tbaa !12
  store <4 x float> %463, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 288), align 16, !tbaa !12
  store <4 x float> %464, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 304), align 16, !tbaa !12
  store <4 x float> %469, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 320), align 16, !tbaa !12
  store <4 x float> %470, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 336), align 16, !tbaa !12
  store <4 x float> %475, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 352), align 16, !tbaa !12
  store <4 x float> %476, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 368), align 16, !tbaa !12
  store float %479, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 384), align 16, !tbaa !12
  store float %482, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 388), align 4, !tbaa !12
  store float %485, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 392), align 8, !tbaa !12
  store float %488, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 396), align 4, !tbaa !12
  %492 = load <4 x float>, ptr @main.b, align 16, !tbaa !12
  %493 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 16), align 16, !tbaa !12
  %494 = fneg <4 x float> %492
  %495 = fneg <4 x float> %493
  store <4 x float> %494, ptr @main.b, align 16, !tbaa !12
  store <4 x float> %495, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 16), align 16, !tbaa !12
  %496 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 32), align 16, !tbaa !12
  %497 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 48), align 16, !tbaa !12
  %498 = fneg <4 x float> %496
  %499 = fneg <4 x float> %497
  store <4 x float> %498, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 32), align 16, !tbaa !12
  store <4 x float> %499, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 48), align 16, !tbaa !12
  %500 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 64), align 16, !tbaa !12
  %501 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 80), align 16, !tbaa !12
  %502 = fneg <4 x float> %500
  %503 = fneg <4 x float> %501
  store <4 x float> %502, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 64), align 16, !tbaa !12
  store <4 x float> %503, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 80), align 16, !tbaa !12
  %504 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 96), align 16, !tbaa !12
  %505 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 112), align 16, !tbaa !12
  %506 = fneg <4 x float> %504
  %507 = fneg <4 x float> %505
  store <4 x float> %506, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 96), align 16, !tbaa !12
  store <4 x float> %507, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 112), align 16, !tbaa !12
  %508 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 128), align 16, !tbaa !12
  %509 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 144), align 16, !tbaa !12
  %510 = fneg <4 x float> %508
  %511 = fneg <4 x float> %509
  store <4 x float> %510, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 128), align 16, !tbaa !12
  store <4 x float> %511, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 144), align 16, !tbaa !12
  %512 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 160), align 16, !tbaa !12
  %513 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 176), align 16, !tbaa !12
  %514 = fneg <4 x float> %512
  %515 = fneg <4 x float> %513
  store <4 x float> %514, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 160), align 16, !tbaa !12
  store <4 x float> %515, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 176), align 16, !tbaa !12
  %516 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 192), align 16, !tbaa !12
  %517 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 208), align 16, !tbaa !12
  %518 = fneg <4 x float> %516
  %519 = fneg <4 x float> %517
  store <4 x float> %518, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 192), align 16, !tbaa !12
  store <4 x float> %519, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 208), align 16, !tbaa !12
  %520 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 224), align 16, !tbaa !12
  %521 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 240), align 16, !tbaa !12
  %522 = fneg <4 x float> %520
  %523 = fneg <4 x float> %521
  store <4 x float> %522, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 224), align 16, !tbaa !12
  store <4 x float> %523, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 240), align 16, !tbaa !12
  %524 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 256), align 16, !tbaa !12
  %525 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 272), align 16, !tbaa !12
  %526 = fneg <4 x float> %524
  %527 = fneg <4 x float> %525
  store <4 x float> %526, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 256), align 16, !tbaa !12
  store <4 x float> %527, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 272), align 16, !tbaa !12
  %528 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 288), align 16, !tbaa !12
  %529 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 304), align 16, !tbaa !12
  %530 = fneg <4 x float> %528
  %531 = fneg <4 x float> %529
  store <4 x float> %530, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 288), align 16, !tbaa !12
  store <4 x float> %531, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 304), align 16, !tbaa !12
  %532 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 320), align 16, !tbaa !12
  %533 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 336), align 16, !tbaa !12
  %534 = fneg <4 x float> %532
  %535 = fneg <4 x float> %533
  store <4 x float> %534, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 320), align 16, !tbaa !12
  store <4 x float> %535, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 336), align 16, !tbaa !12
  %536 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 352), align 16, !tbaa !12
  %537 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 368), align 16, !tbaa !12
  %538 = fneg <4 x float> %536
  %539 = fneg <4 x float> %537
  store <4 x float> %538, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 352), align 16, !tbaa !12
  store <4 x float> %539, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 368), align 16, !tbaa !12
  %540 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 384), align 16, !tbaa !12
  %541 = fneg float %540
  store float %541, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 384), align 16, !tbaa !12
  %542 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 388), align 4, !tbaa !12
  %543 = fneg float %542
  store float %543, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 388), align 4, !tbaa !12
  %544 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 392), align 8, !tbaa !12
  %545 = fneg float %544
  store float %545, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 392), align 8, !tbaa !12
  %546 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 396), align 4, !tbaa !12
  %547 = fneg float %546
  store float %547, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 396), align 4, !tbaa !12
  tail call void @dmxpy(i32 noundef 100, ptr noundef nonnull @main.b, i32 noundef 100, i32 noundef 201, ptr noundef nonnull @main.x, ptr noundef nonnull @main.a)
  br label %548

548:                                              ; preds = %548, %491
  %549 = phi i64 [ 0, %491 ], [ %570, %548 ]
  %550 = phi <2 x float> [ zeroinitializer, %491 ], [ %569, %548 ]
  %551 = getelementptr inbounds nuw [4 x i8], ptr @main.b, i64 %549
  %552 = load float, ptr %551, align 8, !tbaa !12
  %553 = getelementptr inbounds nuw [4 x i8], ptr @main.x, i64 %549
  %554 = load float, ptr %553, align 8, !tbaa !12
  %555 = insertelement <2 x float> poison, float %554, i64 0
  %556 = insertelement <2 x float> %555, float %552, i64 1
  %557 = tail call <2 x float> @llvm.fabs.v2f32(<2 x float> %556)
  %558 = fcmp ogt <2 x float> %550, %557
  %559 = select <2 x i1> %558, <2 x float> %550, <2 x float> %557
  %560 = or disjoint i64 %549, 1
  %561 = getelementptr inbounds nuw [4 x i8], ptr @main.b, i64 %560
  %562 = load float, ptr %561, align 4, !tbaa !12
  %563 = getelementptr inbounds nuw [4 x i8], ptr @main.x, i64 %560
  %564 = load float, ptr %563, align 4, !tbaa !12
  %565 = insertelement <2 x float> poison, float %564, i64 0
  %566 = insertelement <2 x float> %565, float %562, i64 1
  %567 = tail call <2 x float> @llvm.fabs.v2f32(<2 x float> %566)
  %568 = fcmp ogt <2 x float> %559, %567
  %569 = select <2 x i1> %568, <2 x float> %559, <2 x float> %567
  %570 = add nuw nsw i64 %549, 2
  %571 = icmp eq i64 %570, 100
  br i1 %571, label %572, label %548, !llvm.loop !27

572:                                              ; preds = %548
  %573 = fadd float %312, %311
  %574 = fmul float %368, 1.000000e+02
  %575 = extractelement <2 x float> %569, i64 0
  %576 = fmul float %574, %575
  %577 = fmul float %576, f0x34000000
  %578 = extractelement <2 x float> %569, i64 1
  %579 = fdiv float %578, %577
  %580 = load float, ptr @main.x, align 16, !tbaa !12
  %581 = fadd float %580, -1.000000e+00
  %582 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.x, i64 396), align 4, !tbaa !12
  %583 = fadd float %582, -1.000000e+00
  %584 = load ptr, ptr @stderr, align 8, !tbaa !9
  %585 = tail call i64 @fwrite(ptr nonnull @.str.7, i64 38, i64 1, ptr %584) #14
  %586 = load ptr, ptr @stderr, align 8, !tbaa !9
  %587 = tail call i64 @fwrite(ptr nonnull @.str.8, i64 34, i64 1, ptr %586) #14
  %588 = load ptr, ptr @stderr, align 8, !tbaa !9
  %589 = fpext float %579 to double
  %590 = fpext float %578 to double
  %591 = fpext float %581 to double
  %592 = fpext float %583 to double
  %593 = tail call i32 (ptr, ptr, ...) @fprintf(ptr noundef %588, ptr noundef nonnull @.str.9, double noundef %589, double noundef %590, double noundef f0x3E80000000000000, double noundef %591, double noundef %592) #15
  %594 = load ptr, ptr @stderr, align 8, !tbaa !9
  %595 = tail call i32 (ptr, ptr, ...) @fprintf(ptr noundef %594, ptr noundef nonnull @.str.10, i32 noundef 100) #15
  %596 = load ptr, ptr @stderr, align 8, !tbaa !9
  %597 = tail call i32 (ptr, ptr, ...) @fprintf(ptr noundef %596, ptr noundef nonnull @.str.11, i32 noundef 201) #15
  %598 = load ptr, ptr @stderr, align 8, !tbaa !9
  %599 = tail call i64 @fwrite(ptr nonnull @.str.12, i64 55, i64 1, ptr %598) #14
  %600 = load ptr, ptr @stderr, align 8, !tbaa !9
  %601 = tail call i64 @fwrite(ptr nonnull @.str.13, i64 12, i64 1, ptr %600) #14
  store float %573, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 120), align 8, !tbaa !12
  %602 = fcmp ogt float %573, 0.000000e+00
  br i1 %602, label %603, label %609

603:                                              ; preds = %572
  %604 = fpext nnan float %573 to double
  %605 = fmul nnan double %604, 1.000000e+06
  %606 = fdiv double f0x4124F49560000000, %605
  %607 = fptrunc double %606 to float
  %608 = fdiv float 2.000000e+00, %607
  br label %609

609:                                              ; preds = %572, %603
  %610 = phi float [ %607, %603 ], [ 0.000000e+00, %572 ]
  %611 = phi float [ %608, %603 ], [ 0.000000e+00, %572 ]
  store float %610, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 180), align 4, !tbaa !12
  store float %611, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 240), align 16, !tbaa !12
  %612 = fdiv float %573, 5.600000e-02
  store float %612, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 300), align 4, !tbaa !12
  %613 = load ptr, ptr @stderr, align 8, !tbaa !9
  %614 = tail call i64 @fwrite(ptr nonnull @.str.14, i64 29, i64 1, ptr %613) #14
  br label %615

615:                                              ; preds = %609, %797
  %616 = phi i32 [ -3, %609 ], [ %619, %797 ]
  %617 = phi i32 [ 100, %609 ], [ %801, %797 ]
  %618 = tail call i64 @clock() #13
  %619 = add nsw i32 %616, 1
  br label %620

620:                                              ; preds = %615, %794
  %621 = phi i32 [ %795, %794 ], [ 0, %615 ]
  br label %622

622:                                              ; preds = %620, %674
  %623 = phi i64 [ %675, %674 ], [ 0, %620 ]
  %624 = phi i32 [ %666, %674 ], [ 1325, %620 ]
  %625 = mul nuw nsw i64 %623, 804
  %626 = getelementptr i8, ptr @main.a, i64 %625
  br label %656

627:                                              ; preds = %674
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(400) @main.b, i8 0, i64 400, i1 false), !tbaa !12
  %628 = load <4 x float>, ptr @main.b, align 16, !tbaa !12
  %629 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 16), align 16, !tbaa !12
  %630 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 32), align 16, !tbaa !12
  %631 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 48), align 16, !tbaa !12
  %632 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 64), align 16, !tbaa !12
  %633 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 80), align 16, !tbaa !12
  %634 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 96), align 16, !tbaa !12
  %635 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 112), align 16, !tbaa !12
  %636 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 128), align 16, !tbaa !12
  %637 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 144), align 16, !tbaa !12
  %638 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 160), align 16, !tbaa !12
  %639 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 176), align 16, !tbaa !12
  %640 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 192), align 16, !tbaa !12
  %641 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 208), align 16, !tbaa !12
  %642 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 224), align 16, !tbaa !12
  %643 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 240), align 16, !tbaa !12
  %644 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 256), align 16, !tbaa !12
  %645 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 272), align 16, !tbaa !12
  %646 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 288), align 16, !tbaa !12
  %647 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 304), align 16, !tbaa !12
  %648 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 320), align 16, !tbaa !12
  %649 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 336), align 16, !tbaa !12
  %650 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 352), align 16, !tbaa !12
  %651 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 368), align 16, !tbaa !12
  %652 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 384), align 16, !tbaa !12
  %653 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 388), align 4, !tbaa !12
  %654 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 392), align 8, !tbaa !12
  %655 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 396), align 4, !tbaa !12
  br label %677

656:                                              ; preds = %656, %622
  %657 = phi i64 [ 0, %622 ], [ %672, %656 ]
  %658 = phi i32 [ %624, %622 ], [ %666, %656 ]
  %659 = mul nuw nsw i32 %658, 3125
  %660 = and i32 %659, 65535
  %661 = add nsw i32 %660, -32768
  %662 = sitofp i32 %661 to float
  %663 = fmul nnan float %662, f0x38800000
  %664 = getelementptr [4 x i8], ptr %626, i64 %657
  store float %663, ptr %664, align 4, !tbaa !12
  %665 = mul nsw i32 %658, 761
  %666 = and i32 %665, 65535
  %667 = add nsw i32 %666, -32768
  %668 = sitofp i32 %667 to float
  %669 = fmul nnan float %668, f0x38800000
  %670 = getelementptr [4 x i8], ptr %626, i64 %657
  %671 = getelementptr i8, ptr %670, i64 4
  store float %669, ptr %671, align 4, !tbaa !12
  %672 = add nuw nsw i64 %657, 2
  %673 = icmp eq i64 %672, 100
  br i1 %673, label %674, label %656, !llvm.loop !14

674:                                              ; preds = %656
  %675 = add nuw nsw i64 %623, 1
  %676 = icmp eq i64 %675, 100
  br i1 %676, label %627, label %622, !llvm.loop !16

677:                                              ; preds = %677, %627
  %678 = phi float [ %655, %627 ], [ %791, %677 ]
  %679 = phi float [ %654, %627 ], [ %788, %677 ]
  %680 = phi float [ %653, %627 ], [ %785, %677 ]
  %681 = phi float [ %652, %627 ], [ %782, %677 ]
  %682 = phi <4 x float> [ %651, %627 ], [ %779, %677 ]
  %683 = phi <4 x float> [ %650, %627 ], [ %778, %677 ]
  %684 = phi <4 x float> [ %649, %627 ], [ %773, %677 ]
  %685 = phi <4 x float> [ %648, %627 ], [ %772, %677 ]
  %686 = phi <4 x float> [ %647, %627 ], [ %767, %677 ]
  %687 = phi <4 x float> [ %646, %627 ], [ %766, %677 ]
  %688 = phi <4 x float> [ %645, %627 ], [ %761, %677 ]
  %689 = phi <4 x float> [ %644, %627 ], [ %760, %677 ]
  %690 = phi <4 x float> [ %643, %627 ], [ %755, %677 ]
  %691 = phi <4 x float> [ %642, %627 ], [ %754, %677 ]
  %692 = phi <4 x float> [ %641, %627 ], [ %749, %677 ]
  %693 = phi <4 x float> [ %640, %627 ], [ %748, %677 ]
  %694 = phi <4 x float> [ %639, %627 ], [ %743, %677 ]
  %695 = phi <4 x float> [ %638, %627 ], [ %742, %677 ]
  %696 = phi <4 x float> [ %637, %627 ], [ %737, %677 ]
  %697 = phi <4 x float> [ %636, %627 ], [ %736, %677 ]
  %698 = phi <4 x float> [ %635, %627 ], [ %731, %677 ]
  %699 = phi <4 x float> [ %634, %627 ], [ %730, %677 ]
  %700 = phi <4 x float> [ %633, %627 ], [ %725, %677 ]
  %701 = phi <4 x float> [ %632, %627 ], [ %724, %677 ]
  %702 = phi <4 x float> [ %631, %627 ], [ %719, %677 ]
  %703 = phi <4 x float> [ %630, %627 ], [ %718, %677 ]
  %704 = phi <4 x float> [ %629, %627 ], [ %713, %677 ]
  %705 = phi <4 x float> [ %628, %627 ], [ %712, %677 ]
  %706 = phi i64 [ 0, %627 ], [ %792, %677 ]
  %707 = mul nuw nsw i64 %706, 804
  %708 = getelementptr i8, ptr @main.a, i64 %707
  %709 = getelementptr i8, ptr %708, i64 16
  %710 = load <4 x float>, ptr %708, align 4, !tbaa !12
  %711 = load <4 x float>, ptr %709, align 4, !tbaa !12
  %712 = fadd <4 x float> %705, %710
  %713 = fadd <4 x float> %704, %711
  %714 = getelementptr i8, ptr %708, i64 32
  %715 = getelementptr i8, ptr %708, i64 48
  %716 = load <4 x float>, ptr %714, align 4, !tbaa !12
  %717 = load <4 x float>, ptr %715, align 4, !tbaa !12
  %718 = fadd <4 x float> %703, %716
  %719 = fadd <4 x float> %702, %717
  %720 = getelementptr i8, ptr %708, i64 64
  %721 = getelementptr i8, ptr %708, i64 80
  %722 = load <4 x float>, ptr %720, align 4, !tbaa !12
  %723 = load <4 x float>, ptr %721, align 4, !tbaa !12
  %724 = fadd <4 x float> %701, %722
  %725 = fadd <4 x float> %700, %723
  %726 = getelementptr i8, ptr %708, i64 96
  %727 = getelementptr i8, ptr %708, i64 112
  %728 = load <4 x float>, ptr %726, align 4, !tbaa !12
  %729 = load <4 x float>, ptr %727, align 4, !tbaa !12
  %730 = fadd <4 x float> %699, %728
  %731 = fadd <4 x float> %698, %729
  %732 = getelementptr i8, ptr %708, i64 128
  %733 = getelementptr i8, ptr %708, i64 144
  %734 = load <4 x float>, ptr %732, align 4, !tbaa !12
  %735 = load <4 x float>, ptr %733, align 4, !tbaa !12
  %736 = fadd <4 x float> %697, %734
  %737 = fadd <4 x float> %696, %735
  %738 = getelementptr i8, ptr %708, i64 160
  %739 = getelementptr i8, ptr %708, i64 176
  %740 = load <4 x float>, ptr %738, align 4, !tbaa !12
  %741 = load <4 x float>, ptr %739, align 4, !tbaa !12
  %742 = fadd <4 x float> %695, %740
  %743 = fadd <4 x float> %694, %741
  %744 = getelementptr i8, ptr %708, i64 192
  %745 = getelementptr i8, ptr %708, i64 208
  %746 = load <4 x float>, ptr %744, align 4, !tbaa !12
  %747 = load <4 x float>, ptr %745, align 4, !tbaa !12
  %748 = fadd <4 x float> %693, %746
  %749 = fadd <4 x float> %692, %747
  %750 = getelementptr i8, ptr %708, i64 224
  %751 = getelementptr i8, ptr %708, i64 240
  %752 = load <4 x float>, ptr %750, align 4, !tbaa !12
  %753 = load <4 x float>, ptr %751, align 4, !tbaa !12
  %754 = fadd <4 x float> %691, %752
  %755 = fadd <4 x float> %690, %753
  %756 = getelementptr i8, ptr %708, i64 256
  %757 = getelementptr i8, ptr %708, i64 272
  %758 = load <4 x float>, ptr %756, align 4, !tbaa !12
  %759 = load <4 x float>, ptr %757, align 4, !tbaa !12
  %760 = fadd <4 x float> %689, %758
  %761 = fadd <4 x float> %688, %759
  %762 = getelementptr i8, ptr %708, i64 288
  %763 = getelementptr i8, ptr %708, i64 304
  %764 = load <4 x float>, ptr %762, align 4, !tbaa !12
  %765 = load <4 x float>, ptr %763, align 4, !tbaa !12
  %766 = fadd <4 x float> %687, %764
  %767 = fadd <4 x float> %686, %765
  %768 = getelementptr i8, ptr %708, i64 320
  %769 = getelementptr i8, ptr %708, i64 336
  %770 = load <4 x float>, ptr %768, align 4, !tbaa !12
  %771 = load <4 x float>, ptr %769, align 4, !tbaa !12
  %772 = fadd <4 x float> %685, %770
  %773 = fadd <4 x float> %684, %771
  %774 = getelementptr i8, ptr %708, i64 352
  %775 = getelementptr i8, ptr %708, i64 368
  %776 = load <4 x float>, ptr %774, align 4, !tbaa !12
  %777 = load <4 x float>, ptr %775, align 4, !tbaa !12
  %778 = fadd <4 x float> %683, %776
  %779 = fadd <4 x float> %682, %777
  %780 = getelementptr i8, ptr %708, i64 384
  %781 = load float, ptr %780, align 4, !tbaa !12
  %782 = fadd float %681, %781
  %783 = getelementptr i8, ptr %708, i64 388
  %784 = load float, ptr %783, align 4, !tbaa !12
  %785 = fadd float %680, %784
  %786 = getelementptr i8, ptr %708, i64 392
  %787 = load float, ptr %786, align 4, !tbaa !12
  %788 = fadd float %679, %787
  %789 = getelementptr i8, ptr %708, i64 396
  %790 = load float, ptr %789, align 4, !tbaa !12
  %791 = fadd float %678, %790
  %792 = add nuw nsw i64 %706, 1
  %793 = icmp eq i64 %792, 100
  br i1 %793, label %794, label %677, !llvm.loop !17

794:                                              ; preds = %677
  store <4 x float> %712, ptr @main.b, align 16, !tbaa !12
  store <4 x float> %713, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 16), align 16, !tbaa !12
  store <4 x float> %718, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 32), align 16, !tbaa !12
  store <4 x float> %719, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 48), align 16, !tbaa !12
  store <4 x float> %724, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 64), align 16, !tbaa !12
  store <4 x float> %725, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 80), align 16, !tbaa !12
  store <4 x float> %730, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 96), align 16, !tbaa !12
  store <4 x float> %731, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 112), align 16, !tbaa !12
  store <4 x float> %736, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 128), align 16, !tbaa !12
  store <4 x float> %737, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 144), align 16, !tbaa !12
  store <4 x float> %742, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 160), align 16, !tbaa !12
  store <4 x float> %743, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 176), align 16, !tbaa !12
  store <4 x float> %748, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 192), align 16, !tbaa !12
  store <4 x float> %749, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 208), align 16, !tbaa !12
  store <4 x float> %754, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 224), align 16, !tbaa !12
  store <4 x float> %755, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 240), align 16, !tbaa !12
  store <4 x float> %760, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 256), align 16, !tbaa !12
  store <4 x float> %761, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 272), align 16, !tbaa !12
  store <4 x float> %766, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 288), align 16, !tbaa !12
  store <4 x float> %767, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 304), align 16, !tbaa !12
  store <4 x float> %772, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 320), align 16, !tbaa !12
  store <4 x float> %773, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 336), align 16, !tbaa !12
  store <4 x float> %778, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 352), align 16, !tbaa !12
  store <4 x float> %779, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 368), align 16, !tbaa !12
  store float %782, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 384), align 16, !tbaa !12
  store float %785, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 388), align 4, !tbaa !12
  store float %788, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 392), align 8, !tbaa !12
  store float %791, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 396), align 4, !tbaa !12
  %795 = add nuw nsw i32 %621, 1
  %796 = icmp eq i32 %795, %617
  br i1 %796, label %797, label %620, !llvm.loop !28

797:                                              ; preds = %794
  %798 = tail call i64 @clock() #13
  %799 = load ptr, ptr @stderr, align 8, !tbaa !9
  %800 = tail call i32 (ptr, ptr, ...) @fprintf(ptr noundef %799, ptr noundef nonnull @.str.15, i32 noundef %617, double noundef 0.000000e+00) #15
  %801 = shl nsw i32 %617, 1
  %802 = icmp eq i32 %619, 0
  br i1 %802, label %803, label %615, !llvm.loop !29

803:                                              ; preds = %797
  %804 = load ptr, ptr @stderr, align 8, !tbaa !9
  %805 = tail call i32 (ptr, ptr, ...) @fprintf(ptr noundef %804, ptr noundef nonnull @.str.16, double noundef 0.000000e+00) #15
  %806 = load ptr, ptr @stderr, align 8, !tbaa !9
  %807 = tail call i64 @fwrite(ptr nonnull @.str.17, i64 46, i64 1, ptr %806) #14
  br label %808

808:                                              ; preds = %998, %803
  %809 = phi i32 [ 100, %803 ], [ %1000, %998 ]
  %810 = phi i32 [ -3, %803 ], [ %812, %998 ]
  store i32 %809, ptr @main.ntimes, align 4, !tbaa !18
  %811 = tail call i64 @clock() #13
  %812 = add nsw i32 %810, 1
  %813 = load i32, ptr @main.ntimes, align 4, !tbaa !18
  %814 = icmp sgt i32 %813, 0
  br i1 %814, label %815, label %992

815:                                              ; preds = %808, %989
  %816 = phi i32 [ %990, %989 ], [ 0, %808 ]
  br label %817

817:                                              ; preds = %815, %869
  %818 = phi i64 [ %870, %869 ], [ 0, %815 ]
  %819 = phi i32 [ %861, %869 ], [ 1325, %815 ]
  %820 = mul nuw nsw i64 %818, 804
  %821 = getelementptr i8, ptr @main.a, i64 %820
  br label %851

822:                                              ; preds = %869
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(400) @main.b, i8 0, i64 400, i1 false), !tbaa !12
  %823 = load <4 x float>, ptr @main.b, align 16, !tbaa !12
  %824 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 16), align 16, !tbaa !12
  %825 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 32), align 16, !tbaa !12
  %826 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 48), align 16, !tbaa !12
  %827 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 64), align 16, !tbaa !12
  %828 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 80), align 16, !tbaa !12
  %829 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 96), align 16, !tbaa !12
  %830 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 112), align 16, !tbaa !12
  %831 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 128), align 16, !tbaa !12
  %832 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 144), align 16, !tbaa !12
  %833 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 160), align 16, !tbaa !12
  %834 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 176), align 16, !tbaa !12
  %835 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 192), align 16, !tbaa !12
  %836 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 208), align 16, !tbaa !12
  %837 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 224), align 16, !tbaa !12
  %838 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 240), align 16, !tbaa !12
  %839 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 256), align 16, !tbaa !12
  %840 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 272), align 16, !tbaa !12
  %841 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 288), align 16, !tbaa !12
  %842 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 304), align 16, !tbaa !12
  %843 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 320), align 16, !tbaa !12
  %844 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 336), align 16, !tbaa !12
  %845 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 352), align 16, !tbaa !12
  %846 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 368), align 16, !tbaa !12
  %847 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 384), align 16, !tbaa !12
  %848 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 388), align 4, !tbaa !12
  %849 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 392), align 8, !tbaa !12
  %850 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 396), align 4, !tbaa !12
  br label %872

851:                                              ; preds = %851, %817
  %852 = phi i64 [ 0, %817 ], [ %867, %851 ]
  %853 = phi i32 [ %819, %817 ], [ %861, %851 ]
  %854 = mul nuw nsw i32 %853, 3125
  %855 = and i32 %854, 65535
  %856 = add nsw i32 %855, -32768
  %857 = sitofp i32 %856 to float
  %858 = fmul nnan float %857, f0x38800000
  %859 = getelementptr [4 x i8], ptr %821, i64 %852
  store float %858, ptr %859, align 4, !tbaa !12
  %860 = mul nsw i32 %853, 761
  %861 = and i32 %860, 65535
  %862 = add nsw i32 %861, -32768
  %863 = sitofp i32 %862 to float
  %864 = fmul nnan float %863, f0x38800000
  %865 = getelementptr [4 x i8], ptr %821, i64 %852
  %866 = getelementptr i8, ptr %865, i64 4
  store float %864, ptr %866, align 4, !tbaa !12
  %867 = add nuw nsw i64 %852, 2
  %868 = icmp eq i64 %867, 100
  br i1 %868, label %869, label %851, !llvm.loop !14

869:                                              ; preds = %851
  %870 = add nuw nsw i64 %818, 1
  %871 = icmp eq i64 %870, 100
  br i1 %871, label %822, label %817, !llvm.loop !16

872:                                              ; preds = %872, %822
  %873 = phi float [ %850, %822 ], [ %986, %872 ]
  %874 = phi float [ %849, %822 ], [ %983, %872 ]
  %875 = phi float [ %848, %822 ], [ %980, %872 ]
  %876 = phi float [ %847, %822 ], [ %977, %872 ]
  %877 = phi <4 x float> [ %846, %822 ], [ %974, %872 ]
  %878 = phi <4 x float> [ %845, %822 ], [ %973, %872 ]
  %879 = phi <4 x float> [ %844, %822 ], [ %968, %872 ]
  %880 = phi <4 x float> [ %843, %822 ], [ %967, %872 ]
  %881 = phi <4 x float> [ %842, %822 ], [ %962, %872 ]
  %882 = phi <4 x float> [ %841, %822 ], [ %961, %872 ]
  %883 = phi <4 x float> [ %840, %822 ], [ %956, %872 ]
  %884 = phi <4 x float> [ %839, %822 ], [ %955, %872 ]
  %885 = phi <4 x float> [ %838, %822 ], [ %950, %872 ]
  %886 = phi <4 x float> [ %837, %822 ], [ %949, %872 ]
  %887 = phi <4 x float> [ %836, %822 ], [ %944, %872 ]
  %888 = phi <4 x float> [ %835, %822 ], [ %943, %872 ]
  %889 = phi <4 x float> [ %834, %822 ], [ %938, %872 ]
  %890 = phi <4 x float> [ %833, %822 ], [ %937, %872 ]
  %891 = phi <4 x float> [ %832, %822 ], [ %932, %872 ]
  %892 = phi <4 x float> [ %831, %822 ], [ %931, %872 ]
  %893 = phi <4 x float> [ %830, %822 ], [ %926, %872 ]
  %894 = phi <4 x float> [ %829, %822 ], [ %925, %872 ]
  %895 = phi <4 x float> [ %828, %822 ], [ %920, %872 ]
  %896 = phi <4 x float> [ %827, %822 ], [ %919, %872 ]
  %897 = phi <4 x float> [ %826, %822 ], [ %914, %872 ]
  %898 = phi <4 x float> [ %825, %822 ], [ %913, %872 ]
  %899 = phi <4 x float> [ %824, %822 ], [ %908, %872 ]
  %900 = phi <4 x float> [ %823, %822 ], [ %907, %872 ]
  %901 = phi i64 [ 0, %822 ], [ %987, %872 ]
  %902 = mul nuw nsw i64 %901, 804
  %903 = getelementptr i8, ptr @main.a, i64 %902
  %904 = getelementptr i8, ptr %903, i64 16
  %905 = load <4 x float>, ptr %903, align 4, !tbaa !12
  %906 = load <4 x float>, ptr %904, align 4, !tbaa !12
  %907 = fadd <4 x float> %900, %905
  %908 = fadd <4 x float> %899, %906
  %909 = getelementptr i8, ptr %903, i64 32
  %910 = getelementptr i8, ptr %903, i64 48
  %911 = load <4 x float>, ptr %909, align 4, !tbaa !12
  %912 = load <4 x float>, ptr %910, align 4, !tbaa !12
  %913 = fadd <4 x float> %898, %911
  %914 = fadd <4 x float> %897, %912
  %915 = getelementptr i8, ptr %903, i64 64
  %916 = getelementptr i8, ptr %903, i64 80
  %917 = load <4 x float>, ptr %915, align 4, !tbaa !12
  %918 = load <4 x float>, ptr %916, align 4, !tbaa !12
  %919 = fadd <4 x float> %896, %917
  %920 = fadd <4 x float> %895, %918
  %921 = getelementptr i8, ptr %903, i64 96
  %922 = getelementptr i8, ptr %903, i64 112
  %923 = load <4 x float>, ptr %921, align 4, !tbaa !12
  %924 = load <4 x float>, ptr %922, align 4, !tbaa !12
  %925 = fadd <4 x float> %894, %923
  %926 = fadd <4 x float> %893, %924
  %927 = getelementptr i8, ptr %903, i64 128
  %928 = getelementptr i8, ptr %903, i64 144
  %929 = load <4 x float>, ptr %927, align 4, !tbaa !12
  %930 = load <4 x float>, ptr %928, align 4, !tbaa !12
  %931 = fadd <4 x float> %892, %929
  %932 = fadd <4 x float> %891, %930
  %933 = getelementptr i8, ptr %903, i64 160
  %934 = getelementptr i8, ptr %903, i64 176
  %935 = load <4 x float>, ptr %933, align 4, !tbaa !12
  %936 = load <4 x float>, ptr %934, align 4, !tbaa !12
  %937 = fadd <4 x float> %890, %935
  %938 = fadd <4 x float> %889, %936
  %939 = getelementptr i8, ptr %903, i64 192
  %940 = getelementptr i8, ptr %903, i64 208
  %941 = load <4 x float>, ptr %939, align 4, !tbaa !12
  %942 = load <4 x float>, ptr %940, align 4, !tbaa !12
  %943 = fadd <4 x float> %888, %941
  %944 = fadd <4 x float> %887, %942
  %945 = getelementptr i8, ptr %903, i64 224
  %946 = getelementptr i8, ptr %903, i64 240
  %947 = load <4 x float>, ptr %945, align 4, !tbaa !12
  %948 = load <4 x float>, ptr %946, align 4, !tbaa !12
  %949 = fadd <4 x float> %886, %947
  %950 = fadd <4 x float> %885, %948
  %951 = getelementptr i8, ptr %903, i64 256
  %952 = getelementptr i8, ptr %903, i64 272
  %953 = load <4 x float>, ptr %951, align 4, !tbaa !12
  %954 = load <4 x float>, ptr %952, align 4, !tbaa !12
  %955 = fadd <4 x float> %884, %953
  %956 = fadd <4 x float> %883, %954
  %957 = getelementptr i8, ptr %903, i64 288
  %958 = getelementptr i8, ptr %903, i64 304
  %959 = load <4 x float>, ptr %957, align 4, !tbaa !12
  %960 = load <4 x float>, ptr %958, align 4, !tbaa !12
  %961 = fadd <4 x float> %882, %959
  %962 = fadd <4 x float> %881, %960
  %963 = getelementptr i8, ptr %903, i64 320
  %964 = getelementptr i8, ptr %903, i64 336
  %965 = load <4 x float>, ptr %963, align 4, !tbaa !12
  %966 = load <4 x float>, ptr %964, align 4, !tbaa !12
  %967 = fadd <4 x float> %880, %965
  %968 = fadd <4 x float> %879, %966
  %969 = getelementptr i8, ptr %903, i64 352
  %970 = getelementptr i8, ptr %903, i64 368
  %971 = load <4 x float>, ptr %969, align 4, !tbaa !12
  %972 = load <4 x float>, ptr %970, align 4, !tbaa !12
  %973 = fadd <4 x float> %878, %971
  %974 = fadd <4 x float> %877, %972
  %975 = getelementptr i8, ptr %903, i64 384
  %976 = load float, ptr %975, align 4, !tbaa !12
  %977 = fadd float %876, %976
  %978 = getelementptr i8, ptr %903, i64 388
  %979 = load float, ptr %978, align 4, !tbaa !12
  %980 = fadd float %875, %979
  %981 = getelementptr i8, ptr %903, i64 392
  %982 = load float, ptr %981, align 4, !tbaa !12
  %983 = fadd float %874, %982
  %984 = getelementptr i8, ptr %903, i64 396
  %985 = load float, ptr %984, align 4, !tbaa !12
  %986 = fadd float %873, %985
  %987 = add nuw nsw i64 %901, 1
  %988 = icmp eq i64 %987, 100
  br i1 %988, label %989, label %872, !llvm.loop !17

989:                                              ; preds = %872
  store <4 x float> %907, ptr @main.b, align 16, !tbaa !12
  store <4 x float> %908, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 16), align 16, !tbaa !12
  store <4 x float> %913, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 32), align 16, !tbaa !12
  store <4 x float> %914, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 48), align 16, !tbaa !12
  store <4 x float> %919, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 64), align 16, !tbaa !12
  store <4 x float> %920, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 80), align 16, !tbaa !12
  store <4 x float> %925, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 96), align 16, !tbaa !12
  store <4 x float> %926, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 112), align 16, !tbaa !12
  store <4 x float> %931, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 128), align 16, !tbaa !12
  store <4 x float> %932, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 144), align 16, !tbaa !12
  store <4 x float> %937, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 160), align 16, !tbaa !12
  store <4 x float> %938, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 176), align 16, !tbaa !12
  store <4 x float> %943, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 192), align 16, !tbaa !12
  store <4 x float> %944, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 208), align 16, !tbaa !12
  store <4 x float> %949, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 224), align 16, !tbaa !12
  store <4 x float> %950, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 240), align 16, !tbaa !12
  store <4 x float> %955, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 256), align 16, !tbaa !12
  store <4 x float> %956, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 272), align 16, !tbaa !12
  store <4 x float> %961, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 288), align 16, !tbaa !12
  store <4 x float> %962, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 304), align 16, !tbaa !12
  store <4 x float> %967, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 320), align 16, !tbaa !12
  store <4 x float> %968, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 336), align 16, !tbaa !12
  store <4 x float> %973, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 352), align 16, !tbaa !12
  store <4 x float> %974, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 368), align 16, !tbaa !12
  store float %977, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 384), align 16, !tbaa !12
  store float %980, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 388), align 4, !tbaa !12
  store float %983, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 392), align 8, !tbaa !12
  store float %986, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 396), align 4, !tbaa !12
  tail call void @dgefa(ptr noundef nonnull @main.a, i32 noundef 201, i32 noundef 100, ptr noundef nonnull @main.ipvt, ptr noundef nonnull @main.info)
  %990 = add nuw nsw i32 %816, 1
  %991 = icmp eq i32 %990, %813
  br i1 %991, label %992, label %815, !llvm.loop !30

992:                                              ; preds = %989, %808
  %993 = tail call i64 @clock() #13
  %994 = load ptr, ptr @stderr, align 8, !tbaa !9
  %995 = load i32, ptr @main.ntimes, align 4, !tbaa !18
  %996 = tail call i32 (ptr, ptr, ...) @fprintf(ptr noundef %994, ptr noundef nonnull @.str.15, i32 noundef %995, double noundef 0.000000e+00) #15
  %997 = icmp eq i32 %810, -1
  br i1 %997, label %1001, label %998

998:                                              ; preds = %992
  %999 = load i32, ptr @main.ntimes, align 4, !tbaa !18
  %1000 = shl nsw i32 %999, 1
  br label %808, !llvm.loop !31

1001:                                             ; preds = %992
  %1002 = sitofp i64 %618 to float
  %1003 = fdiv nnan float %1002, 1.000000e+06
  %1004 = sitofp i64 %798 to float
  %1005 = fdiv nnan float %1004, 1.000000e+06
  %1006 = fsub float %1005, %1003
  %1007 = fdiv float %1006, 4.000000e+02
  store i32 1000, ptr @main.ntimes, align 4
  %1008 = load ptr, ptr @stderr, align 8, !tbaa !9
  %1009 = tail call i32 (ptr, ptr, ...) @fprintf(ptr noundef %1008, ptr noundef nonnull @.str.18, i32 noundef 0) #15
  %1010 = load ptr, ptr @stderr, align 8, !tbaa !9
  %1011 = tail call i32 (ptr, ptr, ...) @fprintf(ptr noundef %1010, ptr noundef nonnull @.str.19, i32 noundef 201) #15
  %1012 = load ptr, ptr @stderr, align 8, !tbaa !9
  %1013 = tail call i64 @fwrite(ptr nonnull @.str.12, i64 55, i64 1, ptr %1012) #14
  %1014 = load ptr, ptr @stderr, align 8, !tbaa !9
  %1015 = tail call i64 @fwrite(ptr nonnull @.str.13, i64 12, i64 1, ptr %1014) #14
  %1016 = load i32, ptr @main.ntimes, align 4, !tbaa !18
  %1017 = sitofp i32 %1016 to float
  %1018 = fmul float %1007, %1017
  store float 0.000000e+00, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 204), align 4, !tbaa !12
  store i32 1, ptr @main.j, align 4, !tbaa !18
  br label %1019

1019:                                             ; preds = %1001, %1331
  %1020 = tail call i64 @clock() #13
  %1021 = sitofp i64 %1020 to float
  %1022 = fdiv float %1021, 1.000000e+06
  %1023 = load i32, ptr @main.ntimes, align 4, !tbaa !18
  %1024 = icmp sgt i32 %1023, 0
  br i1 %1024, label %1025, label %1202

1025:                                             ; preds = %1019, %1199
  %1026 = phi i32 [ %1200, %1199 ], [ 0, %1019 ]
  br label %1027

1027:                                             ; preds = %1025, %1079
  %1028 = phi i64 [ %1080, %1079 ], [ 0, %1025 ]
  %1029 = phi i32 [ %1071, %1079 ], [ 1325, %1025 ]
  %1030 = mul nuw nsw i64 %1028, 804
  %1031 = getelementptr i8, ptr @main.a, i64 %1030
  br label %1061

1032:                                             ; preds = %1079
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(400) @main.b, i8 0, i64 400, i1 false), !tbaa !12
  %1033 = load <4 x float>, ptr @main.b, align 16, !tbaa !12
  %1034 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 16), align 16, !tbaa !12
  %1035 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 32), align 16, !tbaa !12
  %1036 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 48), align 16, !tbaa !12
  %1037 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 64), align 16, !tbaa !12
  %1038 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 80), align 16, !tbaa !12
  %1039 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 96), align 16, !tbaa !12
  %1040 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 112), align 16, !tbaa !12
  %1041 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 128), align 16, !tbaa !12
  %1042 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 144), align 16, !tbaa !12
  %1043 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 160), align 16, !tbaa !12
  %1044 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 176), align 16, !tbaa !12
  %1045 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 192), align 16, !tbaa !12
  %1046 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 208), align 16, !tbaa !12
  %1047 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 224), align 16, !tbaa !12
  %1048 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 240), align 16, !tbaa !12
  %1049 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 256), align 16, !tbaa !12
  %1050 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 272), align 16, !tbaa !12
  %1051 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 288), align 16, !tbaa !12
  %1052 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 304), align 16, !tbaa !12
  %1053 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 320), align 16, !tbaa !12
  %1054 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 336), align 16, !tbaa !12
  %1055 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 352), align 16, !tbaa !12
  %1056 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 368), align 16, !tbaa !12
  %1057 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 384), align 16, !tbaa !12
  %1058 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 388), align 4, !tbaa !12
  %1059 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 392), align 8, !tbaa !12
  %1060 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 396), align 4, !tbaa !12
  br label %1082

1061:                                             ; preds = %1061, %1027
  %1062 = phi i64 [ 0, %1027 ], [ %1077, %1061 ]
  %1063 = phi i32 [ %1029, %1027 ], [ %1071, %1061 ]
  %1064 = mul nuw nsw i32 %1063, 3125
  %1065 = and i32 %1064, 65535
  %1066 = add nsw i32 %1065, -32768
  %1067 = sitofp i32 %1066 to float
  %1068 = fmul nnan float %1067, f0x38800000
  %1069 = getelementptr [4 x i8], ptr %1031, i64 %1062
  store float %1068, ptr %1069, align 4, !tbaa !12
  %1070 = mul nsw i32 %1063, 761
  %1071 = and i32 %1070, 65535
  %1072 = add nsw i32 %1071, -32768
  %1073 = sitofp i32 %1072 to float
  %1074 = fmul nnan float %1073, f0x38800000
  %1075 = getelementptr [4 x i8], ptr %1031, i64 %1062
  %1076 = getelementptr i8, ptr %1075, i64 4
  store float %1074, ptr %1076, align 4, !tbaa !12
  %1077 = add nuw nsw i64 %1062, 2
  %1078 = icmp eq i64 %1077, 100
  br i1 %1078, label %1079, label %1061, !llvm.loop !14

1079:                                             ; preds = %1061
  %1080 = add nuw nsw i64 %1028, 1
  %1081 = icmp eq i64 %1080, 100
  br i1 %1081, label %1032, label %1027, !llvm.loop !16

1082:                                             ; preds = %1082, %1032
  %1083 = phi float [ %1060, %1032 ], [ %1196, %1082 ]
  %1084 = phi float [ %1059, %1032 ], [ %1193, %1082 ]
  %1085 = phi float [ %1058, %1032 ], [ %1190, %1082 ]
  %1086 = phi float [ %1057, %1032 ], [ %1187, %1082 ]
  %1087 = phi <4 x float> [ %1056, %1032 ], [ %1184, %1082 ]
  %1088 = phi <4 x float> [ %1055, %1032 ], [ %1183, %1082 ]
  %1089 = phi <4 x float> [ %1054, %1032 ], [ %1178, %1082 ]
  %1090 = phi <4 x float> [ %1053, %1032 ], [ %1177, %1082 ]
  %1091 = phi <4 x float> [ %1052, %1032 ], [ %1172, %1082 ]
  %1092 = phi <4 x float> [ %1051, %1032 ], [ %1171, %1082 ]
  %1093 = phi <4 x float> [ %1050, %1032 ], [ %1166, %1082 ]
  %1094 = phi <4 x float> [ %1049, %1032 ], [ %1165, %1082 ]
  %1095 = phi <4 x float> [ %1048, %1032 ], [ %1160, %1082 ]
  %1096 = phi <4 x float> [ %1047, %1032 ], [ %1159, %1082 ]
  %1097 = phi <4 x float> [ %1046, %1032 ], [ %1154, %1082 ]
  %1098 = phi <4 x float> [ %1045, %1032 ], [ %1153, %1082 ]
  %1099 = phi <4 x float> [ %1044, %1032 ], [ %1148, %1082 ]
  %1100 = phi <4 x float> [ %1043, %1032 ], [ %1147, %1082 ]
  %1101 = phi <4 x float> [ %1042, %1032 ], [ %1142, %1082 ]
  %1102 = phi <4 x float> [ %1041, %1032 ], [ %1141, %1082 ]
  %1103 = phi <4 x float> [ %1040, %1032 ], [ %1136, %1082 ]
  %1104 = phi <4 x float> [ %1039, %1032 ], [ %1135, %1082 ]
  %1105 = phi <4 x float> [ %1038, %1032 ], [ %1130, %1082 ]
  %1106 = phi <4 x float> [ %1037, %1032 ], [ %1129, %1082 ]
  %1107 = phi <4 x float> [ %1036, %1032 ], [ %1124, %1082 ]
  %1108 = phi <4 x float> [ %1035, %1032 ], [ %1123, %1082 ]
  %1109 = phi <4 x float> [ %1034, %1032 ], [ %1118, %1082 ]
  %1110 = phi <4 x float> [ %1033, %1032 ], [ %1117, %1082 ]
  %1111 = phi i64 [ 0, %1032 ], [ %1197, %1082 ]
  %1112 = mul nuw nsw i64 %1111, 804
  %1113 = getelementptr i8, ptr @main.a, i64 %1112
  %1114 = getelementptr i8, ptr %1113, i64 16
  %1115 = load <4 x float>, ptr %1113, align 4, !tbaa !12
  %1116 = load <4 x float>, ptr %1114, align 4, !tbaa !12
  %1117 = fadd <4 x float> %1110, %1115
  %1118 = fadd <4 x float> %1109, %1116
  %1119 = getelementptr i8, ptr %1113, i64 32
  %1120 = getelementptr i8, ptr %1113, i64 48
  %1121 = load <4 x float>, ptr %1119, align 4, !tbaa !12
  %1122 = load <4 x float>, ptr %1120, align 4, !tbaa !12
  %1123 = fadd <4 x float> %1108, %1121
  %1124 = fadd <4 x float> %1107, %1122
  %1125 = getelementptr i8, ptr %1113, i64 64
  %1126 = getelementptr i8, ptr %1113, i64 80
  %1127 = load <4 x float>, ptr %1125, align 4, !tbaa !12
  %1128 = load <4 x float>, ptr %1126, align 4, !tbaa !12
  %1129 = fadd <4 x float> %1106, %1127
  %1130 = fadd <4 x float> %1105, %1128
  %1131 = getelementptr i8, ptr %1113, i64 96
  %1132 = getelementptr i8, ptr %1113, i64 112
  %1133 = load <4 x float>, ptr %1131, align 4, !tbaa !12
  %1134 = load <4 x float>, ptr %1132, align 4, !tbaa !12
  %1135 = fadd <4 x float> %1104, %1133
  %1136 = fadd <4 x float> %1103, %1134
  %1137 = getelementptr i8, ptr %1113, i64 128
  %1138 = getelementptr i8, ptr %1113, i64 144
  %1139 = load <4 x float>, ptr %1137, align 4, !tbaa !12
  %1140 = load <4 x float>, ptr %1138, align 4, !tbaa !12
  %1141 = fadd <4 x float> %1102, %1139
  %1142 = fadd <4 x float> %1101, %1140
  %1143 = getelementptr i8, ptr %1113, i64 160
  %1144 = getelementptr i8, ptr %1113, i64 176
  %1145 = load <4 x float>, ptr %1143, align 4, !tbaa !12
  %1146 = load <4 x float>, ptr %1144, align 4, !tbaa !12
  %1147 = fadd <4 x float> %1100, %1145
  %1148 = fadd <4 x float> %1099, %1146
  %1149 = getelementptr i8, ptr %1113, i64 192
  %1150 = getelementptr i8, ptr %1113, i64 208
  %1151 = load <4 x float>, ptr %1149, align 4, !tbaa !12
  %1152 = load <4 x float>, ptr %1150, align 4, !tbaa !12
  %1153 = fadd <4 x float> %1098, %1151
  %1154 = fadd <4 x float> %1097, %1152
  %1155 = getelementptr i8, ptr %1113, i64 224
  %1156 = getelementptr i8, ptr %1113, i64 240
  %1157 = load <4 x float>, ptr %1155, align 4, !tbaa !12
  %1158 = load <4 x float>, ptr %1156, align 4, !tbaa !12
  %1159 = fadd <4 x float> %1096, %1157
  %1160 = fadd <4 x float> %1095, %1158
  %1161 = getelementptr i8, ptr %1113, i64 256
  %1162 = getelementptr i8, ptr %1113, i64 272
  %1163 = load <4 x float>, ptr %1161, align 4, !tbaa !12
  %1164 = load <4 x float>, ptr %1162, align 4, !tbaa !12
  %1165 = fadd <4 x float> %1094, %1163
  %1166 = fadd <4 x float> %1093, %1164
  %1167 = getelementptr i8, ptr %1113, i64 288
  %1168 = getelementptr i8, ptr %1113, i64 304
  %1169 = load <4 x float>, ptr %1167, align 4, !tbaa !12
  %1170 = load <4 x float>, ptr %1168, align 4, !tbaa !12
  %1171 = fadd <4 x float> %1092, %1169
  %1172 = fadd <4 x float> %1091, %1170
  %1173 = getelementptr i8, ptr %1113, i64 320
  %1174 = getelementptr i8, ptr %1113, i64 336
  %1175 = load <4 x float>, ptr %1173, align 4, !tbaa !12
  %1176 = load <4 x float>, ptr %1174, align 4, !tbaa !12
  %1177 = fadd <4 x float> %1090, %1175
  %1178 = fadd <4 x float> %1089, %1176
  %1179 = getelementptr i8, ptr %1113, i64 352
  %1180 = getelementptr i8, ptr %1113, i64 368
  %1181 = load <4 x float>, ptr %1179, align 4, !tbaa !12
  %1182 = load <4 x float>, ptr %1180, align 4, !tbaa !12
  %1183 = fadd <4 x float> %1088, %1181
  %1184 = fadd <4 x float> %1087, %1182
  %1185 = getelementptr i8, ptr %1113, i64 384
  %1186 = load float, ptr %1185, align 4, !tbaa !12
  %1187 = fadd float %1086, %1186
  %1188 = getelementptr i8, ptr %1113, i64 388
  %1189 = load float, ptr %1188, align 4, !tbaa !12
  %1190 = fadd float %1085, %1189
  %1191 = getelementptr i8, ptr %1113, i64 392
  %1192 = load float, ptr %1191, align 4, !tbaa !12
  %1193 = fadd float %1084, %1192
  %1194 = getelementptr i8, ptr %1113, i64 396
  %1195 = load float, ptr %1194, align 4, !tbaa !12
  %1196 = fadd float %1083, %1195
  %1197 = add nuw nsw i64 %1111, 1
  %1198 = icmp eq i64 %1197, 100
  br i1 %1198, label %1199, label %1082, !llvm.loop !17

1199:                                             ; preds = %1082
  store <4 x float> %1117, ptr @main.b, align 16, !tbaa !12
  store <4 x float> %1118, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 16), align 16, !tbaa !12
  store <4 x float> %1123, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 32), align 16, !tbaa !12
  store <4 x float> %1124, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 48), align 16, !tbaa !12
  store <4 x float> %1129, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 64), align 16, !tbaa !12
  store <4 x float> %1130, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 80), align 16, !tbaa !12
  store <4 x float> %1135, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 96), align 16, !tbaa !12
  store <4 x float> %1136, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 112), align 16, !tbaa !12
  store <4 x float> %1141, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 128), align 16, !tbaa !12
  store <4 x float> %1142, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 144), align 16, !tbaa !12
  store <4 x float> %1147, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 160), align 16, !tbaa !12
  store <4 x float> %1148, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 176), align 16, !tbaa !12
  store <4 x float> %1153, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 192), align 16, !tbaa !12
  store <4 x float> %1154, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 208), align 16, !tbaa !12
  store <4 x float> %1159, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 224), align 16, !tbaa !12
  store <4 x float> %1160, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 240), align 16, !tbaa !12
  store <4 x float> %1165, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 256), align 16, !tbaa !12
  store <4 x float> %1166, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 272), align 16, !tbaa !12
  store <4 x float> %1171, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 288), align 16, !tbaa !12
  store <4 x float> %1172, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 304), align 16, !tbaa !12
  store <4 x float> %1177, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 320), align 16, !tbaa !12
  store <4 x float> %1178, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 336), align 16, !tbaa !12
  store <4 x float> %1183, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 352), align 16, !tbaa !12
  store <4 x float> %1184, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 368), align 16, !tbaa !12
  store float %1187, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 384), align 16, !tbaa !12
  store float %1190, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 388), align 4, !tbaa !12
  store float %1193, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 392), align 8, !tbaa !12
  store float %1196, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 396), align 4, !tbaa !12
  tail call void @dgefa(ptr noundef nonnull @main.a, i32 noundef 201, i32 noundef 100, ptr noundef nonnull @main.ipvt, ptr noundef nonnull @main.info)
  %1200 = add nuw nsw i32 %1026, 1
  %1201 = icmp eq i32 %1200, %1023
  br i1 %1201, label %1202, label %1025, !llvm.loop !32

1202:                                             ; preds = %1199, %1019
  %1203 = tail call i64 @clock() #13
  %1204 = sitofp i64 %1203 to float
  %1205 = fdiv float %1204, 1.000000e+06
  %1206 = fsub float %1205, %1022
  %1207 = fsub float %1206, %1018
  %1208 = load i32, ptr @main.ntimes, align 4, !tbaa !18
  %1209 = sitofp i32 %1208 to float
  %1210 = fdiv float %1207, %1209
  %1211 = load i32, ptr @main.j, align 4, !tbaa !18
  %1212 = sext i32 %1211 to i64
  %1213 = getelementptr inbounds [4 x i8], ptr @atime, i64 %1212
  store float %1210, ptr %1213, align 4, !tbaa !12
  %1214 = tail call i64 @clock() #13
  %1215 = sitofp i64 %1214 to float
  %1216 = fdiv float %1215, 1.000000e+06
  %1217 = load i32, ptr @main.ntimes, align 4, !tbaa !18
  %1218 = icmp sgt i32 %1217, 0
  br i1 %1218, label %1219, label %1331

1219:                                             ; preds = %1202, %1328
  %1220 = phi i32 [ %1329, %1328 ], [ 0, %1202 ]
  br label %1221

1221:                                             ; preds = %1219, %1274
  %1222 = phi i64 [ %1234, %1274 ], [ 0, %1219 ]
  %1223 = getelementptr inbounds nuw [4 x i8], ptr @main.ipvt, i64 %1222
  %1224 = load i32, ptr %1223, align 4, !tbaa !18
  %1225 = sext i32 %1224 to i64
  %1226 = getelementptr inbounds [4 x i8], ptr @main.b, i64 %1225
  %1227 = load float, ptr %1226, align 4, !tbaa !12
  %1228 = zext i32 %1224 to i64
  %1229 = icmp eq i64 %1222, %1228
  br i1 %1229, label %1233, label %1230

1230:                                             ; preds = %1221
  %1231 = getelementptr inbounds nuw [4 x i8], ptr @main.b, i64 %1222
  %1232 = load float, ptr %1231, align 4, !tbaa !12
  store float %1232, ptr %1226, align 4, !tbaa !12
  store float %1227, ptr %1231, align 4, !tbaa !12
  br label %1233

1233:                                             ; preds = %1230, %1221
  %1234 = add nuw nsw i64 %1222, 1
  %1235 = mul nuw nsw i64 %1222, 808
  %1236 = getelementptr i8, ptr @main.a, i64 %1235
  %1237 = getelementptr i8, ptr %1236, i64 4
  %1238 = getelementptr inbounds nuw [4 x i8], ptr @main.b, i64 %1234
  %1239 = fcmp oeq float %1227, 0.000000e+00
  br i1 %1239, label %1274, label %1240

1240:                                             ; preds = %1233
  %1241 = sub nuw nsw i64 99, %1222
  %1242 = icmp samesign ugt i64 %1222, 91
  br i1 %1242, label %1263, label %1243

1243:                                             ; preds = %1240
  %1244 = and i64 %1241, 120
  %1245 = insertelement <4 x float> poison, float %1227, i64 0
  %1246 = shufflevector <4 x float> %1245, <4 x float> poison, <4 x i32> zeroinitializer
  br label %1247

1247:                                             ; preds = %1247, %1243
  %1248 = phi i64 [ 0, %1243 ], [ %1259, %1247 ]
  %1249 = getelementptr inbounds nuw [4 x i8], ptr %1238, i64 %1248
  %1250 = getelementptr inbounds nuw i8, ptr %1249, i64 16
  %1251 = load <4 x float>, ptr %1249, align 4, !tbaa !12
  %1252 = load <4 x float>, ptr %1250, align 4, !tbaa !12
  %1253 = getelementptr inbounds nuw [4 x i8], ptr %1237, i64 %1248
  %1254 = getelementptr inbounds nuw i8, ptr %1253, i64 16
  %1255 = load <4 x float>, ptr %1253, align 4, !tbaa !12
  %1256 = load <4 x float>, ptr %1254, align 4, !tbaa !12
  %1257 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %1246, <4 x float> %1255, <4 x float> %1251)
  %1258 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %1246, <4 x float> %1256, <4 x float> %1252)
  store <4 x float> %1257, ptr %1249, align 4, !tbaa !12
  store <4 x float> %1258, ptr %1250, align 4, !tbaa !12
  %1259 = add nuw i64 %1248, 8
  %1260 = icmp eq i64 %1259, %1244
  br i1 %1260, label %1261, label %1247, !llvm.loop !33

1261:                                             ; preds = %1247
  %1262 = icmp eq i64 %1241, %1244
  br i1 %1262, label %1274, label %1263

1263:                                             ; preds = %1240, %1261
  %1264 = phi i64 [ 0, %1240 ], [ %1244, %1261 ]
  br label %1265

1265:                                             ; preds = %1263, %1265
  %1266 = phi i64 [ %1272, %1265 ], [ %1264, %1263 ]
  %1267 = getelementptr inbounds nuw [4 x i8], ptr %1238, i64 %1266
  %1268 = load float, ptr %1267, align 4, !tbaa !12
  %1269 = getelementptr inbounds nuw [4 x i8], ptr %1237, i64 %1266
  %1270 = load float, ptr %1269, align 4, !tbaa !12
  %1271 = tail call float @llvm.fmuladd.f32(float %1227, float %1270, float %1268)
  store float %1271, ptr %1267, align 4, !tbaa !12
  %1272 = add nuw nsw i64 %1266, 1
  %1273 = icmp eq i64 %1272, %1241
  br i1 %1273, label %1274, label %1265, !llvm.loop !34

1274:                                             ; preds = %1265, %1261, %1233
  %1275 = icmp eq i64 %1234, 99
  br i1 %1275, label %1276, label %1221, !llvm.loop !23

1276:                                             ; preds = %1274, %1326
  %1277 = phi i64 [ %1278, %1326 ], [ 0, %1274 ]
  %1278 = add nuw nsw i64 %1277, 1
  %1279 = sub nuw nsw i64 99, %1277
  %1280 = getelementptr inbounds nuw [4 x i8], ptr @main.b, i64 %1279
  %1281 = load float, ptr %1280, align 4, !tbaa !12
  %1282 = getelementptr [4 x i8], ptr @main.a, i64 %1279
  %1283 = mul nuw nsw i64 %1279, 804
  %1284 = getelementptr i8, ptr %1282, i64 %1283
  %1285 = load float, ptr %1284, align 4, !tbaa !12
  %1286 = fdiv float %1281, %1285
  store float %1286, ptr %1280, align 4, !tbaa !12
  %1287 = fneg float %1286
  %1288 = mul nuw nsw i64 %1279, 804
  %1289 = getelementptr inbounds nuw i8, ptr @main.a, i64 %1288
  %1290 = icmp samesign ugt i64 %1277, 98
  %1291 = fcmp oeq float %1286, 0.000000e+00
  %1292 = or i1 %1290, %1291
  br i1 %1292, label %1326, label %1293

1293:                                             ; preds = %1276
  %1294 = icmp samesign ugt i64 %1277, 91
  br i1 %1294, label %1315, label %1295

1295:                                             ; preds = %1293
  %1296 = and i64 %1279, 120
  %1297 = insertelement <4 x float> poison, float %1287, i64 0
  %1298 = shufflevector <4 x float> %1297, <4 x float> poison, <4 x i32> zeroinitializer
  br label %1299

1299:                                             ; preds = %1299, %1295
  %1300 = phi i64 [ 0, %1295 ], [ %1311, %1299 ]
  %1301 = getelementptr inbounds nuw [4 x i8], ptr @main.b, i64 %1300
  %1302 = getelementptr inbounds nuw i8, ptr %1301, i64 16
  %1303 = load <4 x float>, ptr %1301, align 16, !tbaa !12
  %1304 = load <4 x float>, ptr %1302, align 16, !tbaa !12
  %1305 = getelementptr inbounds nuw [4 x i8], ptr %1289, i64 %1300
  %1306 = getelementptr inbounds nuw i8, ptr %1305, i64 16
  %1307 = load <4 x float>, ptr %1305, align 4, !tbaa !12
  %1308 = load <4 x float>, ptr %1306, align 4, !tbaa !12
  %1309 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %1298, <4 x float> %1307, <4 x float> %1303)
  %1310 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %1298, <4 x float> %1308, <4 x float> %1304)
  store <4 x float> %1309, ptr %1301, align 16, !tbaa !12
  store <4 x float> %1310, ptr %1302, align 16, !tbaa !12
  %1311 = add nuw i64 %1300, 8
  %1312 = icmp eq i64 %1311, %1296
  br i1 %1312, label %1313, label %1299, !llvm.loop !35

1313:                                             ; preds = %1299
  %1314 = icmp eq i64 %1279, %1296
  br i1 %1314, label %1326, label %1315

1315:                                             ; preds = %1293, %1313
  %1316 = phi i64 [ 0, %1293 ], [ %1296, %1313 ]
  br label %1317

1317:                                             ; preds = %1315, %1317
  %1318 = phi i64 [ %1324, %1317 ], [ %1316, %1315 ]
  %1319 = getelementptr inbounds nuw [4 x i8], ptr @main.b, i64 %1318
  %1320 = load float, ptr %1319, align 4, !tbaa !12
  %1321 = getelementptr inbounds nuw [4 x i8], ptr %1289, i64 %1318
  %1322 = load float, ptr %1321, align 4, !tbaa !12
  %1323 = tail call float @llvm.fmuladd.f32(float %1287, float %1322, float %1320)
  store float %1323, ptr %1319, align 4, !tbaa !12
  %1324 = add nuw nsw i64 %1318, 1
  %1325 = icmp eq i64 %1324, %1279
  br i1 %1325, label %1326, label %1317, !llvm.loop !36

1326:                                             ; preds = %1317, %1313, %1276
  %1327 = icmp eq i64 %1278, 100
  br i1 %1327, label %1328, label %1276, !llvm.loop !26

1328:                                             ; preds = %1326
  %1329 = add nuw nsw i32 %1220, 1
  %1330 = icmp eq i32 %1329, %1217
  br i1 %1330, label %1331, label %1219, !llvm.loop !37

1331:                                             ; preds = %1328, %1202
  %1332 = tail call i64 @clock() #13
  %1333 = sitofp i64 %1332 to float
  %1334 = fdiv float %1333, 1.000000e+06
  %1335 = fsub float %1334, %1216
  %1336 = load i32, ptr @main.ntimes, align 4, !tbaa !18
  %1337 = sitofp i32 %1336 to float
  %1338 = fdiv float %1335, %1337
  %1339 = load i32, ptr @main.j, align 4, !tbaa !18
  %1340 = sext i32 %1339 to i64
  %1341 = getelementptr inbounds [4 x i8], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 60), i64 %1340
  store float %1338, ptr %1341, align 4, !tbaa !12
  %1342 = getelementptr inbounds [4 x i8], ptr @atime, i64 %1340
  %1343 = load float, ptr %1342, align 4, !tbaa !12
  %1344 = fadd float %1343, %1338
  %1345 = getelementptr inbounds [4 x i8], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 120), i64 %1340
  store float %1344, ptr %1345, align 4, !tbaa !12
  %1346 = fpext float %1344 to double
  %1347 = fmul double %1346, 1.000000e+06
  %1348 = fdiv double f0x4124F49560000000, %1347
  %1349 = fptrunc double %1348 to float
  %1350 = getelementptr inbounds [4 x i8], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 180), i64 %1340
  store float %1349, ptr %1350, align 4, !tbaa !12
  %1351 = fdiv float 2.000000e+00, %1349
  %1352 = getelementptr inbounds [4 x i8], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 240), i64 %1340
  store float %1351, ptr %1352, align 4, !tbaa !12
  %1353 = fdiv float %1344, 5.600000e-02
  %1354 = getelementptr inbounds [4 x i8], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 300), i64 %1340
  store float %1353, ptr %1354, align 4, !tbaa !12
  %1355 = load float, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 204), align 4, !tbaa !12
  %1356 = fadd float %1355, %1349
  store float %1356, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 204), align 4, !tbaa !12
  %1357 = add nsw i32 %1339, 1
  store i32 %1357, ptr @main.j, align 4, !tbaa !18
  %1358 = icmp slt i32 %1339, 5
  br i1 %1358, label %1019, label %1359, !llvm.loop !38

1359:                                             ; preds = %1331
  %1360 = fdiv float %1356, 5.000000e+00
  store float %1360, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 204), align 4, !tbaa !12
  %1361 = load ptr, ptr @stderr, align 8, !tbaa !9
  %1362 = tail call i32 (ptr, ptr, ...) @fprintf(ptr noundef %1361, ptr noundef nonnull @.str.20, double noundef 0.000000e+00) #15
  %1363 = load ptr, ptr @stderr, align 8, !tbaa !9
  %1364 = tail call i64 @fwrite(ptr nonnull @.str.21, i64 30, i64 1, ptr %1363) #14
  %1365 = tail call i64 @clock() #13
  %1366 = sitofp i64 %1365 to float
  %1367 = fdiv nnan float %1366, 1.000000e+06
  br label %1368

1368:                                             ; preds = %1359, %1542
  %1369 = phi i32 [ %1543, %1542 ], [ 0, %1359 ]
  br label %1370

1370:                                             ; preds = %1368, %1422
  %1371 = phi i64 [ %1423, %1422 ], [ 0, %1368 ]
  %1372 = phi i32 [ %1414, %1422 ], [ 1325, %1368 ]
  %1373 = mul nuw nsw i64 %1371, 800
  %1374 = getelementptr i8, ptr @main.aa, i64 %1373
  br label %1404

1375:                                             ; preds = %1422
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(400) @main.b, i8 0, i64 400, i1 false), !tbaa !12
  %1376 = load <4 x float>, ptr @main.b, align 16, !tbaa !12
  %1377 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 16), align 16, !tbaa !12
  %1378 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 32), align 16, !tbaa !12
  %1379 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 48), align 16, !tbaa !12
  %1380 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 64), align 16, !tbaa !12
  %1381 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 80), align 16, !tbaa !12
  %1382 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 96), align 16, !tbaa !12
  %1383 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 112), align 16, !tbaa !12
  %1384 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 128), align 16, !tbaa !12
  %1385 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 144), align 16, !tbaa !12
  %1386 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 160), align 16, !tbaa !12
  %1387 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 176), align 16, !tbaa !12
  %1388 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 192), align 16, !tbaa !12
  %1389 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 208), align 16, !tbaa !12
  %1390 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 224), align 16, !tbaa !12
  %1391 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 240), align 16, !tbaa !12
  %1392 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 256), align 16, !tbaa !12
  %1393 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 272), align 16, !tbaa !12
  %1394 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 288), align 16, !tbaa !12
  %1395 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 304), align 16, !tbaa !12
  %1396 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 320), align 16, !tbaa !12
  %1397 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 336), align 16, !tbaa !12
  %1398 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 352), align 16, !tbaa !12
  %1399 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 368), align 16, !tbaa !12
  %1400 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 384), align 16, !tbaa !12
  %1401 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 388), align 4, !tbaa !12
  %1402 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 392), align 8, !tbaa !12
  %1403 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 396), align 4, !tbaa !12
  br label %1425

1404:                                             ; preds = %1404, %1370
  %1405 = phi i64 [ 0, %1370 ], [ %1420, %1404 ]
  %1406 = phi i32 [ %1372, %1370 ], [ %1414, %1404 ]
  %1407 = mul nuw nsw i32 %1406, 3125
  %1408 = and i32 %1407, 65535
  %1409 = add nsw i32 %1408, -32768
  %1410 = sitofp i32 %1409 to float
  %1411 = fmul nnan float %1410, f0x38800000
  %1412 = getelementptr [4 x i8], ptr %1374, i64 %1405
  store float %1411, ptr %1412, align 8, !tbaa !12
  %1413 = mul nsw i32 %1406, 761
  %1414 = and i32 %1413, 65535
  %1415 = add nsw i32 %1414, -32768
  %1416 = sitofp i32 %1415 to float
  %1417 = fmul nnan float %1416, f0x38800000
  %1418 = getelementptr [4 x i8], ptr %1374, i64 %1405
  %1419 = getelementptr i8, ptr %1418, i64 4
  store float %1417, ptr %1419, align 4, !tbaa !12
  %1420 = add nuw nsw i64 %1405, 2
  %1421 = icmp eq i64 %1420, 100
  br i1 %1421, label %1422, label %1404, !llvm.loop !14

1422:                                             ; preds = %1404
  %1423 = add nuw nsw i64 %1371, 1
  %1424 = icmp eq i64 %1423, 100
  br i1 %1424, label %1375, label %1370, !llvm.loop !16

1425:                                             ; preds = %1425, %1375
  %1426 = phi float [ %1403, %1375 ], [ %1539, %1425 ]
  %1427 = phi float [ %1402, %1375 ], [ %1536, %1425 ]
  %1428 = phi float [ %1401, %1375 ], [ %1533, %1425 ]
  %1429 = phi float [ %1400, %1375 ], [ %1530, %1425 ]
  %1430 = phi <4 x float> [ %1399, %1375 ], [ %1527, %1425 ]
  %1431 = phi <4 x float> [ %1398, %1375 ], [ %1526, %1425 ]
  %1432 = phi <4 x float> [ %1397, %1375 ], [ %1521, %1425 ]
  %1433 = phi <4 x float> [ %1396, %1375 ], [ %1520, %1425 ]
  %1434 = phi <4 x float> [ %1395, %1375 ], [ %1515, %1425 ]
  %1435 = phi <4 x float> [ %1394, %1375 ], [ %1514, %1425 ]
  %1436 = phi <4 x float> [ %1393, %1375 ], [ %1509, %1425 ]
  %1437 = phi <4 x float> [ %1392, %1375 ], [ %1508, %1425 ]
  %1438 = phi <4 x float> [ %1391, %1375 ], [ %1503, %1425 ]
  %1439 = phi <4 x float> [ %1390, %1375 ], [ %1502, %1425 ]
  %1440 = phi <4 x float> [ %1389, %1375 ], [ %1497, %1425 ]
  %1441 = phi <4 x float> [ %1388, %1375 ], [ %1496, %1425 ]
  %1442 = phi <4 x float> [ %1387, %1375 ], [ %1491, %1425 ]
  %1443 = phi <4 x float> [ %1386, %1375 ], [ %1490, %1425 ]
  %1444 = phi <4 x float> [ %1385, %1375 ], [ %1485, %1425 ]
  %1445 = phi <4 x float> [ %1384, %1375 ], [ %1484, %1425 ]
  %1446 = phi <4 x float> [ %1383, %1375 ], [ %1479, %1425 ]
  %1447 = phi <4 x float> [ %1382, %1375 ], [ %1478, %1425 ]
  %1448 = phi <4 x float> [ %1381, %1375 ], [ %1473, %1425 ]
  %1449 = phi <4 x float> [ %1380, %1375 ], [ %1472, %1425 ]
  %1450 = phi <4 x float> [ %1379, %1375 ], [ %1467, %1425 ]
  %1451 = phi <4 x float> [ %1378, %1375 ], [ %1466, %1425 ]
  %1452 = phi <4 x float> [ %1377, %1375 ], [ %1461, %1425 ]
  %1453 = phi <4 x float> [ %1376, %1375 ], [ %1460, %1425 ]
  %1454 = phi i64 [ 0, %1375 ], [ %1540, %1425 ]
  %1455 = mul nuw nsw i64 %1454, 800
  %1456 = getelementptr i8, ptr @main.aa, i64 %1455
  %1457 = getelementptr i8, ptr %1456, i64 16
  %1458 = load <4 x float>, ptr %1456, align 16, !tbaa !12
  %1459 = load <4 x float>, ptr %1457, align 16, !tbaa !12
  %1460 = fadd <4 x float> %1453, %1458
  %1461 = fadd <4 x float> %1452, %1459
  %1462 = getelementptr i8, ptr %1456, i64 32
  %1463 = getelementptr i8, ptr %1456, i64 48
  %1464 = load <4 x float>, ptr %1462, align 16, !tbaa !12
  %1465 = load <4 x float>, ptr %1463, align 16, !tbaa !12
  %1466 = fadd <4 x float> %1451, %1464
  %1467 = fadd <4 x float> %1450, %1465
  %1468 = getelementptr i8, ptr %1456, i64 64
  %1469 = getelementptr i8, ptr %1456, i64 80
  %1470 = load <4 x float>, ptr %1468, align 16, !tbaa !12
  %1471 = load <4 x float>, ptr %1469, align 16, !tbaa !12
  %1472 = fadd <4 x float> %1449, %1470
  %1473 = fadd <4 x float> %1448, %1471
  %1474 = getelementptr i8, ptr %1456, i64 96
  %1475 = getelementptr i8, ptr %1456, i64 112
  %1476 = load <4 x float>, ptr %1474, align 16, !tbaa !12
  %1477 = load <4 x float>, ptr %1475, align 16, !tbaa !12
  %1478 = fadd <4 x float> %1447, %1476
  %1479 = fadd <4 x float> %1446, %1477
  %1480 = getelementptr i8, ptr %1456, i64 128
  %1481 = getelementptr i8, ptr %1456, i64 144
  %1482 = load <4 x float>, ptr %1480, align 16, !tbaa !12
  %1483 = load <4 x float>, ptr %1481, align 16, !tbaa !12
  %1484 = fadd <4 x float> %1445, %1482
  %1485 = fadd <4 x float> %1444, %1483
  %1486 = getelementptr i8, ptr %1456, i64 160
  %1487 = getelementptr i8, ptr %1456, i64 176
  %1488 = load <4 x float>, ptr %1486, align 16, !tbaa !12
  %1489 = load <4 x float>, ptr %1487, align 16, !tbaa !12
  %1490 = fadd <4 x float> %1443, %1488
  %1491 = fadd <4 x float> %1442, %1489
  %1492 = getelementptr i8, ptr %1456, i64 192
  %1493 = getelementptr i8, ptr %1456, i64 208
  %1494 = load <4 x float>, ptr %1492, align 16, !tbaa !12
  %1495 = load <4 x float>, ptr %1493, align 16, !tbaa !12
  %1496 = fadd <4 x float> %1441, %1494
  %1497 = fadd <4 x float> %1440, %1495
  %1498 = getelementptr i8, ptr %1456, i64 224
  %1499 = getelementptr i8, ptr %1456, i64 240
  %1500 = load <4 x float>, ptr %1498, align 16, !tbaa !12
  %1501 = load <4 x float>, ptr %1499, align 16, !tbaa !12
  %1502 = fadd <4 x float> %1439, %1500
  %1503 = fadd <4 x float> %1438, %1501
  %1504 = getelementptr i8, ptr %1456, i64 256
  %1505 = getelementptr i8, ptr %1456, i64 272
  %1506 = load <4 x float>, ptr %1504, align 16, !tbaa !12
  %1507 = load <4 x float>, ptr %1505, align 16, !tbaa !12
  %1508 = fadd <4 x float> %1437, %1506
  %1509 = fadd <4 x float> %1436, %1507
  %1510 = getelementptr i8, ptr %1456, i64 288
  %1511 = getelementptr i8, ptr %1456, i64 304
  %1512 = load <4 x float>, ptr %1510, align 16, !tbaa !12
  %1513 = load <4 x float>, ptr %1511, align 16, !tbaa !12
  %1514 = fadd <4 x float> %1435, %1512
  %1515 = fadd <4 x float> %1434, %1513
  %1516 = getelementptr i8, ptr %1456, i64 320
  %1517 = getelementptr i8, ptr %1456, i64 336
  %1518 = load <4 x float>, ptr %1516, align 16, !tbaa !12
  %1519 = load <4 x float>, ptr %1517, align 16, !tbaa !12
  %1520 = fadd <4 x float> %1433, %1518
  %1521 = fadd <4 x float> %1432, %1519
  %1522 = getelementptr i8, ptr %1456, i64 352
  %1523 = getelementptr i8, ptr %1456, i64 368
  %1524 = load <4 x float>, ptr %1522, align 16, !tbaa !12
  %1525 = load <4 x float>, ptr %1523, align 16, !tbaa !12
  %1526 = fadd <4 x float> %1431, %1524
  %1527 = fadd <4 x float> %1430, %1525
  %1528 = getelementptr i8, ptr %1456, i64 384
  %1529 = load float, ptr %1528, align 16, !tbaa !12
  %1530 = fadd float %1429, %1529
  %1531 = getelementptr i8, ptr %1456, i64 388
  %1532 = load float, ptr %1531, align 4, !tbaa !12
  %1533 = fadd float %1428, %1532
  %1534 = getelementptr i8, ptr %1456, i64 392
  %1535 = load float, ptr %1534, align 8, !tbaa !12
  %1536 = fadd float %1427, %1535
  %1537 = getelementptr i8, ptr %1456, i64 396
  %1538 = load float, ptr %1537, align 4, !tbaa !12
  %1539 = fadd float %1426, %1538
  %1540 = add nuw nsw i64 %1454, 1
  %1541 = icmp eq i64 %1540, 100
  br i1 %1541, label %1542, label %1425, !llvm.loop !17

1542:                                             ; preds = %1425
  store <4 x float> %1460, ptr @main.b, align 16, !tbaa !12
  store <4 x float> %1461, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 16), align 16, !tbaa !12
  store <4 x float> %1466, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 32), align 16, !tbaa !12
  store <4 x float> %1467, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 48), align 16, !tbaa !12
  store <4 x float> %1472, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 64), align 16, !tbaa !12
  store <4 x float> %1473, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 80), align 16, !tbaa !12
  store <4 x float> %1478, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 96), align 16, !tbaa !12
  store <4 x float> %1479, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 112), align 16, !tbaa !12
  store <4 x float> %1484, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 128), align 16, !tbaa !12
  store <4 x float> %1485, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 144), align 16, !tbaa !12
  store <4 x float> %1490, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 160), align 16, !tbaa !12
  store <4 x float> %1491, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 176), align 16, !tbaa !12
  store <4 x float> %1496, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 192), align 16, !tbaa !12
  store <4 x float> %1497, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 208), align 16, !tbaa !12
  store <4 x float> %1502, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 224), align 16, !tbaa !12
  store <4 x float> %1503, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 240), align 16, !tbaa !12
  store <4 x float> %1508, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 256), align 16, !tbaa !12
  store <4 x float> %1509, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 272), align 16, !tbaa !12
  store <4 x float> %1514, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 288), align 16, !tbaa !12
  store <4 x float> %1515, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 304), align 16, !tbaa !12
  store <4 x float> %1520, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 320), align 16, !tbaa !12
  store <4 x float> %1521, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 336), align 16, !tbaa !12
  store <4 x float> %1526, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 352), align 16, !tbaa !12
  store <4 x float> %1527, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 368), align 16, !tbaa !12
  store float %1530, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 384), align 16, !tbaa !12
  store float %1533, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 388), align 4, !tbaa !12
  store float %1536, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 392), align 8, !tbaa !12
  store float %1539, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 396), align 4, !tbaa !12
  %1543 = add nuw nsw i32 %1369, 1
  %1544 = icmp eq i32 %1543, 400
  br i1 %1544, label %1545, label %1368, !llvm.loop !39

1545:                                             ; preds = %1542
  %1546 = tail call i64 @clock() #13
  %1547 = sitofp i64 %1546 to float
  %1548 = fdiv nnan float %1547, 1.000000e+06
  %1549 = fsub float %1548, %1367
  %1550 = fdiv float %1549, 4.000000e+02
  %1551 = load ptr, ptr @stderr, align 8, !tbaa !9
  %1552 = tail call i32 (ptr, ptr, ...) @fprintf(ptr noundef %1551, ptr noundef nonnull @.str.16, double noundef 0.000000e+00) #15
  %1553 = load ptr, ptr @stderr, align 8, !tbaa !9
  %1554 = tail call i32 (ptr, ptr, ...) @fprintf(ptr noundef %1553, ptr noundef nonnull @.str.19, i32 noundef 200) #15
  %1555 = load ptr, ptr @stderr, align 8, !tbaa !9
  %1556 = tail call i64 @fwrite(ptr nonnull @.str.12, i64 55, i64 1, ptr %1555) #14
  %1557 = load ptr, ptr @stderr, align 8, !tbaa !9
  %1558 = tail call i64 @fwrite(ptr nonnull @.str.13, i64 12, i64 1, ptr %1557) #14
  %1559 = load i32, ptr @main.ntimes, align 4, !tbaa !18
  %1560 = sitofp i32 %1559 to float
  %1561 = fmul float %1550, %1560
  store float 0.000000e+00, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 228), align 4, !tbaa !12
  store i32 7, ptr @main.j, align 4, !tbaa !18
  br label %1562

1562:                                             ; preds = %1545, %1874
  %1563 = tail call i64 @clock() #13
  %1564 = sitofp i64 %1563 to float
  %1565 = fdiv float %1564, 1.000000e+06
  %1566 = load i32, ptr @main.ntimes, align 4, !tbaa !18
  %1567 = icmp sgt i32 %1566, 0
  br i1 %1567, label %1568, label %1745

1568:                                             ; preds = %1562, %1742
  %1569 = phi i32 [ %1743, %1742 ], [ 0, %1562 ]
  br label %1570

1570:                                             ; preds = %1568, %1622
  %1571 = phi i64 [ %1623, %1622 ], [ 0, %1568 ]
  %1572 = phi i32 [ %1614, %1622 ], [ 1325, %1568 ]
  %1573 = mul nuw nsw i64 %1571, 800
  %1574 = getelementptr i8, ptr @main.aa, i64 %1573
  br label %1604

1575:                                             ; preds = %1622
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(400) @main.b, i8 0, i64 400, i1 false), !tbaa !12
  %1576 = load <4 x float>, ptr @main.b, align 16, !tbaa !12
  %1577 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 16), align 16, !tbaa !12
  %1578 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 32), align 16, !tbaa !12
  %1579 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 48), align 16, !tbaa !12
  %1580 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 64), align 16, !tbaa !12
  %1581 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 80), align 16, !tbaa !12
  %1582 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 96), align 16, !tbaa !12
  %1583 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 112), align 16, !tbaa !12
  %1584 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 128), align 16, !tbaa !12
  %1585 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 144), align 16, !tbaa !12
  %1586 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 160), align 16, !tbaa !12
  %1587 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 176), align 16, !tbaa !12
  %1588 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 192), align 16, !tbaa !12
  %1589 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 208), align 16, !tbaa !12
  %1590 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 224), align 16, !tbaa !12
  %1591 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 240), align 16, !tbaa !12
  %1592 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 256), align 16, !tbaa !12
  %1593 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 272), align 16, !tbaa !12
  %1594 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 288), align 16, !tbaa !12
  %1595 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 304), align 16, !tbaa !12
  %1596 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 320), align 16, !tbaa !12
  %1597 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 336), align 16, !tbaa !12
  %1598 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 352), align 16, !tbaa !12
  %1599 = load <4 x float>, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 368), align 16, !tbaa !12
  %1600 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 384), align 16, !tbaa !12
  %1601 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 388), align 4, !tbaa !12
  %1602 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 392), align 8, !tbaa !12
  %1603 = load float, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 396), align 4, !tbaa !12
  br label %1625

1604:                                             ; preds = %1604, %1570
  %1605 = phi i64 [ 0, %1570 ], [ %1620, %1604 ]
  %1606 = phi i32 [ %1572, %1570 ], [ %1614, %1604 ]
  %1607 = mul nuw nsw i32 %1606, 3125
  %1608 = and i32 %1607, 65535
  %1609 = add nsw i32 %1608, -32768
  %1610 = sitofp i32 %1609 to float
  %1611 = fmul nnan float %1610, f0x38800000
  %1612 = getelementptr [4 x i8], ptr %1574, i64 %1605
  store float %1611, ptr %1612, align 8, !tbaa !12
  %1613 = mul nsw i32 %1606, 761
  %1614 = and i32 %1613, 65535
  %1615 = add nsw i32 %1614, -32768
  %1616 = sitofp i32 %1615 to float
  %1617 = fmul nnan float %1616, f0x38800000
  %1618 = getelementptr [4 x i8], ptr %1574, i64 %1605
  %1619 = getelementptr i8, ptr %1618, i64 4
  store float %1617, ptr %1619, align 4, !tbaa !12
  %1620 = add nuw nsw i64 %1605, 2
  %1621 = icmp eq i64 %1620, 100
  br i1 %1621, label %1622, label %1604, !llvm.loop !14

1622:                                             ; preds = %1604
  %1623 = add nuw nsw i64 %1571, 1
  %1624 = icmp eq i64 %1623, 100
  br i1 %1624, label %1575, label %1570, !llvm.loop !16

1625:                                             ; preds = %1625, %1575
  %1626 = phi float [ %1603, %1575 ], [ %1739, %1625 ]
  %1627 = phi float [ %1602, %1575 ], [ %1736, %1625 ]
  %1628 = phi float [ %1601, %1575 ], [ %1733, %1625 ]
  %1629 = phi float [ %1600, %1575 ], [ %1730, %1625 ]
  %1630 = phi <4 x float> [ %1599, %1575 ], [ %1727, %1625 ]
  %1631 = phi <4 x float> [ %1598, %1575 ], [ %1726, %1625 ]
  %1632 = phi <4 x float> [ %1597, %1575 ], [ %1721, %1625 ]
  %1633 = phi <4 x float> [ %1596, %1575 ], [ %1720, %1625 ]
  %1634 = phi <4 x float> [ %1595, %1575 ], [ %1715, %1625 ]
  %1635 = phi <4 x float> [ %1594, %1575 ], [ %1714, %1625 ]
  %1636 = phi <4 x float> [ %1593, %1575 ], [ %1709, %1625 ]
  %1637 = phi <4 x float> [ %1592, %1575 ], [ %1708, %1625 ]
  %1638 = phi <4 x float> [ %1591, %1575 ], [ %1703, %1625 ]
  %1639 = phi <4 x float> [ %1590, %1575 ], [ %1702, %1625 ]
  %1640 = phi <4 x float> [ %1589, %1575 ], [ %1697, %1625 ]
  %1641 = phi <4 x float> [ %1588, %1575 ], [ %1696, %1625 ]
  %1642 = phi <4 x float> [ %1587, %1575 ], [ %1691, %1625 ]
  %1643 = phi <4 x float> [ %1586, %1575 ], [ %1690, %1625 ]
  %1644 = phi <4 x float> [ %1585, %1575 ], [ %1685, %1625 ]
  %1645 = phi <4 x float> [ %1584, %1575 ], [ %1684, %1625 ]
  %1646 = phi <4 x float> [ %1583, %1575 ], [ %1679, %1625 ]
  %1647 = phi <4 x float> [ %1582, %1575 ], [ %1678, %1625 ]
  %1648 = phi <4 x float> [ %1581, %1575 ], [ %1673, %1625 ]
  %1649 = phi <4 x float> [ %1580, %1575 ], [ %1672, %1625 ]
  %1650 = phi <4 x float> [ %1579, %1575 ], [ %1667, %1625 ]
  %1651 = phi <4 x float> [ %1578, %1575 ], [ %1666, %1625 ]
  %1652 = phi <4 x float> [ %1577, %1575 ], [ %1661, %1625 ]
  %1653 = phi <4 x float> [ %1576, %1575 ], [ %1660, %1625 ]
  %1654 = phi i64 [ 0, %1575 ], [ %1740, %1625 ]
  %1655 = mul nuw nsw i64 %1654, 800
  %1656 = getelementptr i8, ptr @main.aa, i64 %1655
  %1657 = getelementptr i8, ptr %1656, i64 16
  %1658 = load <4 x float>, ptr %1656, align 16, !tbaa !12
  %1659 = load <4 x float>, ptr %1657, align 16, !tbaa !12
  %1660 = fadd <4 x float> %1653, %1658
  %1661 = fadd <4 x float> %1652, %1659
  %1662 = getelementptr i8, ptr %1656, i64 32
  %1663 = getelementptr i8, ptr %1656, i64 48
  %1664 = load <4 x float>, ptr %1662, align 16, !tbaa !12
  %1665 = load <4 x float>, ptr %1663, align 16, !tbaa !12
  %1666 = fadd <4 x float> %1651, %1664
  %1667 = fadd <4 x float> %1650, %1665
  %1668 = getelementptr i8, ptr %1656, i64 64
  %1669 = getelementptr i8, ptr %1656, i64 80
  %1670 = load <4 x float>, ptr %1668, align 16, !tbaa !12
  %1671 = load <4 x float>, ptr %1669, align 16, !tbaa !12
  %1672 = fadd <4 x float> %1649, %1670
  %1673 = fadd <4 x float> %1648, %1671
  %1674 = getelementptr i8, ptr %1656, i64 96
  %1675 = getelementptr i8, ptr %1656, i64 112
  %1676 = load <4 x float>, ptr %1674, align 16, !tbaa !12
  %1677 = load <4 x float>, ptr %1675, align 16, !tbaa !12
  %1678 = fadd <4 x float> %1647, %1676
  %1679 = fadd <4 x float> %1646, %1677
  %1680 = getelementptr i8, ptr %1656, i64 128
  %1681 = getelementptr i8, ptr %1656, i64 144
  %1682 = load <4 x float>, ptr %1680, align 16, !tbaa !12
  %1683 = load <4 x float>, ptr %1681, align 16, !tbaa !12
  %1684 = fadd <4 x float> %1645, %1682
  %1685 = fadd <4 x float> %1644, %1683
  %1686 = getelementptr i8, ptr %1656, i64 160
  %1687 = getelementptr i8, ptr %1656, i64 176
  %1688 = load <4 x float>, ptr %1686, align 16, !tbaa !12
  %1689 = load <4 x float>, ptr %1687, align 16, !tbaa !12
  %1690 = fadd <4 x float> %1643, %1688
  %1691 = fadd <4 x float> %1642, %1689
  %1692 = getelementptr i8, ptr %1656, i64 192
  %1693 = getelementptr i8, ptr %1656, i64 208
  %1694 = load <4 x float>, ptr %1692, align 16, !tbaa !12
  %1695 = load <4 x float>, ptr %1693, align 16, !tbaa !12
  %1696 = fadd <4 x float> %1641, %1694
  %1697 = fadd <4 x float> %1640, %1695
  %1698 = getelementptr i8, ptr %1656, i64 224
  %1699 = getelementptr i8, ptr %1656, i64 240
  %1700 = load <4 x float>, ptr %1698, align 16, !tbaa !12
  %1701 = load <4 x float>, ptr %1699, align 16, !tbaa !12
  %1702 = fadd <4 x float> %1639, %1700
  %1703 = fadd <4 x float> %1638, %1701
  %1704 = getelementptr i8, ptr %1656, i64 256
  %1705 = getelementptr i8, ptr %1656, i64 272
  %1706 = load <4 x float>, ptr %1704, align 16, !tbaa !12
  %1707 = load <4 x float>, ptr %1705, align 16, !tbaa !12
  %1708 = fadd <4 x float> %1637, %1706
  %1709 = fadd <4 x float> %1636, %1707
  %1710 = getelementptr i8, ptr %1656, i64 288
  %1711 = getelementptr i8, ptr %1656, i64 304
  %1712 = load <4 x float>, ptr %1710, align 16, !tbaa !12
  %1713 = load <4 x float>, ptr %1711, align 16, !tbaa !12
  %1714 = fadd <4 x float> %1635, %1712
  %1715 = fadd <4 x float> %1634, %1713
  %1716 = getelementptr i8, ptr %1656, i64 320
  %1717 = getelementptr i8, ptr %1656, i64 336
  %1718 = load <4 x float>, ptr %1716, align 16, !tbaa !12
  %1719 = load <4 x float>, ptr %1717, align 16, !tbaa !12
  %1720 = fadd <4 x float> %1633, %1718
  %1721 = fadd <4 x float> %1632, %1719
  %1722 = getelementptr i8, ptr %1656, i64 352
  %1723 = getelementptr i8, ptr %1656, i64 368
  %1724 = load <4 x float>, ptr %1722, align 16, !tbaa !12
  %1725 = load <4 x float>, ptr %1723, align 16, !tbaa !12
  %1726 = fadd <4 x float> %1631, %1724
  %1727 = fadd <4 x float> %1630, %1725
  %1728 = getelementptr i8, ptr %1656, i64 384
  %1729 = load float, ptr %1728, align 16, !tbaa !12
  %1730 = fadd float %1629, %1729
  %1731 = getelementptr i8, ptr %1656, i64 388
  %1732 = load float, ptr %1731, align 4, !tbaa !12
  %1733 = fadd float %1628, %1732
  %1734 = getelementptr i8, ptr %1656, i64 392
  %1735 = load float, ptr %1734, align 8, !tbaa !12
  %1736 = fadd float %1627, %1735
  %1737 = getelementptr i8, ptr %1656, i64 396
  %1738 = load float, ptr %1737, align 4, !tbaa !12
  %1739 = fadd float %1626, %1738
  %1740 = add nuw nsw i64 %1654, 1
  %1741 = icmp eq i64 %1740, 100
  br i1 %1741, label %1742, label %1625, !llvm.loop !17

1742:                                             ; preds = %1625
  store <4 x float> %1660, ptr @main.b, align 16, !tbaa !12
  store <4 x float> %1661, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 16), align 16, !tbaa !12
  store <4 x float> %1666, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 32), align 16, !tbaa !12
  store <4 x float> %1667, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 48), align 16, !tbaa !12
  store <4 x float> %1672, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 64), align 16, !tbaa !12
  store <4 x float> %1673, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 80), align 16, !tbaa !12
  store <4 x float> %1678, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 96), align 16, !tbaa !12
  store <4 x float> %1679, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 112), align 16, !tbaa !12
  store <4 x float> %1684, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 128), align 16, !tbaa !12
  store <4 x float> %1685, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 144), align 16, !tbaa !12
  store <4 x float> %1690, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 160), align 16, !tbaa !12
  store <4 x float> %1691, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 176), align 16, !tbaa !12
  store <4 x float> %1696, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 192), align 16, !tbaa !12
  store <4 x float> %1697, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 208), align 16, !tbaa !12
  store <4 x float> %1702, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 224), align 16, !tbaa !12
  store <4 x float> %1703, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 240), align 16, !tbaa !12
  store <4 x float> %1708, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 256), align 16, !tbaa !12
  store <4 x float> %1709, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 272), align 16, !tbaa !12
  store <4 x float> %1714, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 288), align 16, !tbaa !12
  store <4 x float> %1715, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 304), align 16, !tbaa !12
  store <4 x float> %1720, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 320), align 16, !tbaa !12
  store <4 x float> %1721, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 336), align 16, !tbaa !12
  store <4 x float> %1726, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 352), align 16, !tbaa !12
  store <4 x float> %1727, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 368), align 16, !tbaa !12
  store float %1730, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 384), align 16, !tbaa !12
  store float %1733, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 388), align 4, !tbaa !12
  store float %1736, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 392), align 8, !tbaa !12
  store float %1739, ptr getelementptr inbounds nuw (i8, ptr @main.b, i64 396), align 4, !tbaa !12
  tail call void @dgefa(ptr noundef nonnull @main.aa, i32 noundef 200, i32 noundef 100, ptr noundef nonnull @main.ipvt, ptr noundef nonnull @main.info)
  %1743 = add nuw nsw i32 %1569, 1
  %1744 = icmp eq i32 %1743, %1566
  br i1 %1744, label %1745, label %1568, !llvm.loop !40

1745:                                             ; preds = %1742, %1562
  %1746 = tail call i64 @clock() #13
  %1747 = sitofp i64 %1746 to float
  %1748 = fdiv float %1747, 1.000000e+06
  %1749 = fsub float %1748, %1565
  %1750 = fsub float %1749, %1561
  %1751 = load i32, ptr @main.ntimes, align 4, !tbaa !18
  %1752 = sitofp i32 %1751 to float
  %1753 = fdiv float %1750, %1752
  %1754 = load i32, ptr @main.j, align 4, !tbaa !18
  %1755 = sext i32 %1754 to i64
  %1756 = getelementptr inbounds [4 x i8], ptr @atime, i64 %1755
  store float %1753, ptr %1756, align 4, !tbaa !12
  %1757 = tail call i64 @clock() #13
  %1758 = sitofp i64 %1757 to float
  %1759 = fdiv float %1758, 1.000000e+06
  %1760 = load i32, ptr @main.ntimes, align 4, !tbaa !18
  %1761 = icmp sgt i32 %1760, 0
  br i1 %1761, label %1762, label %1874

1762:                                             ; preds = %1745, %1871
  %1763 = phi i32 [ %1872, %1871 ], [ 0, %1745 ]
  br label %1764

1764:                                             ; preds = %1762, %1817
  %1765 = phi i64 [ %1777, %1817 ], [ 0, %1762 ]
  %1766 = getelementptr inbounds nuw [4 x i8], ptr @main.ipvt, i64 %1765
  %1767 = load i32, ptr %1766, align 4, !tbaa !18
  %1768 = sext i32 %1767 to i64
  %1769 = getelementptr inbounds [4 x i8], ptr @main.b, i64 %1768
  %1770 = load float, ptr %1769, align 4, !tbaa !12
  %1771 = zext i32 %1767 to i64
  %1772 = icmp eq i64 %1765, %1771
  br i1 %1772, label %1776, label %1773

1773:                                             ; preds = %1764
  %1774 = getelementptr inbounds nuw [4 x i8], ptr @main.b, i64 %1765
  %1775 = load float, ptr %1774, align 4, !tbaa !12
  store float %1775, ptr %1769, align 4, !tbaa !12
  store float %1770, ptr %1774, align 4, !tbaa !12
  br label %1776

1776:                                             ; preds = %1773, %1764
  %1777 = add nuw nsw i64 %1765, 1
  %1778 = mul nuw nsw i64 %1765, 804
  %1779 = getelementptr i8, ptr @main.aa, i64 %1778
  %1780 = getelementptr i8, ptr %1779, i64 4
  %1781 = getelementptr inbounds nuw [4 x i8], ptr @main.b, i64 %1777
  %1782 = fcmp oeq float %1770, 0.000000e+00
  br i1 %1782, label %1817, label %1783

1783:                                             ; preds = %1776
  %1784 = sub nuw nsw i64 99, %1765
  %1785 = icmp samesign ugt i64 %1765, 91
  br i1 %1785, label %1806, label %1786

1786:                                             ; preds = %1783
  %1787 = and i64 %1784, 120
  %1788 = insertelement <4 x float> poison, float %1770, i64 0
  %1789 = shufflevector <4 x float> %1788, <4 x float> poison, <4 x i32> zeroinitializer
  br label %1790

1790:                                             ; preds = %1790, %1786
  %1791 = phi i64 [ 0, %1786 ], [ %1802, %1790 ]
  %1792 = getelementptr inbounds nuw [4 x i8], ptr %1781, i64 %1791
  %1793 = getelementptr inbounds nuw i8, ptr %1792, i64 16
  %1794 = load <4 x float>, ptr %1792, align 4, !tbaa !12
  %1795 = load <4 x float>, ptr %1793, align 4, !tbaa !12
  %1796 = getelementptr inbounds nuw [4 x i8], ptr %1780, i64 %1791
  %1797 = getelementptr inbounds nuw i8, ptr %1796, i64 16
  %1798 = load <4 x float>, ptr %1796, align 4, !tbaa !12
  %1799 = load <4 x float>, ptr %1797, align 4, !tbaa !12
  %1800 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %1789, <4 x float> %1798, <4 x float> %1794)
  %1801 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %1789, <4 x float> %1799, <4 x float> %1795)
  store <4 x float> %1800, ptr %1792, align 4, !tbaa !12
  store <4 x float> %1801, ptr %1793, align 4, !tbaa !12
  %1802 = add nuw i64 %1791, 8
  %1803 = icmp eq i64 %1802, %1787
  br i1 %1803, label %1804, label %1790, !llvm.loop !41

1804:                                             ; preds = %1790
  %1805 = icmp eq i64 %1784, %1787
  br i1 %1805, label %1817, label %1806

1806:                                             ; preds = %1783, %1804
  %1807 = phi i64 [ 0, %1783 ], [ %1787, %1804 ]
  br label %1808

1808:                                             ; preds = %1806, %1808
  %1809 = phi i64 [ %1815, %1808 ], [ %1807, %1806 ]
  %1810 = getelementptr inbounds nuw [4 x i8], ptr %1781, i64 %1809
  %1811 = load float, ptr %1810, align 4, !tbaa !12
  %1812 = getelementptr inbounds nuw [4 x i8], ptr %1780, i64 %1809
  %1813 = load float, ptr %1812, align 4, !tbaa !12
  %1814 = tail call float @llvm.fmuladd.f32(float %1770, float %1813, float %1811)
  store float %1814, ptr %1810, align 4, !tbaa !12
  %1815 = add nuw nsw i64 %1809, 1
  %1816 = icmp eq i64 %1815, %1784
  br i1 %1816, label %1817, label %1808, !llvm.loop !42

1817:                                             ; preds = %1808, %1804, %1776
  %1818 = icmp eq i64 %1777, 99
  br i1 %1818, label %1819, label %1764, !llvm.loop !23

1819:                                             ; preds = %1817, %1869
  %1820 = phi i64 [ %1821, %1869 ], [ 0, %1817 ]
  %1821 = add nuw nsw i64 %1820, 1
  %1822 = sub nuw nsw i64 99, %1820
  %1823 = getelementptr inbounds nuw [4 x i8], ptr @main.b, i64 %1822
  %1824 = load float, ptr %1823, align 4, !tbaa !12
  %1825 = getelementptr [4 x i8], ptr @main.aa, i64 %1822
  %1826 = mul nuw nsw i64 %1822, 800
  %1827 = getelementptr i8, ptr %1825, i64 %1826
  %1828 = load float, ptr %1827, align 4, !tbaa !12
  %1829 = fdiv float %1824, %1828
  store float %1829, ptr %1823, align 4, !tbaa !12
  %1830 = fneg float %1829
  %1831 = mul nuw nsw i64 %1822, 800
  %1832 = getelementptr inbounds nuw i8, ptr @main.aa, i64 %1831
  %1833 = icmp samesign ugt i64 %1820, 98
  %1834 = fcmp oeq float %1829, 0.000000e+00
  %1835 = or i1 %1833, %1834
  br i1 %1835, label %1869, label %1836

1836:                                             ; preds = %1819
  %1837 = icmp samesign ugt i64 %1820, 91
  br i1 %1837, label %1858, label %1838

1838:                                             ; preds = %1836
  %1839 = and i64 %1822, 120
  %1840 = insertelement <4 x float> poison, float %1830, i64 0
  %1841 = shufflevector <4 x float> %1840, <4 x float> poison, <4 x i32> zeroinitializer
  br label %1842

1842:                                             ; preds = %1842, %1838
  %1843 = phi i64 [ 0, %1838 ], [ %1854, %1842 ]
  %1844 = getelementptr inbounds nuw [4 x i8], ptr @main.b, i64 %1843
  %1845 = getelementptr inbounds nuw i8, ptr %1844, i64 16
  %1846 = load <4 x float>, ptr %1844, align 16, !tbaa !12
  %1847 = load <4 x float>, ptr %1845, align 16, !tbaa !12
  %1848 = getelementptr inbounds nuw [4 x i8], ptr %1832, i64 %1843
  %1849 = getelementptr inbounds nuw i8, ptr %1848, i64 16
  %1850 = load <4 x float>, ptr %1848, align 16, !tbaa !12
  %1851 = load <4 x float>, ptr %1849, align 16, !tbaa !12
  %1852 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %1841, <4 x float> %1850, <4 x float> %1846)
  %1853 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %1841, <4 x float> %1851, <4 x float> %1847)
  store <4 x float> %1852, ptr %1844, align 16, !tbaa !12
  store <4 x float> %1853, ptr %1845, align 16, !tbaa !12
  %1854 = add nuw i64 %1843, 8
  %1855 = icmp eq i64 %1854, %1839
  br i1 %1855, label %1856, label %1842, !llvm.loop !43

1856:                                             ; preds = %1842
  %1857 = icmp eq i64 %1822, %1839
  br i1 %1857, label %1869, label %1858

1858:                                             ; preds = %1836, %1856
  %1859 = phi i64 [ 0, %1836 ], [ %1839, %1856 ]
  br label %1860

1860:                                             ; preds = %1858, %1860
  %1861 = phi i64 [ %1867, %1860 ], [ %1859, %1858 ]
  %1862 = getelementptr inbounds nuw [4 x i8], ptr @main.b, i64 %1861
  %1863 = load float, ptr %1862, align 4, !tbaa !12
  %1864 = getelementptr inbounds nuw [4 x i8], ptr %1832, i64 %1861
  %1865 = load float, ptr %1864, align 4, !tbaa !12
  %1866 = tail call float @llvm.fmuladd.f32(float %1830, float %1865, float %1863)
  store float %1866, ptr %1862, align 4, !tbaa !12
  %1867 = add nuw nsw i64 %1861, 1
  %1868 = icmp eq i64 %1867, %1822
  br i1 %1868, label %1869, label %1860, !llvm.loop !44

1869:                                             ; preds = %1860, %1856, %1819
  %1870 = icmp eq i64 %1821, 100
  br i1 %1870, label %1871, label %1819, !llvm.loop !26

1871:                                             ; preds = %1869
  %1872 = add nuw nsw i32 %1763, 1
  %1873 = icmp eq i32 %1872, %1760
  br i1 %1873, label %1874, label %1762, !llvm.loop !45

1874:                                             ; preds = %1871, %1745
  %1875 = tail call i64 @clock() #13
  %1876 = sitofp i64 %1875 to float
  %1877 = fdiv float %1876, 1.000000e+06
  %1878 = fsub float %1877, %1759
  %1879 = load i32, ptr @main.ntimes, align 4, !tbaa !18
  %1880 = sitofp i32 %1879 to float
  %1881 = fdiv float %1878, %1880
  %1882 = load i32, ptr @main.j, align 4, !tbaa !18
  %1883 = sext i32 %1882 to i64
  %1884 = getelementptr inbounds [4 x i8], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 60), i64 %1883
  store float %1881, ptr %1884, align 4, !tbaa !12
  %1885 = getelementptr inbounds [4 x i8], ptr @atime, i64 %1883
  %1886 = load float, ptr %1885, align 4, !tbaa !12
  %1887 = fadd float %1886, %1881
  %1888 = getelementptr inbounds [4 x i8], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 120), i64 %1883
  store float %1887, ptr %1888, align 4, !tbaa !12
  %1889 = fpext float %1887 to double
  %1890 = fmul double %1889, 1.000000e+06
  %1891 = fdiv double f0x4124F49560000000, %1890
  %1892 = fptrunc double %1891 to float
  %1893 = getelementptr inbounds [4 x i8], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 180), i64 %1883
  store float %1892, ptr %1893, align 4, !tbaa !12
  %1894 = fdiv float 2.000000e+00, %1892
  %1895 = getelementptr inbounds [4 x i8], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 240), i64 %1883
  store float %1894, ptr %1895, align 4, !tbaa !12
  %1896 = fdiv float %1887, 5.600000e-02
  %1897 = getelementptr inbounds [4 x i8], ptr getelementptr inbounds nuw (i8, ptr @atime, i64 300), i64 %1883
  store float %1896, ptr %1897, align 4, !tbaa !12
  %1898 = load float, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 228), align 4, !tbaa !12
  %1899 = fadd float %1898, %1892
  store float %1899, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 228), align 4, !tbaa !12
  %1900 = add nsw i32 %1882, 1
  store i32 %1900, ptr @main.j, align 4, !tbaa !18
  %1901 = icmp slt i32 %1882, 11
  br i1 %1901, label %1562, label %1902, !llvm.loop !46

1902:                                             ; preds = %1874
  %1903 = fdiv float %1899, 5.000000e+00
  store float %1903, ptr getelementptr inbounds nuw (i8, ptr @atime, i64 228), align 4, !tbaa !12
  %1904 = load ptr, ptr @stderr, align 8, !tbaa !9
  %1905 = tail call i32 (ptr, ptr, ...) @fprintf(ptr noundef %1904, ptr noundef nonnull @.str.20, double noundef 0.000000e+00) #15
  ret i32 0
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #4

; Function Attrs: nofree nounwind
declare noundef i32 @fprintf(ptr noundef captures(none), ptr noundef readonly captures(none), ...) local_unnamed_addr #5

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @matgen(ptr nofree noundef captures(none) %0, i32 noundef %1, i32 noundef %2, ptr nofree noundef captures(none) %3, ptr nofree noundef captures(none) initializes((0, 4)) %4) local_unnamed_addr #6 {
  store float 0.000000e+00, ptr %4, align 4, !tbaa !12
  %6 = icmp sgt i32 %2, 0
  br i1 %6, label %7, label %121

7:                                                ; preds = %5
  %8 = sext i32 %1 to i64
  %9 = zext nneg i32 %2 to i64
  br label %10

10:                                               ; preds = %7, %29
  %11 = phi i64 [ 0, %7 ], [ %30, %29 ]
  %12 = phi i32 [ 1325, %7 ], [ %19, %29 ]
  %13 = mul nsw i64 %11, %8
  %14 = getelementptr [4 x i8], ptr %0, i64 %13
  br label %15

15:                                               ; preds = %10, %15
  %16 = phi i64 [ 0, %10 ], [ %27, %15 ]
  %17 = phi i32 [ %12, %10 ], [ %19, %15 ]
  %18 = mul nuw nsw i32 %17, 3125
  %19 = and i32 %18, 65535
  %20 = add nsw i32 %19, -32768
  %21 = sitofp i32 %20 to float
  %22 = fmul nnan float %21, f0x38800000
  %23 = getelementptr [4 x i8], ptr %14, i64 %16
  store float %22, ptr %23, align 4, !tbaa !12
  %24 = load float, ptr %4, align 4, !tbaa !12
  %25 = fcmp ogt float %22, %24
  %26 = select i1 %25, float %22, float %24
  store float %26, ptr %4, align 4, !tbaa !12
  %27 = add nuw nsw i64 %16, 1
  %28 = icmp eq i64 %27, %9
  br i1 %28, label %29, label %15, !llvm.loop !14

29:                                               ; preds = %15
  %30 = add nuw nsw i64 %11, 1
  %31 = icmp eq i64 %30, %9
  br i1 %31, label %32, label %10, !llvm.loop !16

32:                                               ; preds = %29
  %33 = zext nneg i32 %2 to i64
  %34 = shl nuw nsw i64 %33, 2
  tail call void @llvm.memset.p0.i64(ptr align 4 %3, i8 0, i64 %34, i1 false), !tbaa !12
  %35 = sext i32 %1 to i64
  %36 = zext nneg i32 %2 to i64
  %37 = shl nuw nsw i64 %9, 2
  %38 = getelementptr i8, ptr %3, i64 %37
  %39 = add nuw nsw i64 %9, 4611686018427387903
  %40 = mul i64 %39, %35
  %41 = add i64 %40, %9
  %42 = shl i64 %41, 2
  %43 = getelementptr i8, ptr %0, i64 %42
  %44 = icmp ult i32 %2, 8
  %45 = icmp ult ptr %3, %43
  %46 = icmp ult ptr %0, %38
  %47 = and i1 %45, %46
  %48 = icmp slt i32 %1, 0
  %49 = or i1 %47, %48
  %50 = and i64 %9, 2147483640
  %51 = icmp eq i64 %50, %9
  %52 = and i64 %36, 3
  %53 = icmp eq i64 %52, 0
  br label %54

54:                                               ; preds = %32, %118
  %55 = phi i64 [ 0, %32 ], [ %119, %118 ]
  %56 = mul nsw i64 %55, %35
  %57 = getelementptr [4 x i8], ptr %0, i64 %56
  %58 = select i1 %44, i1 true, i1 %49
  br i1 %58, label %74, label %59

59:                                               ; preds = %54, %59
  %60 = phi i64 [ %71, %59 ], [ 0, %54 ]
  %61 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %60
  %62 = getelementptr inbounds nuw i8, ptr %61, i64 16
  %63 = load <4 x float>, ptr %61, align 4, !tbaa !12, !alias.scope !47, !noalias !50
  %64 = load <4 x float>, ptr %62, align 4, !tbaa !12, !alias.scope !47, !noalias !50
  %65 = getelementptr [4 x i8], ptr %57, i64 %60
  %66 = getelementptr i8, ptr %65, i64 16
  %67 = load <4 x float>, ptr %65, align 4, !tbaa !12, !alias.scope !50
  %68 = load <4 x float>, ptr %66, align 4, !tbaa !12, !alias.scope !50
  %69 = fadd <4 x float> %63, %67
  %70 = fadd <4 x float> %64, %68
  store <4 x float> %69, ptr %61, align 4, !tbaa !12, !alias.scope !47, !noalias !50
  store <4 x float> %70, ptr %62, align 4, !tbaa !12, !alias.scope !47, !noalias !50
  %71 = add nuw i64 %60, 8
  %72 = icmp eq i64 %71, %50
  br i1 %72, label %73, label %59, !llvm.loop !52

73:                                               ; preds = %59
  br i1 %51, label %118, label %74

74:                                               ; preds = %54, %73
  %75 = phi i64 [ %50, %73 ], [ 0, %54 ]
  br i1 %53, label %87, label %76

76:                                               ; preds = %74, %76
  %77 = phi i64 [ %84, %76 ], [ %75, %74 ]
  %78 = phi i64 [ %85, %76 ], [ 0, %74 ]
  %79 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %77
  %80 = load float, ptr %79, align 4, !tbaa !12
  %81 = getelementptr [4 x i8], ptr %57, i64 %77
  %82 = load float, ptr %81, align 4, !tbaa !12
  %83 = fadd float %80, %82
  store float %83, ptr %79, align 4, !tbaa !12
  %84 = add nuw nsw i64 %77, 1
  %85 = add i64 %78, 1
  %86 = icmp eq i64 %85, %52
  br i1 %86, label %87, label %76, !llvm.loop !53

87:                                               ; preds = %76, %74
  %88 = phi i64 [ %75, %74 ], [ %84, %76 ]
  %89 = sub nsw i64 %75, %36
  %90 = icmp ugt i64 %89, -4
  br i1 %90, label %118, label %91

91:                                               ; preds = %87, %91
  %92 = phi i64 [ %116, %91 ], [ %88, %87 ]
  %93 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %92
  %94 = load float, ptr %93, align 4, !tbaa !12
  %95 = getelementptr [4 x i8], ptr %57, i64 %92
  %96 = load float, ptr %95, align 4, !tbaa !12
  %97 = fadd float %94, %96
  store float %97, ptr %93, align 4, !tbaa !12
  %98 = add nuw nsw i64 %92, 1
  %99 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %98
  %100 = load float, ptr %99, align 4, !tbaa !12
  %101 = getelementptr [4 x i8], ptr %57, i64 %98
  %102 = load float, ptr %101, align 4, !tbaa !12
  %103 = fadd float %100, %102
  store float %103, ptr %99, align 4, !tbaa !12
  %104 = add nuw nsw i64 %92, 2
  %105 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %104
  %106 = load float, ptr %105, align 4, !tbaa !12
  %107 = getelementptr [4 x i8], ptr %57, i64 %104
  %108 = load float, ptr %107, align 4, !tbaa !12
  %109 = fadd float %106, %108
  store float %109, ptr %105, align 4, !tbaa !12
  %110 = add nuw nsw i64 %92, 3
  %111 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %110
  %112 = load float, ptr %111, align 4, !tbaa !12
  %113 = getelementptr [4 x i8], ptr %57, i64 %110
  %114 = load float, ptr %113, align 4, !tbaa !12
  %115 = fadd float %112, %114
  store float %115, ptr %111, align 4, !tbaa !12
  %116 = add nuw nsw i64 %92, 4
  %117 = icmp eq i64 %116, %36
  br i1 %117, label %118, label %91, !llvm.loop !55

118:                                              ; preds = %87, %91, %73
  %119 = add nuw nsw i64 %55, 1
  %120 = icmp eq i64 %119, %36
  br i1 %120, label %121, label %54, !llvm.loop !17

121:                                              ; preds = %118, %5
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @dgefa(ptr nofree noundef captures(none) %0, i32 noundef %1, i32 noundef %2, ptr nofree noundef writeonly captures(none) %3, ptr nofree noundef writeonly captures(none) initializes((0, 4)) %4) local_unnamed_addr #6 {
  store i32 0, ptr %4, align 4, !tbaa !18
  %6 = add i32 %2, -1
  %7 = icmp sgt i32 %2, 1
  br i1 %7, label %8, label %216

8:                                                ; preds = %5
  %9 = sext i32 %1 to i64
  %10 = zext nneg i32 %2 to i64
  %11 = zext nneg i32 %6 to i64
  %12 = zext nneg i32 %2 to i64
  %13 = shl nsw i64 %9, 2
  %14 = add nsw i64 %13, 4
  %15 = shl nuw nsw i64 %10, 2
  %16 = add nsw i64 %15, -4
  %17 = mul i64 %16, %9
  %18 = getelementptr i8, ptr %0, i64 %17
  %19 = getelementptr i8, ptr %18, i64 %15
  %20 = getelementptr i8, ptr %0, i64 %15
  %21 = add nsw i64 %10, -1
  %22 = add nsw i64 %10, -2
  %23 = icmp slt i32 %1, 0
  br label %24

24:                                               ; preds = %8, %213
  %25 = phi i64 [ 0, %8 ], [ %41, %213 ]
  %26 = phi i64 [ 1, %8 ], [ %214, %213 ]
  %27 = sub i64 %21, %25
  %28 = add nuw i64 %25, 1
  %29 = mul i64 %14, %28
  %30 = getelementptr i8, ptr %0, i64 %29
  %31 = shl nuw nsw i64 %25, 2
  %32 = getelementptr i8, ptr %0, i64 %31
  %33 = getelementptr i8, ptr %32, i64 4
  %34 = trunc i64 %25 to i32
  %35 = mul i32 %1, %34
  %36 = sext i32 %35 to i64
  %37 = shl nsw i64 %36, 2
  %38 = getelementptr i8, ptr %33, i64 %37
  %39 = getelementptr i8, ptr %20, i64 %37
  %40 = trunc i64 %25 to i32
  %41 = add nuw nsw i64 %25, 1
  %42 = sub nsw i64 %10, %25
  %43 = mul nsw i64 %25, %9
  %44 = mul nsw i32 %1, %40
  %45 = sext i32 %44 to i64
  %46 = getelementptr [4 x i8], ptr %0, i64 %25
  %47 = getelementptr [4 x i8], ptr %46, i64 %45
  %48 = icmp eq i64 %42, 1
  br i1 %48, label %92, label %49

49:                                               ; preds = %24
  %50 = load float, ptr %47, align 4, !tbaa !12
  %51 = tail call float @llvm.fabs.f32(float %50)
  %52 = and i64 %27, 1
  %53 = icmp eq i64 %22, %25
  br i1 %53, label %81, label %54

54:                                               ; preds = %49
  %55 = and i64 %27, -2
  br label %56

56:                                               ; preds = %56, %54
  %57 = phi i64 [ 1, %54 ], [ %76, %56 ]
  %58 = phi i32 [ 0, %54 ], [ %75, %56 ]
  %59 = phi float [ %51, %54 ], [ %73, %56 ]
  %60 = phi i64 [ 0, %54 ], [ %77, %56 ]
  %61 = getelementptr inbounds nuw [4 x i8], ptr %47, i64 %57
  %62 = load float, ptr %61, align 4, !tbaa !12
  %63 = tail call float @llvm.fabs.f32(float %62)
  %64 = fcmp ogt float %63, %59
  %65 = select i1 %64, float %63, float %59
  %66 = trunc nuw nsw i64 %57 to i32
  %67 = select i1 %64, i32 %66, i32 %58
  %68 = add nuw nsw i64 %57, 1
  %69 = getelementptr inbounds nuw [4 x i8], ptr %47, i64 %68
  %70 = load float, ptr %69, align 4, !tbaa !12
  %71 = tail call float @llvm.fabs.f32(float %70)
  %72 = fcmp ogt float %71, %65
  %73 = select i1 %72, float %71, float %65
  %74 = trunc nuw nsw i64 %68 to i32
  %75 = select i1 %72, i32 %74, i32 %67
  %76 = add nuw nsw i64 %57, 2
  %77 = add nuw i64 %60, 2
  %78 = icmp eq i64 %77, %55
  br i1 %78, label %79, label %56, !llvm.loop !56

79:                                               ; preds = %56
  %80 = icmp eq i64 %52, 0
  br i1 %80, label %92, label %81

81:                                               ; preds = %79, %49
  %82 = phi i64 [ 1, %49 ], [ %76, %79 ]
  %83 = phi i32 [ 0, %49 ], [ %75, %79 ]
  %84 = phi float [ %51, %49 ], [ %73, %79 ]
  %85 = trunc i64 %27 to i1
  tail call void @llvm.assume(i1 %85)
  %86 = getelementptr inbounds nuw [4 x i8], ptr %47, i64 %82
  %87 = load float, ptr %86, align 4, !tbaa !12
  %88 = tail call float @llvm.fabs.f32(float %87)
  %89 = fcmp ogt float %88, %84
  %90 = trunc nuw nsw i64 %82 to i32
  %91 = select i1 %89, i32 %90, i32 %83
  br label %92

92:                                               ; preds = %81, %79, %24
  %93 = phi i32 [ 0, %24 ], [ %75, %79 ], [ %91, %81 ]
  %94 = add nsw i32 %93, %40
  %95 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %25
  store i32 %94, ptr %95, align 4, !tbaa !18
  %96 = sext i32 %94 to i64
  %97 = getelementptr [4 x i8], ptr %0, i64 %43
  %98 = getelementptr [4 x i8], ptr %97, i64 %96
  %99 = load float, ptr %98, align 4, !tbaa !12
  %100 = fcmp une float %99, 0.000000e+00
  br i1 %100, label %101, label %212

101:                                              ; preds = %92
  %102 = icmp eq i32 %93, 0
  %103 = load float, ptr %47, align 4, !tbaa !12
  br i1 %102, label %105, label %104

104:                                              ; preds = %101
  store float %103, ptr %98, align 4, !tbaa !12
  store float %99, ptr %47, align 4, !tbaa !12
  br label %105

105:                                              ; preds = %104, %101
  %106 = phi float [ %99, %104 ], [ %103, %101 ]
  %107 = fdiv float -1.000000e+00, %106
  %108 = sub nsw i64 %10, %41
  %109 = getelementptr i8, ptr %47, i64 4
  %110 = icmp ult i64 %108, 8
  br i1 %110, label %127, label %111

111:                                              ; preds = %105
  %112 = and i64 %108, -8
  %113 = insertelement <4 x float> poison, float %107, i64 0
  %114 = shufflevector <4 x float> %113, <4 x float> poison, <4 x i32> zeroinitializer
  br label %115

115:                                              ; preds = %115, %111
  %116 = phi i64 [ 0, %111 ], [ %123, %115 ]
  %117 = getelementptr inbounds nuw [4 x i8], ptr %109, i64 %116
  %118 = getelementptr inbounds nuw i8, ptr %117, i64 16
  %119 = load <4 x float>, ptr %117, align 4, !tbaa !12
  %120 = load <4 x float>, ptr %118, align 4, !tbaa !12
  %121 = fmul <4 x float> %114, %119
  %122 = fmul <4 x float> %114, %120
  store <4 x float> %121, ptr %117, align 4, !tbaa !12
  store <4 x float> %122, ptr %118, align 4, !tbaa !12
  %123 = add nuw i64 %116, 8
  %124 = icmp eq i64 %123, %112
  br i1 %124, label %125, label %115, !llvm.loop !57

125:                                              ; preds = %115
  %126 = icmp eq i64 %108, %112
  br i1 %126, label %136, label %127

127:                                              ; preds = %105, %125
  %128 = phi i64 [ 0, %105 ], [ %112, %125 ]
  br label %129

129:                                              ; preds = %127, %129
  %130 = phi i64 [ %134, %129 ], [ %128, %127 ]
  %131 = getelementptr inbounds nuw [4 x i8], ptr %109, i64 %130
  %132 = load float, ptr %131, align 4, !tbaa !12
  %133 = fmul float %107, %132
  store float %133, ptr %131, align 4, !tbaa !12
  %134 = add nuw nsw i64 %130, 1
  %135 = icmp eq i64 %134, %108
  br i1 %135, label %136, label %129, !llvm.loop !58

136:                                              ; preds = %129, %125
  %137 = getelementptr [4 x i8], ptr %0, i64 %96
  %138 = icmp ult i64 %108, 8
  %139 = icmp ult ptr %30, %39
  %140 = icmp ult ptr %38, %19
  %141 = and i1 %139, %140
  %142 = or i1 %141, %23
  %143 = and i64 %108, -8
  %144 = icmp eq i64 %108, %143
  %145 = sub i64 %21, %25
  %146 = and i64 %145, 1
  %147 = icmp eq i64 %146, 0
  br label %148

148:                                              ; preds = %136, %209
  %149 = phi i64 [ %26, %136 ], [ %210, %209 ]
  %150 = mul nsw i64 %149, %9
  %151 = getelementptr [4 x i8], ptr %137, i64 %150
  %152 = load float, ptr %151, align 4, !tbaa !12
  %153 = add nsw i64 %150, %25
  br i1 %102, label %157, label %154

154:                                              ; preds = %148
  %155 = getelementptr inbounds [4 x i8], ptr %0, i64 %153
  %156 = load float, ptr %155, align 4, !tbaa !12
  store float %156, ptr %151, align 4, !tbaa !12
  store float %152, ptr %155, align 4, !tbaa !12
  br label %157

157:                                              ; preds = %148, %154
  %158 = getelementptr [4 x i8], ptr %0, i64 %153
  %159 = getelementptr i8, ptr %158, i64 4
  %160 = fcmp oeq float %152, 0.000000e+00
  br i1 %160, label %209, label %161

161:                                              ; preds = %157
  %162 = select i1 %138, i1 true, i1 %142
  br i1 %162, label %181, label %163

163:                                              ; preds = %161
  %164 = insertelement <4 x float> poison, float %152, i64 0
  %165 = shufflevector <4 x float> %164, <4 x float> poison, <4 x i32> zeroinitializer
  br label %166

166:                                              ; preds = %166, %163
  %167 = phi i64 [ 0, %163 ], [ %178, %166 ]
  %168 = getelementptr inbounds nuw [4 x i8], ptr %159, i64 %167
  %169 = getelementptr inbounds nuw i8, ptr %168, i64 16
  %170 = load <4 x float>, ptr %168, align 4, !tbaa !12, !alias.scope !59, !noalias !62
  %171 = load <4 x float>, ptr %169, align 4, !tbaa !12, !alias.scope !59, !noalias !62
  %172 = getelementptr inbounds nuw [4 x i8], ptr %109, i64 %167
  %173 = getelementptr inbounds nuw i8, ptr %172, i64 16
  %174 = load <4 x float>, ptr %172, align 4, !tbaa !12, !alias.scope !62
  %175 = load <4 x float>, ptr %173, align 4, !tbaa !12, !alias.scope !62
  %176 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %165, <4 x float> %174, <4 x float> %170)
  %177 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %165, <4 x float> %175, <4 x float> %171)
  store <4 x float> %176, ptr %168, align 4, !tbaa !12, !alias.scope !59, !noalias !62
  store <4 x float> %177, ptr %169, align 4, !tbaa !12, !alias.scope !59, !noalias !62
  %178 = add nuw i64 %167, 8
  %179 = icmp eq i64 %178, %143
  br i1 %179, label %180, label %166, !llvm.loop !64

180:                                              ; preds = %166
  br i1 %144, label %209, label %181

181:                                              ; preds = %161, %180
  %182 = phi i64 [ %143, %180 ], [ 0, %161 ]
  %183 = add i64 %25, %182
  br i1 %147, label %191, label %184

184:                                              ; preds = %181
  %185 = getelementptr inbounds nuw [4 x i8], ptr %159, i64 %182
  %186 = load float, ptr %185, align 4, !tbaa !12
  %187 = getelementptr inbounds nuw [4 x i8], ptr %109, i64 %182
  %188 = load float, ptr %187, align 4, !tbaa !12
  %189 = tail call float @llvm.fmuladd.f32(float %152, float %188, float %186)
  store float %189, ptr %185, align 4, !tbaa !12
  %190 = or disjoint i64 %182, 1
  br label %191

191:                                              ; preds = %184, %181
  %192 = phi i64 [ %182, %181 ], [ %190, %184 ]
  %193 = icmp eq i64 %22, %183
  br i1 %193, label %209, label %194

194:                                              ; preds = %191, %194
  %195 = phi i64 [ %207, %194 ], [ %192, %191 ]
  %196 = getelementptr inbounds nuw [4 x i8], ptr %159, i64 %195
  %197 = load float, ptr %196, align 4, !tbaa !12
  %198 = getelementptr inbounds nuw [4 x i8], ptr %109, i64 %195
  %199 = load float, ptr %198, align 4, !tbaa !12
  %200 = tail call float @llvm.fmuladd.f32(float %152, float %199, float %197)
  store float %200, ptr %196, align 4, !tbaa !12
  %201 = add nuw nsw i64 %195, 1
  %202 = getelementptr inbounds nuw [4 x i8], ptr %159, i64 %201
  %203 = load float, ptr %202, align 4, !tbaa !12
  %204 = getelementptr inbounds nuw [4 x i8], ptr %109, i64 %201
  %205 = load float, ptr %204, align 4, !tbaa !12
  %206 = tail call float @llvm.fmuladd.f32(float %152, float %205, float %203)
  store float %206, ptr %202, align 4, !tbaa !12
  %207 = add nuw nsw i64 %195, 2
  %208 = icmp eq i64 %207, %108
  br i1 %208, label %209, label %194, !llvm.loop !65

209:                                              ; preds = %191, %194, %180, %157
  %210 = add nuw nsw i64 %149, 1
  %211 = icmp eq i64 %210, %12
  br i1 %211, label %213, label %148, !llvm.loop !66

212:                                              ; preds = %92
  store i32 %40, ptr %4, align 4, !tbaa !18
  br label %213

213:                                              ; preds = %209, %212
  %214 = add nuw nsw i64 %26, 1
  %215 = icmp eq i64 %41, %11
  br i1 %215, label %216, label %24, !llvm.loop !67

216:                                              ; preds = %213, %5
  %217 = sext i32 %6 to i64
  %218 = getelementptr inbounds [4 x i8], ptr %3, i64 %217
  store i32 %6, ptr %218, align 4, !tbaa !18
  %219 = add i32 %1, 1
  %220 = mul i32 %6, %219
  %221 = sext i32 %220 to i64
  %222 = getelementptr inbounds [4 x i8], ptr %0, i64 %221
  %223 = load float, ptr %222, align 4, !tbaa !12
  %224 = fcmp oeq float %223, 0.000000e+00
  br i1 %224, label %225, label %226

225:                                              ; preds = %216
  store i32 %6, ptr %4, align 4, !tbaa !18
  br label %226

226:                                              ; preds = %225, %216
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @dgesl(ptr nofree noundef readonly captures(none) %0, i32 noundef %1, i32 noundef %2, ptr nofree noundef readonly captures(none) %3, ptr nofree noundef captures(none) %4, i32 noundef %5) local_unnamed_addr #6 {
  %7 = add i32 %2, -1
  %8 = icmp eq i32 %5, 0
  br i1 %8, label %14, label %9

9:                                                ; preds = %6
  %10 = icmp sgt i32 %2, 0
  br i1 %10, label %11, label %378

11:                                               ; preds = %9
  %12 = sext i32 %1 to i64
  %13 = zext nneg i32 %2 to i64
  br label %222

14:                                               ; preds = %6
  %15 = icmp sgt i32 %2, 1
  br i1 %15, label %16, label %117

16:                                               ; preds = %14
  %17 = add i32 %1, 1
  %18 = zext nneg i32 %2 to i64
  %19 = zext nneg i32 %7 to i64
  %20 = shl nuw nsw i64 %18, 2
  %21 = getelementptr i8, ptr %4, i64 %20
  %22 = getelementptr i8, ptr %0, i64 4
  %23 = add nsw i64 %18, -2
  br label %24

24:                                               ; preds = %16, %115
  %25 = phi i64 [ 0, %16 ], [ %49, %115 ]
  %26 = shl nuw nsw i64 %25, 2
  %27 = getelementptr i8, ptr %4, i64 %26
  %28 = getelementptr i8, ptr %27, i64 4
  %29 = trunc i64 %25 to i32
  %30 = mul i32 %17, %29
  %31 = sext i32 %30 to i64
  %32 = shl nsw i64 %31, 2
  %33 = getelementptr i8, ptr %22, i64 %32
  %34 = sub nsw i64 %18, %25
  %35 = shl i64 %34, 2
  %36 = getelementptr i8, ptr %0, i64 %35
  %37 = getelementptr i8, ptr %36, i64 %32
  %38 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %25
  %39 = load i32, ptr %38, align 4, !tbaa !18
  %40 = sext i32 %39 to i64
  %41 = getelementptr inbounds [4 x i8], ptr %4, i64 %40
  %42 = load float, ptr %41, align 4, !tbaa !12
  %43 = zext i32 %39 to i64
  %44 = icmp eq i64 %25, %43
  br i1 %44, label %48, label %45

45:                                               ; preds = %24
  %46 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %25
  %47 = load float, ptr %46, align 4, !tbaa !12
  store float %47, ptr %41, align 4, !tbaa !12
  store float %42, ptr %46, align 4, !tbaa !12
  br label %48

48:                                               ; preds = %45, %24
  %49 = add nuw nsw i64 %25, 1
  %50 = trunc nuw nsw i64 %25 to i32
  %51 = mul i32 %17, %50
  %52 = sext i32 %51 to i64
  %53 = getelementptr [4 x i8], ptr %0, i64 %52
  %54 = getelementptr i8, ptr %53, i64 4
  %55 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %49
  %56 = fcmp oeq float %42, 0.000000e+00
  br i1 %56, label %115, label %57

57:                                               ; preds = %48
  %58 = sub nsw i64 %18, %49
  %59 = icmp ult i64 %58, 8
  br i1 %59, label %84, label %60

60:                                               ; preds = %57
  %61 = icmp ult ptr %28, %37
  %62 = icmp ult ptr %33, %21
  %63 = and i1 %61, %62
  br i1 %63, label %84, label %64

64:                                               ; preds = %60
  %65 = and i64 %58, -8
  %66 = insertelement <4 x float> poison, float %42, i64 0
  %67 = shufflevector <4 x float> %66, <4 x float> poison, <4 x i32> zeroinitializer
  br label %68

68:                                               ; preds = %68, %64
  %69 = phi i64 [ 0, %64 ], [ %80, %68 ]
  %70 = getelementptr inbounds nuw [4 x i8], ptr %55, i64 %69
  %71 = getelementptr inbounds nuw i8, ptr %70, i64 16
  %72 = load <4 x float>, ptr %70, align 4, !tbaa !12, !alias.scope !68, !noalias !71
  %73 = load <4 x float>, ptr %71, align 4, !tbaa !12, !alias.scope !68, !noalias !71
  %74 = getelementptr inbounds nuw [4 x i8], ptr %54, i64 %69
  %75 = getelementptr inbounds nuw i8, ptr %74, i64 16
  %76 = load <4 x float>, ptr %74, align 4, !tbaa !12, !alias.scope !71
  %77 = load <4 x float>, ptr %75, align 4, !tbaa !12, !alias.scope !71
  %78 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %67, <4 x float> %76, <4 x float> %72)
  %79 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %67, <4 x float> %77, <4 x float> %73)
  store <4 x float> %78, ptr %70, align 4, !tbaa !12, !alias.scope !68, !noalias !71
  store <4 x float> %79, ptr %71, align 4, !tbaa !12, !alias.scope !68, !noalias !71
  %80 = add nuw i64 %69, 8
  %81 = icmp eq i64 %80, %65
  br i1 %81, label %82, label %68, !llvm.loop !73

82:                                               ; preds = %68
  %83 = icmp eq i64 %58, %65
  br i1 %83, label %115, label %84

84:                                               ; preds = %60, %57, %82
  %85 = phi i64 [ 0, %60 ], [ 0, %57 ], [ %65, %82 ]
  %86 = add i64 %25, %85
  %87 = sub nsw i64 %25, %18
  %88 = and i64 %87, 1
  %89 = icmp eq i64 %88, 0
  br i1 %89, label %90, label %97

90:                                               ; preds = %84
  %91 = getelementptr inbounds nuw [4 x i8], ptr %55, i64 %85
  %92 = load float, ptr %91, align 4, !tbaa !12
  %93 = getelementptr inbounds nuw [4 x i8], ptr %54, i64 %85
  %94 = load float, ptr %93, align 4, !tbaa !12
  %95 = tail call float @llvm.fmuladd.f32(float %42, float %94, float %92)
  store float %95, ptr %91, align 4, !tbaa !12
  %96 = or disjoint i64 %85, 1
  br label %97

97:                                               ; preds = %90, %84
  %98 = phi i64 [ %85, %84 ], [ %96, %90 ]
  %99 = icmp eq i64 %23, %86
  br i1 %99, label %115, label %100

100:                                              ; preds = %97, %100
  %101 = phi i64 [ %113, %100 ], [ %98, %97 ]
  %102 = getelementptr inbounds nuw [4 x i8], ptr %55, i64 %101
  %103 = load float, ptr %102, align 4, !tbaa !12
  %104 = getelementptr inbounds nuw [4 x i8], ptr %54, i64 %101
  %105 = load float, ptr %104, align 4, !tbaa !12
  %106 = tail call float @llvm.fmuladd.f32(float %42, float %105, float %103)
  store float %106, ptr %102, align 4, !tbaa !12
  %107 = add nuw nsw i64 %101, 1
  %108 = getelementptr inbounds nuw [4 x i8], ptr %55, i64 %107
  %109 = load float, ptr %108, align 4, !tbaa !12
  %110 = getelementptr inbounds nuw [4 x i8], ptr %54, i64 %107
  %111 = load float, ptr %110, align 4, !tbaa !12
  %112 = tail call float @llvm.fmuladd.f32(float %42, float %111, float %109)
  store float %112, ptr %108, align 4, !tbaa !12
  %113 = add nuw nsw i64 %101, 2
  %114 = icmp eq i64 %113, %58
  br i1 %114, label %115, label %100, !llvm.loop !74

115:                                              ; preds = %97, %100, %82, %48
  %116 = icmp eq i64 %49, %19
  br i1 %116, label %117, label %24, !llvm.loop !23

117:                                              ; preds = %115, %14
  %118 = icmp sgt i32 %2, 0
  br i1 %118, label %119, label %378

119:                                              ; preds = %117
  %120 = zext nneg i32 %2 to i64
  %121 = sext i32 %1 to i64
  %122 = zext nneg i32 %2 to i64
  %123 = shl nuw nsw i64 %120, 2
  %124 = add nsw i64 %123, -4
  %125 = add nuw nsw i64 %120, 4611686018427387903
  %126 = mul i64 %125, %121
  %127 = shl i64 %126, 2
  %128 = mul nsw i64 %121, -4
  %129 = shl nsw i64 %121, 2
  %130 = sub nuw nsw i64 -4, %129
  %131 = add nsw i64 %120, -2
  %132 = getelementptr i8, ptr %0, i64 %127
  %133 = getelementptr i8, ptr %0, i64 %127
  %134 = getelementptr i8, ptr %133, i64 %123
  %135 = getelementptr i8, ptr %134, i64 -4
  br label %136

136:                                              ; preds = %119, %220
  %137 = phi i64 [ 0, %119 ], [ %145, %220 ]
  %138 = shl i64 %137, 2
  %139 = sub i64 %124, %138
  %140 = getelementptr i8, ptr %4, i64 %139
  %141 = mul i64 %128, %137
  %142 = getelementptr i8, ptr %132, i64 %141
  %143 = mul i64 %130, %137
  %144 = getelementptr i8, ptr %135, i64 %143
  %145 = add nuw nsw i64 %137, 1
  %146 = trunc i64 %145 to i32
  %147 = sub nsw i64 %120, %145
  %148 = sub nsw i32 %2, %146
  %149 = getelementptr inbounds [4 x i8], ptr %4, i64 %147
  %150 = load float, ptr %149, align 4, !tbaa !12
  %151 = mul nsw i64 %147, %121
  %152 = mul nsw i32 %148, %1
  %153 = sext i32 %152 to i64
  %154 = getelementptr [4 x i8], ptr %0, i64 %147
  %155 = getelementptr [4 x i8], ptr %154, i64 %153
  %156 = load float, ptr %155, align 4, !tbaa !12
  %157 = fdiv float %150, %156
  store float %157, ptr %149, align 4, !tbaa !12
  %158 = fneg float %157
  %159 = getelementptr inbounds [4 x i8], ptr %0, i64 %151
  %160 = icmp slt i64 %147, 1
  %161 = fcmp oeq float %157, 0.000000e+00
  %162 = or i1 %160, %161
  br i1 %162, label %220, label %163

163:                                              ; preds = %136
  %164 = icmp ult i64 %147, 8
  br i1 %164, label %189, label %165

165:                                              ; preds = %163
  %166 = icmp ult ptr %4, %144
  %167 = icmp ult ptr %142, %140
  %168 = and i1 %166, %167
  br i1 %168, label %189, label %169

169:                                              ; preds = %165
  %170 = and i64 %147, 9223372036854775800
  %171 = insertelement <4 x float> poison, float %158, i64 0
  %172 = shufflevector <4 x float> %171, <4 x float> poison, <4 x i32> zeroinitializer
  br label %173

173:                                              ; preds = %173, %169
  %174 = phi i64 [ 0, %169 ], [ %185, %173 ]
  %175 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %174
  %176 = getelementptr inbounds nuw i8, ptr %175, i64 16
  %177 = load <4 x float>, ptr %175, align 4, !tbaa !12, !alias.scope !75, !noalias !78
  %178 = load <4 x float>, ptr %176, align 4, !tbaa !12, !alias.scope !75, !noalias !78
  %179 = getelementptr inbounds nuw [4 x i8], ptr %159, i64 %174
  %180 = getelementptr inbounds nuw i8, ptr %179, i64 16
  %181 = load <4 x float>, ptr %179, align 4, !tbaa !12, !alias.scope !78
  %182 = load <4 x float>, ptr %180, align 4, !tbaa !12, !alias.scope !78
  %183 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %172, <4 x float> %181, <4 x float> %177)
  %184 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %172, <4 x float> %182, <4 x float> %178)
  store <4 x float> %183, ptr %175, align 4, !tbaa !12, !alias.scope !75, !noalias !78
  store <4 x float> %184, ptr %176, align 4, !tbaa !12, !alias.scope !75, !noalias !78
  %185 = add nuw i64 %174, 8
  %186 = icmp eq i64 %185, %170
  br i1 %186, label %187, label %173, !llvm.loop !80

187:                                              ; preds = %173
  %188 = icmp eq i64 %147, %170
  br i1 %188, label %220, label %189

189:                                              ; preds = %165, %163, %187
  %190 = phi i64 [ 0, %165 ], [ 0, %163 ], [ %170, %187 ]
  %191 = add nuw i64 %137, %190
  %192 = sub nsw i64 %137, %120
  %193 = and i64 %192, 1
  %194 = icmp eq i64 %193, 0
  br i1 %194, label %195, label %202

195:                                              ; preds = %189
  %196 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %190
  %197 = load float, ptr %196, align 4, !tbaa !12
  %198 = getelementptr inbounds nuw [4 x i8], ptr %159, i64 %190
  %199 = load float, ptr %198, align 4, !tbaa !12
  %200 = tail call float @llvm.fmuladd.f32(float %158, float %199, float %197)
  store float %200, ptr %196, align 4, !tbaa !12
  %201 = or disjoint i64 %190, 1
  br label %202

202:                                              ; preds = %195, %189
  %203 = phi i64 [ %190, %189 ], [ %201, %195 ]
  %204 = icmp eq i64 %131, %191
  br i1 %204, label %220, label %205

205:                                              ; preds = %202, %205
  %206 = phi i64 [ %218, %205 ], [ %203, %202 ]
  %207 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %206
  %208 = load float, ptr %207, align 4, !tbaa !12
  %209 = getelementptr inbounds nuw [4 x i8], ptr %159, i64 %206
  %210 = load float, ptr %209, align 4, !tbaa !12
  %211 = tail call float @llvm.fmuladd.f32(float %158, float %210, float %208)
  store float %211, ptr %207, align 4, !tbaa !12
  %212 = add nuw nsw i64 %206, 1
  %213 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %212
  %214 = load float, ptr %213, align 4, !tbaa !12
  %215 = getelementptr inbounds nuw [4 x i8], ptr %159, i64 %212
  %216 = load float, ptr %215, align 4, !tbaa !12
  %217 = tail call float @llvm.fmuladd.f32(float %158, float %216, float %214)
  store float %217, ptr %213, align 4, !tbaa !12
  %218 = add nuw nsw i64 %206, 2
  %219 = icmp eq i64 %218, %147
  br i1 %219, label %220, label %205, !llvm.loop !81

220:                                              ; preds = %202, %205, %187, %136
  %221 = icmp eq i64 %145, %122
  br i1 %221, label %378, label %136, !llvm.loop !26

222:                                              ; preds = %11, %282
  %223 = phi i64 [ 0, %11 ], [ %292, %282 ]
  %224 = trunc i64 %223 to i32
  %225 = mul nsw i64 %223, %12
  %226 = mul nsw i32 %1, %224
  %227 = getelementptr inbounds [4 x i8], ptr %0, i64 %225
  %228 = icmp eq i64 %223, 0
  br i1 %228, label %282, label %229

229:                                              ; preds = %222
  %230 = and i64 %223, 3
  %231 = icmp samesign ult i64 %223, 4
  br i1 %231, label %266, label %232

232:                                              ; preds = %229
  %233 = and i64 %223, 9223372036854775804
  br label %234

234:                                              ; preds = %234, %232
  %235 = phi i64 [ 0, %232 ], [ %261, %234 ]
  %236 = phi float [ 0.000000e+00, %232 ], [ %260, %234 ]
  %237 = phi i64 [ 0, %232 ], [ %262, %234 ]
  %238 = getelementptr inbounds nuw [4 x i8], ptr %227, i64 %235
  %239 = load float, ptr %238, align 4, !tbaa !12
  %240 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %235
  %241 = load float, ptr %240, align 4, !tbaa !12
  %242 = tail call float @llvm.fmuladd.f32(float %239, float %241, float %236)
  %243 = or disjoint i64 %235, 1
  %244 = getelementptr inbounds nuw [4 x i8], ptr %227, i64 %243
  %245 = load float, ptr %244, align 4, !tbaa !12
  %246 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %243
  %247 = load float, ptr %246, align 4, !tbaa !12
  %248 = tail call float @llvm.fmuladd.f32(float %245, float %247, float %242)
  %249 = or disjoint i64 %235, 2
  %250 = getelementptr inbounds nuw [4 x i8], ptr %227, i64 %249
  %251 = load float, ptr %250, align 4, !tbaa !12
  %252 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %249
  %253 = load float, ptr %252, align 4, !tbaa !12
  %254 = tail call float @llvm.fmuladd.f32(float %251, float %253, float %248)
  %255 = or disjoint i64 %235, 3
  %256 = getelementptr inbounds nuw [4 x i8], ptr %227, i64 %255
  %257 = load float, ptr %256, align 4, !tbaa !12
  %258 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %255
  %259 = load float, ptr %258, align 4, !tbaa !12
  %260 = tail call float @llvm.fmuladd.f32(float %257, float %259, float %254)
  %261 = add nuw nsw i64 %235, 4
  %262 = add i64 %237, 4
  %263 = icmp eq i64 %262, %233
  br i1 %263, label %264, label %234, !llvm.loop !82

264:                                              ; preds = %234
  %265 = icmp eq i64 %230, 0
  br i1 %265, label %282, label %266

266:                                              ; preds = %264, %229
  %267 = phi i64 [ 0, %229 ], [ %261, %264 ]
  %268 = phi float [ 0.000000e+00, %229 ], [ %260, %264 ]
  %269 = icmp ne i64 %230, 0
  tail call void @llvm.assume(i1 %269)
  br label %270

270:                                              ; preds = %270, %266
  %271 = phi i64 [ %279, %270 ], [ %267, %266 ]
  %272 = phi float [ %278, %270 ], [ %268, %266 ]
  %273 = phi i64 [ %280, %270 ], [ 0, %266 ]
  %274 = getelementptr inbounds nuw [4 x i8], ptr %227, i64 %271
  %275 = load float, ptr %274, align 4, !tbaa !12
  %276 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %271
  %277 = load float, ptr %276, align 4, !tbaa !12
  %278 = tail call float @llvm.fmuladd.f32(float %275, float %277, float %272)
  %279 = add nuw nsw i64 %271, 1
  %280 = add i64 %273, 1
  %281 = icmp eq i64 %280, %230
  br i1 %281, label %282, label %270, !llvm.loop !83

282:                                              ; preds = %264, %270, %222
  %283 = phi float [ 0.000000e+00, %222 ], [ %260, %264 ], [ %278, %270 ]
  %284 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %223
  %285 = load float, ptr %284, align 4, !tbaa !12
  %286 = fsub float %285, %283
  %287 = sext i32 %226 to i64
  %288 = getelementptr [4 x i8], ptr %0, i64 %223
  %289 = getelementptr [4 x i8], ptr %288, i64 %287
  %290 = load float, ptr %289, align 4, !tbaa !12
  %291 = fdiv float %286, %290
  store float %291, ptr %284, align 4, !tbaa !12
  %292 = add nuw nsw i64 %223, 1
  %293 = icmp eq i64 %292, %13
  br i1 %293, label %294, label %222, !llvm.loop !84

294:                                              ; preds = %282
  %295 = icmp sgt i32 %2, 2
  br i1 %295, label %296, label %378

296:                                              ; preds = %294
  %297 = add i32 %1, 1
  %298 = zext nneg i32 %2 to i64
  %299 = zext nneg i32 %7 to i64
  br label %300

300:                                              ; preds = %296, %375
  %301 = phi i64 [ 0, %296 ], [ %377, %375 ]
  %302 = phi i64 [ 1, %296 ], [ %303, %375 ]
  %303 = add nuw nsw i64 %302, 1
  %304 = sub nsw i64 %298, %303
  %305 = getelementptr inbounds [4 x i8], ptr %4, i64 %304
  %306 = load float, ptr %305, align 4, !tbaa !12
  %307 = trunc nsw i64 %304 to i32
  %308 = mul i32 %297, %307
  %309 = sext i32 %308 to i64
  %310 = getelementptr [4 x i8], ptr %0, i64 %309
  %311 = getelementptr i8, ptr %310, i64 4
  %312 = getelementptr i8, ptr %305, i64 4
  %313 = and i64 %302, 3
  %314 = icmp ult i64 %301, 3
  br i1 %314, label %349, label %315

315:                                              ; preds = %300
  %316 = and i64 %302, 9223372036854775804
  br label %317

317:                                              ; preds = %317, %315
  %318 = phi i64 [ 0, %315 ], [ %344, %317 ]
  %319 = phi float [ 0.000000e+00, %315 ], [ %343, %317 ]
  %320 = phi i64 [ 0, %315 ], [ %345, %317 ]
  %321 = getelementptr inbounds nuw [4 x i8], ptr %311, i64 %318
  %322 = load float, ptr %321, align 4, !tbaa !12
  %323 = getelementptr inbounds nuw [4 x i8], ptr %312, i64 %318
  %324 = load float, ptr %323, align 4, !tbaa !12
  %325 = tail call float @llvm.fmuladd.f32(float %322, float %324, float %319)
  %326 = or disjoint i64 %318, 1
  %327 = getelementptr inbounds nuw [4 x i8], ptr %311, i64 %326
  %328 = load float, ptr %327, align 4, !tbaa !12
  %329 = getelementptr inbounds nuw [4 x i8], ptr %312, i64 %326
  %330 = load float, ptr %329, align 4, !tbaa !12
  %331 = tail call float @llvm.fmuladd.f32(float %328, float %330, float %325)
  %332 = or disjoint i64 %318, 2
  %333 = getelementptr inbounds nuw [4 x i8], ptr %311, i64 %332
  %334 = load float, ptr %333, align 4, !tbaa !12
  %335 = getelementptr inbounds nuw [4 x i8], ptr %312, i64 %332
  %336 = load float, ptr %335, align 4, !tbaa !12
  %337 = tail call float @llvm.fmuladd.f32(float %334, float %336, float %331)
  %338 = or disjoint i64 %318, 3
  %339 = getelementptr inbounds nuw [4 x i8], ptr %311, i64 %338
  %340 = load float, ptr %339, align 4, !tbaa !12
  %341 = getelementptr inbounds nuw [4 x i8], ptr %312, i64 %338
  %342 = load float, ptr %341, align 4, !tbaa !12
  %343 = tail call float @llvm.fmuladd.f32(float %340, float %342, float %337)
  %344 = add nuw nsw i64 %318, 4
  %345 = add i64 %320, 4
  %346 = icmp eq i64 %345, %316
  br i1 %346, label %347, label %317, !llvm.loop !82

347:                                              ; preds = %317
  %348 = icmp eq i64 %313, 0
  br i1 %348, label %365, label %349

349:                                              ; preds = %347, %300
  %350 = phi i64 [ 0, %300 ], [ %344, %347 ]
  %351 = phi float [ 0.000000e+00, %300 ], [ %343, %347 ]
  %352 = icmp ne i64 %313, 0
  tail call void @llvm.assume(i1 %352)
  br label %353

353:                                              ; preds = %353, %349
  %354 = phi i64 [ %350, %349 ], [ %362, %353 ]
  %355 = phi float [ %351, %349 ], [ %361, %353 ]
  %356 = phi i64 [ 0, %349 ], [ %363, %353 ]
  %357 = getelementptr inbounds nuw [4 x i8], ptr %311, i64 %354
  %358 = load float, ptr %357, align 4, !tbaa !12
  %359 = getelementptr inbounds nuw [4 x i8], ptr %312, i64 %354
  %360 = load float, ptr %359, align 4, !tbaa !12
  %361 = tail call float @llvm.fmuladd.f32(float %358, float %360, float %355)
  %362 = add nuw nsw i64 %354, 1
  %363 = add i64 %356, 1
  %364 = icmp eq i64 %363, %313
  br i1 %364, label %365, label %353, !llvm.loop !85

365:                                              ; preds = %353, %347
  %366 = phi float [ %343, %347 ], [ %361, %353 ]
  %367 = fadd float %306, %366
  store float %367, ptr %305, align 4, !tbaa !12
  %368 = getelementptr inbounds [4 x i8], ptr %3, i64 %304
  %369 = load i32, ptr %368, align 4, !tbaa !18
  %370 = icmp eq i32 %369, %307
  br i1 %370, label %375, label %371

371:                                              ; preds = %365
  %372 = sext i32 %369 to i64
  %373 = getelementptr inbounds [4 x i8], ptr %4, i64 %372
  %374 = load float, ptr %373, align 4, !tbaa !12
  store float %367, ptr %373, align 4, !tbaa !12
  store float %374, ptr %305, align 4, !tbaa !12
  br label %375

375:                                              ; preds = %365, %371
  %376 = icmp eq i64 %303, %299
  %377 = add i64 %301, 1
  br i1 %376, label %378, label %300, !llvm.loop !86

378:                                              ; preds = %375, %220, %9, %117, %294
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @dmxpy(i32 noundef %0, ptr nofree noundef captures(none) %1, i32 noundef %2, i32 noundef %3, ptr nofree noundef readonly captures(none) %4, ptr nofree noundef readonly captures(none) %5) local_unnamed_addr #6 {
  %7 = and i32 %2, -2147483647
  %8 = icmp eq i32 %7, 1
  %9 = icmp sgt i32 %0, 0
  %10 = and i1 %8, %9
  br i1 %10, label %11, label %80

11:                                               ; preds = %6
  %12 = zext nneg i32 %0 to i64
  %13 = icmp ult i32 %0, 8
  br i1 %13, label %47, label %14

14:                                               ; preds = %11
  %15 = shl nuw nsw i64 %12, 2
  %16 = getelementptr i8, ptr %1, i64 %15
  %17 = getelementptr i8, ptr %4, i64 4
  %18 = getelementptr i8, ptr %5, i64 %15
  %19 = icmp ult ptr %1, %17
  %20 = icmp ult ptr %4, %16
  %21 = and i1 %19, %20
  %22 = icmp ult ptr %1, %18
  %23 = icmp ult ptr %5, %16
  %24 = and i1 %22, %23
  %25 = or i1 %21, %24
  br i1 %25, label %47, label %26

26:                                               ; preds = %14
  %27 = and i64 %12, 2147483640
  %28 = load float, ptr %4, align 4, !tbaa !12, !alias.scope !87
  %29 = insertelement <4 x float> poison, float %28, i64 0
  %30 = shufflevector <4 x float> %29, <4 x float> poison, <4 x i32> zeroinitializer
  br label %31

31:                                               ; preds = %31, %26
  %32 = phi i64 [ 0, %26 ], [ %43, %31 ]
  %33 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %32
  %34 = getelementptr inbounds nuw i8, ptr %33, i64 16
  %35 = load <4 x float>, ptr %33, align 4, !tbaa !12, !alias.scope !90, !noalias !92
  %36 = load <4 x float>, ptr %34, align 4, !tbaa !12, !alias.scope !90, !noalias !92
  %37 = getelementptr inbounds nuw [4 x i8], ptr %5, i64 %32
  %38 = getelementptr inbounds nuw i8, ptr %37, i64 16
  %39 = load <4 x float>, ptr %37, align 4, !tbaa !12, !alias.scope !94
  %40 = load <4 x float>, ptr %38, align 4, !tbaa !12, !alias.scope !94
  %41 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %30, <4 x float> %39, <4 x float> %35)
  %42 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %30, <4 x float> %40, <4 x float> %36)
  store <4 x float> %41, ptr %33, align 4, !tbaa !12, !alias.scope !90, !noalias !92
  store <4 x float> %42, ptr %34, align 4, !tbaa !12, !alias.scope !90, !noalias !92
  %43 = add nuw i64 %32, 8
  %44 = icmp eq i64 %43, %27
  br i1 %44, label %45, label %31, !llvm.loop !95

45:                                               ; preds = %31
  %46 = icmp eq i64 %27, %12
  br i1 %46, label %80, label %47

47:                                               ; preds = %14, %11, %45
  %48 = phi i64 [ 0, %14 ], [ 0, %11 ], [ %27, %45 ]
  %49 = and i64 %12, 1
  %50 = icmp eq i64 %49, 0
  br i1 %50, label %59, label %51

51:                                               ; preds = %47
  %52 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %48
  %53 = load float, ptr %52, align 4, !tbaa !12
  %54 = load float, ptr %4, align 4, !tbaa !12
  %55 = getelementptr inbounds nuw [4 x i8], ptr %5, i64 %48
  %56 = load float, ptr %55, align 4, !tbaa !12
  %57 = tail call float @llvm.fmuladd.f32(float %54, float %56, float %53)
  store float %57, ptr %52, align 4, !tbaa !12
  %58 = or disjoint i64 %48, 1
  br label %59

59:                                               ; preds = %51, %47
  %60 = phi i64 [ %48, %47 ], [ %58, %51 ]
  %61 = add nsw i64 %12, -1
  %62 = icmp eq i64 %48, %61
  br i1 %62, label %80, label %63

63:                                               ; preds = %59, %63
  %64 = phi i64 [ %78, %63 ], [ %60, %59 ]
  %65 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %64
  %66 = load float, ptr %65, align 4, !tbaa !12
  %67 = load float, ptr %4, align 4, !tbaa !12
  %68 = getelementptr inbounds nuw [4 x i8], ptr %5, i64 %64
  %69 = load float, ptr %68, align 4, !tbaa !12
  %70 = tail call float @llvm.fmuladd.f32(float %67, float %69, float %66)
  store float %70, ptr %65, align 4, !tbaa !12
  %71 = add nuw nsw i64 %64, 1
  %72 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %71
  %73 = load float, ptr %72, align 4, !tbaa !12
  %74 = load float, ptr %4, align 4, !tbaa !12
  %75 = getelementptr inbounds nuw [4 x i8], ptr %5, i64 %71
  %76 = load float, ptr %75, align 4, !tbaa !12
  %77 = tail call float @llvm.fmuladd.f32(float %74, float %76, float %73)
  store float %77, ptr %72, align 4, !tbaa !12
  %78 = add nuw nsw i64 %64, 2
  %79 = icmp eq i64 %78, %12
  br i1 %79, label %80, label %63, !llvm.loop !96

80:                                               ; preds = %59, %63, %45, %6
  %81 = srem i32 %2, 4
  %82 = icmp sgt i32 %81, 1
  br i1 %82, label %83, label %204

83:                                               ; preds = %80
  br i1 %9, label %84, label %347

84:                                               ; preds = %83
  %85 = add nsw i32 %81, -1
  %86 = add nsw i32 %81, -2
  %87 = zext nneg i32 %86 to i64
  %88 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %87
  %89 = mul nuw nsw i32 %86, %3
  %90 = zext nneg i32 %85 to i64
  %91 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %90
  %92 = mul nsw i32 %85, %3
  %93 = sext i32 %89 to i64
  %94 = sext i32 %92 to i64
  %95 = zext nneg i32 %0 to i64
  %96 = getelementptr [4 x i8], ptr %5, i64 %93
  %97 = getelementptr [4 x i8], ptr %5, i64 %94
  %98 = icmp ult i32 %0, 16
  br i1 %98, label %159, label %99

99:                                               ; preds = %84
  %100 = shl nuw nsw i64 %95, 2
  %101 = getelementptr i8, ptr %1, i64 %100
  %102 = shl nuw nsw i64 %90, 2
  %103 = getelementptr i8, ptr %4, i64 %102
  %104 = getelementptr i8, ptr %103, i64 4
  %105 = shl nuw nsw i64 %87, 2
  %106 = getelementptr i8, ptr %4, i64 %105
  %107 = getelementptr i8, ptr %106, i64 4
  %108 = add nsw i64 %94, %95
  %109 = shl nsw i64 %108, 2
  %110 = getelementptr i8, ptr %5, i64 %109
  %111 = add nsw i64 %93, %95
  %112 = shl nsw i64 %111, 2
  %113 = getelementptr i8, ptr %5, i64 %112
  %114 = icmp ult ptr %1, %104
  %115 = icmp ult ptr %91, %101
  %116 = and i1 %114, %115
  %117 = icmp ult ptr %1, %107
  %118 = icmp ult ptr %88, %101
  %119 = and i1 %117, %118
  %120 = or i1 %116, %119
  %121 = icmp ult ptr %1, %110
  %122 = icmp ult ptr %97, %101
  %123 = and i1 %121, %122
  %124 = or i1 %120, %123
  %125 = icmp ult ptr %1, %113
  %126 = icmp ult ptr %96, %101
  %127 = and i1 %125, %126
  %128 = or i1 %124, %127
  br i1 %128, label %159, label %129

129:                                              ; preds = %99
  %130 = and i64 %95, 2147483640
  %131 = load float, ptr %88, align 4, !tbaa !12, !alias.scope !97
  %132 = insertelement <4 x float> poison, float %131, i64 0
  %133 = shufflevector <4 x float> %132, <4 x float> poison, <4 x i32> zeroinitializer
  %134 = load float, ptr %91, align 4, !tbaa !12, !alias.scope !100
  %135 = insertelement <4 x float> poison, float %134, i64 0
  %136 = shufflevector <4 x float> %135, <4 x float> poison, <4 x i32> zeroinitializer
  br label %137

137:                                              ; preds = %137, %129
  %138 = phi i64 [ 0, %129 ], [ %155, %137 ]
  %139 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %138
  %140 = getelementptr inbounds nuw i8, ptr %139, i64 16
  %141 = load <4 x float>, ptr %139, align 4, !tbaa !12, !alias.scope !102, !noalias !104
  %142 = load <4 x float>, ptr %140, align 4, !tbaa !12, !alias.scope !102, !noalias !104
  %143 = getelementptr [4 x i8], ptr %96, i64 %138
  %144 = getelementptr i8, ptr %143, i64 16
  %145 = load <4 x float>, ptr %143, align 4, !tbaa !12, !alias.scope !107
  %146 = load <4 x float>, ptr %144, align 4, !tbaa !12, !alias.scope !107
  %147 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %133, <4 x float> %145, <4 x float> %141)
  %148 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %133, <4 x float> %146, <4 x float> %142)
  %149 = getelementptr [4 x i8], ptr %97, i64 %138
  %150 = getelementptr i8, ptr %149, i64 16
  %151 = load <4 x float>, ptr %149, align 4, !tbaa !12, !alias.scope !108
  %152 = load <4 x float>, ptr %150, align 4, !tbaa !12, !alias.scope !108
  %153 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %136, <4 x float> %151, <4 x float> %147)
  %154 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %136, <4 x float> %152, <4 x float> %148)
  store <4 x float> %153, ptr %139, align 4, !tbaa !12, !alias.scope !102, !noalias !104
  store <4 x float> %154, ptr %140, align 4, !tbaa !12, !alias.scope !102, !noalias !104
  %155 = add nuw i64 %138, 8
  %156 = icmp eq i64 %155, %130
  br i1 %156, label %157, label %137, !llvm.loop !109

157:                                              ; preds = %137
  %158 = icmp eq i64 %130, %95
  br i1 %158, label %208, label %159

159:                                              ; preds = %99, %84, %157
  %160 = phi i64 [ 0, %99 ], [ 0, %84 ], [ %130, %157 ]
  %161 = and i64 %95, 1
  %162 = icmp eq i64 %161, 0
  br i1 %162, label %175, label %163

163:                                              ; preds = %159
  %164 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %160
  %165 = load float, ptr %164, align 4, !tbaa !12
  %166 = load float, ptr %88, align 4, !tbaa !12
  %167 = getelementptr [4 x i8], ptr %96, i64 %160
  %168 = load float, ptr %167, align 4, !tbaa !12
  %169 = tail call float @llvm.fmuladd.f32(float %166, float %168, float %165)
  %170 = load float, ptr %91, align 4, !tbaa !12
  %171 = getelementptr [4 x i8], ptr %97, i64 %160
  %172 = load float, ptr %171, align 4, !tbaa !12
  %173 = tail call float @llvm.fmuladd.f32(float %170, float %172, float %169)
  store float %173, ptr %164, align 4, !tbaa !12
  %174 = or disjoint i64 %160, 1
  br label %175

175:                                              ; preds = %163, %159
  %176 = phi i64 [ %160, %159 ], [ %174, %163 ]
  %177 = add nsw i64 %95, -1
  %178 = icmp eq i64 %160, %177
  br i1 %178, label %208, label %179

179:                                              ; preds = %175, %179
  %180 = phi i64 [ %202, %179 ], [ %176, %175 ]
  %181 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %180
  %182 = load float, ptr %181, align 4, !tbaa !12
  %183 = load float, ptr %88, align 4, !tbaa !12
  %184 = getelementptr [4 x i8], ptr %96, i64 %180
  %185 = load float, ptr %184, align 4, !tbaa !12
  %186 = tail call float @llvm.fmuladd.f32(float %183, float %185, float %182)
  %187 = load float, ptr %91, align 4, !tbaa !12
  %188 = getelementptr [4 x i8], ptr %97, i64 %180
  %189 = load float, ptr %188, align 4, !tbaa !12
  %190 = tail call float @llvm.fmuladd.f32(float %187, float %189, float %186)
  store float %190, ptr %181, align 4, !tbaa !12
  %191 = add nuw nsw i64 %180, 1
  %192 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %191
  %193 = load float, ptr %192, align 4, !tbaa !12
  %194 = load float, ptr %88, align 4, !tbaa !12
  %195 = getelementptr [4 x i8], ptr %96, i64 %191
  %196 = load float, ptr %195, align 4, !tbaa !12
  %197 = tail call float @llvm.fmuladd.f32(float %194, float %196, float %193)
  %198 = load float, ptr %91, align 4, !tbaa !12
  %199 = getelementptr [4 x i8], ptr %97, i64 %191
  %200 = load float, ptr %199, align 4, !tbaa !12
  %201 = tail call float @llvm.fmuladd.f32(float %198, float %200, float %197)
  store float %201, ptr %192, align 4, !tbaa !12
  %202 = add nuw nsw i64 %180, 2
  %203 = icmp eq i64 %202, %95
  br i1 %203, label %208, label %179, !llvm.loop !110

204:                                              ; preds = %80
  %205 = srem i32 %2, 8
  %206 = icmp sgt i32 %205, 3
  %207 = and i1 %206, %9
  br i1 %207, label %211, label %347

208:                                              ; preds = %175, %179, %157
  %209 = srem i32 %2, 8
  %210 = icmp sgt i32 %209, 3
  br i1 %210, label %211, label %347

211:                                              ; preds = %204, %208
  %212 = phi i32 [ %205, %204 ], [ %209, %208 ]
  %213 = add nsw i32 %212, -1
  %214 = add nsw i32 %212, -4
  %215 = zext i32 %214 to i64
  %216 = getelementptr [4 x i8], ptr %4, i64 %215
  %217 = mul i32 %214, %3
  %218 = add nsw i32 %212, -3
  %219 = zext i32 %218 to i64
  %220 = getelementptr [4 x i8], ptr %4, i64 %219
  %221 = mul i32 %218, %3
  %222 = add nsw i32 %212, -2
  %223 = zext i32 %222 to i64
  %224 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %223
  %225 = mul i32 %222, %3
  %226 = zext nneg i32 %213 to i64
  %227 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %226
  %228 = mul i32 %213, %3
  %229 = sext i32 %217 to i64
  %230 = sext i32 %221 to i64
  %231 = sext i32 %225 to i64
  %232 = sext i32 %228 to i64
  %233 = zext nneg i32 %0 to i64
  %234 = getelementptr [4 x i8], ptr %5, i64 %229
  %235 = getelementptr [4 x i8], ptr %5, i64 %230
  %236 = getelementptr [4 x i8], ptr %5, i64 %231
  %237 = getelementptr [4 x i8], ptr %5, i64 %232
  %238 = icmp ult i32 %0, 20
  br i1 %238, label %323, label %239

239:                                              ; preds = %211
  %240 = shl nuw nsw i64 %233, 2
  %241 = getelementptr i8, ptr %1, i64 %240
  %242 = shl nuw nsw i64 %226, 2
  %243 = getelementptr i8, ptr %4, i64 %242
  %244 = shl nuw nsw i64 %223, 2
  %245 = getelementptr i8, ptr %4, i64 %244
  %246 = shl nuw nsw i64 %219, 2
  %247 = getelementptr i8, ptr %4, i64 %246
  %248 = shl nuw nsw i64 %215, 2
  %249 = getelementptr i8, ptr %4, i64 %248
  %250 = insertelement <4 x ptr> poison, ptr %243, i64 0
  %251 = insertelement <4 x ptr> %250, ptr %245, i64 1
  %252 = insertelement <4 x ptr> %251, ptr %247, i64 2
  %253 = insertelement <4 x ptr> %252, ptr %249, i64 3
  %254 = getelementptr i8, <4 x ptr> %253, i64 4
  %255 = add nsw i64 %232, %233
  %256 = shl nsw i64 %255, 2
  %257 = getelementptr i8, ptr %5, i64 %256
  %258 = add nsw i64 %231, %233
  %259 = shl nsw i64 %258, 2
  %260 = getelementptr i8, ptr %5, i64 %259
  %261 = add nsw i64 %230, %233
  %262 = shl nsw i64 %261, 2
  %263 = getelementptr i8, ptr %5, i64 %262
  %264 = add nsw i64 %229, %233
  %265 = shl nsw i64 %264, 2
  %266 = getelementptr i8, ptr %5, i64 %265
  %267 = insertelement <8 x ptr> poison, ptr %1, i64 0
  %268 = shufflevector <8 x ptr> %267, <8 x ptr> poison, <8 x i32> zeroinitializer
  %269 = shufflevector <4 x ptr> %254, <4 x ptr> poison, <8 x i32> <i32 0, i32 1, i32 2, i32 3, i32 poison, i32 poison, i32 poison, i32 poison>
  %270 = insertelement <8 x ptr> %269, ptr %257, i64 4
  %271 = insertelement <8 x ptr> %270, ptr %260, i64 5
  %272 = insertelement <8 x ptr> %271, ptr %263, i64 6
  %273 = insertelement <8 x ptr> %272, ptr %266, i64 7
  %274 = icmp ult <8 x ptr> %268, %273
  %275 = insertelement <8 x ptr> poison, ptr %227, i64 0
  %276 = insertelement <8 x ptr> %275, ptr %224, i64 1
  %277 = insertelement <8 x ptr> %276, ptr %220, i64 2
  %278 = insertelement <8 x ptr> %277, ptr %216, i64 3
  %279 = insertelement <8 x ptr> %278, ptr %237, i64 4
  %280 = insertelement <8 x ptr> %279, ptr %236, i64 5
  %281 = insertelement <8 x ptr> %280, ptr %235, i64 6
  %282 = insertelement <8 x ptr> %281, ptr %234, i64 7
  %283 = insertelement <8 x ptr> poison, ptr %241, i64 0
  %284 = shufflevector <8 x ptr> %283, <8 x ptr> poison, <8 x i32> zeroinitializer
  %285 = icmp ult <8 x ptr> %282, %284
  %286 = and <8 x i1> %274, %285
  %287 = bitcast <8 x i1> %286 to i8
  %288 = icmp eq i8 %287, 0
  br i1 %288, label %289, label %323

289:                                              ; preds = %239
  %290 = and i64 %233, 2147483644
  %291 = load float, ptr %216, align 4, !tbaa !12, !alias.scope !111
  %292 = insertelement <4 x float> poison, float %291, i64 0
  %293 = shufflevector <4 x float> %292, <4 x float> poison, <4 x i32> zeroinitializer
  %294 = load float, ptr %220, align 4, !tbaa !12, !alias.scope !114
  %295 = insertelement <4 x float> poison, float %294, i64 0
  %296 = shufflevector <4 x float> %295, <4 x float> poison, <4 x i32> zeroinitializer
  %297 = load float, ptr %224, align 4, !tbaa !12, !alias.scope !116
  %298 = insertelement <4 x float> poison, float %297, i64 0
  %299 = shufflevector <4 x float> %298, <4 x float> poison, <4 x i32> zeroinitializer
  %300 = load float, ptr %227, align 4, !tbaa !12, !alias.scope !118
  %301 = insertelement <4 x float> poison, float %300, i64 0
  %302 = shufflevector <4 x float> %301, <4 x float> poison, <4 x i32> zeroinitializer
  br label %303

303:                                              ; preds = %303, %289
  %304 = phi i64 [ 0, %289 ], [ %319, %303 ]
  %305 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %304
  %306 = load <4 x float>, ptr %305, align 4, !tbaa !12, !alias.scope !120, !noalias !122
  %307 = getelementptr [4 x i8], ptr %234, i64 %304
  %308 = load <4 x float>, ptr %307, align 4, !tbaa !12, !alias.scope !127
  %309 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %293, <4 x float> %308, <4 x float> %306)
  %310 = getelementptr [4 x i8], ptr %235, i64 %304
  %311 = load <4 x float>, ptr %310, align 4, !tbaa !12, !alias.scope !128
  %312 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %296, <4 x float> %311, <4 x float> %309)
  %313 = getelementptr [4 x i8], ptr %236, i64 %304
  %314 = load <4 x float>, ptr %313, align 4, !tbaa !12, !alias.scope !129
  %315 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %299, <4 x float> %314, <4 x float> %312)
  %316 = getelementptr [4 x i8], ptr %237, i64 %304
  %317 = load <4 x float>, ptr %316, align 4, !tbaa !12, !alias.scope !130
  %318 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %302, <4 x float> %317, <4 x float> %315)
  store <4 x float> %318, ptr %305, align 4, !tbaa !12, !alias.scope !120, !noalias !122
  %319 = add nuw i64 %304, 4
  %320 = icmp eq i64 %319, %290
  br i1 %320, label %321, label %303, !llvm.loop !131

321:                                              ; preds = %303
  %322 = icmp eq i64 %290, %233
  br i1 %322, label %347, label %323

323:                                              ; preds = %239, %211, %321
  %324 = phi i64 [ 0, %239 ], [ 0, %211 ], [ %290, %321 ]
  br label %325

325:                                              ; preds = %323, %325
  %326 = phi i64 [ %345, %325 ], [ %324, %323 ]
  %327 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %326
  %328 = load float, ptr %327, align 4, !tbaa !12
  %329 = load float, ptr %216, align 4, !tbaa !12
  %330 = getelementptr [4 x i8], ptr %234, i64 %326
  %331 = load float, ptr %330, align 4, !tbaa !12
  %332 = tail call float @llvm.fmuladd.f32(float %329, float %331, float %328)
  %333 = load float, ptr %220, align 4, !tbaa !12
  %334 = getelementptr [4 x i8], ptr %235, i64 %326
  %335 = load float, ptr %334, align 4, !tbaa !12
  %336 = tail call float @llvm.fmuladd.f32(float %333, float %335, float %332)
  %337 = load float, ptr %224, align 4, !tbaa !12
  %338 = getelementptr [4 x i8], ptr %236, i64 %326
  %339 = load float, ptr %338, align 4, !tbaa !12
  %340 = tail call float @llvm.fmuladd.f32(float %337, float %339, float %336)
  %341 = load float, ptr %227, align 4, !tbaa !12
  %342 = getelementptr [4 x i8], ptr %237, i64 %326
  %343 = load float, ptr %342, align 4, !tbaa !12
  %344 = tail call float @llvm.fmuladd.f32(float %341, float %343, float %340)
  store float %344, ptr %327, align 4, !tbaa !12
  %345 = add nuw nsw i64 %326, 1
  %346 = icmp eq i64 %345, %233
  br i1 %346, label %347, label %325, !llvm.loop !132

347:                                              ; preds = %325, %321, %204, %83, %208
  %348 = srem i32 %2, 16
  %349 = icmp sgt i32 %348, 7
  br i1 %349, label %350, label %586

350:                                              ; preds = %347
  br i1 %9, label %351, label %1046

351:                                              ; preds = %350
  %352 = add nsw i32 %348, -1
  %353 = add nsw i32 %348, -8
  %354 = zext i32 %353 to i64
  %355 = getelementptr [4 x i8], ptr %4, i64 %354
  %356 = mul i32 %353, %3
  %357 = add nsw i32 %348, -7
  %358 = zext i32 %357 to i64
  %359 = getelementptr [4 x i8], ptr %4, i64 %358
  %360 = mul i32 %357, %3
  %361 = add nsw i32 %348, -6
  %362 = zext i32 %361 to i64
  %363 = getelementptr [4 x i8], ptr %4, i64 %362
  %364 = mul i32 %361, %3
  %365 = add nsw i32 %348, -5
  %366 = zext i32 %365 to i64
  %367 = getelementptr [4 x i8], ptr %4, i64 %366
  %368 = mul i32 %365, %3
  %369 = add nsw i32 %348, -4
  %370 = zext i32 %369 to i64
  %371 = getelementptr [4 x i8], ptr %4, i64 %370
  %372 = mul i32 %369, %3
  %373 = add nsw i32 %348, -3
  %374 = zext i32 %373 to i64
  %375 = getelementptr [4 x i8], ptr %4, i64 %374
  %376 = mul i32 %373, %3
  %377 = add nsw i32 %348, -2
  %378 = zext i32 %377 to i64
  %379 = getelementptr [4 x i8], ptr %4, i64 %378
  %380 = mul i32 %377, %3
  %381 = zext i32 %352 to i64
  %382 = getelementptr [4 x i8], ptr %4, i64 %381
  %383 = mul i32 %352, %3
  %384 = sext i32 %356 to i64
  %385 = sext i32 %360 to i64
  %386 = sext i32 %364 to i64
  %387 = sext i32 %368 to i64
  %388 = sext i32 %372 to i64
  %389 = sext i32 %376 to i64
  %390 = sext i32 %380 to i64
  %391 = sext i32 %383 to i64
  %392 = zext nneg i32 %0 to i64
  %393 = getelementptr [4 x i8], ptr %5, i64 %384
  %394 = getelementptr [4 x i8], ptr %5, i64 %385
  %395 = getelementptr [4 x i8], ptr %5, i64 %386
  %396 = getelementptr [4 x i8], ptr %5, i64 %387
  %397 = getelementptr [4 x i8], ptr %5, i64 %388
  %398 = getelementptr [4 x i8], ptr %5, i64 %389
  %399 = getelementptr [4 x i8], ptr %5, i64 %390
  %400 = getelementptr [4 x i8], ptr %5, i64 %391
  %401 = icmp ult i32 %0, 20
  br i1 %401, label %546, label %402

402:                                              ; preds = %351
  %403 = shl nuw nsw i64 %392, 2
  %404 = getelementptr i8, ptr %1, i64 %403
  %405 = shl nuw nsw i64 %381, 2
  %406 = getelementptr i8, ptr %4, i64 %405
  %407 = shl nuw nsw i64 %378, 2
  %408 = getelementptr i8, ptr %4, i64 %407
  %409 = shl nuw nsw i64 %374, 2
  %410 = getelementptr i8, ptr %4, i64 %409
  %411 = shl nuw nsw i64 %370, 2
  %412 = getelementptr i8, ptr %4, i64 %411
  %413 = shl nuw nsw i64 %366, 2
  %414 = getelementptr i8, ptr %4, i64 %413
  %415 = shl nuw nsw i64 %362, 2
  %416 = getelementptr i8, ptr %4, i64 %415
  %417 = shl nuw nsw i64 %358, 2
  %418 = getelementptr i8, ptr %4, i64 %417
  %419 = shl nuw nsw i64 %354, 2
  %420 = getelementptr i8, ptr %4, i64 %419
  %421 = insertelement <8 x ptr> poison, ptr %406, i64 0
  %422 = insertelement <8 x ptr> %421, ptr %408, i64 1
  %423 = insertelement <8 x ptr> %422, ptr %410, i64 2
  %424 = insertelement <8 x ptr> %423, ptr %412, i64 3
  %425 = insertelement <8 x ptr> %424, ptr %414, i64 4
  %426 = insertelement <8 x ptr> %425, ptr %416, i64 5
  %427 = insertelement <8 x ptr> %426, ptr %418, i64 6
  %428 = insertelement <8 x ptr> %427, ptr %420, i64 7
  %429 = getelementptr i8, <8 x ptr> %428, i64 4
  %430 = add nsw i64 %391, %392
  %431 = shl nsw i64 %430, 2
  %432 = getelementptr i8, ptr %5, i64 %431
  %433 = add nsw i64 %390, %392
  %434 = shl nsw i64 %433, 2
  %435 = getelementptr i8, ptr %5, i64 %434
  %436 = add nsw i64 %389, %392
  %437 = shl nsw i64 %436, 2
  %438 = getelementptr i8, ptr %5, i64 %437
  %439 = add nsw i64 %388, %392
  %440 = shl nsw i64 %439, 2
  %441 = getelementptr i8, ptr %5, i64 %440
  %442 = add nsw i64 %387, %392
  %443 = shl nsw i64 %442, 2
  %444 = getelementptr i8, ptr %5, i64 %443
  %445 = add nsw i64 %386, %392
  %446 = shl nsw i64 %445, 2
  %447 = getelementptr i8, ptr %5, i64 %446
  %448 = add nsw i64 %385, %392
  %449 = shl nsw i64 %448, 2
  %450 = getelementptr i8, ptr %5, i64 %449
  %451 = add nsw i64 %384, %392
  %452 = shl nsw i64 %451, 2
  %453 = getelementptr i8, ptr %5, i64 %452
  %454 = insertelement <16 x ptr> poison, ptr %1, i64 0
  %455 = shufflevector <16 x ptr> %454, <16 x ptr> poison, <16 x i32> zeroinitializer
  %456 = shufflevector <8 x ptr> %429, <8 x ptr> poison, <16 x i32> <i32 0, i32 1, i32 2, i32 3, i32 4, i32 5, i32 6, i32 7, i32 poison, i32 poison, i32 poison, i32 poison, i32 poison, i32 poison, i32 poison, i32 poison>
  %457 = insertelement <16 x ptr> %456, ptr %432, i64 8
  %458 = insertelement <16 x ptr> %457, ptr %435, i64 9
  %459 = insertelement <16 x ptr> %458, ptr %438, i64 10
  %460 = insertelement <16 x ptr> %459, ptr %441, i64 11
  %461 = insertelement <16 x ptr> %460, ptr %444, i64 12
  %462 = insertelement <16 x ptr> %461, ptr %447, i64 13
  %463 = insertelement <16 x ptr> %462, ptr %450, i64 14
  %464 = insertelement <16 x ptr> %463, ptr %453, i64 15
  %465 = icmp ult <16 x ptr> %455, %464
  %466 = insertelement <16 x ptr> poison, ptr %382, i64 0
  %467 = insertelement <16 x ptr> %466, ptr %379, i64 1
  %468 = insertelement <16 x ptr> %467, ptr %375, i64 2
  %469 = insertelement <16 x ptr> %468, ptr %371, i64 3
  %470 = insertelement <16 x ptr> %469, ptr %367, i64 4
  %471 = insertelement <16 x ptr> %470, ptr %363, i64 5
  %472 = insertelement <16 x ptr> %471, ptr %359, i64 6
  %473 = insertelement <16 x ptr> %472, ptr %355, i64 7
  %474 = insertelement <16 x ptr> %473, ptr %400, i64 8
  %475 = insertelement <16 x ptr> %474, ptr %399, i64 9
  %476 = insertelement <16 x ptr> %475, ptr %398, i64 10
  %477 = insertelement <16 x ptr> %476, ptr %397, i64 11
  %478 = insertelement <16 x ptr> %477, ptr %396, i64 12
  %479 = insertelement <16 x ptr> %478, ptr %395, i64 13
  %480 = insertelement <16 x ptr> %479, ptr %394, i64 14
  %481 = insertelement <16 x ptr> %480, ptr %393, i64 15
  %482 = insertelement <16 x ptr> poison, ptr %404, i64 0
  %483 = shufflevector <16 x ptr> %482, <16 x ptr> poison, <16 x i32> zeroinitializer
  %484 = icmp ult <16 x ptr> %481, %483
  %485 = and <16 x i1> %465, %484
  %486 = bitcast <16 x i1> %485 to i16
  %487 = icmp eq i16 %486, 0
  br i1 %487, label %488, label %546

488:                                              ; preds = %402
  %489 = and i64 %392, 2147483644
  %490 = load float, ptr %355, align 4, !tbaa !12, !alias.scope !133
  %491 = insertelement <4 x float> poison, float %490, i64 0
  %492 = shufflevector <4 x float> %491, <4 x float> poison, <4 x i32> zeroinitializer
  %493 = load float, ptr %359, align 4, !tbaa !12, !alias.scope !136
  %494 = insertelement <4 x float> poison, float %493, i64 0
  %495 = shufflevector <4 x float> %494, <4 x float> poison, <4 x i32> zeroinitializer
  %496 = load float, ptr %363, align 4, !tbaa !12, !alias.scope !138
  %497 = insertelement <4 x float> poison, float %496, i64 0
  %498 = shufflevector <4 x float> %497, <4 x float> poison, <4 x i32> zeroinitializer
  %499 = load float, ptr %367, align 4, !tbaa !12, !alias.scope !140
  %500 = insertelement <4 x float> poison, float %499, i64 0
  %501 = shufflevector <4 x float> %500, <4 x float> poison, <4 x i32> zeroinitializer
  %502 = load float, ptr %371, align 4, !tbaa !12, !alias.scope !142
  %503 = insertelement <4 x float> poison, float %502, i64 0
  %504 = shufflevector <4 x float> %503, <4 x float> poison, <4 x i32> zeroinitializer
  %505 = load float, ptr %375, align 4, !tbaa !12, !alias.scope !144
  %506 = insertelement <4 x float> poison, float %505, i64 0
  %507 = shufflevector <4 x float> %506, <4 x float> poison, <4 x i32> zeroinitializer
  %508 = load float, ptr %379, align 4, !tbaa !12, !alias.scope !146
  %509 = insertelement <4 x float> poison, float %508, i64 0
  %510 = shufflevector <4 x float> %509, <4 x float> poison, <4 x i32> zeroinitializer
  %511 = load float, ptr %382, align 4, !tbaa !12, !alias.scope !148
  %512 = insertelement <4 x float> poison, float %511, i64 0
  %513 = shufflevector <4 x float> %512, <4 x float> poison, <4 x i32> zeroinitializer
  br label %514

514:                                              ; preds = %514, %488
  %515 = phi i64 [ 0, %488 ], [ %542, %514 ]
  %516 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %515
  %517 = load <4 x float>, ptr %516, align 4, !tbaa !12, !alias.scope !150, !noalias !152
  %518 = getelementptr [4 x i8], ptr %393, i64 %515
  %519 = load <4 x float>, ptr %518, align 4, !tbaa !12, !alias.scope !161
  %520 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %492, <4 x float> %519, <4 x float> %517)
  %521 = getelementptr [4 x i8], ptr %394, i64 %515
  %522 = load <4 x float>, ptr %521, align 4, !tbaa !12, !alias.scope !162
  %523 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %495, <4 x float> %522, <4 x float> %520)
  %524 = getelementptr [4 x i8], ptr %395, i64 %515
  %525 = load <4 x float>, ptr %524, align 4, !tbaa !12, !alias.scope !163
  %526 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %498, <4 x float> %525, <4 x float> %523)
  %527 = getelementptr [4 x i8], ptr %396, i64 %515
  %528 = load <4 x float>, ptr %527, align 4, !tbaa !12, !alias.scope !164
  %529 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %501, <4 x float> %528, <4 x float> %526)
  %530 = getelementptr [4 x i8], ptr %397, i64 %515
  %531 = load <4 x float>, ptr %530, align 4, !tbaa !12, !alias.scope !165
  %532 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %504, <4 x float> %531, <4 x float> %529)
  %533 = getelementptr [4 x i8], ptr %398, i64 %515
  %534 = load <4 x float>, ptr %533, align 4, !tbaa !12, !alias.scope !166
  %535 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %507, <4 x float> %534, <4 x float> %532)
  %536 = getelementptr [4 x i8], ptr %399, i64 %515
  %537 = load <4 x float>, ptr %536, align 4, !tbaa !12, !alias.scope !167
  %538 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %510, <4 x float> %537, <4 x float> %535)
  %539 = getelementptr [4 x i8], ptr %400, i64 %515
  %540 = load <4 x float>, ptr %539, align 4, !tbaa !12, !alias.scope !168
  %541 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %513, <4 x float> %540, <4 x float> %538)
  store <4 x float> %541, ptr %516, align 4, !tbaa !12, !alias.scope !150, !noalias !152
  %542 = add nuw i64 %515, 4
  %543 = icmp eq i64 %542, %489
  br i1 %543, label %544, label %514, !llvm.loop !169

544:                                              ; preds = %514
  %545 = icmp eq i64 %489, %392
  br i1 %545, label %586, label %546

546:                                              ; preds = %402, %351, %544
  %547 = phi i64 [ 0, %402 ], [ 0, %351 ], [ %489, %544 ]
  br label %548

548:                                              ; preds = %546, %548
  %549 = phi i64 [ %584, %548 ], [ %547, %546 ]
  %550 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %549
  %551 = load float, ptr %550, align 4, !tbaa !12
  %552 = load float, ptr %355, align 4, !tbaa !12
  %553 = getelementptr [4 x i8], ptr %393, i64 %549
  %554 = load float, ptr %553, align 4, !tbaa !12
  %555 = tail call float @llvm.fmuladd.f32(float %552, float %554, float %551)
  %556 = load float, ptr %359, align 4, !tbaa !12
  %557 = getelementptr [4 x i8], ptr %394, i64 %549
  %558 = load float, ptr %557, align 4, !tbaa !12
  %559 = tail call float @llvm.fmuladd.f32(float %556, float %558, float %555)
  %560 = load float, ptr %363, align 4, !tbaa !12
  %561 = getelementptr [4 x i8], ptr %395, i64 %549
  %562 = load float, ptr %561, align 4, !tbaa !12
  %563 = tail call float @llvm.fmuladd.f32(float %560, float %562, float %559)
  %564 = load float, ptr %367, align 4, !tbaa !12
  %565 = getelementptr [4 x i8], ptr %396, i64 %549
  %566 = load float, ptr %565, align 4, !tbaa !12
  %567 = tail call float @llvm.fmuladd.f32(float %564, float %566, float %563)
  %568 = load float, ptr %371, align 4, !tbaa !12
  %569 = getelementptr [4 x i8], ptr %397, i64 %549
  %570 = load float, ptr %569, align 4, !tbaa !12
  %571 = tail call float @llvm.fmuladd.f32(float %568, float %570, float %567)
  %572 = load float, ptr %375, align 4, !tbaa !12
  %573 = getelementptr [4 x i8], ptr %398, i64 %549
  %574 = load float, ptr %573, align 4, !tbaa !12
  %575 = tail call float @llvm.fmuladd.f32(float %572, float %574, float %571)
  %576 = load float, ptr %379, align 4, !tbaa !12
  %577 = getelementptr [4 x i8], ptr %399, i64 %549
  %578 = load float, ptr %577, align 4, !tbaa !12
  %579 = tail call float @llvm.fmuladd.f32(float %576, float %578, float %575)
  %580 = load float, ptr %382, align 4, !tbaa !12
  %581 = getelementptr [4 x i8], ptr %400, i64 %549
  %582 = load float, ptr %581, align 4, !tbaa !12
  %583 = tail call float @llvm.fmuladd.f32(float %580, float %582, float %579)
  store float %583, ptr %550, align 4, !tbaa !12
  %584 = add nuw nsw i64 %549, 1
  %585 = icmp eq i64 %584, %392
  br i1 %585, label %586, label %548, !llvm.loop !170

586:                                              ; preds = %548, %544, %347
  %587 = add nsw i32 %348, 15
  %588 = icmp slt i32 %587, %2
  %589 = and i1 %588, %9
  br i1 %589, label %590, label %1046

590:                                              ; preds = %586
  %591 = add nsw i32 %348, 15
  %592 = zext i32 %591 to i64
  %593 = sext i32 %3 to i64
  %594 = zext i32 %2 to i64
  %595 = zext nneg i32 %0 to i64
  %596 = shl nuw nsw i64 %595, 2
  %597 = getelementptr i8, ptr %1, i64 %596
  %598 = shl nuw nsw i64 %592, 2
  %599 = getelementptr i8, ptr %4, i64 %598
  %600 = getelementptr i8, ptr %599, i64 -60
  %601 = add nuw nsw i64 %592, 16
  %602 = tail call i64 @llvm.umax.i64(i64 %601, i64 %594)
  %603 = xor i64 %592, -1
  %604 = add nsw i64 %602, %603
  %605 = shl nsw i64 %604, 2
  %606 = and i64 %605, -64
  %607 = add nsw i64 %606, %598
  %608 = getelementptr i8, ptr %4, i64 %607
  %609 = getelementptr i8, ptr %608, i64 4
  %610 = mul nsw i64 %593, %592
  %611 = shl i64 %610, 2
  %612 = getelementptr i8, ptr %5, i64 %611
  %613 = mul i64 %607, %593
  %614 = getelementptr i8, ptr %5, i64 %613
  %615 = getelementptr i8, ptr %614, i64 %596
  %616 = add nuw nsw i64 %592, 4611686018427387903
  %617 = mul i64 %616, %593
  %618 = shl i64 %617, 2
  %619 = getelementptr i8, ptr %5, i64 %618
  %620 = add nsw i64 %606, %598
  %621 = add i64 %620, -4
  %622 = mul i64 %621, %593
  %623 = getelementptr i8, ptr %5, i64 %622
  %624 = getelementptr i8, ptr %623, i64 %596
  %625 = add nuw nsw i64 %592, 4611686018427387902
  %626 = mul i64 %625, %593
  %627 = shl i64 %626, 2
  %628 = getelementptr i8, ptr %5, i64 %627
  %629 = add nsw i64 %606, %598
  %630 = add i64 %629, -8
  %631 = mul i64 %630, %593
  %632 = getelementptr i8, ptr %5, i64 %631
  %633 = getelementptr i8, ptr %632, i64 %596
  %634 = add nuw nsw i64 %592, 4611686018427387901
  %635 = mul i64 %634, %593
  %636 = shl i64 %635, 2
  %637 = getelementptr i8, ptr %5, i64 %636
  %638 = add nsw i64 %606, %598
  %639 = add i64 %638, -12
  %640 = mul i64 %639, %593
  %641 = getelementptr i8, ptr %5, i64 %640
  %642 = getelementptr i8, ptr %641, i64 %596
  %643 = add nuw nsw i64 %592, 4611686018427387900
  %644 = mul i64 %643, %593
  %645 = shl i64 %644, 2
  %646 = getelementptr i8, ptr %5, i64 %645
  %647 = add nsw i64 %606, %598
  %648 = add i64 %647, -16
  %649 = mul i64 %648, %593
  %650 = getelementptr i8, ptr %5, i64 %649
  %651 = getelementptr i8, ptr %650, i64 %596
  %652 = add nuw nsw i64 %592, 4611686018427387899
  %653 = mul i64 %652, %593
  %654 = shl i64 %653, 2
  %655 = getelementptr i8, ptr %5, i64 %654
  %656 = add nsw i64 %606, %598
  %657 = add i64 %656, -20
  %658 = mul i64 %657, %593
  %659 = getelementptr i8, ptr %5, i64 %658
  %660 = getelementptr i8, ptr %659, i64 %596
  %661 = add nuw nsw i64 %592, 4611686018427387898
  %662 = mul i64 %661, %593
  %663 = shl i64 %662, 2
  %664 = getelementptr i8, ptr %5, i64 %663
  %665 = add nsw i64 %606, %598
  %666 = add i64 %665, -24
  %667 = mul i64 %666, %593
  %668 = getelementptr i8, ptr %5, i64 %667
  %669 = getelementptr i8, ptr %668, i64 %596
  %670 = add nuw nsw i64 %592, 4611686018427387897
  %671 = mul i64 %670, %593
  %672 = shl i64 %671, 2
  %673 = getelementptr i8, ptr %5, i64 %672
  %674 = add nsw i64 %606, %598
  %675 = add i64 %674, -28
  %676 = mul i64 %675, %593
  %677 = getelementptr i8, ptr %5, i64 %676
  %678 = getelementptr i8, ptr %677, i64 %596
  %679 = add nuw nsw i64 %592, 4611686018427387896
  %680 = mul i64 %679, %593
  %681 = shl i64 %680, 2
  %682 = getelementptr i8, ptr %5, i64 %681
  %683 = add nsw i64 %606, %598
  %684 = add i64 %683, -32
  %685 = mul i64 %684, %593
  %686 = getelementptr i8, ptr %5, i64 %685
  %687 = getelementptr i8, ptr %686, i64 %596
  %688 = add nuw nsw i64 %592, 4611686018427387895
  %689 = mul i64 %688, %593
  %690 = shl i64 %689, 2
  %691 = getelementptr i8, ptr %5, i64 %690
  %692 = add nsw i64 %606, %598
  %693 = add i64 %692, -36
  %694 = mul i64 %693, %593
  %695 = getelementptr i8, ptr %5, i64 %694
  %696 = getelementptr i8, ptr %695, i64 %596
  %697 = add nuw nsw i64 %592, 4611686018427387894
  %698 = mul i64 %697, %593
  %699 = shl i64 %698, 2
  %700 = getelementptr i8, ptr %5, i64 %699
  %701 = add nsw i64 %606, %598
  %702 = add i64 %701, -40
  %703 = mul i64 %702, %593
  %704 = getelementptr i8, ptr %5, i64 %703
  %705 = getelementptr i8, ptr %704, i64 %596
  %706 = add nuw nsw i64 %592, 4611686018427387893
  %707 = mul i64 %706, %593
  %708 = shl i64 %707, 2
  %709 = getelementptr i8, ptr %5, i64 %708
  %710 = add nsw i64 %606, %598
  %711 = add i64 %710, -44
  %712 = mul i64 %711, %593
  %713 = getelementptr i8, ptr %5, i64 %712
  %714 = getelementptr i8, ptr %713, i64 %596
  %715 = add nuw nsw i64 %592, 4611686018427387892
  %716 = mul i64 %715, %593
  %717 = shl i64 %716, 2
  %718 = getelementptr i8, ptr %5, i64 %717
  %719 = add nsw i64 %606, %598
  %720 = add i64 %719, -48
  %721 = mul i64 %720, %593
  %722 = getelementptr i8, ptr %5, i64 %721
  %723 = getelementptr i8, ptr %722, i64 %596
  %724 = add nuw nsw i64 %592, 4611686018427387891
  %725 = mul i64 %724, %593
  %726 = shl i64 %725, 2
  %727 = getelementptr i8, ptr %5, i64 %726
  %728 = add nsw i64 %606, %598
  %729 = add i64 %728, -52
  %730 = mul i64 %729, %593
  %731 = getelementptr i8, ptr %5, i64 %730
  %732 = getelementptr i8, ptr %731, i64 %596
  %733 = add nuw nsw i64 %592, 4611686018427387890
  %734 = mul i64 %733, %593
  %735 = shl i64 %734, 2
  %736 = getelementptr i8, ptr %5, i64 %735
  %737 = add nsw i64 %606, %598
  %738 = add i64 %737, -56
  %739 = mul i64 %738, %593
  %740 = getelementptr i8, ptr %5, i64 %739
  %741 = getelementptr i8, ptr %740, i64 %596
  %742 = add nuw nsw i64 %592, 4611686018427387889
  %743 = mul i64 %742, %593
  %744 = shl i64 %743, 2
  %745 = getelementptr i8, ptr %5, i64 %744
  %746 = add nsw i64 %606, %598
  %747 = add i64 %746, -60
  %748 = mul i64 %747, %593
  %749 = getelementptr i8, ptr %5, i64 %748
  %750 = getelementptr i8, ptr %749, i64 %596
  %751 = insertelement <16 x ptr> poison, ptr %1, i64 0
  %752 = shufflevector <16 x ptr> %751, <16 x ptr> poison, <16 x i32> zeroinitializer
  %753 = insertelement <16 x ptr> poison, ptr %615, i64 0
  %754 = insertelement <16 x ptr> %753, ptr %609, i64 1
  %755 = insertelement <16 x ptr> %754, ptr %624, i64 2
  %756 = insertelement <16 x ptr> %755, ptr %633, i64 3
  %757 = insertelement <16 x ptr> %756, ptr %642, i64 4
  %758 = insertelement <16 x ptr> %757, ptr %651, i64 5
  %759 = insertelement <16 x ptr> %758, ptr %660, i64 6
  %760 = insertelement <16 x ptr> %759, ptr %669, i64 7
  %761 = insertelement <16 x ptr> %760, ptr %678, i64 8
  %762 = insertelement <16 x ptr> %761, ptr %687, i64 9
  %763 = insertelement <16 x ptr> %762, ptr %696, i64 10
  %764 = insertelement <16 x ptr> %763, ptr %705, i64 11
  %765 = insertelement <16 x ptr> %764, ptr %714, i64 12
  %766 = insertelement <16 x ptr> %765, ptr %723, i64 13
  %767 = insertelement <16 x ptr> %766, ptr %732, i64 14
  %768 = insertelement <16 x ptr> %767, ptr %741, i64 15
  %769 = insertelement <16 x ptr> poison, ptr %612, i64 0
  %770 = insertelement <16 x ptr> %769, ptr %600, i64 1
  %771 = insertelement <16 x ptr> %770, ptr %619, i64 2
  %772 = insertelement <16 x ptr> %771, ptr %628, i64 3
  %773 = insertelement <16 x ptr> %772, ptr %637, i64 4
  %774 = insertelement <16 x ptr> %773, ptr %646, i64 5
  %775 = insertelement <16 x ptr> %774, ptr %655, i64 6
  %776 = insertelement <16 x ptr> %775, ptr %664, i64 7
  %777 = insertelement <16 x ptr> %776, ptr %673, i64 8
  %778 = insertelement <16 x ptr> %777, ptr %682, i64 9
  %779 = insertelement <16 x ptr> %778, ptr %691, i64 10
  %780 = insertelement <16 x ptr> %779, ptr %700, i64 11
  %781 = insertelement <16 x ptr> %780, ptr %709, i64 12
  %782 = insertelement <16 x ptr> %781, ptr %718, i64 13
  %783 = insertelement <16 x ptr> %782, ptr %727, i64 14
  %784 = insertelement <16 x ptr> %783, ptr %736, i64 15
  %785 = insertelement <16 x ptr> poison, ptr %597, i64 0
  %786 = shufflevector <16 x ptr> %785, <16 x ptr> poison, <16 x i32> zeroinitializer
  %787 = icmp ult i32 %0, 8
  %788 = icmp ult <16 x ptr> %752, %768
  %789 = icmp ult <16 x ptr> %784, %786
  %790 = icmp slt i32 %3, 0
  %791 = and <16 x i1> %788, %789
  %792 = icmp ult ptr %1, %750
  %793 = icmp ult ptr %745, %597
  %794 = and i1 %792, %793
  %795 = bitcast <16 x i1> %791 to i16
  %796 = icmp ne i16 %795, 0
  %797 = or i1 %796, %794
  %798 = or i1 %797, %790
  %799 = and i64 %595, 2147483644
  %800 = icmp eq i64 %799, %595
  br label %801

801:                                              ; preds = %590, %1043
  %802 = phi i64 [ %592, %590 ], [ %1044, %1043 ]
  %803 = add nsw i64 %802, -15
  %804 = getelementptr inbounds [4 x i8], ptr %4, i64 %803
  %805 = mul nsw i64 %803, %593
  %806 = add nsw i64 %802, -14
  %807 = getelementptr inbounds [4 x i8], ptr %4, i64 %806
  %808 = mul nsw i64 %806, %593
  %809 = add nsw i64 %802, -13
  %810 = getelementptr inbounds [4 x i8], ptr %4, i64 %809
  %811 = mul nsw i64 %809, %593
  %812 = add nsw i64 %802, -12
  %813 = getelementptr inbounds [4 x i8], ptr %4, i64 %812
  %814 = mul nsw i64 %812, %593
  %815 = add nsw i64 %802, -11
  %816 = getelementptr inbounds [4 x i8], ptr %4, i64 %815
  %817 = mul nsw i64 %815, %593
  %818 = add nsw i64 %802, -10
  %819 = getelementptr inbounds [4 x i8], ptr %4, i64 %818
  %820 = mul nsw i64 %818, %593
  %821 = add nsw i64 %802, -9
  %822 = getelementptr inbounds [4 x i8], ptr %4, i64 %821
  %823 = mul nsw i64 %821, %593
  %824 = add nsw i64 %802, -8
  %825 = getelementptr inbounds [4 x i8], ptr %4, i64 %824
  %826 = mul nsw i64 %824, %593
  %827 = add nsw i64 %802, -7
  %828 = getelementptr inbounds [4 x i8], ptr %4, i64 %827
  %829 = mul nsw i64 %827, %593
  %830 = add nsw i64 %802, -6
  %831 = getelementptr inbounds [4 x i8], ptr %4, i64 %830
  %832 = mul nsw i64 %830, %593
  %833 = add nsw i64 %802, -5
  %834 = getelementptr inbounds [4 x i8], ptr %4, i64 %833
  %835 = mul nsw i64 %833, %593
  %836 = add nsw i64 %802, -4
  %837 = getelementptr inbounds [4 x i8], ptr %4, i64 %836
  %838 = mul nsw i64 %836, %593
  %839 = add nsw i64 %802, -3
  %840 = getelementptr inbounds [4 x i8], ptr %4, i64 %839
  %841 = mul nsw i64 %839, %593
  %842 = add nsw i64 %802, -2
  %843 = getelementptr inbounds [4 x i8], ptr %4, i64 %842
  %844 = mul nsw i64 %842, %593
  %845 = add nsw i64 %802, -1
  %846 = getelementptr inbounds [4 x i8], ptr %4, i64 %845
  %847 = mul nsw i64 %845, %593
  %848 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %802
  %849 = mul nsw i64 %802, %593
  %850 = getelementptr [4 x i8], ptr %5, i64 %805
  %851 = getelementptr [4 x i8], ptr %5, i64 %808
  %852 = getelementptr [4 x i8], ptr %5, i64 %811
  %853 = getelementptr [4 x i8], ptr %5, i64 %814
  %854 = getelementptr [4 x i8], ptr %5, i64 %817
  %855 = getelementptr [4 x i8], ptr %5, i64 %820
  %856 = getelementptr [4 x i8], ptr %5, i64 %823
  %857 = getelementptr [4 x i8], ptr %5, i64 %826
  %858 = getelementptr [4 x i8], ptr %5, i64 %829
  %859 = getelementptr [4 x i8], ptr %5, i64 %832
  %860 = getelementptr [4 x i8], ptr %5, i64 %835
  %861 = getelementptr [4 x i8], ptr %5, i64 %838
  %862 = getelementptr [4 x i8], ptr %5, i64 %841
  %863 = getelementptr [4 x i8], ptr %5, i64 %844
  %864 = getelementptr [4 x i8], ptr %5, i64 %847
  %865 = getelementptr [4 x i8], ptr %5, i64 %849
  %866 = select i1 %787, i1 true, i1 %798
  br i1 %866, label %971, label %867

867:                                              ; preds = %801
  %868 = load float, ptr %804, align 4, !tbaa !12, !alias.scope !171
  %869 = insertelement <4 x float> poison, float %868, i64 0
  %870 = shufflevector <4 x float> %869, <4 x float> poison, <4 x i32> zeroinitializer
  %871 = load float, ptr %807, align 4, !tbaa !12, !alias.scope !171
  %872 = insertelement <4 x float> poison, float %871, i64 0
  %873 = shufflevector <4 x float> %872, <4 x float> poison, <4 x i32> zeroinitializer
  %874 = load float, ptr %810, align 4, !tbaa !12, !alias.scope !171
  %875 = insertelement <4 x float> poison, float %874, i64 0
  %876 = shufflevector <4 x float> %875, <4 x float> poison, <4 x i32> zeroinitializer
  %877 = load float, ptr %813, align 4, !tbaa !12, !alias.scope !171
  %878 = insertelement <4 x float> poison, float %877, i64 0
  %879 = shufflevector <4 x float> %878, <4 x float> poison, <4 x i32> zeroinitializer
  %880 = load float, ptr %816, align 4, !tbaa !12, !alias.scope !171
  %881 = insertelement <4 x float> poison, float %880, i64 0
  %882 = shufflevector <4 x float> %881, <4 x float> poison, <4 x i32> zeroinitializer
  %883 = load float, ptr %819, align 4, !tbaa !12, !alias.scope !171
  %884 = insertelement <4 x float> poison, float %883, i64 0
  %885 = shufflevector <4 x float> %884, <4 x float> poison, <4 x i32> zeroinitializer
  %886 = load float, ptr %822, align 4, !tbaa !12, !alias.scope !171
  %887 = insertelement <4 x float> poison, float %886, i64 0
  %888 = shufflevector <4 x float> %887, <4 x float> poison, <4 x i32> zeroinitializer
  %889 = load float, ptr %825, align 4, !tbaa !12, !alias.scope !171
  %890 = insertelement <4 x float> poison, float %889, i64 0
  %891 = shufflevector <4 x float> %890, <4 x float> poison, <4 x i32> zeroinitializer
  %892 = load float, ptr %828, align 4, !tbaa !12, !alias.scope !171
  %893 = insertelement <4 x float> poison, float %892, i64 0
  %894 = shufflevector <4 x float> %893, <4 x float> poison, <4 x i32> zeroinitializer
  %895 = load float, ptr %831, align 4, !tbaa !12, !alias.scope !171
  %896 = insertelement <4 x float> poison, float %895, i64 0
  %897 = shufflevector <4 x float> %896, <4 x float> poison, <4 x i32> zeroinitializer
  %898 = load float, ptr %834, align 4, !tbaa !12, !alias.scope !171
  %899 = insertelement <4 x float> poison, float %898, i64 0
  %900 = shufflevector <4 x float> %899, <4 x float> poison, <4 x i32> zeroinitializer
  %901 = load float, ptr %837, align 4, !tbaa !12, !alias.scope !171
  %902 = insertelement <4 x float> poison, float %901, i64 0
  %903 = shufflevector <4 x float> %902, <4 x float> poison, <4 x i32> zeroinitializer
  %904 = load float, ptr %840, align 4, !tbaa !12, !alias.scope !171
  %905 = insertelement <4 x float> poison, float %904, i64 0
  %906 = shufflevector <4 x float> %905, <4 x float> poison, <4 x i32> zeroinitializer
  %907 = load float, ptr %843, align 4, !tbaa !12, !alias.scope !171
  %908 = insertelement <4 x float> poison, float %907, i64 0
  %909 = shufflevector <4 x float> %908, <4 x float> poison, <4 x i32> zeroinitializer
  %910 = load float, ptr %846, align 4, !tbaa !12, !alias.scope !171
  %911 = insertelement <4 x float> poison, float %910, i64 0
  %912 = shufflevector <4 x float> %911, <4 x float> poison, <4 x i32> zeroinitializer
  %913 = load float, ptr %848, align 4, !tbaa !12, !alias.scope !171
  %914 = insertelement <4 x float> poison, float %913, i64 0
  %915 = shufflevector <4 x float> %914, <4 x float> poison, <4 x i32> zeroinitializer
  br label %916

916:                                              ; preds = %916, %867
  %917 = phi i64 [ 0, %867 ], [ %968, %916 ]
  %918 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %917
  %919 = load <4 x float>, ptr %918, align 4, !tbaa !12, !alias.scope !174, !noalias !176
  %920 = getelementptr [4 x i8], ptr %850, i64 %917
  %921 = load <4 x float>, ptr %920, align 4, !tbaa !12, !alias.scope !193
  %922 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %870, <4 x float> %921, <4 x float> %919)
  %923 = getelementptr [4 x i8], ptr %851, i64 %917
  %924 = load <4 x float>, ptr %923, align 4, !tbaa !12, !alias.scope !194
  %925 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %873, <4 x float> %924, <4 x float> %922)
  %926 = getelementptr [4 x i8], ptr %852, i64 %917
  %927 = load <4 x float>, ptr %926, align 4, !tbaa !12, !alias.scope !195
  %928 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %876, <4 x float> %927, <4 x float> %925)
  %929 = getelementptr [4 x i8], ptr %853, i64 %917
  %930 = load <4 x float>, ptr %929, align 4, !tbaa !12, !alias.scope !196
  %931 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %879, <4 x float> %930, <4 x float> %928)
  %932 = getelementptr [4 x i8], ptr %854, i64 %917
  %933 = load <4 x float>, ptr %932, align 4, !tbaa !12, !alias.scope !197
  %934 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %882, <4 x float> %933, <4 x float> %931)
  %935 = getelementptr [4 x i8], ptr %855, i64 %917
  %936 = load <4 x float>, ptr %935, align 4, !tbaa !12, !alias.scope !198
  %937 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %885, <4 x float> %936, <4 x float> %934)
  %938 = getelementptr [4 x i8], ptr %856, i64 %917
  %939 = load <4 x float>, ptr %938, align 4, !tbaa !12, !alias.scope !199
  %940 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %888, <4 x float> %939, <4 x float> %937)
  %941 = getelementptr [4 x i8], ptr %857, i64 %917
  %942 = load <4 x float>, ptr %941, align 4, !tbaa !12, !alias.scope !200
  %943 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %891, <4 x float> %942, <4 x float> %940)
  %944 = getelementptr [4 x i8], ptr %858, i64 %917
  %945 = load <4 x float>, ptr %944, align 4, !tbaa !12, !alias.scope !201
  %946 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %894, <4 x float> %945, <4 x float> %943)
  %947 = getelementptr [4 x i8], ptr %859, i64 %917
  %948 = load <4 x float>, ptr %947, align 4, !tbaa !12, !alias.scope !202
  %949 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %897, <4 x float> %948, <4 x float> %946)
  %950 = getelementptr [4 x i8], ptr %860, i64 %917
  %951 = load <4 x float>, ptr %950, align 4, !tbaa !12, !alias.scope !203
  %952 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %900, <4 x float> %951, <4 x float> %949)
  %953 = getelementptr [4 x i8], ptr %861, i64 %917
  %954 = load <4 x float>, ptr %953, align 4, !tbaa !12, !alias.scope !204
  %955 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %903, <4 x float> %954, <4 x float> %952)
  %956 = getelementptr [4 x i8], ptr %862, i64 %917
  %957 = load <4 x float>, ptr %956, align 4, !tbaa !12, !alias.scope !205
  %958 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %906, <4 x float> %957, <4 x float> %955)
  %959 = getelementptr [4 x i8], ptr %863, i64 %917
  %960 = load <4 x float>, ptr %959, align 4, !tbaa !12, !alias.scope !206
  %961 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %909, <4 x float> %960, <4 x float> %958)
  %962 = getelementptr [4 x i8], ptr %864, i64 %917
  %963 = load <4 x float>, ptr %962, align 4, !tbaa !12, !alias.scope !207
  %964 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %912, <4 x float> %963, <4 x float> %961)
  %965 = getelementptr [4 x i8], ptr %865, i64 %917
  %966 = load <4 x float>, ptr %965, align 4, !tbaa !12, !alias.scope !208
  %967 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %915, <4 x float> %966, <4 x float> %964)
  store <4 x float> %967, ptr %918, align 4, !tbaa !12, !alias.scope !174, !noalias !176
  %968 = add nuw i64 %917, 4
  %969 = icmp eq i64 %968, %799
  br i1 %969, label %970, label %916, !llvm.loop !209

970:                                              ; preds = %916
  br i1 %800, label %1043, label %971

971:                                              ; preds = %801, %970
  %972 = phi i64 [ %799, %970 ], [ 0, %801 ]
  br label %973

973:                                              ; preds = %971, %973
  %974 = phi i64 [ %1041, %973 ], [ %972, %971 ]
  %975 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %974
  %976 = load float, ptr %975, align 4, !tbaa !12
  %977 = load float, ptr %804, align 4, !tbaa !12
  %978 = getelementptr [4 x i8], ptr %850, i64 %974
  %979 = load float, ptr %978, align 4, !tbaa !12
  %980 = tail call float @llvm.fmuladd.f32(float %977, float %979, float %976)
  %981 = load float, ptr %807, align 4, !tbaa !12
  %982 = getelementptr [4 x i8], ptr %851, i64 %974
  %983 = load float, ptr %982, align 4, !tbaa !12
  %984 = tail call float @llvm.fmuladd.f32(float %981, float %983, float %980)
  %985 = load float, ptr %810, align 4, !tbaa !12
  %986 = getelementptr [4 x i8], ptr %852, i64 %974
  %987 = load float, ptr %986, align 4, !tbaa !12
  %988 = tail call float @llvm.fmuladd.f32(float %985, float %987, float %984)
  %989 = load float, ptr %813, align 4, !tbaa !12
  %990 = getelementptr [4 x i8], ptr %853, i64 %974
  %991 = load float, ptr %990, align 4, !tbaa !12
  %992 = tail call float @llvm.fmuladd.f32(float %989, float %991, float %988)
  %993 = load float, ptr %816, align 4, !tbaa !12
  %994 = getelementptr [4 x i8], ptr %854, i64 %974
  %995 = load float, ptr %994, align 4, !tbaa !12
  %996 = tail call float @llvm.fmuladd.f32(float %993, float %995, float %992)
  %997 = load float, ptr %819, align 4, !tbaa !12
  %998 = getelementptr [4 x i8], ptr %855, i64 %974
  %999 = load float, ptr %998, align 4, !tbaa !12
  %1000 = tail call float @llvm.fmuladd.f32(float %997, float %999, float %996)
  %1001 = load float, ptr %822, align 4, !tbaa !12
  %1002 = getelementptr [4 x i8], ptr %856, i64 %974
  %1003 = load float, ptr %1002, align 4, !tbaa !12
  %1004 = tail call float @llvm.fmuladd.f32(float %1001, float %1003, float %1000)
  %1005 = load float, ptr %825, align 4, !tbaa !12
  %1006 = getelementptr [4 x i8], ptr %857, i64 %974
  %1007 = load float, ptr %1006, align 4, !tbaa !12
  %1008 = tail call float @llvm.fmuladd.f32(float %1005, float %1007, float %1004)
  %1009 = load float, ptr %828, align 4, !tbaa !12
  %1010 = getelementptr [4 x i8], ptr %858, i64 %974
  %1011 = load float, ptr %1010, align 4, !tbaa !12
  %1012 = tail call float @llvm.fmuladd.f32(float %1009, float %1011, float %1008)
  %1013 = load float, ptr %831, align 4, !tbaa !12
  %1014 = getelementptr [4 x i8], ptr %859, i64 %974
  %1015 = load float, ptr %1014, align 4, !tbaa !12
  %1016 = tail call float @llvm.fmuladd.f32(float %1013, float %1015, float %1012)
  %1017 = load float, ptr %834, align 4, !tbaa !12
  %1018 = getelementptr [4 x i8], ptr %860, i64 %974
  %1019 = load float, ptr %1018, align 4, !tbaa !12
  %1020 = tail call float @llvm.fmuladd.f32(float %1017, float %1019, float %1016)
  %1021 = load float, ptr %837, align 4, !tbaa !12
  %1022 = getelementptr [4 x i8], ptr %861, i64 %974
  %1023 = load float, ptr %1022, align 4, !tbaa !12
  %1024 = tail call float @llvm.fmuladd.f32(float %1021, float %1023, float %1020)
  %1025 = load float, ptr %840, align 4, !tbaa !12
  %1026 = getelementptr [4 x i8], ptr %862, i64 %974
  %1027 = load float, ptr %1026, align 4, !tbaa !12
  %1028 = tail call float @llvm.fmuladd.f32(float %1025, float %1027, float %1024)
  %1029 = load float, ptr %843, align 4, !tbaa !12
  %1030 = getelementptr [4 x i8], ptr %863, i64 %974
  %1031 = load float, ptr %1030, align 4, !tbaa !12
  %1032 = tail call float @llvm.fmuladd.f32(float %1029, float %1031, float %1028)
  %1033 = load float, ptr %846, align 4, !tbaa !12
  %1034 = getelementptr [4 x i8], ptr %864, i64 %974
  %1035 = load float, ptr %1034, align 4, !tbaa !12
  %1036 = tail call float @llvm.fmuladd.f32(float %1033, float %1035, float %1032)
  %1037 = load float, ptr %848, align 4, !tbaa !12
  %1038 = getelementptr [4 x i8], ptr %865, i64 %974
  %1039 = load float, ptr %1038, align 4, !tbaa !12
  %1040 = tail call float @llvm.fmuladd.f32(float %1037, float %1039, float %1036)
  store float %1040, ptr %975, align 4, !tbaa !12
  %1041 = add nuw nsw i64 %974, 1
  %1042 = icmp eq i64 %1041, %595
  br i1 %1042, label %1043, label %973, !llvm.loop !210

1043:                                             ; preds = %973, %970
  %1044 = add nuw nsw i64 %802, 16
  %1045 = icmp samesign ult i64 %1044, %594
  br i1 %1045, label %801, label %1046, !llvm.loop !211

1046:                                             ; preds = %1043, %350, %586
  ret void
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef float @epslon(float noundef %0) local_unnamed_addr #2 {
  %2 = tail call float @llvm.fabs.f32(float %0)
  %3 = fmul float %2, f0x34000000
  ret float %3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local void @print_time(i32 noundef %0) local_unnamed_addr #2 {
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: read) uwtable
define dso_local i32 @idamax(i32 noundef %0, ptr nofree noundef readonly captures(none) %1, i32 noundef %2) local_unnamed_addr #7 {
  %4 = icmp slt i32 %0, 1
  br i1 %4, label %102, label %5

5:                                                ; preds = %3
  %6 = icmp eq i32 %0, 1
  br i1 %6, label %102, label %7

7:                                                ; preds = %5
  %8 = icmp eq i32 %2, 1
  br i1 %8, label %44, label %9

9:                                                ; preds = %7
  %10 = add i32 %2, 1
  %11 = load float, ptr %1, align 4, !tbaa !12
  %12 = tail call float @llvm.fabs.f32(float %11)
  %13 = sext i32 %10 to i64
  %14 = sext i32 %2 to i64
  %15 = add nsw i32 %0, -1
  %16 = and i32 %15, 1
  %17 = icmp eq i32 %0, 2
  br i1 %17, label %91, label %18

18:                                               ; preds = %9
  %19 = and i32 %15, -2
  br label %20

20:                                               ; preds = %20, %18
  %21 = phi i64 [ %13, %18 ], [ %40, %20 ]
  %22 = phi i32 [ undef, %18 ], [ %39, %20 ]
  %23 = phi i32 [ 1, %18 ], [ %41, %20 ]
  %24 = phi float [ %12, %18 ], [ %38, %20 ]
  %25 = phi i32 [ 0, %18 ], [ %42, %20 ]
  %26 = getelementptr inbounds [4 x i8], ptr %1, i64 %21
  %27 = load float, ptr %26, align 4, !tbaa !12
  %28 = tail call float @llvm.fabs.f32(float %27)
  %29 = fcmp ogt float %28, %24
  %30 = select i1 %29, float %28, float %24
  %31 = select i1 %29, i32 %23, i32 %22
  %32 = add nsw i64 %21, %14
  %33 = add nuw nsw i32 %23, 1
  %34 = getelementptr inbounds [4 x i8], ptr %1, i64 %32
  %35 = load float, ptr %34, align 4, !tbaa !12
  %36 = tail call float @llvm.fabs.f32(float %35)
  %37 = fcmp ogt float %36, %30
  %38 = select i1 %37, float %36, float %30
  %39 = select i1 %37, i32 %33, i32 %31
  %40 = add nsw i64 %32, %14
  %41 = add nuw nsw i32 %23, 2
  %42 = add i32 %25, 2
  %43 = icmp eq i32 %42, %19
  br i1 %43, label %89, label %20, !llvm.loop !212

44:                                               ; preds = %7
  %45 = load float, ptr %1, align 4, !tbaa !12
  %46 = tail call float @llvm.fabs.f32(float %45)
  %47 = zext nneg i32 %0 to i64
  %48 = add nsw i64 %47, -1
  %49 = and i64 %48, 1
  %50 = icmp eq i32 %0, 2
  br i1 %50, label %78, label %51

51:                                               ; preds = %44
  %52 = and i64 %48, -2
  br label %53

53:                                               ; preds = %53, %51
  %54 = phi i64 [ 1, %51 ], [ %73, %53 ]
  %55 = phi i32 [ 0, %51 ], [ %72, %53 ]
  %56 = phi float [ %46, %51 ], [ %70, %53 ]
  %57 = phi i64 [ 0, %51 ], [ %74, %53 ]
  %58 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %54
  %59 = load float, ptr %58, align 4, !tbaa !12
  %60 = tail call float @llvm.fabs.f32(float %59)
  %61 = fcmp ogt float %60, %56
  %62 = select i1 %61, float %60, float %56
  %63 = trunc nuw nsw i64 %54 to i32
  %64 = select i1 %61, i32 %63, i32 %55
  %65 = add nuw nsw i64 %54, 1
  %66 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %65
  %67 = load float, ptr %66, align 4, !tbaa !12
  %68 = tail call float @llvm.fabs.f32(float %67)
  %69 = fcmp ogt float %68, %62
  %70 = select i1 %69, float %68, float %62
  %71 = trunc nuw nsw i64 %65 to i32
  %72 = select i1 %69, i32 %71, i32 %64
  %73 = add nuw nsw i64 %54, 2
  %74 = add nuw i64 %57, 2
  %75 = icmp eq i64 %74, %52
  br i1 %75, label %76, label %53, !llvm.loop !56

76:                                               ; preds = %53
  %77 = icmp eq i64 %49, 0
  br i1 %77, label %102, label %78

78:                                               ; preds = %76, %44
  %79 = phi i64 [ 1, %44 ], [ %73, %76 ]
  %80 = phi i32 [ 0, %44 ], [ %72, %76 ]
  %81 = phi float [ %46, %44 ], [ %70, %76 ]
  %82 = trunc i64 %48 to i1
  tail call void @llvm.assume(i1 %82)
  %83 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %79
  %84 = load float, ptr %83, align 4, !tbaa !12
  %85 = tail call float @llvm.fabs.f32(float %84)
  %86 = fcmp ogt float %85, %81
  %87 = trunc nuw nsw i64 %79 to i32
  %88 = select i1 %86, i32 %87, i32 %80
  br label %102

89:                                               ; preds = %20
  %90 = icmp eq i32 %16, 0
  br i1 %90, label %102, label %91

91:                                               ; preds = %89, %9
  %92 = phi i64 [ %13, %9 ], [ %40, %89 ]
  %93 = phi i32 [ undef, %9 ], [ %39, %89 ]
  %94 = phi i32 [ 1, %9 ], [ %41, %89 ]
  %95 = phi float [ %12, %9 ], [ %38, %89 ]
  %96 = trunc i32 %15 to i1
  tail call void @llvm.assume(i1 %96)
  %97 = getelementptr inbounds [4 x i8], ptr %1, i64 %92
  %98 = load float, ptr %97, align 4, !tbaa !12
  %99 = tail call float @llvm.fabs.f32(float %98)
  %100 = fcmp ogt float %99, %95
  %101 = select i1 %100, i32 %94, i32 %93
  br label %102

102:                                              ; preds = %91, %89, %78, %76, %5, %3
  %103 = phi i32 [ 0, %5 ], [ -1, %3 ], [ %88, %78 ], [ %72, %76 ], [ %39, %89 ], [ %101, %91 ]
  ret i32 %103
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @dscal(i32 noundef %0, float noundef %1, ptr nofree noundef captures(none) %2, i32 noundef %3) local_unnamed_addr #6 {
  %5 = icmp slt i32 %0, 1
  br i1 %5, label %49, label %6

6:                                                ; preds = %4
  %7 = icmp eq i32 %3, 1
  br i1 %7, label %8, label %29

8:                                                ; preds = %6
  %9 = zext nneg i32 %0 to i64
  %10 = icmp ult i32 %0, 8
  br i1 %10, label %27, label %11

11:                                               ; preds = %8
  %12 = and i64 %9, 2147483640
  %13 = insertelement <4 x float> poison, float %1, i64 0
  %14 = shufflevector <4 x float> %13, <4 x float> poison, <4 x i32> zeroinitializer
  br label %15

15:                                               ; preds = %15, %11
  %16 = phi i64 [ 0, %11 ], [ %23, %15 ]
  %17 = getelementptr inbounds nuw [4 x i8], ptr %2, i64 %16
  %18 = getelementptr inbounds nuw i8, ptr %17, i64 16
  %19 = load <4 x float>, ptr %17, align 4, !tbaa !12
  %20 = load <4 x float>, ptr %18, align 4, !tbaa !12
  %21 = fmul <4 x float> %14, %19
  %22 = fmul <4 x float> %14, %20
  store <4 x float> %21, ptr %17, align 4, !tbaa !12
  store <4 x float> %22, ptr %18, align 4, !tbaa !12
  %23 = add nuw i64 %16, 8
  %24 = icmp eq i64 %23, %12
  br i1 %24, label %25, label %15, !llvm.loop !213

25:                                               ; preds = %15
  %26 = icmp eq i64 %12, %9
  br i1 %26, label %49, label %27

27:                                               ; preds = %8, %25
  %28 = phi i64 [ 0, %8 ], [ %12, %25 ]
  br label %42

29:                                               ; preds = %6
  %30 = mul nsw i32 %3, %0
  %31 = icmp sgt i32 %30, 0
  br i1 %31, label %32, label %49

32:                                               ; preds = %29
  %33 = sext i32 %3 to i64
  %34 = zext nneg i32 %30 to i64
  br label %35

35:                                               ; preds = %32, %35
  %36 = phi i64 [ 0, %32 ], [ %40, %35 ]
  %37 = getelementptr inbounds [4 x i8], ptr %2, i64 %36
  %38 = load float, ptr %37, align 4, !tbaa !12
  %39 = fmul float %1, %38
  store float %39, ptr %37, align 4, !tbaa !12
  %40 = add nsw i64 %36, %33
  %41 = icmp slt i64 %40, %34
  br i1 %41, label %35, label %49, !llvm.loop !214

42:                                               ; preds = %27, %42
  %43 = phi i64 [ %47, %42 ], [ %28, %27 ]
  %44 = getelementptr inbounds nuw [4 x i8], ptr %2, i64 %43
  %45 = load float, ptr %44, align 4, !tbaa !12
  %46 = fmul float %1, %45
  store float %46, ptr %44, align 4, !tbaa !12
  %47 = add nuw nsw i64 %43, 1
  %48 = icmp eq i64 %47, %9
  br i1 %48, label %49, label %42, !llvm.loop !215

49:                                               ; preds = %35, %42, %25, %29, %4
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @daxpy(i32 noundef %0, float noundef %1, ptr nofree noundef readonly captures(none) %2, i32 noundef %3, ptr nofree noundef captures(none) %4, i32 noundef %5) local_unnamed_addr #6 {
  %7 = icmp slt i32 %0, 1
  %8 = fcmp oeq float %1, 0.000000e+00
  %9 = or i1 %7, %8
  br i1 %9, label %176, label %10

10:                                               ; preds = %6
  %11 = icmp ne i32 %3, 1
  %12 = icmp ne i32 %5, 1
  %13 = or i1 %11, %12
  br i1 %13, label %59, label %14

14:                                               ; preds = %10
  %15 = zext nneg i32 %0 to i64
  %16 = icmp ult i32 %0, 8
  br i1 %16, label %44, label %17

17:                                               ; preds = %14
  %18 = shl nuw nsw i64 %15, 2
  %19 = getelementptr i8, ptr %4, i64 %18
  %20 = getelementptr i8, ptr %2, i64 %18
  %21 = icmp ult ptr %4, %20
  %22 = icmp ult ptr %2, %19
  %23 = and i1 %21, %22
  br i1 %23, label %44, label %24

24:                                               ; preds = %17
  %25 = and i64 %15, 2147483640
  %26 = insertelement <4 x float> poison, float %1, i64 0
  %27 = shufflevector <4 x float> %26, <4 x float> poison, <4 x i32> zeroinitializer
  br label %28

28:                                               ; preds = %28, %24
  %29 = phi i64 [ 0, %24 ], [ %40, %28 ]
  %30 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %29
  %31 = getelementptr inbounds nuw i8, ptr %30, i64 16
  %32 = load <4 x float>, ptr %30, align 4, !tbaa !12, !alias.scope !216, !noalias !219
  %33 = load <4 x float>, ptr %31, align 4, !tbaa !12, !alias.scope !216, !noalias !219
  %34 = getelementptr inbounds nuw [4 x i8], ptr %2, i64 %29
  %35 = getelementptr inbounds nuw i8, ptr %34, i64 16
  %36 = load <4 x float>, ptr %34, align 4, !tbaa !12, !alias.scope !219
  %37 = load <4 x float>, ptr %35, align 4, !tbaa !12, !alias.scope !219
  %38 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %27, <4 x float> %36, <4 x float> %32)
  %39 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %27, <4 x float> %37, <4 x float> %33)
  store <4 x float> %38, ptr %30, align 4, !tbaa !12, !alias.scope !216, !noalias !219
  store <4 x float> %39, ptr %31, align 4, !tbaa !12, !alias.scope !216, !noalias !219
  %40 = add nuw i64 %29, 8
  %41 = icmp eq i64 %40, %25
  br i1 %41, label %42, label %28, !llvm.loop !221

42:                                               ; preds = %28
  %43 = icmp eq i64 %25, %15
  br i1 %43, label %176, label %44

44:                                               ; preds = %17, %14, %42
  %45 = phi i64 [ 0, %17 ], [ 0, %14 ], [ %25, %42 ]
  %46 = and i64 %15, 1
  %47 = icmp eq i64 %46, 0
  br i1 %47, label %55, label %48

48:                                               ; preds = %44
  %49 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %45
  %50 = load float, ptr %49, align 4, !tbaa !12
  %51 = getelementptr inbounds nuw [4 x i8], ptr %2, i64 %45
  %52 = load float, ptr %51, align 4, !tbaa !12
  %53 = tail call float @llvm.fmuladd.f32(float %1, float %52, float %50)
  store float %53, ptr %49, align 4, !tbaa !12
  %54 = or disjoint i64 %45, 1
  br label %55

55:                                               ; preds = %48, %44
  %56 = phi i64 [ %45, %44 ], [ %54, %48 ]
  %57 = add nsw i64 %15, -1
  %58 = icmp eq i64 %45, %57
  br i1 %58, label %176, label %161

59:                                               ; preds = %10
  %60 = icmp slt i32 %5, 0
  %61 = sub nsw i32 1, %0
  %62 = mul nsw i32 %5, %61
  %63 = select i1 %60, i32 %62, i32 0
  %64 = icmp slt i32 %3, 0
  %65 = mul nsw i32 %3, %61
  %66 = select i1 %64, i32 %65, i32 0
  %67 = sext i32 %66 to i64
  %68 = sext i32 %3 to i64
  %69 = sext i32 %63 to i64
  %70 = sext i32 %5 to i64
  %71 = zext nneg i32 %0 to i64
  %72 = icmp ult i32 %0, 16
  br i1 %72, label %119, label %73

73:                                               ; preds = %59
  %74 = icmp ne i32 %5, 1
  %75 = icmp ne i32 %3, 1
  %76 = or i1 %74, %75
  br i1 %76, label %119, label %77

77:                                               ; preds = %73
  %78 = shl nsw i64 %69, 2
  %79 = getelementptr i8, ptr %4, i64 %78
  %80 = add nsw i32 %0, -1
  %81 = zext i32 %80 to i64
  %82 = shl nuw nsw i64 %81, 2
  %83 = getelementptr i8, ptr %4, i64 %78
  %84 = getelementptr i8, ptr %83, i64 %82
  %85 = getelementptr i8, ptr %84, i64 4
  %86 = shl nsw i64 %67, 2
  %87 = getelementptr i8, ptr %2, i64 %86
  %88 = getelementptr i8, ptr %2, i64 %86
  %89 = getelementptr i8, ptr %88, i64 %82
  %90 = getelementptr i8, ptr %89, i64 4
  %91 = icmp ult ptr %79, %90
  %92 = icmp ult ptr %87, %85
  %93 = and i1 %91, %92
  br i1 %93, label %119, label %94

94:                                               ; preds = %77
  %95 = and i64 %71, 2147483640
  %96 = add nsw i64 %95, %69
  %97 = add nsw i64 %95, %67
  %98 = trunc nuw nsw i64 %95 to i32
  %99 = insertelement <4 x float> poison, float %1, i64 0
  %100 = shufflevector <4 x float> %99, <4 x float> poison, <4 x i32> zeroinitializer
  %101 = getelementptr [4 x i8], ptr %4, i64 %69
  %102 = getelementptr [4 x i8], ptr %2, i64 %67
  br label %103

103:                                              ; preds = %103, %94
  %104 = phi i64 [ 0, %94 ], [ %115, %103 ]
  %105 = getelementptr [4 x i8], ptr %101, i64 %104
  %106 = getelementptr inbounds nuw i8, ptr %105, i64 16
  %107 = load <4 x float>, ptr %105, align 4, !tbaa !12, !alias.scope !222, !noalias !225
  %108 = load <4 x float>, ptr %106, align 4, !tbaa !12, !alias.scope !222, !noalias !225
  %109 = getelementptr [4 x i8], ptr %102, i64 %104
  %110 = getelementptr inbounds nuw i8, ptr %109, i64 16
  %111 = load <4 x float>, ptr %109, align 4, !tbaa !12, !alias.scope !225
  %112 = load <4 x float>, ptr %110, align 4, !tbaa !12, !alias.scope !225
  %113 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %100, <4 x float> %111, <4 x float> %107)
  %114 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %100, <4 x float> %112, <4 x float> %108)
  store <4 x float> %113, ptr %105, align 4, !tbaa !12, !alias.scope !222, !noalias !225
  store <4 x float> %114, ptr %106, align 4, !tbaa !12, !alias.scope !222, !noalias !225
  %115 = add nuw i64 %104, 8
  %116 = icmp eq i64 %115, %95
  br i1 %116, label %117, label %103, !llvm.loop !227

117:                                              ; preds = %103
  %118 = icmp eq i64 %95, %71
  br i1 %118, label %176, label %119

119:                                              ; preds = %77, %73, %59, %117
  %120 = phi i64 [ %69, %77 ], [ %69, %73 ], [ %69, %59 ], [ %96, %117 ]
  %121 = phi i64 [ %67, %77 ], [ %67, %73 ], [ %67, %59 ], [ %97, %117 ]
  %122 = phi i32 [ 0, %77 ], [ 0, %73 ], [ 0, %59 ], [ %98, %117 ]
  %123 = sub i32 %0, %122
  %124 = add i32 %122, 1
  %125 = and i32 %123, 1
  %126 = icmp eq i32 %125, 0
  br i1 %126, label %136, label %127

127:                                              ; preds = %119
  %128 = getelementptr inbounds [4 x i8], ptr %4, i64 %120
  %129 = load float, ptr %128, align 4, !tbaa !12
  %130 = getelementptr inbounds [4 x i8], ptr %2, i64 %121
  %131 = load float, ptr %130, align 4, !tbaa !12
  %132 = tail call float @llvm.fmuladd.f32(float %1, float %131, float %129)
  store float %132, ptr %128, align 4, !tbaa !12
  %133 = add nsw i64 %121, %68
  %134 = add nsw i64 %120, %70
  %135 = add nuw nsw i32 %122, 1
  br label %136

136:                                              ; preds = %127, %119
  %137 = phi i64 [ %120, %119 ], [ %134, %127 ]
  %138 = phi i64 [ %121, %119 ], [ %133, %127 ]
  %139 = phi i32 [ %122, %119 ], [ %135, %127 ]
  %140 = icmp eq i32 %0, %124
  br i1 %140, label %176, label %141

141:                                              ; preds = %136, %141
  %142 = phi i64 [ %158, %141 ], [ %137, %136 ]
  %143 = phi i64 [ %157, %141 ], [ %138, %136 ]
  %144 = phi i32 [ %159, %141 ], [ %139, %136 ]
  %145 = getelementptr inbounds [4 x i8], ptr %4, i64 %142
  %146 = load float, ptr %145, align 4, !tbaa !12
  %147 = getelementptr inbounds [4 x i8], ptr %2, i64 %143
  %148 = load float, ptr %147, align 4, !tbaa !12
  %149 = tail call float @llvm.fmuladd.f32(float %1, float %148, float %146)
  store float %149, ptr %145, align 4, !tbaa !12
  %150 = add nsw i64 %143, %68
  %151 = add nsw i64 %142, %70
  %152 = getelementptr inbounds [4 x i8], ptr %4, i64 %151
  %153 = load float, ptr %152, align 4, !tbaa !12
  %154 = getelementptr inbounds [4 x i8], ptr %2, i64 %150
  %155 = load float, ptr %154, align 4, !tbaa !12
  %156 = tail call float @llvm.fmuladd.f32(float %1, float %155, float %153)
  store float %156, ptr %152, align 4, !tbaa !12
  %157 = add nsw i64 %150, %68
  %158 = add nsw i64 %151, %70
  %159 = add nuw nsw i32 %144, 2
  %160 = icmp eq i32 %159, %0
  br i1 %160, label %176, label %141, !llvm.loop !228

161:                                              ; preds = %55, %161
  %162 = phi i64 [ %174, %161 ], [ %56, %55 ]
  %163 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %162
  %164 = load float, ptr %163, align 4, !tbaa !12
  %165 = getelementptr inbounds nuw [4 x i8], ptr %2, i64 %162
  %166 = load float, ptr %165, align 4, !tbaa !12
  %167 = tail call float @llvm.fmuladd.f32(float %1, float %166, float %164)
  store float %167, ptr %163, align 4, !tbaa !12
  %168 = add nuw nsw i64 %162, 1
  %169 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %168
  %170 = load float, ptr %169, align 4, !tbaa !12
  %171 = getelementptr inbounds nuw [4 x i8], ptr %2, i64 %168
  %172 = load float, ptr %171, align 4, !tbaa !12
  %173 = tail call float @llvm.fmuladd.f32(float %1, float %172, float %170)
  store float %173, ptr %169, align 4, !tbaa !12
  %174 = add nuw nsw i64 %162, 2
  %175 = icmp eq i64 %174, %15
  br i1 %175, label %176, label %161, !llvm.loop !229

176:                                              ; preds = %55, %161, %136, %141, %42, %117, %6
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: read) uwtable
define dso_local float @ddot(i32 noundef %0, ptr nofree noundef readonly captures(none) %1, i32 noundef %2, ptr nofree noundef readonly captures(none) %3, i32 noundef %4) local_unnamed_addr #7 {
  %6 = icmp slt i32 %0, 1
  br i1 %6, label %114, label %7

7:                                                ; preds = %5
  %8 = icmp ne i32 %2, 1
  %9 = icmp ne i32 %4, 1
  %10 = or i1 %8, %9
  br i1 %10, label %17, label %11

11:                                               ; preds = %7
  %12 = zext nneg i32 %0 to i64
  %13 = and i64 %12, 3
  %14 = icmp ult i32 %0, 4
  br i1 %14, label %98, label %15

15:                                               ; preds = %11
  %16 = and i64 %12, 2147483644
  br label %54

17:                                               ; preds = %7
  %18 = icmp slt i32 %4, 0
  %19 = sub nsw i32 1, %0
  %20 = mul nsw i32 %4, %19
  %21 = select i1 %18, i32 %20, i32 0
  %22 = icmp slt i32 %2, 0
  %23 = mul nsw i32 %2, %19
  %24 = select i1 %22, i32 %23, i32 0
  %25 = sext i32 %21 to i64
  %26 = sext i32 %4 to i64
  %27 = sext i32 %24 to i64
  %28 = sext i32 %2 to i64
  %29 = and i32 %0, 1
  %30 = icmp eq i32 %0, 1
  br i1 %30, label %86, label %31

31:                                               ; preds = %17
  %32 = and i32 %0, 2147483646
  br label %33

33:                                               ; preds = %33, %31
  %34 = phi i64 [ %27, %31 ], [ %50, %33 ]
  %35 = phi i64 [ %25, %31 ], [ %51, %33 ]
  %36 = phi float [ 0.000000e+00, %31 ], [ %49, %33 ]
  %37 = phi i32 [ 0, %31 ], [ %52, %33 ]
  %38 = getelementptr inbounds [4 x i8], ptr %1, i64 %34
  %39 = load float, ptr %38, align 4, !tbaa !12
  %40 = getelementptr inbounds [4 x i8], ptr %3, i64 %35
  %41 = load float, ptr %40, align 4, !tbaa !12
  %42 = tail call float @llvm.fmuladd.f32(float %39, float %41, float %36)
  %43 = add nsw i64 %34, %28
  %44 = add nsw i64 %35, %26
  %45 = getelementptr inbounds [4 x i8], ptr %1, i64 %43
  %46 = load float, ptr %45, align 4, !tbaa !12
  %47 = getelementptr inbounds [4 x i8], ptr %3, i64 %44
  %48 = load float, ptr %47, align 4, !tbaa !12
  %49 = tail call float @llvm.fmuladd.f32(float %46, float %48, float %42)
  %50 = add nsw i64 %43, %28
  %51 = add nsw i64 %44, %26
  %52 = add i32 %37, 2
  %53 = icmp eq i32 %52, %32
  br i1 %53, label %84, label %33, !llvm.loop !230

54:                                               ; preds = %54, %15
  %55 = phi i64 [ 0, %15 ], [ %81, %54 ]
  %56 = phi float [ 0.000000e+00, %15 ], [ %80, %54 ]
  %57 = phi i64 [ 0, %15 ], [ %82, %54 ]
  %58 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %55
  %59 = load float, ptr %58, align 4, !tbaa !12
  %60 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %55
  %61 = load float, ptr %60, align 4, !tbaa !12
  %62 = tail call float @llvm.fmuladd.f32(float %59, float %61, float %56)
  %63 = or disjoint i64 %55, 1
  %64 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %63
  %65 = load float, ptr %64, align 4, !tbaa !12
  %66 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %63
  %67 = load float, ptr %66, align 4, !tbaa !12
  %68 = tail call float @llvm.fmuladd.f32(float %65, float %67, float %62)
  %69 = or disjoint i64 %55, 2
  %70 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %69
  %71 = load float, ptr %70, align 4, !tbaa !12
  %72 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %69
  %73 = load float, ptr %72, align 4, !tbaa !12
  %74 = tail call float @llvm.fmuladd.f32(float %71, float %73, float %68)
  %75 = or disjoint i64 %55, 3
  %76 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %75
  %77 = load float, ptr %76, align 4, !tbaa !12
  %78 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %75
  %79 = load float, ptr %78, align 4, !tbaa !12
  %80 = tail call float @llvm.fmuladd.f32(float %77, float %79, float %74)
  %81 = add nuw nsw i64 %55, 4
  %82 = add i64 %57, 4
  %83 = icmp eq i64 %82, %16
  br i1 %83, label %96, label %54, !llvm.loop !82

84:                                               ; preds = %33
  %85 = icmp eq i32 %29, 0
  br i1 %85, label %114, label %86

86:                                               ; preds = %84, %17
  %87 = phi i64 [ %27, %17 ], [ %50, %84 ]
  %88 = phi i64 [ %25, %17 ], [ %51, %84 ]
  %89 = phi float [ 0.000000e+00, %17 ], [ %49, %84 ]
  %90 = trunc i32 %0 to i1
  tail call void @llvm.assume(i1 %90)
  %91 = getelementptr inbounds [4 x i8], ptr %1, i64 %87
  %92 = load float, ptr %91, align 4, !tbaa !12
  %93 = getelementptr inbounds [4 x i8], ptr %3, i64 %88
  %94 = load float, ptr %93, align 4, !tbaa !12
  %95 = tail call float @llvm.fmuladd.f32(float %92, float %94, float %89)
  br label %114

96:                                               ; preds = %54
  %97 = icmp eq i64 %13, 0
  br i1 %97, label %114, label %98

98:                                               ; preds = %96, %11
  %99 = phi i64 [ 0, %11 ], [ %81, %96 ]
  %100 = phi float [ 0.000000e+00, %11 ], [ %80, %96 ]
  %101 = icmp ne i64 %13, 0
  tail call void @llvm.assume(i1 %101)
  br label %102

102:                                              ; preds = %102, %98
  %103 = phi i64 [ %99, %98 ], [ %111, %102 ]
  %104 = phi float [ %100, %98 ], [ %110, %102 ]
  %105 = phi i64 [ 0, %98 ], [ %112, %102 ]
  %106 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %103
  %107 = load float, ptr %106, align 4, !tbaa !12
  %108 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %103
  %109 = load float, ptr %108, align 4, !tbaa !12
  %110 = tail call float @llvm.fmuladd.f32(float %107, float %109, float %104)
  %111 = add nuw nsw i64 %103, 1
  %112 = add i64 %105, 1
  %113 = icmp eq i64 %112, %13
  br i1 %113, label %114, label %102, !llvm.loop !231

114:                                              ; preds = %96, %102, %86, %84, %5
  %115 = phi float [ %95, %86 ], [ 0.000000e+00, %5 ], [ %49, %84 ], [ %80, %96 ], [ %110, %102 ]
  ret float %115
}

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare float @llvm.fmuladd.f32(float, float, float) #8

; Function Attrs: nofree nounwind
declare noundef i64 @fwrite(ptr noundef readonly captures(none), i64 noundef, i64 noundef, ptr noundef captures(none)) local_unnamed_addr #9

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare float @llvm.fabs.f32(float) #10

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #11

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare <4 x float> @llvm.fmuladd.v4f32(<4 x float>, <4 x float>, <4 x float>) #10

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare <2 x float> @llvm.fabs.v2f32(<2 x float>) #10

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write)
declare void @llvm.assume(i1 noundef) #12

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.umax.i64(i64, i64) #10

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { cold nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #5 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #7 = { nofree norecurse nosync nounwind memory(argmem: read) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #8 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #9 = { nofree nounwind }
attributes #10 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #11 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #12 = { nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write) }
attributes #13 = { nounwind }
attributes #14 = { cold }
attributes #15 = { cold nounwind }

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
!10 = !{!"p1 _ZTS8_IO_FILE", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!13, !13, i64 0}
!13 = !{!"float", !7, i64 0}
!14 = distinct !{!14, !15}
!15 = !{!"llvm.loop.mustprogress"}
!16 = distinct !{!16, !15}
!17 = distinct !{!17, !15}
!18 = !{!6, !6, i64 0}
!19 = distinct !{!19, !15, !20, !21}
!20 = !{!"llvm.loop.isvectorized", i32 1}
!21 = !{!"llvm.loop.unroll.runtime.disable"}
!22 = distinct !{!22, !15, !21, !20}
!23 = distinct !{!23, !15}
!24 = distinct !{!24, !15, !20, !21}
!25 = distinct !{!25, !15, !21, !20}
!26 = distinct !{!26, !15}
!27 = distinct !{!27, !15}
!28 = distinct !{!28, !15}
!29 = distinct !{!29, !15}
!30 = distinct !{!30, !15}
!31 = distinct !{!31, !15}
!32 = distinct !{!32, !15}
!33 = distinct !{!33, !15, !20, !21}
!34 = distinct !{!34, !15, !21, !20}
!35 = distinct !{!35, !15, !20, !21}
!36 = distinct !{!36, !15, !21, !20}
!37 = distinct !{!37, !15}
!38 = distinct !{!38, !15}
!39 = distinct !{!39, !15}
!40 = distinct !{!40, !15}
!41 = distinct !{!41, !15, !20, !21}
!42 = distinct !{!42, !15, !21, !20}
!43 = distinct !{!43, !15, !20, !21}
!44 = distinct !{!44, !15, !21, !20}
!45 = distinct !{!45, !15}
!46 = distinct !{!46, !15}
!47 = !{!48}
!48 = distinct !{!48, !49}
!49 = distinct !{!49, !"LVerDomain"}
!50 = !{!51}
!51 = distinct !{!51, !49}
!52 = distinct !{!52, !15, !20, !21}
!53 = distinct !{!53, !54}
!54 = !{!"llvm.loop.unroll.disable"}
!55 = distinct !{!55, !15, !20}
!56 = distinct !{!56, !15}
!57 = distinct !{!57, !15, !20, !21}
!58 = distinct !{!58, !15, !21, !20}
!59 = !{!60}
!60 = distinct !{!60, !61}
!61 = distinct !{!61, !"LVerDomain"}
!62 = !{!63}
!63 = distinct !{!63, !61}
!64 = distinct !{!64, !15, !20, !21}
!65 = distinct !{!65, !15, !20}
!66 = distinct !{!66, !15}
!67 = distinct !{!67, !15}
!68 = !{!69}
!69 = distinct !{!69, !70}
!70 = distinct !{!70, !"LVerDomain"}
!71 = !{!72}
!72 = distinct !{!72, !70}
!73 = distinct !{!73, !15, !20, !21}
!74 = distinct !{!74, !15, !20}
!75 = !{!76}
!76 = distinct !{!76, !77}
!77 = distinct !{!77, !"LVerDomain"}
!78 = !{!79}
!79 = distinct !{!79, !77}
!80 = distinct !{!80, !15, !20, !21}
!81 = distinct !{!81, !15, !20}
!82 = distinct !{!82, !15}
!83 = distinct !{!83, !54}
!84 = distinct !{!84, !15}
!85 = distinct !{!85, !54}
!86 = distinct !{!86, !15}
!87 = !{!88}
!88 = distinct !{!88, !89}
!89 = distinct !{!89, !"LVerDomain"}
!90 = !{!91}
!91 = distinct !{!91, !89}
!92 = !{!88, !93}
!93 = distinct !{!93, !89}
!94 = !{!93}
!95 = distinct !{!95, !15, !20, !21}
!96 = distinct !{!96, !15, !20}
!97 = !{!98}
!98 = distinct !{!98, !99}
!99 = distinct !{!99, !"LVerDomain"}
!100 = !{!101}
!101 = distinct !{!101, !99}
!102 = !{!103}
!103 = distinct !{!103, !99}
!104 = !{!101, !98, !105, !106}
!105 = distinct !{!105, !99}
!106 = distinct !{!106, !99}
!107 = !{!106}
!108 = !{!105}
!109 = distinct !{!109, !15, !20, !21}
!110 = distinct !{!110, !15, !20}
!111 = !{!112}
!112 = distinct !{!112, !113}
!113 = distinct !{!113, !"LVerDomain"}
!114 = !{!115}
!115 = distinct !{!115, !113}
!116 = !{!117}
!117 = distinct !{!117, !113}
!118 = !{!119}
!119 = distinct !{!119, !113}
!120 = !{!121}
!121 = distinct !{!121, !113}
!122 = !{!119, !117, !115, !112, !123, !124, !125, !126}
!123 = distinct !{!123, !113}
!124 = distinct !{!124, !113}
!125 = distinct !{!125, !113}
!126 = distinct !{!126, !113}
!127 = !{!126}
!128 = !{!125}
!129 = !{!124}
!130 = !{!123}
!131 = distinct !{!131, !15, !20, !21}
!132 = distinct !{!132, !15, !20}
!133 = !{!134}
!134 = distinct !{!134, !135}
!135 = distinct !{!135, !"LVerDomain"}
!136 = !{!137}
!137 = distinct !{!137, !135}
!138 = !{!139}
!139 = distinct !{!139, !135}
!140 = !{!141}
!141 = distinct !{!141, !135}
!142 = !{!143}
!143 = distinct !{!143, !135}
!144 = !{!145}
!145 = distinct !{!145, !135}
!146 = !{!147}
!147 = distinct !{!147, !135}
!148 = !{!149}
!149 = distinct !{!149, !135}
!150 = !{!151}
!151 = distinct !{!151, !135}
!152 = !{!149, !147, !145, !143, !141, !139, !137, !134, !153, !154, !155, !156, !157, !158, !159, !160}
!153 = distinct !{!153, !135}
!154 = distinct !{!154, !135}
!155 = distinct !{!155, !135}
!156 = distinct !{!156, !135}
!157 = distinct !{!157, !135}
!158 = distinct !{!158, !135}
!159 = distinct !{!159, !135}
!160 = distinct !{!160, !135}
!161 = !{!160}
!162 = !{!159}
!163 = !{!158}
!164 = !{!157}
!165 = !{!156}
!166 = !{!155}
!167 = !{!154}
!168 = !{!153}
!169 = distinct !{!169, !15, !20, !21}
!170 = distinct !{!170, !15, !20}
!171 = !{!172}
!172 = distinct !{!172, !173}
!173 = distinct !{!173, !"LVerDomain"}
!174 = !{!175}
!175 = distinct !{!175, !173}
!176 = !{!172, !177, !178, !179, !180, !181, !182, !183, !184, !185, !186, !187, !188, !189, !190, !191, !192}
!177 = distinct !{!177, !173}
!178 = distinct !{!178, !173}
!179 = distinct !{!179, !173}
!180 = distinct !{!180, !173}
!181 = distinct !{!181, !173}
!182 = distinct !{!182, !173}
!183 = distinct !{!183, !173}
!184 = distinct !{!184, !173}
!185 = distinct !{!185, !173}
!186 = distinct !{!186, !173}
!187 = distinct !{!187, !173}
!188 = distinct !{!188, !173}
!189 = distinct !{!189, !173}
!190 = distinct !{!190, !173}
!191 = distinct !{!191, !173}
!192 = distinct !{!192, !173}
!193 = !{!192}
!194 = !{!191}
!195 = !{!190}
!196 = !{!189}
!197 = !{!188}
!198 = !{!187}
!199 = !{!186}
!200 = !{!185}
!201 = !{!184}
!202 = !{!183}
!203 = !{!182}
!204 = !{!181}
!205 = !{!180}
!206 = !{!179}
!207 = !{!178}
!208 = !{!177}
!209 = distinct !{!209, !15, !20, !21}
!210 = distinct !{!210, !15, !20}
!211 = distinct !{!211, !15}
!212 = distinct !{!212, !15}
!213 = distinct !{!213, !15, !20, !21}
!214 = distinct !{!214, !15, !20}
!215 = distinct !{!215, !15, !21, !20}
!216 = !{!217}
!217 = distinct !{!217, !218}
!218 = distinct !{!218, !"LVerDomain"}
!219 = !{!220}
!220 = distinct !{!220, !218}
!221 = distinct !{!221, !15, !20, !21}
!222 = !{!223}
!223 = distinct !{!223, !224}
!224 = distinct !{!224, !"LVerDomain"}
!225 = !{!226}
!226 = distinct !{!226, !224}
!227 = distinct !{!227, !15, !20, !21}
!228 = distinct !{!228, !15, !20}
!229 = distinct !{!229, !15, !20}
!230 = distinct !{!230, !15}
!231 = distinct !{!231, !54}
