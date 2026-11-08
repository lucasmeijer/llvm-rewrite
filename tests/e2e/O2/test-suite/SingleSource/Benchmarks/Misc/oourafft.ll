; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/oourafft.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/oourafft.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/oourafft.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.timeval = type { i64, i64 }

@.str = private unnamed_addr constant [45 x i8] c"FFT sanity check failed! Difference is: %le\0A\00", align 1
@.str.1 = private unnamed_addr constant [7 x i8] c"%e %e\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = alloca %struct.timeval, align 8
  %2 = alloca %struct.timeval, align 8
  %3 = alloca %struct.timeval, align 8
  %4 = alloca %struct.timeval, align 8
  call void @llvm.lifetime.start.p0(ptr nonnull %4) #17
  %5 = call i32 @gettimeofday(ptr noundef nonnull %4, ptr noundef null) #17
  call void @llvm.lifetime.end.p0(ptr nonnull %4) #17
  call void @llvm.lifetime.start.p0(ptr nonnull %3) #17
  %6 = call i32 @gettimeofday(ptr noundef nonnull %3, ptr noundef null) #17
  call void @llvm.lifetime.end.p0(ptr nonnull %3) #17
  %7 = tail call noalias align 16 dereferenceable_or_null(128) ptr @memalign(i64 noundef 16, i64 noundef 128) #18
  %8 = tail call noalias align 16 dereferenceable_or_null(20480) ptr @memalign(i64 noundef 16, i64 noundef 20480) #18
  store <2 x double> <double 1.000000e+00, double 0.000000e+00>, ptr %8, align 16, !tbaa !9
  %9 = getelementptr inbounds nuw i8, ptr %8, i64 2048
  store <2 x double> splat (double f0x3FE6A09E667F3BCD), ptr %9, align 16, !tbaa !9
  br label %10

10:                                               ; preds = %23, %0
  %11 = phi i64 [ 2, %0 ], [ %35, %23 ]
  %12 = trunc nuw nsw i64 %11 to i32
  %13 = uitofp nneg i32 %12 to double
  %14 = fmul nnan double %13, f0x3F6921FB54442D18
  %15 = tail call double @cos(double noundef %14) #17
  %16 = tail call double @sin(double noundef %14) #17
  %17 = getelementptr inbounds nuw [8 x i8], ptr %8, i64 %11
  store double %15, ptr %17, align 16, !tbaa !9
  %18 = getelementptr inbounds nuw i8, ptr %17, i64 8
  store double %16, ptr %18, align 8, !tbaa !9
  %19 = sub nuw nsw i64 512, %11
  %20 = getelementptr inbounds nuw [8 x i8], ptr %8, i64 %19
  store double %16, ptr %20, align 16, !tbaa !9
  %21 = getelementptr i8, ptr %20, i64 8
  store double %15, ptr %21, align 8, !tbaa !9
  %22 = icmp samesign ult i64 %11, 254
  br i1 %22, label %23, label %36

23:                                               ; preds = %10
  %24 = add nuw nsw i64 %11, 2
  %25 = trunc nuw nsw i64 %24 to i32
  %26 = uitofp nneg i32 %25 to double
  %27 = fmul nnan double %26, f0x3F6921FB54442D18
  %28 = tail call double @cos(double noundef %27) #17
  %29 = tail call double @sin(double noundef %27) #17
  %30 = getelementptr inbounds nuw [8 x i8], ptr %8, i64 %24
  store double %28, ptr %30, align 16, !tbaa !9
  %31 = getelementptr inbounds nuw i8, ptr %30, i64 8
  store double %29, ptr %31, align 8, !tbaa !9
  %32 = sub nuw nsw i64 510, %11
  %33 = getelementptr inbounds nuw [8 x i8], ptr %8, i64 %32
  store double %29, ptr %33, align 16, !tbaa !9
  %34 = getelementptr i8, ptr %33, i64 8
  store double %28, ptr %34, align 8, !tbaa !9
  %35 = add nuw nsw i64 %11, 4
  br label %10

36:                                               ; preds = %10
  tail call fastcc void @bitrv2(i32 noundef 512, ptr noundef %7, ptr noundef nonnull %8)
  %37 = tail call noalias align 16 dereferenceable_or_null(16384) ptr @memalign(i64 noundef 16, i64 noundef 16384) #18
  %38 = tail call noalias align 16 dereferenceable_or_null(16384) ptr @memalign(i64 noundef 16, i64 noundef 16384) #18
  %39 = tail call noalias align 16 dereferenceable_or_null(16384) ptr @memalign(i64 noundef 16, i64 noundef 16384) #18
  br label %40

40:                                               ; preds = %40, %36
  %41 = phi i64 [ 0, %36 ], [ %49, %40 ]
  %42 = phi i32 [ 0, %36 ], [ %45, %40 ]
  %43 = mul nuw nsw i32 %42, 7141
  %44 = add nuw nsw i32 %43, 54773
  %45 = urem i32 %44, 259200
  %46 = uitofp nneg i32 %45 to double
  %47 = fmul nnan double %46, f0x3ED02E85C0898B71
  %48 = getelementptr inbounds nuw [8 x i8], ptr %37, i64 %41
  store double %47, ptr %48, align 8, !tbaa !9
  %49 = add nuw nsw i64 %41, 1
  %50 = and i64 %49, 4294967295
  %51 = icmp eq i64 %50, 2048
  br i1 %51, label %52, label %40, !llvm.loop !11

52:                                               ; preds = %40
  tail call fastcc void @bitrv2(i32 noundef 2048, ptr noundef %7, ptr noundef nonnull %37)
  tail call fastcc void @cftfsub(i32 noundef 2048, ptr noundef nonnull %37, ptr noundef nonnull readonly %8)
  tail call void @cdft(i32 noundef 2048, i32 noundef -1, ptr noundef nonnull %37, ptr noundef %7, ptr noundef nonnull %8)
  br label %53

53:                                               ; preds = %53, %52
  %54 = phi i64 [ 0, %52 ], [ %68, %53 ]
  %55 = phi double [ 0.000000e+00, %52 ], [ %67, %53 ]
  %56 = phi i32 [ 0, %52 ], [ %59, %53 ]
  %57 = mul nuw nsw i32 %56, 7141
  %58 = add nuw nsw i32 %57, 54773
  %59 = urem i32 %58, 259200
  %60 = uitofp nneg i32 %59 to double
  %61 = getelementptr inbounds nuw [8 x i8], ptr %37, i64 %54
  %62 = load double, ptr %61, align 8, !tbaa !9
  %63 = fmul double %62, f0xBF50000000000000
  %64 = tail call double @llvm.fmuladd.f64(double %60, double f0x3ED02E85C0898B71, double %63)
  %65 = tail call double @llvm.fabs.f64(double %64)
  %66 = fcmp ogt double %55, %65
  %67 = select i1 %66, double %55, double %65
  %68 = add nuw nsw i64 %54, 1
  %69 = and i64 %68, 4294967295
  %70 = icmp eq i64 %69, 2048
  br i1 %70, label %71, label %53, !llvm.loop !13

71:                                               ; preds = %53
  %72 = fcmp ogt double %67, 1.000000e-10
  br i1 %72, label %73, label %75

73:                                               ; preds = %71
  %74 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %67)
  tail call void @abort() #19
  unreachable

75:                                               ; preds = %71
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(16384) %37, i8 0, i64 16384, i1 false)
  br label %76

76:                                               ; preds = %76, %75
  %77 = phi i64 [ 0, %75 ], [ %85, %76 ]
  %78 = phi i32 [ 0, %75 ], [ %81, %76 ]
  %79 = mul nuw nsw i32 %78, 7141
  %80 = add nuw nsw i32 %79, 54773
  %81 = urem i32 %80, 259200
  %82 = uitofp nneg i32 %81 to double
  %83 = fmul nnan double %82, f0x3ED02E85C0898B71
  %84 = getelementptr inbounds nuw [8 x i8], ptr %37, i64 %77
  store double %83, ptr %84, align 8, !tbaa !9
  %85 = add nuw nsw i64 %77, 1
  %86 = and i64 %85, 4294967295
  %87 = icmp eq i64 %86, 1024
  br i1 %87, label %88, label %76, !llvm.loop !11

88:                                               ; preds = %76
  tail call fastcc void @bitrv2(i32 noundef 2048, ptr noundef %7, ptr noundef nonnull %37)
  tail call fastcc void @cftfsub(i32 noundef 2048, ptr noundef nonnull %37, ptr noundef nonnull readonly %8)
  br label %89

89:                                               ; preds = %89, %88
  %90 = phi i64 [ 0, %88 ], [ %111, %89 ]
  %91 = shl nuw nsw i64 %90, 4
  %92 = getelementptr inbounds nuw i8, ptr %37, i64 %91
  %93 = getelementptr inbounds nuw i8, ptr %92, i64 8
  %94 = load double, ptr %93, align 8, !tbaa !9
  %95 = fneg double %94
  store double %95, ptr %93, align 8, !tbaa !9
  %96 = shl i64 %90, 4
  %97 = getelementptr inbounds nuw i8, ptr %37, i64 %96
  %98 = getelementptr inbounds nuw i8, ptr %97, i64 24
  %99 = load double, ptr %98, align 8, !tbaa !9
  %100 = fneg double %99
  store double %100, ptr %98, align 8, !tbaa !9
  %101 = shl i64 %90, 4
  %102 = getelementptr inbounds nuw i8, ptr %37, i64 %101
  %103 = getelementptr inbounds nuw i8, ptr %102, i64 40
  %104 = load double, ptr %103, align 8, !tbaa !9
  %105 = fneg double %104
  store double %105, ptr %103, align 8, !tbaa !9
  %106 = shl i64 %90, 4
  %107 = getelementptr inbounds nuw i8, ptr %37, i64 %106
  %108 = getelementptr inbounds nuw i8, ptr %107, i64 56
  %109 = load double, ptr %108, align 8, !tbaa !9
  %110 = fneg double %109
  store double %110, ptr %108, align 8, !tbaa !9
  %111 = add nuw nsw i64 %90, 4
  %112 = icmp eq i64 %111, 1024
  br i1 %112, label %113, label %89, !llvm.loop !14

113:                                              ; preds = %89
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(16384) %39, i8 0, i64 16384, i1 false)
  br label %114

114:                                              ; preds = %114, %113
  %115 = phi i64 [ 0, %113 ], [ %123, %114 ]
  %116 = phi i32 [ 0, %113 ], [ %119, %114 ]
  %117 = mul nuw nsw i32 %116, 7141
  %118 = add nuw nsw i32 %117, 54773
  %119 = urem i32 %118, 259200
  %120 = uitofp nneg i32 %119 to double
  %121 = fmul nnan double %120, f0x3ED02E85C0898B71
  %122 = getelementptr inbounds nuw [8 x i8], ptr %39, i64 %115
  store double %121, ptr %122, align 8, !tbaa !9
  %123 = add nuw nsw i64 %115, 1
  %124 = and i64 %123, 4294967295
  %125 = icmp eq i64 %124, 1024
  br i1 %125, label %126, label %114, !llvm.loop !11

126:                                              ; preds = %114
  call void @llvm.lifetime.start.p0(ptr nonnull %2) #17
  %127 = call i32 @gettimeofday(ptr noundef nonnull %2, ptr noundef null) #17
  call void @llvm.lifetime.end.p0(ptr nonnull %2) #17
  br label %128

128:                                              ; preds = %126, %149
  %129 = phi i32 [ 0, %126 ], [ %150, %149 ]
  tail call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 16 dereferenceable(16384) %38, ptr noundef nonnull align 16 dereferenceable(16384) %39, i64 16384, i1 false)
  tail call fastcc void @bitrv2(i32 noundef 2048, ptr noundef %7, ptr noundef nonnull %38)
  tail call fastcc void @cftfsub(i32 noundef 2048, ptr noundef nonnull %38, ptr noundef nonnull readonly %8)
  br label %130

130:                                              ; preds = %130, %128
  %131 = phi i64 [ 0, %128 ], [ %147, %130 ]
  %132 = shl nuw nsw i64 %131, 1
  %133 = getelementptr inbounds nuw [8 x i8], ptr %38, i64 %132
  %134 = load <4 x double>, ptr %133, align 16, !tbaa !9
  %135 = shufflevector <4 x double> %134, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %136 = shufflevector <4 x double> %134, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %137 = getelementptr inbounds nuw [8 x i8], ptr %37, i64 %132
  %138 = load <4 x double>, ptr %137, align 16, !tbaa !9
  %139 = shufflevector <4 x double> %138, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %140 = shufflevector <4 x double> %138, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %141 = fneg <2 x double> %140
  %142 = fmul <2 x double> %136, %141
  %143 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %135, <2 x double> %139, <2 x double> %142)
  %144 = fmul <2 x double> %139, %136
  %145 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %135, <2 x double> %140, <2 x double> %144)
  %146 = shufflevector <2 x double> %143, <2 x double> %145, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %146, ptr %133, align 16, !tbaa !9
  %147 = add nuw i64 %131, 2
  %148 = icmp eq i64 %147, 1024
  br i1 %148, label %149, label %130, !llvm.loop !15

149:                                              ; preds = %130
  tail call void @cdft(i32 noundef 2048, i32 noundef -1, ptr noundef nonnull %38, ptr noundef %7, ptr noundef nonnull %8)
  %150 = add nuw nsw i32 %129, 1
  %151 = icmp eq i32 %150, 150000
  br i1 %151, label %152, label %128, !llvm.loop !18

152:                                              ; preds = %149
  call void @llvm.lifetime.start.p0(ptr nonnull %1) #17
  %153 = call i32 @gettimeofday(ptr noundef nonnull %1, ptr noundef null) #17
  call void @llvm.lifetime.end.p0(ptr nonnull %1) #17
  br label %154

154:                                              ; preds = %152, %154
  %155 = phi i64 [ 0, %152 ], [ %168, %154 ]
  %156 = shl nuw nsw i64 %155, 4
  %157 = getelementptr inbounds nuw i8, ptr %38, i64 %156
  %158 = load double, ptr %157, align 16, !tbaa !9
  %159 = tail call double @llvm.fabs.f64(double %158)
  %160 = fcmp ogt double %159, 1.000000e-09
  %161 = select i1 %160, double %158, double 0.000000e+00
  %162 = getelementptr inbounds nuw i8, ptr %157, i64 8
  %163 = load double, ptr %162, align 8, !tbaa !9
  %164 = tail call double @llvm.fabs.f64(double %163)
  %165 = fcmp ogt double %164, 1.000000e-09
  %166 = select i1 %165, double %163, double 0.000000e+00
  %167 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %161, double noundef %166)
  %168 = add nuw nsw i64 %155, 1
  %169 = icmp eq i64 %168, 1024
  br i1 %169, label %170, label %154, !llvm.loop !19

170:                                              ; preds = %154
  tail call void @free(ptr noundef nonnull %37) #17
  tail call void @free(ptr noundef nonnull %8) #17
  tail call void @free(ptr noundef %7) #17
  tail call void @free(ptr noundef nonnull %38) #17
  tail call void @free(ptr noundef nonnull %39) #17
  ret i32 0
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nofree nounwind uwtable
define dso_local double @get_time() local_unnamed_addr #2 {
  %1 = alloca %struct.timeval, align 8
  call void @llvm.lifetime.start.p0(ptr nonnull %1) #17
  %2 = call i32 @gettimeofday(ptr noundef nonnull %1, ptr noundef null) #17
  %3 = load i64, ptr %1, align 8, !tbaa !20
  %4 = sitofp i64 %3 to double
  %5 = getelementptr inbounds nuw i8, ptr %1, i64 8
  %6 = load i64, ptr %5, align 8, !tbaa !23
  %7 = sitofp i64 %6 to double
  %8 = tail call double @llvm.fmuladd.f64(double %7, double f0x3EB0C6F7A0B5ED8D, double %4)
  call void @llvm.lifetime.end.p0(ptr nonnull %1) #17
  ret double %8
}

; Function Attrs: mustprogress nofree nounwind willreturn allockind("alloc,uninitialized,aligned") allocsize(1) memory(inaccessiblemem: readwrite, errnomem: write)
declare noalias noundef ptr @memalign(i64 allocalign noundef, i64 noundef) local_unnamed_addr #3

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite, errnomem: write) uwtable
define dso_local void @makewt(i32 noundef %0, ptr nofree noundef captures(none) %1, ptr nofree noundef captures(none) %2) local_unnamed_addr #4 {
  %4 = icmp sgt i32 %0, 2
  br i1 %4, label %5, label %33

5:                                                ; preds = %3
  %6 = lshr i32 %0, 1
  %7 = uitofp nneg i32 %6 to double
  %8 = fdiv double f0x3FE921FB54442D18, %7
  store <2 x double> <double 1.000000e+00, double 0.000000e+00>, ptr %2, align 8, !tbaa !9
  %9 = fmul double %8, %7
  %10 = tail call double @cos(double noundef %9) #17
  %11 = zext nneg i32 %6 to i64
  %12 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %11
  store double %10, ptr %12, align 8, !tbaa !9
  %13 = getelementptr inbounds nuw i8, ptr %12, i64 8
  store double %10, ptr %13, align 8, !tbaa !9
  %14 = icmp samesign ugt i32 %0, 5
  br i1 %14, label %15, label %33

15:                                               ; preds = %5
  %16 = zext nneg i32 %0 to i64
  %17 = zext nneg i32 %6 to i64
  br label %18

18:                                               ; preds = %15, %18
  %19 = phi i64 [ 2, %15 ], [ %30, %18 ]
  %20 = trunc nuw nsw i64 %19 to i32
  %21 = uitofp nneg i32 %20 to double
  %22 = fmul double %8, %21
  %23 = tail call double @cos(double noundef %22) #17
  %24 = tail call double @sin(double noundef %22) #17
  %25 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %19
  store double %23, ptr %25, align 8, !tbaa !9
  %26 = getelementptr inbounds nuw i8, ptr %25, i64 8
  store double %24, ptr %26, align 8, !tbaa !9
  %27 = sub nsw i64 %16, %19
  %28 = getelementptr inbounds [8 x i8], ptr %2, i64 %27
  store double %24, ptr %28, align 8, !tbaa !9
  %29 = getelementptr i8, ptr %28, i64 8
  store double %23, ptr %29, align 8, !tbaa !9
  %30 = add nuw nsw i64 %19, 2
  %31 = icmp samesign ult i64 %30, %17
  br i1 %31, label %18, label %32, !llvm.loop !24

32:                                               ; preds = %18
  tail call fastcc void @bitrv2(i32 noundef %0, ptr noundef %1, ptr noundef nonnull %2)
  br label %33

33:                                               ; preds = %5, %32, %3
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: write) uwtable
define dso_local void @putdata(i32 noundef %0, i32 noundef %1, ptr nofree noundef writeonly captures(none) %2) local_unnamed_addr #5 {
  %4 = icmp sgt i32 %0, %1
  br i1 %4, label %45, label %5

5:                                                ; preds = %3
  %6 = sext i32 %0 to i64
  %7 = add i32 %1, 1
  %8 = sub i32 %7, %0
  %9 = and i32 %8, 1
  %10 = icmp eq i32 %1, %0
  br i1 %10, label %35, label %11

11:                                               ; preds = %5
  %12 = and i32 %8, -2
  br label %13

13:                                               ; preds = %13, %11
  %14 = phi i64 [ %6, %11 ], [ %30, %13 ]
  %15 = phi i32 [ 0, %11 ], [ %25, %13 ]
  %16 = phi i32 [ 0, %11 ], [ %31, %13 ]
  %17 = mul nuw nsw i32 %15, 7141
  %18 = add nuw nsw i32 %17, 54773
  %19 = urem i32 %18, 259200
  %20 = uitofp nneg i32 %19 to double
  %21 = fmul nnan double %20, f0x3ED02E85C0898B71
  %22 = getelementptr inbounds [8 x i8], ptr %2, i64 %14
  store double %21, ptr %22, align 8, !tbaa !9
  %23 = mul nuw nsw i32 %19, 7141
  %24 = add nuw nsw i32 %23, 54773
  %25 = urem i32 %24, 259200
  %26 = uitofp nneg i32 %25 to double
  %27 = fmul nnan double %26, f0x3ED02E85C0898B71
  %28 = getelementptr [8 x i8], ptr %2, i64 %14
  %29 = getelementptr i8, ptr %28, i64 8
  store double %27, ptr %29, align 8, !tbaa !9
  %30 = add nsw i64 %14, 2
  %31 = add i32 %16, 2
  %32 = icmp eq i32 %31, %12
  br i1 %32, label %33, label %13, !llvm.loop !11

33:                                               ; preds = %13
  %34 = icmp eq i32 %9, 0
  br i1 %34, label %45, label %35

35:                                               ; preds = %33, %5
  %36 = phi i64 [ %6, %5 ], [ %30, %33 ]
  %37 = phi i32 [ 0, %5 ], [ %25, %33 ]
  %38 = trunc i32 %8 to i1
  tail call void @llvm.assume(i1 %38)
  %39 = mul nuw nsw i32 %37, 7141
  %40 = add nuw nsw i32 %39, 54773
  %41 = urem i32 %40, 259200
  %42 = uitofp nneg i32 %41 to double
  %43 = fmul nnan double %42, f0x3ED02E85C0898B71
  %44 = getelementptr inbounds [8 x i8], ptr %2, i64 %36
  store double %43, ptr %44, align 8, !tbaa !9
  br label %45

45:                                               ; preds = %35, %33, %3
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @cdft(i32 noundef %0, i32 noundef %1, ptr nofree noundef %2, ptr nofree noundef captures(none) %3, ptr nofree noundef readonly captures(none) %4) local_unnamed_addr #6 {
  %6 = icmp sgt i32 %0, 4
  br i1 %6, label %7, label %577

7:                                                ; preds = %5
  %8 = icmp sgt i32 %1, -1
  br i1 %8, label %9, label %10

9:                                                ; preds = %7
  tail call fastcc void @bitrv2(i32 noundef %0, ptr noundef %3, ptr noundef %2)
  br label %579

10:                                               ; preds = %7
  store i32 0, ptr %3, align 4, !tbaa !25
  %11 = icmp samesign ugt i32 %0, 8
  br i1 %11, label %12, label %56

12:                                               ; preds = %10, %49
  %13 = phi i32 [ %50, %49 ], [ 1, %10 ]
  %14 = phi i32 [ %15, %49 ], [ %0, %10 ]
  %15 = lshr i32 %14, 1
  %16 = icmp sgt i32 %13, 0
  br i1 %16, label %17, label %49

17:                                               ; preds = %12
  %18 = zext nneg i32 %13 to i64
  %19 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %18
  %20 = icmp ult i32 %13, 8
  br i1 %20, label %39, label %21

21:                                               ; preds = %17
  %22 = and i64 %18, 2147483640
  %23 = insertelement <4 x i32> poison, i32 %15, i64 0
  %24 = shufflevector <4 x i32> %23, <4 x i32> poison, <4 x i32> zeroinitializer
  br label %25

25:                                               ; preds = %25, %21
  %26 = phi i64 [ 0, %21 ], [ %35, %25 ]
  %27 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %26
  %28 = getelementptr inbounds nuw i8, ptr %27, i64 16
  %29 = load <4 x i32>, ptr %27, align 4, !tbaa !25
  %30 = load <4 x i32>, ptr %28, align 4, !tbaa !25
  %31 = add nsw <4 x i32> %29, %24
  %32 = add nsw <4 x i32> %30, %24
  %33 = getelementptr inbounds nuw [4 x i8], ptr %19, i64 %26
  %34 = getelementptr inbounds nuw i8, ptr %33, i64 16
  store <4 x i32> %31, ptr %33, align 4, !tbaa !25
  store <4 x i32> %32, ptr %34, align 4, !tbaa !25
  %35 = add nuw i64 %26, 8
  %36 = icmp eq i64 %35, %22
  br i1 %36, label %37, label %25, !llvm.loop !26

37:                                               ; preds = %25
  %38 = icmp eq i64 %22, %18
  br i1 %38, label %49, label %39

39:                                               ; preds = %17, %37
  %40 = phi i64 [ 0, %17 ], [ %22, %37 ]
  br label %41

41:                                               ; preds = %39, %41
  %42 = phi i64 [ %47, %41 ], [ %40, %39 ]
  %43 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %42
  %44 = load i32, ptr %43, align 4, !tbaa !25
  %45 = add nsw i32 %44, %15
  %46 = getelementptr inbounds nuw [4 x i8], ptr %19, i64 %42
  store i32 %45, ptr %46, align 4, !tbaa !25
  %47 = add nuw nsw i64 %42, 1
  %48 = icmp eq i64 %47, %18
  br i1 %48, label %49, label %41, !llvm.loop !27

49:                                               ; preds = %41, %37, %12
  %50 = shl i32 %13, 1
  %51 = shl i32 %13, 4
  %52 = icmp slt i32 %51, %15
  br i1 %52, label %12, label %53, !llvm.loop !28

53:                                               ; preds = %49
  %54 = shl i32 %13, 2
  %55 = icmp eq i32 %51, %15
  br i1 %55, label %58, label %165

56:                                               ; preds = %10
  %57 = icmp eq i32 %0, 8
  br i1 %57, label %60, label %165

58:                                               ; preds = %53
  %59 = icmp sgt i32 %50, 0
  br i1 %59, label %60, label %233

60:                                               ; preds = %58, %56
  %61 = phi i32 [ %50, %58 ], [ 1, %56 ]
  %62 = phi i32 [ %54, %58 ], [ 2, %56 ]
  %63 = shl nsw i32 %61, 2
  %64 = zext nneg i32 %62 to i64
  %65 = zext nneg i32 %61 to i64
  %66 = getelementptr [8 x i8], ptr %2, i64 %64
  br label %67

67:                                               ; preds = %136, %60
  %68 = phi i64 [ 0, %60 ], [ %163, %136 ]
  %69 = icmp eq i64 %68, 0
  br i1 %69, label %136, label %70

70:                                               ; preds = %67
  %71 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %68
  %72 = load i32, ptr %71, align 4, !tbaa !25
  %73 = sext i32 %72 to i64
  %74 = trunc i64 %68 to i32
  %75 = shl i32 %74, 1
  br label %76

76:                                               ; preds = %76, %70
  %77 = phi i64 [ 0, %70 ], [ %132, %76 ]
  %78 = shl nuw nsw i64 %77, 1
  %79 = add nsw i64 %78, %73
  %80 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %77
  %81 = load i32, ptr %80, align 4, !tbaa !25
  %82 = add nsw i32 %81, %75
  %83 = getelementptr inbounds [8 x i8], ptr %2, i64 %79
  %84 = load double, ptr %83, align 8, !tbaa !9
  %85 = getelementptr i8, ptr %83, i64 8
  %86 = load double, ptr %85, align 8, !tbaa !9
  %87 = fneg double %86
  %88 = sext i32 %82 to i64
  %89 = getelementptr inbounds [8 x i8], ptr %2, i64 %88
  %90 = load double, ptr %89, align 8, !tbaa !9
  %91 = getelementptr i8, ptr %89, i64 8
  %92 = load double, ptr %91, align 8, !tbaa !9
  %93 = fneg double %92
  store double %90, ptr %83, align 8, !tbaa !9
  store double %93, ptr %85, align 8, !tbaa !9
  store double %84, ptr %89, align 8, !tbaa !9
  store double %87, ptr %91, align 8, !tbaa !9
  %94 = add nsw i64 %79, %64
  %95 = add nsw i32 %82, %63
  %96 = getelementptr inbounds [8 x i8], ptr %2, i64 %94
  %97 = load double, ptr %96, align 8, !tbaa !9
  %98 = getelementptr i8, ptr %96, i64 8
  %99 = load double, ptr %98, align 8, !tbaa !9
  %100 = fneg double %99
  %101 = sext i32 %95 to i64
  %102 = getelementptr inbounds [8 x i8], ptr %2, i64 %101
  %103 = load double, ptr %102, align 8, !tbaa !9
  %104 = getelementptr i8, ptr %102, i64 8
  %105 = load double, ptr %104, align 8, !tbaa !9
  %106 = fneg double %105
  store double %103, ptr %96, align 8, !tbaa !9
  store double %106, ptr %98, align 8, !tbaa !9
  store double %97, ptr %102, align 8, !tbaa !9
  store double %100, ptr %104, align 8, !tbaa !9
  %107 = add nsw i64 %94, %64
  %108 = sub nsw i32 %95, %62
  %109 = getelementptr inbounds [8 x i8], ptr %2, i64 %107
  %110 = load double, ptr %109, align 8, !tbaa !9
  %111 = getelementptr i8, ptr %109, i64 8
  %112 = load double, ptr %111, align 8, !tbaa !9
  %113 = fneg double %112
  %114 = sext i32 %108 to i64
  %115 = getelementptr inbounds [8 x i8], ptr %2, i64 %114
  %116 = load double, ptr %115, align 8, !tbaa !9
  %117 = getelementptr i8, ptr %115, i64 8
  %118 = load double, ptr %117, align 8, !tbaa !9
  %119 = fneg double %118
  store double %116, ptr %109, align 8, !tbaa !9
  store double %119, ptr %111, align 8, !tbaa !9
  store double %110, ptr %115, align 8, !tbaa !9
  store double %113, ptr %117, align 8, !tbaa !9
  %120 = add nsw i32 %108, %63
  %121 = getelementptr [8 x i8], ptr %66, i64 %107
  %122 = load double, ptr %121, align 8, !tbaa !9
  %123 = getelementptr i8, ptr %121, i64 8
  %124 = load double, ptr %123, align 8, !tbaa !9
  %125 = fneg double %124
  %126 = sext i32 %120 to i64
  %127 = getelementptr inbounds [8 x i8], ptr %2, i64 %126
  %128 = load double, ptr %127, align 8, !tbaa !9
  %129 = getelementptr i8, ptr %127, i64 8
  %130 = load double, ptr %129, align 8, !tbaa !9
  %131 = fneg double %130
  store double %128, ptr %121, align 8, !tbaa !9
  store double %131, ptr %123, align 8, !tbaa !9
  store double %122, ptr %127, align 8, !tbaa !9
  store double %125, ptr %129, align 8, !tbaa !9
  %132 = add nuw nsw i64 %77, 1
  %133 = icmp eq i64 %132, %68
  br i1 %133, label %134, label %76, !llvm.loop !29

134:                                              ; preds = %76
  %135 = add nsw i32 %72, %75
  br label %136

136:                                              ; preds = %134, %67
  %137 = phi i32 [ %135, %134 ], [ 0, %67 ]
  %138 = sext i32 %137 to i64
  %139 = getelementptr [8 x i8], ptr %2, i64 %138
  %140 = getelementptr i8, ptr %139, i64 8
  %141 = load double, ptr %140, align 8, !tbaa !9
  %142 = fneg double %141
  store double %142, ptr %140, align 8, !tbaa !9
  %143 = add nsw i32 %137, %62
  %144 = add nsw i32 %143, %62
  %145 = sext i32 %143 to i64
  %146 = getelementptr inbounds [8 x i8], ptr %2, i64 %145
  %147 = load double, ptr %146, align 8, !tbaa !9
  %148 = getelementptr i8, ptr %146, i64 8
  %149 = load double, ptr %148, align 8, !tbaa !9
  %150 = fneg double %149
  %151 = sext i32 %144 to i64
  %152 = getelementptr inbounds [8 x i8], ptr %2, i64 %151
  %153 = load double, ptr %152, align 8, !tbaa !9
  %154 = getelementptr i8, ptr %152, i64 8
  %155 = load double, ptr %154, align 8, !tbaa !9
  %156 = fneg double %155
  store double %153, ptr %146, align 8, !tbaa !9
  store double %156, ptr %148, align 8, !tbaa !9
  store double %147, ptr %152, align 8, !tbaa !9
  store double %150, ptr %154, align 8, !tbaa !9
  %157 = add nsw i32 %144, %62
  %158 = sext i32 %157 to i64
  %159 = getelementptr [8 x i8], ptr %2, i64 %158
  %160 = getelementptr i8, ptr %159, i64 8
  %161 = load double, ptr %160, align 8, !tbaa !9
  %162 = fneg double %161
  store double %162, ptr %160, align 8, !tbaa !9
  %163 = add nuw nsw i64 %68, 1
  %164 = icmp eq i64 %163, %65
  br i1 %164, label %233, label %67, !llvm.loop !30

165:                                              ; preds = %56, %53
  %166 = phi i32 [ 2, %56 ], [ %54, %53 ]
  %167 = phi i32 [ 1, %56 ], [ %50, %53 ]
  %168 = getelementptr inbounds nuw i8, ptr %2, i64 8
  %169 = load double, ptr %168, align 8, !tbaa !9
  %170 = fneg double %169
  store double %170, ptr %168, align 8, !tbaa !9
  %171 = sext i32 %166 to i64
  %172 = getelementptr [8 x i8], ptr %2, i64 %171
  %173 = getelementptr i8, ptr %172, i64 8
  %174 = load double, ptr %173, align 8, !tbaa !9
  %175 = fneg double %174
  store double %175, ptr %173, align 8, !tbaa !9
  %176 = icmp sgt i32 %167, 1
  br i1 %176, label %177, label %233

177:                                              ; preds = %165
  %178 = zext nneg i32 %167 to i64
  br label %179

179:                                              ; preds = %218, %177
  %180 = phi i64 [ 1, %177 ], [ %231, %218 ]
  %181 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %180
  %182 = load i32, ptr %181, align 4, !tbaa !25
  %183 = sext i32 %182 to i64
  %184 = trunc i64 %180 to i32
  %185 = shl i32 %184, 1
  br label %186

186:                                              ; preds = %186, %179
  %187 = phi i64 [ 0, %179 ], [ %216, %186 ]
  %188 = shl nuw nsw i64 %187, 1
  %189 = add nsw i64 %188, %183
  %190 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %187
  %191 = load i32, ptr %190, align 4, !tbaa !25
  %192 = add nsw i32 %191, %185
  %193 = getelementptr inbounds [8 x i8], ptr %2, i64 %189
  %194 = load double, ptr %193, align 8, !tbaa !9
  %195 = getelementptr i8, ptr %193, i64 8
  %196 = load double, ptr %195, align 8, !tbaa !9
  %197 = fneg double %196
  %198 = sext i32 %192 to i64
  %199 = getelementptr inbounds [8 x i8], ptr %2, i64 %198
  %200 = load double, ptr %199, align 8, !tbaa !9
  %201 = getelementptr i8, ptr %199, i64 8
  %202 = load double, ptr %201, align 8, !tbaa !9
  %203 = fneg double %202
  store double %200, ptr %193, align 8, !tbaa !9
  store double %203, ptr %195, align 8, !tbaa !9
  store double %194, ptr %199, align 8, !tbaa !9
  store double %197, ptr %201, align 8, !tbaa !9
  %204 = add nsw i32 %192, %166
  %205 = getelementptr [8 x i8], ptr %172, i64 %189
  %206 = load double, ptr %205, align 8, !tbaa !9
  %207 = getelementptr i8, ptr %205, i64 8
  %208 = load double, ptr %207, align 8, !tbaa !9
  %209 = fneg double %208
  %210 = sext i32 %204 to i64
  %211 = getelementptr inbounds [8 x i8], ptr %2, i64 %210
  %212 = load double, ptr %211, align 8, !tbaa !9
  %213 = getelementptr i8, ptr %211, i64 8
  %214 = load double, ptr %213, align 8, !tbaa !9
  %215 = fneg double %214
  store double %212, ptr %205, align 8, !tbaa !9
  store double %215, ptr %207, align 8, !tbaa !9
  store double %206, ptr %211, align 8, !tbaa !9
  store double %209, ptr %213, align 8, !tbaa !9
  %216 = add nuw nsw i64 %187, 1
  %217 = icmp eq i64 %216, %180
  br i1 %217, label %218, label %186, !llvm.loop !31

218:                                              ; preds = %186
  %219 = add nsw i32 %185, %182
  %220 = sext i32 %219 to i64
  %221 = getelementptr [8 x i8], ptr %2, i64 %220
  %222 = getelementptr i8, ptr %221, i64 8
  %223 = load double, ptr %222, align 8, !tbaa !9
  %224 = fneg double %223
  store double %224, ptr %222, align 8, !tbaa !9
  %225 = add nsw i32 %219, %166
  %226 = sext i32 %225 to i64
  %227 = getelementptr [8 x i8], ptr %2, i64 %226
  %228 = getelementptr i8, ptr %227, i64 8
  %229 = load double, ptr %228, align 8, !tbaa !9
  %230 = fneg double %229
  store double %230, ptr %228, align 8, !tbaa !9
  %231 = add nuw nsw i64 %180, 1
  %232 = icmp eq i64 %231, %178
  br i1 %232, label %233, label %179, !llvm.loop !32

233:                                              ; preds = %218, %136, %58, %165
  br i1 %11, label %234, label %241

234:                                              ; preds = %233
  tail call fastcc void @cft1st(i32 noundef range(i32 5, -2147483648) %0, ptr noundef %2, ptr noundef readonly %4)
  %235 = icmp samesign ugt i32 %0, 32
  br i1 %235, label %236, label %241

236:                                              ; preds = %234, %236
  %237 = phi i32 [ %239, %236 ], [ 32, %234 ]
  %238 = phi i32 [ %237, %236 ], [ 8, %234 ]
  tail call fastcc void @cftmdl(i32 noundef range(i32 5, -2147483648) %0, i32 noundef %238, ptr noundef %2, ptr noundef readonly %4)
  %239 = shl i32 %237, 2
  %240 = icmp slt i32 %239, %0
  br i1 %240, label %236, label %241, !llvm.loop !33

241:                                              ; preds = %236, %234, %233
  %242 = phi i32 [ 2, %233 ], [ 8, %234 ], [ %237, %236 ]
  %243 = shl i32 %242, 2
  %244 = icmp eq i32 %243, %0
  %245 = icmp sgt i32 %242, 0
  br i1 %244, label %318, label %246

246:                                              ; preds = %241
  br i1 %245, label %247, label %581

247:                                              ; preds = %246
  %248 = zext nneg i32 %242 to i64
  %249 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %248
  %250 = add nsw i64 %248, -2
  %251 = lshr exact i64 %250, 1
  %252 = add nuw i64 %251, 1
  %253 = icmp ult i64 %250, 34
  br i1 %253, label %316, label %254

254:                                              ; preds = %247
  %255 = shl nuw nsw i64 %248, 3
  %256 = getelementptr i8, ptr %2, i64 %255
  %257 = getelementptr i8, ptr %256, i64 -8
  %258 = getelementptr i8, ptr %2, i64 8
  %259 = getelementptr i8, ptr %2, i64 %255
  %260 = shl nuw nsw i64 %248, 3
  %261 = getelementptr i8, ptr %2, i64 %255
  %262 = getelementptr i8, ptr %261, i64 %260
  %263 = getelementptr i8, ptr %262, i64 -8
  %264 = getelementptr i8, ptr %2, i64 %260
  %265 = getelementptr i8, ptr %264, i64 8
  %266 = shl nuw nsw i64 %248, 4
  %267 = getelementptr i8, ptr %2, i64 %266
  %268 = icmp ult ptr %2, %259
  %269 = icmp ult ptr %258, %257
  %270 = and i1 %268, %269
  %271 = icmp ult ptr %2, %263
  %272 = icmp ult ptr %249, %257
  %273 = and i1 %271, %272
  %274 = or i1 %270, %273
  %275 = icmp ult ptr %2, %267
  %276 = icmp ult ptr %265, %257
  %277 = and i1 %275, %276
  %278 = or i1 %274, %277
  %279 = icmp ult ptr %258, %263
  %280 = icmp ult ptr %249, %259
  %281 = and i1 %279, %280
  %282 = or i1 %278, %281
  %283 = icmp ult ptr %258, %267
  %284 = icmp ult ptr %265, %259
  %285 = and i1 %283, %284
  %286 = or i1 %282, %285
  %287 = icmp ult ptr %249, %267
  %288 = icmp ult ptr %265, %263
  %289 = and i1 %287, %288
  %290 = or i1 %286, %289
  br i1 %290, label %316, label %291

291:                                              ; preds = %254
  %292 = and i64 %252, -2
  %293 = shl i64 %292, 1
  br label %294

294:                                              ; preds = %294, %291
  %295 = phi i64 [ 0, %291 ], [ %312, %294 ]
  %296 = shl i64 %295, 1
  %297 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %296
  %298 = load <4 x double>, ptr %297, align 8, !tbaa !9
  %299 = shufflevector <4 x double> %298, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %300 = shufflevector <4 x double> %298, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %301 = getelementptr inbounds nuw [8 x i8], ptr %249, i64 %296
  %302 = load <4 x double>, ptr %301, align 8, !tbaa !9
  %303 = shufflevector <4 x double> %302, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %304 = shufflevector <4 x double> %302, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %305 = fsub <2 x double> %299, %303
  %306 = fsub <2 x double> %304, %300
  %307 = fadd <2 x double> %299, %303
  %308 = fneg <2 x double> %300
  %309 = fsub <2 x double> %308, %304
  %310 = shufflevector <2 x double> %307, <2 x double> %309, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %310, ptr %297, align 8, !tbaa !9
  %311 = shufflevector <2 x double> %305, <2 x double> %306, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %311, ptr %301, align 8, !tbaa !9
  %312 = add nuw i64 %295, 2
  %313 = icmp eq i64 %312, %292
  br i1 %313, label %314, label %294, !llvm.loop !34

314:                                              ; preds = %294
  %315 = icmp eq i64 %252, %292
  br i1 %315, label %581, label %316

316:                                              ; preds = %254, %247, %314
  %317 = phi i64 [ 0, %254 ], [ 0, %247 ], [ %293, %314 ]
  br label %560

318:                                              ; preds = %241
  br i1 %245, label %319, label %581

319:                                              ; preds = %318
  %320 = zext nneg i32 %242 to i64
  %321 = getelementptr [8 x i8], ptr %2, i64 %320
  %322 = add nsw i64 %320, -2
  %323 = lshr exact i64 %322, 1
  %324 = add nuw i64 %323, 1
  %325 = icmp ult i64 %322, 50
  br i1 %325, label %519, label %326

326:                                              ; preds = %319
  %327 = shl nuw nsw i64 %320, 3
  %328 = add nsw i64 %327, -16
  %329 = getelementptr i8, ptr %2, i64 %327
  %330 = getelementptr i8, ptr %329, i64 -8
  %331 = getelementptr i8, ptr %2, i64 8
  %332 = getelementptr i8, ptr %2, i64 %327
  %333 = shl nuw nsw i64 %320, 4
  %334 = getelementptr i8, ptr %2, i64 %333
  %335 = getelementptr i8, ptr %2, i64 %328
  %336 = getelementptr i8, ptr %335, i64 %333
  %337 = getelementptr i8, ptr %336, i64 8
  %338 = getelementptr i8, ptr %2, i64 %333
  %339 = getelementptr i8, ptr %338, i64 8
  %340 = mul nuw nsw i64 %320, 24
  %341 = getelementptr i8, ptr %2, i64 %340
  %342 = shl nuw nsw i64 %320, 3
  %343 = getelementptr i8, ptr %2, i64 %328
  %344 = getelementptr i8, ptr %343, i64 %342
  %345 = getelementptr i8, ptr %344, i64 8
  %346 = getelementptr i8, ptr %2, i64 %342
  %347 = getelementptr i8, ptr %346, i64 8
  %348 = shl nuw nsw i64 %320, 4
  %349 = getelementptr i8, ptr %2, i64 %348
  %350 = mul nuw nsw i64 %320, 24
  %351 = getelementptr i8, ptr %2, i64 %350
  %352 = getelementptr i8, ptr %2, i64 %350
  %353 = getelementptr i8, ptr %352, i64 %328
  %354 = getelementptr i8, ptr %353, i64 8
  %355 = getelementptr i8, ptr %2, i64 %350
  %356 = getelementptr i8, ptr %355, i64 8
  %357 = shl nuw nsw i64 %320, 5
  %358 = getelementptr i8, ptr %2, i64 %357
  %359 = icmp ult ptr %2, %332
  %360 = icmp ult ptr %331, %330
  %361 = and i1 %359, %360
  %362 = icmp ult ptr %2, %337
  %363 = icmp ult ptr %334, %330
  %364 = and i1 %362, %363
  %365 = or i1 %361, %364
  %366 = icmp ult ptr %2, %341
  %367 = icmp ult ptr %339, %330
  %368 = and i1 %366, %367
  %369 = or i1 %365, %368
  %370 = icmp ult ptr %2, %345
  %371 = icmp ult ptr %321, %330
  %372 = and i1 %370, %371
  %373 = or i1 %369, %372
  %374 = icmp ult ptr %2, %349
  %375 = icmp ult ptr %347, %330
  %376 = and i1 %374, %375
  %377 = or i1 %373, %376
  %378 = icmp ult ptr %2, %354
  %379 = icmp ult ptr %351, %330
  %380 = and i1 %378, %379
  %381 = or i1 %377, %380
  %382 = icmp ult ptr %2, %358
  %383 = icmp ult ptr %356, %330
  %384 = and i1 %382, %383
  %385 = or i1 %381, %384
  %386 = icmp ult ptr %331, %337
  %387 = icmp ult ptr %334, %332
  %388 = and i1 %386, %387
  %389 = or i1 %385, %388
  %390 = icmp ult ptr %331, %341
  %391 = icmp ult ptr %339, %332
  %392 = and i1 %390, %391
  %393 = or i1 %389, %392
  %394 = icmp ult ptr %331, %345
  %395 = icmp ult ptr %321, %332
  %396 = and i1 %394, %395
  %397 = or i1 %393, %396
  %398 = icmp ult ptr %331, %349
  %399 = icmp ult ptr %347, %332
  %400 = and i1 %398, %399
  %401 = or i1 %397, %400
  %402 = icmp ult ptr %331, %354
  %403 = icmp ult ptr %351, %332
  %404 = and i1 %402, %403
  %405 = or i1 %401, %404
  %406 = icmp ult ptr %331, %358
  %407 = icmp ult ptr %356, %332
  %408 = and i1 %406, %407
  %409 = or i1 %405, %408
  %410 = icmp ult ptr %334, %341
  %411 = icmp ult ptr %339, %337
  %412 = and i1 %410, %411
  %413 = or i1 %409, %412
  %414 = icmp ult ptr %334, %345
  %415 = icmp ult ptr %321, %337
  %416 = and i1 %414, %415
  %417 = or i1 %413, %416
  %418 = icmp ult ptr %334, %349
  %419 = icmp ult ptr %347, %337
  %420 = and i1 %418, %419
  %421 = or i1 %417, %420
  %422 = icmp ult ptr %334, %354
  %423 = icmp ult ptr %351, %337
  %424 = and i1 %422, %423
  %425 = or i1 %421, %424
  %426 = icmp ult ptr %334, %358
  %427 = icmp ult ptr %356, %337
  %428 = and i1 %426, %427
  %429 = or i1 %425, %428
  %430 = icmp ult ptr %339, %345
  %431 = icmp ult ptr %321, %341
  %432 = and i1 %430, %431
  %433 = or i1 %429, %432
  %434 = icmp ult ptr %339, %349
  %435 = icmp ult ptr %347, %341
  %436 = and i1 %434, %435
  %437 = or i1 %433, %436
  %438 = icmp ult ptr %339, %354
  %439 = icmp ult ptr %351, %341
  %440 = and i1 %438, %439
  %441 = or i1 %437, %440
  %442 = icmp ult ptr %339, %358
  %443 = icmp ult ptr %356, %341
  %444 = and i1 %442, %443
  %445 = or i1 %441, %444
  %446 = icmp ult ptr %321, %349
  %447 = icmp ult ptr %347, %345
  %448 = and i1 %446, %447
  %449 = or i1 %445, %448
  %450 = icmp ult ptr %321, %354
  %451 = icmp ult ptr %351, %345
  %452 = and i1 %450, %451
  %453 = or i1 %449, %452
  %454 = icmp ult ptr %321, %358
  %455 = icmp ult ptr %356, %345
  %456 = and i1 %454, %455
  %457 = or i1 %453, %456
  %458 = icmp ult ptr %347, %354
  %459 = icmp ult ptr %351, %349
  %460 = and i1 %458, %459
  %461 = or i1 %457, %460
  %462 = icmp ult ptr %347, %358
  %463 = icmp ult ptr %356, %349
  %464 = and i1 %462, %463
  %465 = or i1 %461, %464
  %466 = icmp ult ptr %351, %358
  %467 = icmp ult ptr %356, %354
  %468 = and i1 %466, %467
  %469 = or i1 %465, %468
  br i1 %469, label %519, label %470

470:                                              ; preds = %326
  %471 = and i64 %324, -2
  %472 = shl i64 %471, 1
  br label %473

473:                                              ; preds = %473, %470
  %474 = phi i64 [ 0, %470 ], [ %515, %473 ]
  %475 = shl i64 %474, 1
  %476 = add nuw nsw i64 %475, %320
  %477 = add nuw nsw i64 %476, %320
  %478 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %475
  %479 = load <4 x double>, ptr %478, align 8, !tbaa !9
  %480 = shufflevector <4 x double> %479, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %481 = shufflevector <4 x double> %479, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %482 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %476
  %483 = load <4 x double>, ptr %482, align 8, !tbaa !9
  %484 = shufflevector <4 x double> %483, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %485 = shufflevector <4 x double> %483, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %486 = fadd <2 x double> %480, %484
  %487 = fneg <2 x double> %481
  %488 = fsub <2 x double> %487, %485
  %489 = fsub <2 x double> %480, %484
  %490 = fsub <2 x double> %485, %481
  %491 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %477
  %492 = load <4 x double>, ptr %491, align 8, !tbaa !9
  %493 = shufflevector <4 x double> %492, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %494 = shufflevector <4 x double> %492, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %495 = getelementptr inbounds nuw [8 x i8], ptr %321, i64 %477
  %496 = load <4 x double>, ptr %495, align 8, !tbaa !9
  %497 = shufflevector <4 x double> %496, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %498 = shufflevector <4 x double> %496, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %499 = fadd <2 x double> %493, %497
  %500 = fadd <2 x double> %494, %498
  %501 = fsub <2 x double> %493, %497
  %502 = fsub <2 x double> %494, %498
  %503 = fadd <2 x double> %486, %499
  %504 = fsub <2 x double> %488, %500
  %505 = shufflevector <2 x double> %503, <2 x double> %504, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %505, ptr %478, align 8, !tbaa !9
  %506 = fsub <2 x double> %486, %499
  %507 = fadd <2 x double> %488, %500
  %508 = shufflevector <2 x double> %506, <2 x double> %507, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %508, ptr %491, align 8, !tbaa !9
  %509 = fsub <2 x double> %489, %502
  %510 = fsub <2 x double> %490, %501
  %511 = shufflevector <2 x double> %509, <2 x double> %510, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %511, ptr %482, align 8, !tbaa !9
  %512 = fadd <2 x double> %489, %502
  %513 = fadd <2 x double> %490, %501
  %514 = shufflevector <2 x double> %512, <2 x double> %513, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %514, ptr %495, align 8, !tbaa !9
  %515 = add nuw i64 %474, 2
  %516 = icmp eq i64 %515, %471
  br i1 %516, label %517, label %473, !llvm.loop !35

517:                                              ; preds = %473
  %518 = icmp eq i64 %324, %471
  br i1 %518, label %581, label %519

519:                                              ; preds = %326, %319, %517
  %520 = phi i64 [ 0, %326 ], [ 0, %319 ], [ %472, %517 ]
  br label %521

521:                                              ; preds = %519, %521
  %522 = phi i64 [ %558, %521 ], [ %520, %519 ]
  %523 = add nuw nsw i64 %522, %320
  %524 = add nuw nsw i64 %523, %320
  %525 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %522
  %526 = load double, ptr %525, align 8, !tbaa !9
  %527 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %523
  %528 = load double, ptr %527, align 8, !tbaa !9
  %529 = fadd double %526, %528
  %530 = getelementptr inbounds nuw i8, ptr %525, i64 8
  %531 = load double, ptr %530, align 8, !tbaa !9
  %532 = fneg double %531
  %533 = getelementptr i8, ptr %527, i64 8
  %534 = load double, ptr %533, align 8, !tbaa !9
  %535 = fsub double %532, %534
  %536 = fsub double %526, %528
  %537 = fsub double %534, %531
  %538 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %524
  %539 = load double, ptr %538, align 8, !tbaa !9
  %540 = getelementptr inbounds nuw [8 x i8], ptr %321, i64 %524
  %541 = load double, ptr %540, align 8, !tbaa !9
  %542 = fadd double %539, %541
  %543 = getelementptr i8, ptr %538, i64 8
  %544 = load double, ptr %543, align 8, !tbaa !9
  %545 = getelementptr i8, ptr %540, i64 8
  %546 = load double, ptr %545, align 8, !tbaa !9
  %547 = fadd double %544, %546
  %548 = fsub double %539, %541
  %549 = fsub double %544, %546
  %550 = fadd double %529, %542
  store double %550, ptr %525, align 8, !tbaa !9
  %551 = fsub double %535, %547
  store double %551, ptr %530, align 8, !tbaa !9
  %552 = fsub double %529, %542
  store double %552, ptr %538, align 8, !tbaa !9
  %553 = fadd double %535, %547
  store double %553, ptr %543, align 8, !tbaa !9
  %554 = fsub double %536, %549
  store double %554, ptr %527, align 8, !tbaa !9
  %555 = fsub double %537, %548
  store double %555, ptr %533, align 8, !tbaa !9
  %556 = fadd double %536, %549
  store double %556, ptr %540, align 8, !tbaa !9
  %557 = fadd double %537, %548
  store double %557, ptr %545, align 8, !tbaa !9
  %558 = add nuw nsw i64 %522, 2
  %559 = icmp samesign ult i64 %558, %320
  br i1 %559, label %521, label %581, !llvm.loop !36

560:                                              ; preds = %316, %560
  %561 = phi i64 [ %575, %560 ], [ %317, %316 ]
  %562 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %561
  %563 = load double, ptr %562, align 8, !tbaa !9
  %564 = getelementptr inbounds nuw [8 x i8], ptr %249, i64 %561
  %565 = load double, ptr %564, align 8, !tbaa !9
  %566 = fsub double %563, %565
  %567 = getelementptr inbounds nuw i8, ptr %562, i64 8
  %568 = load double, ptr %567, align 8, !tbaa !9
  %569 = getelementptr i8, ptr %564, i64 8
  %570 = load double, ptr %569, align 8, !tbaa !9
  %571 = fsub double %570, %568
  %572 = fadd double %563, %565
  store double %572, ptr %562, align 8, !tbaa !9
  %573 = fneg double %568
  %574 = fsub double %573, %570
  store double %574, ptr %567, align 8, !tbaa !9
  store double %566, ptr %564, align 8, !tbaa !9
  store double %571, ptr %569, align 8, !tbaa !9
  %575 = add nuw nsw i64 %561, 2
  %576 = icmp samesign ult i64 %575, %248
  br i1 %576, label %560, label %581, !llvm.loop !37

577:                                              ; preds = %5
  %578 = icmp eq i32 %0, 4
  br i1 %578, label %579, label %581

579:                                              ; preds = %577, %9
  %580 = phi i32 [ %0, %9 ], [ 4, %577 ]
  tail call fastcc void @cftfsub(i32 noundef %580, ptr noundef %2, ptr noundef %4)
  br label %581

581:                                              ; preds = %560, %521, %314, %517, %579, %318, %246, %577
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: read) uwtable
define dso_local double @errorcheck(i32 noundef %0, i32 noundef %1, double noundef %2, ptr nofree noundef readonly captures(none) %3) local_unnamed_addr #7 {
  %5 = icmp sgt i32 %0, %1
  br i1 %5, label %28, label %6

6:                                                ; preds = %4
  %7 = fneg double %2
  %8 = sext i32 %0 to i64
  %9 = add i32 %1, 1
  br label %10

10:                                               ; preds = %6, %10
  %11 = phi i64 [ %8, %6 ], [ %25, %10 ]
  %12 = phi double [ 0.000000e+00, %6 ], [ %24, %10 ]
  %13 = phi i32 [ 0, %6 ], [ %16, %10 ]
  %14 = mul nuw nsw i32 %13, 7141
  %15 = add nuw nsw i32 %14, 54773
  %16 = urem i32 %15, 259200
  %17 = uitofp nneg i32 %16 to double
  %18 = getelementptr inbounds [8 x i8], ptr %3, i64 %11
  %19 = load double, ptr %18, align 8, !tbaa !9
  %20 = fmul double %19, %7
  %21 = tail call double @llvm.fmuladd.f64(double %17, double f0x3ED02E85C0898B71, double %20)
  %22 = tail call double @llvm.fabs.f64(double %21)
  %23 = fcmp ogt double %12, %22
  %24 = select i1 %23, double %12, double %22
  %25 = add nsw i64 %11, 1
  %26 = trunc i64 %25 to i32
  %27 = icmp eq i32 %9, %26
  br i1 %27, label %28, label %10, !llvm.loop !13

28:                                               ; preds = %10, %4
  %29 = phi double [ 0.000000e+00, %4 ], [ %24, %10 ]
  ret double %29
}

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fabs.f64(double) #8

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #9

; Function Attrs: cold nofree noreturn nounwind
declare void @abort() local_unnamed_addr #10

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #11

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #8

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: mustprogress nounwind willreturn allockind("free") memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @free(ptr allocptr noundef captures(none)) local_unnamed_addr #12

; Function Attrs: nofree nounwind
declare noundef i32 @gettimeofday(ptr noundef captures(none), ptr noundef captures(none)) local_unnamed_addr #9

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define internal fastcc void @bitrv2(i32 noundef range(i32 3, -2147483648) %0, ptr nofree noundef captures(none) initializes((0, 4)) %1, ptr nofree noundef captures(none) %2) unnamed_addr #6 {
  store i32 0, ptr %1, align 4, !tbaa !25
  %4 = icmp samesign ugt i32 %0, 8
  br i1 %4, label %5, label %49

5:                                                ; preds = %3, %42
  %6 = phi i32 [ %43, %42 ], [ 1, %3 ]
  %7 = phi i32 [ %8, %42 ], [ %0, %3 ]
  %8 = lshr i32 %7, 1
  %9 = icmp sgt i32 %6, 0
  br i1 %9, label %10, label %42

10:                                               ; preds = %5
  %11 = zext nneg i32 %6 to i64
  %12 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %11
  %13 = icmp ult i32 %6, 8
  br i1 %13, label %32, label %14

14:                                               ; preds = %10
  %15 = and i64 %11, 2147483640
  %16 = insertelement <4 x i32> poison, i32 %8, i64 0
  %17 = shufflevector <4 x i32> %16, <4 x i32> poison, <4 x i32> zeroinitializer
  br label %18

18:                                               ; preds = %18, %14
  %19 = phi i64 [ 0, %14 ], [ %28, %18 ]
  %20 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %19
  %21 = getelementptr inbounds nuw i8, ptr %20, i64 16
  %22 = load <4 x i32>, ptr %20, align 4, !tbaa !25
  %23 = load <4 x i32>, ptr %21, align 4, !tbaa !25
  %24 = add nsw <4 x i32> %22, %17
  %25 = add nsw <4 x i32> %23, %17
  %26 = getelementptr inbounds nuw [4 x i8], ptr %12, i64 %19
  %27 = getelementptr inbounds nuw i8, ptr %26, i64 16
  store <4 x i32> %24, ptr %26, align 4, !tbaa !25
  store <4 x i32> %25, ptr %27, align 4, !tbaa !25
  %28 = add nuw i64 %19, 8
  %29 = icmp eq i64 %28, %15
  br i1 %29, label %30, label %18, !llvm.loop !38

30:                                               ; preds = %18
  %31 = icmp eq i64 %15, %11
  br i1 %31, label %42, label %32

32:                                               ; preds = %10, %30
  %33 = phi i64 [ 0, %10 ], [ %15, %30 ]
  br label %34

34:                                               ; preds = %32, %34
  %35 = phi i64 [ %40, %34 ], [ %33, %32 ]
  %36 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %35
  %37 = load i32, ptr %36, align 4, !tbaa !25
  %38 = add nsw i32 %37, %8
  %39 = getelementptr inbounds nuw [4 x i8], ptr %12, i64 %35
  store i32 %38, ptr %39, align 4, !tbaa !25
  %40 = add nuw nsw i64 %35, 1
  %41 = icmp eq i64 %40, %11
  br i1 %41, label %42, label %34, !llvm.loop !39

42:                                               ; preds = %34, %30, %5
  %43 = shl i32 %6, 1
  %44 = shl i32 %6, 4
  %45 = icmp slt i32 %44, %8
  br i1 %45, label %5, label %46, !llvm.loop !40

46:                                               ; preds = %42
  %47 = shl i32 %6, 2
  %48 = icmp eq i32 %44, %8
  br i1 %48, label %57, label %51

49:                                               ; preds = %3
  %50 = icmp eq i32 %0, 8
  br i1 %50, label %59, label %154

51:                                               ; preds = %46
  %52 = icmp sgt i32 %43, 1
  br i1 %52, label %53, label %154

53:                                               ; preds = %51
  %54 = zext nneg i32 %47 to i64
  %55 = zext nneg i32 %43 to i64
  %56 = getelementptr [8 x i8], ptr %2, i64 %54
  br label %124

57:                                               ; preds = %46
  %58 = icmp sgt i32 %43, 0
  br i1 %58, label %59, label %154

59:                                               ; preds = %49, %57
  %60 = phi i32 [ %43, %57 ], [ 1, %49 ]
  %61 = phi i32 [ %47, %57 ], [ 2, %49 ]
  %62 = shl nsw i32 %60, 2
  %63 = zext nneg i32 %61 to i64
  %64 = zext nneg i32 %60 to i64
  %65 = getelementptr [8 x i8], ptr %2, i64 %63
  br label %66

66:                                               ; preds = %59, %109
  %67 = phi i64 [ 0, %59 ], [ %122, %109 ]
  %68 = icmp eq i64 %67, 0
  br i1 %68, label %109, label %69

69:                                               ; preds = %66
  %70 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %67
  %71 = load i32, ptr %70, align 4, !tbaa !25
  %72 = sext i32 %71 to i64
  %73 = trunc i64 %67 to i32
  %74 = shl i32 %73, 1
  br label %75

75:                                               ; preds = %69, %75
  %76 = phi i64 [ 0, %69 ], [ %107, %75 ]
  %77 = shl nuw nsw i64 %76, 1
  %78 = add nsw i64 %77, %72
  %79 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %76
  %80 = load i32, ptr %79, align 4, !tbaa !25
  %81 = add nsw i32 %80, %74
  %82 = getelementptr inbounds [8 x i8], ptr %2, i64 %78
  %83 = sext i32 %81 to i64
  %84 = getelementptr inbounds [8 x i8], ptr %2, i64 %83
  %85 = load <2 x double>, ptr %82, align 8, !tbaa !9
  %86 = load <2 x double>, ptr %84, align 8, !tbaa !9
  store <2 x double> %86, ptr %82, align 8, !tbaa !9
  store <2 x double> %85, ptr %84, align 8, !tbaa !9
  %87 = add nsw i64 %78, %63
  %88 = add nsw i32 %81, %62
  %89 = getelementptr inbounds [8 x i8], ptr %2, i64 %87
  %90 = sext i32 %88 to i64
  %91 = getelementptr inbounds [8 x i8], ptr %2, i64 %90
  %92 = load <2 x double>, ptr %89, align 8, !tbaa !9
  %93 = load <2 x double>, ptr %91, align 8, !tbaa !9
  store <2 x double> %93, ptr %89, align 8, !tbaa !9
  store <2 x double> %92, ptr %91, align 8, !tbaa !9
  %94 = add nsw i64 %87, %63
  %95 = sub nsw i32 %88, %61
  %96 = getelementptr inbounds [8 x i8], ptr %2, i64 %94
  %97 = sext i32 %95 to i64
  %98 = getelementptr inbounds [8 x i8], ptr %2, i64 %97
  %99 = load <2 x double>, ptr %96, align 8, !tbaa !9
  %100 = load <2 x double>, ptr %98, align 8, !tbaa !9
  store <2 x double> %100, ptr %96, align 8, !tbaa !9
  store <2 x double> %99, ptr %98, align 8, !tbaa !9
  %101 = add nsw i32 %95, %62
  %102 = getelementptr [8 x i8], ptr %65, i64 %94
  %103 = sext i32 %101 to i64
  %104 = getelementptr inbounds [8 x i8], ptr %2, i64 %103
  %105 = load <2 x double>, ptr %102, align 8, !tbaa !9
  %106 = load <2 x double>, ptr %104, align 8, !tbaa !9
  store <2 x double> %106, ptr %102, align 8, !tbaa !9
  store <2 x double> %105, ptr %104, align 8, !tbaa !9
  %107 = add nuw nsw i64 %76, 1
  %108 = icmp eq i64 %107, %67
  br i1 %108, label %109, label %75, !llvm.loop !41

109:                                              ; preds = %75, %66
  %110 = phi i32 [ 0, %66 ], [ %71, %75 ]
  %111 = trunc i64 %67 to i32
  %112 = add i32 %60, %111
  %113 = shl i32 %112, 1
  %114 = add nsw i32 %110, %113
  %115 = add nsw i32 %114, %61
  %116 = sext i32 %114 to i64
  %117 = getelementptr inbounds [8 x i8], ptr %2, i64 %116
  %118 = sext i32 %115 to i64
  %119 = getelementptr inbounds [8 x i8], ptr %2, i64 %118
  %120 = load <2 x double>, ptr %117, align 8, !tbaa !9
  %121 = load <2 x double>, ptr %119, align 8, !tbaa !9
  store <2 x double> %121, ptr %117, align 8, !tbaa !9
  store <2 x double> %120, ptr %119, align 8, !tbaa !9
  %122 = add nuw nsw i64 %67, 1
  %123 = icmp eq i64 %122, %64
  br i1 %123, label %154, label %66, !llvm.loop !42

124:                                              ; preds = %53, %151
  %125 = phi i64 [ 1, %53 ], [ %152, %151 ]
  %126 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %125
  %127 = load i32, ptr %126, align 4, !tbaa !25
  %128 = sext i32 %127 to i64
  %129 = trunc i64 %125 to i32
  %130 = shl i32 %129, 1
  br label %131

131:                                              ; preds = %124, %131
  %132 = phi i64 [ 0, %124 ], [ %149, %131 ]
  %133 = shl nuw nsw i64 %132, 1
  %134 = add nsw i64 %133, %128
  %135 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %132
  %136 = load i32, ptr %135, align 4, !tbaa !25
  %137 = add nsw i32 %136, %130
  %138 = getelementptr inbounds [8 x i8], ptr %2, i64 %134
  %139 = sext i32 %137 to i64
  %140 = getelementptr inbounds [8 x i8], ptr %2, i64 %139
  %141 = load <2 x double>, ptr %138, align 8, !tbaa !9
  %142 = load <2 x double>, ptr %140, align 8, !tbaa !9
  store <2 x double> %142, ptr %138, align 8, !tbaa !9
  store <2 x double> %141, ptr %140, align 8, !tbaa !9
  %143 = add nsw i32 %137, %47
  %144 = getelementptr [8 x i8], ptr %56, i64 %134
  %145 = sext i32 %143 to i64
  %146 = getelementptr inbounds [8 x i8], ptr %2, i64 %145
  %147 = load <2 x double>, ptr %144, align 8, !tbaa !9
  %148 = load <2 x double>, ptr %146, align 8, !tbaa !9
  store <2 x double> %148, ptr %144, align 8, !tbaa !9
  store <2 x double> %147, ptr %146, align 8, !tbaa !9
  %149 = add nuw nsw i64 %132, 1
  %150 = icmp eq i64 %149, %125
  br i1 %150, label %151, label %131, !llvm.loop !43

151:                                              ; preds = %131
  %152 = add nuw nsw i64 %125, 1
  %153 = icmp eq i64 %152, %55
  br i1 %153, label %154, label %124, !llvm.loop !44

154:                                              ; preds = %151, %109, %49, %51, %57
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define internal fastcc void @cftfsub(i32 noundef range(i32 4, -2147483648) %0, ptr nofree noundef captures(none) %1, ptr nofree noundef readonly captures(none) %2) unnamed_addr #6 {
  %4 = icmp samesign ugt i32 %0, 8
  br i1 %4, label %5, label %12

5:                                                ; preds = %3
  tail call fastcc void @cft1st(i32 noundef %0, ptr noundef %1, ptr noundef %2)
  %6 = icmp samesign ugt i32 %0, 32
  br i1 %6, label %7, label %12

7:                                                ; preds = %5, %7
  %8 = phi i32 [ %10, %7 ], [ 32, %5 ]
  %9 = phi i32 [ %8, %7 ], [ 8, %5 ]
  tail call fastcc void @cftmdl(i32 noundef %0, i32 noundef %9, ptr noundef %1, ptr noundef %2)
  %10 = shl i32 %8, 2
  %11 = icmp slt i32 %10, %0
  br i1 %11, label %7, label %12, !llvm.loop !45

12:                                               ; preds = %7, %5, %3
  %13 = phi i32 [ 2, %3 ], [ 8, %5 ], [ %8, %7 ]
  %14 = shl i32 %13, 2
  %15 = icmp eq i32 %14, %0
  %16 = icmp sgt i32 %13, 0
  br i1 %15, label %74, label %17

17:                                               ; preds = %12
  br i1 %16, label %18, label %325

18:                                               ; preds = %17
  %19 = zext nneg i32 %13 to i64
  %20 = zext nneg i32 %13 to i64
  %21 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %19
  %22 = add nsw i64 %20, -2
  %23 = lshr exact i64 %22, 1
  %24 = icmp ult i64 %22, 38
  br i1 %24, label %25, label %26

25:                                               ; preds = %26, %18
  br label %315

26:                                               ; preds = %18
  %27 = shl nuw nsw i64 %20, 3
  %28 = getelementptr i8, ptr %1, i64 %27
  %29 = getelementptr i8, ptr %28, i64 -8
  %30 = getelementptr i8, ptr %1, i64 8
  %31 = getelementptr i8, ptr %1, i64 %27
  %32 = shl nuw nsw i64 %20, 3
  %33 = getelementptr i8, ptr %1, i64 %27
  %34 = getelementptr i8, ptr %33, i64 %32
  %35 = getelementptr i8, ptr %34, i64 -8
  %36 = getelementptr i8, ptr %1, i64 %32
  %37 = getelementptr i8, ptr %36, i64 8
  %38 = shl nuw nsw i64 %20, 4
  %39 = getelementptr i8, ptr %1, i64 %38
  %40 = icmp ult ptr %1, %31
  %41 = icmp ult ptr %30, %29
  %42 = and i1 %40, %41
  %43 = icmp ult ptr %1, %35
  %44 = icmp ult ptr %21, %29
  %45 = and i1 %43, %44
  %46 = or i1 %42, %45
  %47 = icmp ult ptr %1, %39
  %48 = icmp ult ptr %37, %29
  %49 = and i1 %47, %48
  %50 = or i1 %46, %49
  %51 = icmp ult ptr %30, %35
  %52 = icmp ult ptr %21, %31
  %53 = and i1 %51, %52
  %54 = or i1 %50, %53
  %55 = icmp ult ptr %30, %39
  %56 = icmp ult ptr %37, %31
  %57 = and i1 %55, %56
  %58 = or i1 %54, %57
  %59 = icmp ult ptr %21, %39
  %60 = icmp ult ptr %37, %35
  %61 = and i1 %59, %60
  %62 = or i1 %58, %61
  br i1 %62, label %25, label %63

63:                                               ; preds = %26, %63
  %64 = phi i64 [ %72, %63 ], [ 0, %26 ]
  %65 = shl i64 %64, 1
  %66 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %65
  %67 = load <2 x double>, ptr %66, align 8, !tbaa !9
  %68 = getelementptr inbounds nuw [8 x i8], ptr %21, i64 %65
  %69 = load <2 x double>, ptr %68, align 8, !tbaa !9
  %70 = fsub <2 x double> %67, %69
  %71 = fadd <2 x double> %67, %69
  store <2 x double> %71, ptr %66, align 8, !tbaa !9
  store <2 x double> %70, ptr %68, align 8, !tbaa !9
  %72 = add nuw i64 %64, 1
  %73 = icmp eq i64 %64, %23
  br i1 %73, label %325, label %63, !llvm.loop !46

74:                                               ; preds = %12
  br i1 %16, label %75, label %325

75:                                               ; preds = %74
  %76 = zext nneg i32 %13 to i64
  %77 = zext nneg i32 %13 to i64
  %78 = getelementptr [8 x i8], ptr %1, i64 %76
  %79 = add nsw i64 %77, -2
  %80 = lshr exact i64 %79, 1
  %81 = add nuw i64 %80, 1
  %82 = icmp ult i64 %79, 50
  br i1 %82, label %275, label %83

83:                                               ; preds = %75
  %84 = shl nuw nsw i64 %77, 3
  %85 = add nsw i64 %84, -16
  %86 = getelementptr i8, ptr %1, i64 %84
  %87 = getelementptr i8, ptr %86, i64 -8
  %88 = getelementptr i8, ptr %1, i64 8
  %89 = getelementptr i8, ptr %1, i64 %84
  %90 = shl nuw nsw i64 %77, 4
  %91 = getelementptr i8, ptr %1, i64 %90
  %92 = getelementptr i8, ptr %1, i64 %85
  %93 = getelementptr i8, ptr %92, i64 %90
  %94 = getelementptr i8, ptr %93, i64 8
  %95 = getelementptr i8, ptr %1, i64 %90
  %96 = getelementptr i8, ptr %95, i64 8
  %97 = mul nuw nsw i64 %77, 24
  %98 = getelementptr i8, ptr %1, i64 %97
  %99 = shl nuw nsw i64 %77, 3
  %100 = getelementptr i8, ptr %1, i64 %85
  %101 = getelementptr i8, ptr %100, i64 %99
  %102 = getelementptr i8, ptr %101, i64 8
  %103 = getelementptr i8, ptr %1, i64 %99
  %104 = getelementptr i8, ptr %103, i64 8
  %105 = shl nuw nsw i64 %77, 4
  %106 = getelementptr i8, ptr %1, i64 %105
  %107 = mul nuw nsw i64 %77, 24
  %108 = getelementptr i8, ptr %1, i64 %107
  %109 = getelementptr i8, ptr %1, i64 %107
  %110 = getelementptr i8, ptr %109, i64 %85
  %111 = getelementptr i8, ptr %110, i64 8
  %112 = getelementptr i8, ptr %1, i64 %107
  %113 = getelementptr i8, ptr %112, i64 8
  %114 = shl nuw nsw i64 %77, 5
  %115 = getelementptr i8, ptr %1, i64 %114
  %116 = icmp ult ptr %1, %89
  %117 = icmp ult ptr %88, %87
  %118 = and i1 %116, %117
  %119 = icmp ult ptr %1, %94
  %120 = icmp ult ptr %91, %87
  %121 = and i1 %119, %120
  %122 = or i1 %118, %121
  %123 = icmp ult ptr %1, %98
  %124 = icmp ult ptr %96, %87
  %125 = and i1 %123, %124
  %126 = or i1 %122, %125
  %127 = icmp ult ptr %1, %102
  %128 = icmp ult ptr %78, %87
  %129 = and i1 %127, %128
  %130 = or i1 %126, %129
  %131 = icmp ult ptr %1, %106
  %132 = icmp ult ptr %104, %87
  %133 = and i1 %131, %132
  %134 = or i1 %130, %133
  %135 = icmp ult ptr %1, %111
  %136 = icmp ult ptr %108, %87
  %137 = and i1 %135, %136
  %138 = or i1 %134, %137
  %139 = icmp ult ptr %1, %115
  %140 = icmp ult ptr %113, %87
  %141 = and i1 %139, %140
  %142 = or i1 %138, %141
  %143 = icmp ult ptr %88, %94
  %144 = icmp ult ptr %91, %89
  %145 = and i1 %143, %144
  %146 = or i1 %142, %145
  %147 = icmp ult ptr %88, %98
  %148 = icmp ult ptr %96, %89
  %149 = and i1 %147, %148
  %150 = or i1 %146, %149
  %151 = icmp ult ptr %88, %102
  %152 = icmp ult ptr %78, %89
  %153 = and i1 %151, %152
  %154 = or i1 %150, %153
  %155 = icmp ult ptr %88, %106
  %156 = icmp ult ptr %104, %89
  %157 = and i1 %155, %156
  %158 = or i1 %154, %157
  %159 = icmp ult ptr %88, %111
  %160 = icmp ult ptr %108, %89
  %161 = and i1 %159, %160
  %162 = or i1 %158, %161
  %163 = icmp ult ptr %88, %115
  %164 = icmp ult ptr %113, %89
  %165 = and i1 %163, %164
  %166 = or i1 %162, %165
  %167 = icmp ult ptr %91, %98
  %168 = icmp ult ptr %96, %94
  %169 = and i1 %167, %168
  %170 = or i1 %166, %169
  %171 = icmp ult ptr %91, %102
  %172 = icmp ult ptr %78, %94
  %173 = and i1 %171, %172
  %174 = or i1 %170, %173
  %175 = icmp ult ptr %91, %106
  %176 = icmp ult ptr %104, %94
  %177 = and i1 %175, %176
  %178 = or i1 %174, %177
  %179 = icmp ult ptr %91, %111
  %180 = icmp ult ptr %108, %94
  %181 = and i1 %179, %180
  %182 = or i1 %178, %181
  %183 = icmp ult ptr %91, %115
  %184 = icmp ult ptr %113, %94
  %185 = and i1 %183, %184
  %186 = or i1 %182, %185
  %187 = icmp ult ptr %96, %102
  %188 = icmp ult ptr %78, %98
  %189 = and i1 %187, %188
  %190 = or i1 %186, %189
  %191 = icmp ult ptr %96, %106
  %192 = icmp ult ptr %104, %98
  %193 = and i1 %191, %192
  %194 = or i1 %190, %193
  %195 = icmp ult ptr %96, %111
  %196 = icmp ult ptr %108, %98
  %197 = and i1 %195, %196
  %198 = or i1 %194, %197
  %199 = icmp ult ptr %96, %115
  %200 = icmp ult ptr %113, %98
  %201 = and i1 %199, %200
  %202 = or i1 %198, %201
  %203 = icmp ult ptr %78, %106
  %204 = icmp ult ptr %104, %102
  %205 = and i1 %203, %204
  %206 = or i1 %202, %205
  %207 = icmp ult ptr %78, %111
  %208 = icmp ult ptr %108, %102
  %209 = and i1 %207, %208
  %210 = or i1 %206, %209
  %211 = icmp ult ptr %78, %115
  %212 = icmp ult ptr %113, %102
  %213 = and i1 %211, %212
  %214 = or i1 %210, %213
  %215 = icmp ult ptr %104, %111
  %216 = icmp ult ptr %108, %106
  %217 = and i1 %215, %216
  %218 = or i1 %214, %217
  %219 = icmp ult ptr %104, %115
  %220 = icmp ult ptr %113, %106
  %221 = and i1 %219, %220
  %222 = or i1 %218, %221
  %223 = icmp ult ptr %108, %115
  %224 = icmp ult ptr %113, %111
  %225 = and i1 %223, %224
  %226 = or i1 %222, %225
  br i1 %226, label %275, label %227

227:                                              ; preds = %83
  %228 = and i64 %81, -2
  %229 = shl i64 %228, 1
  br label %230

230:                                              ; preds = %230, %227
  %231 = phi i64 [ 0, %227 ], [ %271, %230 ]
  %232 = shl i64 %231, 1
  %233 = add nuw nsw i64 %232, %76
  %234 = add nuw nsw i64 %233, %76
  %235 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %232
  %236 = load <4 x double>, ptr %235, align 8, !tbaa !9
  %237 = shufflevector <4 x double> %236, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %238 = shufflevector <4 x double> %236, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %239 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %233
  %240 = load <4 x double>, ptr %239, align 8, !tbaa !9
  %241 = shufflevector <4 x double> %240, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %242 = shufflevector <4 x double> %240, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %243 = fadd <2 x double> %237, %241
  %244 = fadd <2 x double> %238, %242
  %245 = fsub <2 x double> %237, %241
  %246 = fsub <2 x double> %238, %242
  %247 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %234
  %248 = load <4 x double>, ptr %247, align 8, !tbaa !9
  %249 = shufflevector <4 x double> %248, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %250 = shufflevector <4 x double> %248, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %251 = getelementptr inbounds nuw [8 x i8], ptr %78, i64 %234
  %252 = load <4 x double>, ptr %251, align 8, !tbaa !9
  %253 = shufflevector <4 x double> %252, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %254 = shufflevector <4 x double> %252, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %255 = fadd <2 x double> %249, %253
  %256 = fadd <2 x double> %250, %254
  %257 = fsub <2 x double> %249, %253
  %258 = fsub <2 x double> %250, %254
  %259 = fadd <2 x double> %243, %255
  %260 = fadd <2 x double> %244, %256
  %261 = shufflevector <2 x double> %259, <2 x double> %260, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %261, ptr %235, align 8, !tbaa !9
  %262 = fsub <2 x double> %243, %255
  %263 = fsub <2 x double> %244, %256
  %264 = shufflevector <2 x double> %262, <2 x double> %263, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %264, ptr %247, align 8, !tbaa !9
  %265 = fsub <2 x double> %245, %258
  %266 = fadd <2 x double> %246, %257
  %267 = shufflevector <2 x double> %265, <2 x double> %266, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %267, ptr %239, align 8, !tbaa !9
  %268 = fadd <2 x double> %245, %258
  %269 = fsub <2 x double> %246, %257
  %270 = shufflevector <2 x double> %268, <2 x double> %269, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %270, ptr %251, align 8, !tbaa !9
  %271 = add nuw i64 %231, 2
  %272 = icmp eq i64 %271, %228
  br i1 %272, label %273, label %230, !llvm.loop !47

273:                                              ; preds = %230
  %274 = icmp eq i64 %81, %228
  br i1 %274, label %325, label %275

275:                                              ; preds = %83, %75, %273
  %276 = phi i64 [ 0, %83 ], [ 0, %75 ], [ %229, %273 ]
  br label %277

277:                                              ; preds = %275, %277
  %278 = phi i64 [ %313, %277 ], [ %276, %275 ]
  %279 = add nuw nsw i64 %278, %76
  %280 = add nuw nsw i64 %279, %76
  %281 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %278
  %282 = load double, ptr %281, align 8, !tbaa !9
  %283 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %279
  %284 = load double, ptr %283, align 8, !tbaa !9
  %285 = fadd double %282, %284
  %286 = getelementptr inbounds nuw i8, ptr %281, i64 8
  %287 = load double, ptr %286, align 8, !tbaa !9
  %288 = getelementptr i8, ptr %283, i64 8
  %289 = load double, ptr %288, align 8, !tbaa !9
  %290 = fadd double %287, %289
  %291 = fsub double %282, %284
  %292 = fsub double %287, %289
  %293 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %280
  %294 = load double, ptr %293, align 8, !tbaa !9
  %295 = getelementptr inbounds nuw [8 x i8], ptr %78, i64 %280
  %296 = load double, ptr %295, align 8, !tbaa !9
  %297 = fadd double %294, %296
  %298 = getelementptr i8, ptr %293, i64 8
  %299 = load double, ptr %298, align 8, !tbaa !9
  %300 = getelementptr i8, ptr %295, i64 8
  %301 = load double, ptr %300, align 8, !tbaa !9
  %302 = fadd double %299, %301
  %303 = fsub double %294, %296
  %304 = fsub double %299, %301
  %305 = fadd double %285, %297
  store double %305, ptr %281, align 8, !tbaa !9
  %306 = fadd double %290, %302
  store double %306, ptr %286, align 8, !tbaa !9
  %307 = fsub double %285, %297
  store double %307, ptr %293, align 8, !tbaa !9
  %308 = fsub double %290, %302
  store double %308, ptr %298, align 8, !tbaa !9
  %309 = fsub double %291, %304
  store double %309, ptr %283, align 8, !tbaa !9
  %310 = fadd double %292, %303
  store double %310, ptr %288, align 8, !tbaa !9
  %311 = fadd double %291, %304
  store double %311, ptr %295, align 8, !tbaa !9
  %312 = fsub double %292, %303
  store double %312, ptr %300, align 8, !tbaa !9
  %313 = add nuw nsw i64 %278, 2
  %314 = icmp samesign ult i64 %313, %77
  br i1 %314, label %277, label %325, !llvm.loop !48

315:                                              ; preds = %25, %315
  %316 = phi i64 [ %323, %315 ], [ 0, %25 ]
  %317 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %316
  %318 = getelementptr inbounds nuw [8 x i8], ptr %21, i64 %316
  %319 = load <2 x double>, ptr %317, align 8, !tbaa !9
  %320 = load <2 x double>, ptr %318, align 8, !tbaa !9
  %321 = fadd <2 x double> %319, %320
  store <2 x double> %321, ptr %317, align 8, !tbaa !9
  %322 = fsub <2 x double> %319, %320
  store <2 x double> %322, ptr %318, align 8, !tbaa !9
  %323 = add nuw nsw i64 %316, 2
  %324 = icmp samesign ult i64 %323, %20
  br i1 %324, label %315, label %325, !llvm.loop !49

325:                                              ; preds = %63, %315, %277, %273, %17, %74
  ret void
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @cos(double noundef) local_unnamed_addr #13

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @sin(double noundef) local_unnamed_addr #13

; Function Attrs: inlinehint nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define internal fastcc void @cft1st(i32 noundef range(i32 9, -2147483648) %0, ptr nofree noundef captures(none) %1, ptr nofree noundef readonly captures(none) %2) unnamed_addr #14 {
  %4 = load double, ptr %1, align 8, !tbaa !9
  %5 = getelementptr inbounds nuw i8, ptr %1, i64 16
  %6 = load double, ptr %5, align 8, !tbaa !9
  %7 = fadd double %4, %6
  %8 = getelementptr inbounds nuw i8, ptr %1, i64 8
  %9 = load double, ptr %8, align 8, !tbaa !9
  %10 = getelementptr inbounds nuw i8, ptr %1, i64 24
  %11 = load double, ptr %10, align 8, !tbaa !9
  %12 = fadd double %9, %11
  %13 = fsub double %4, %6
  %14 = fsub double %9, %11
  %15 = getelementptr inbounds nuw i8, ptr %1, i64 32
  %16 = load double, ptr %15, align 8, !tbaa !9
  %17 = getelementptr inbounds nuw i8, ptr %1, i64 48
  %18 = load double, ptr %17, align 8, !tbaa !9
  %19 = fadd double %16, %18
  %20 = getelementptr inbounds nuw i8, ptr %1, i64 40
  %21 = load double, ptr %20, align 8, !tbaa !9
  %22 = getelementptr inbounds nuw i8, ptr %1, i64 56
  %23 = load double, ptr %22, align 8, !tbaa !9
  %24 = fadd double %21, %23
  %25 = fsub double %16, %18
  %26 = fsub double %21, %23
  %27 = fadd double %7, %19
  store double %27, ptr %1, align 8, !tbaa !9
  %28 = fadd double %12, %24
  store double %28, ptr %8, align 8, !tbaa !9
  %29 = fsub double %7, %19
  store double %29, ptr %15, align 8, !tbaa !9
  %30 = fsub double %12, %24
  store double %30, ptr %20, align 8, !tbaa !9
  %31 = fsub double %13, %26
  store double %31, ptr %5, align 8, !tbaa !9
  %32 = fadd double %14, %25
  store double %32, ptr %10, align 8, !tbaa !9
  %33 = fadd double %13, %26
  store double %33, ptr %17, align 8, !tbaa !9
  %34 = fsub double %14, %25
  store double %34, ptr %22, align 8, !tbaa !9
  %35 = getelementptr inbounds nuw i8, ptr %2, i64 16
  %36 = load double, ptr %35, align 8, !tbaa !9
  %37 = getelementptr inbounds nuw i8, ptr %1, i64 64
  %38 = load double, ptr %37, align 8, !tbaa !9
  %39 = getelementptr inbounds nuw i8, ptr %1, i64 80
  %40 = load double, ptr %39, align 8, !tbaa !9
  %41 = fadd double %38, %40
  %42 = getelementptr inbounds nuw i8, ptr %1, i64 72
  %43 = load double, ptr %42, align 8, !tbaa !9
  %44 = getelementptr inbounds nuw i8, ptr %1, i64 88
  %45 = load double, ptr %44, align 8, !tbaa !9
  %46 = fadd double %43, %45
  %47 = fsub double %38, %40
  %48 = fsub double %43, %45
  %49 = getelementptr inbounds nuw i8, ptr %1, i64 96
  %50 = load double, ptr %49, align 8, !tbaa !9
  %51 = getelementptr inbounds nuw i8, ptr %1, i64 112
  %52 = load double, ptr %51, align 8, !tbaa !9
  %53 = fadd double %50, %52
  %54 = getelementptr inbounds nuw i8, ptr %1, i64 104
  %55 = load double, ptr %54, align 8, !tbaa !9
  %56 = getelementptr inbounds nuw i8, ptr %1, i64 120
  %57 = load double, ptr %56, align 8, !tbaa !9
  %58 = fadd double %55, %57
  %59 = fsub double %50, %52
  %60 = fsub double %55, %57
  %61 = fadd double %41, %53
  store double %61, ptr %37, align 8, !tbaa !9
  %62 = fadd double %46, %58
  store double %62, ptr %42, align 8, !tbaa !9
  %63 = fsub double %58, %46
  store double %63, ptr %49, align 8, !tbaa !9
  %64 = fsub double %41, %53
  store double %64, ptr %54, align 8, !tbaa !9
  %65 = fsub double %47, %60
  %66 = fadd double %48, %59
  %67 = fsub double %65, %66
  %68 = fmul double %36, %67
  store double %68, ptr %39, align 8, !tbaa !9
  %69 = fadd double %66, %65
  %70 = fmul double %36, %69
  store double %70, ptr %44, align 8, !tbaa !9
  %71 = fadd double %47, %60
  %72 = fsub double %59, %48
  %73 = fsub double %72, %71
  %74 = fmul double %36, %73
  store double %74, ptr %51, align 8, !tbaa !9
  %75 = fadd double %72, %71
  %76 = fmul double %36, %75
  store double %76, ptr %56, align 8, !tbaa !9
  %77 = icmp samesign ugt i32 %0, 16
  br i1 %77, label %78, label %464

78:                                               ; preds = %3
  %79 = zext nneg i32 %0 to i64
  %80 = add nsw i64 %79, -17
  %81 = lshr i64 %80, 4
  %82 = add nuw nsw i64 %81, 1
  %83 = icmp eq i64 %81, 0
  br i1 %83, label %346, label %84

84:                                               ; preds = %78
  %85 = getelementptr i8, ptr %1, i64 128
  %86 = add nsw i64 %79, -17
  %87 = lshr i64 %86, 4
  %88 = shl i64 %87, 7
  %89 = getelementptr i8, ptr %1, i64 %88
  %90 = getelementptr i8, ptr %89, i64 256
  %91 = getelementptr i8, ptr %2, i64 32
  %92 = shl i64 %87, 5
  %93 = getelementptr i8, ptr %2, i64 %92
  %94 = getelementptr i8, ptr %93, i64 64
  %95 = getelementptr i8, ptr %2, i64 16
  %96 = and i64 %86, -16
  %97 = getelementptr i8, ptr %2, i64 %96
  %98 = getelementptr i8, ptr %97, i64 32
  %99 = icmp ult ptr %85, %94
  %100 = icmp ult ptr %91, %90
  %101 = and i1 %99, %100
  %102 = icmp ult ptr %85, %98
  %103 = icmp ult ptr %95, %90
  %104 = and i1 %102, %103
  %105 = or i1 %101, %104
  br i1 %105, label %346, label %106

106:                                              ; preds = %84
  %107 = and i64 %82, 2305843009213693950
  %108 = shl nuw nsw i64 %107, 1
  %109 = shl i64 %82, 4
  %110 = or i64 %109, 16
  br label %111

111:                                              ; preds = %111, %106
  %112 = phi i64 [ 0, %106 ], [ %342, %111 ]
  %113 = shl i64 %112, 1
  %114 = shl i64 %112, 4
  %115 = or disjoint i64 %113, 2
  %116 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %115
  %117 = load <4 x double>, ptr %116, align 8, !tbaa !9, !alias.scope !50
  %118 = shufflevector <4 x double> %117, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %119 = shufflevector <4 x double> %117, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %120 = shl nuw nsw i64 %115, 4
  %121 = shl i64 %112, 5
  %122 = getelementptr inbounds nuw i8, ptr %2, i64 %120
  %123 = getelementptr i8, ptr %2, i64 %121
  %124 = getelementptr i8, ptr %123, i64 64
  %125 = load double, ptr %122, align 8, !tbaa !9, !alias.scope !53
  %126 = load double, ptr %124, align 8, !tbaa !9, !alias.scope !53
  %127 = insertelement <2 x double> poison, double %125, i64 0
  %128 = insertelement <2 x double> %127, double %126, i64 1
  %129 = getelementptr inbounds nuw i8, ptr %122, i64 8
  %130 = getelementptr i8, ptr %123, i64 72
  %131 = load double, ptr %129, align 8, !tbaa !9, !alias.scope !53
  %132 = load double, ptr %130, align 8, !tbaa !9, !alias.scope !53
  %133 = insertelement <2 x double> poison, double %131, i64 0
  %134 = insertelement <2 x double> %133, double %132, i64 1
  %135 = fmul <2 x double> %119, splat (double 2.000000e+00)
  %136 = fneg <2 x double> %135
  %137 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %136, <2 x double> %134, <2 x double> %128)
  %138 = fneg <2 x double> %134
  %139 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %135, <2 x double> %128, <2 x double> %138)
  %140 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %114
  %141 = getelementptr inbounds nuw i8, ptr %140, i64 128
  %142 = getelementptr [8 x i8], ptr %1, i64 %114
  %143 = getelementptr i8, ptr %142, i64 256
  %144 = load double, ptr %141, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %145 = load double, ptr %143, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %146 = insertelement <2 x double> poison, double %144, i64 0
  %147 = insertelement <2 x double> %146, double %145, i64 1
  %148 = getelementptr inbounds nuw i8, ptr %140, i64 144
  %149 = getelementptr i8, ptr %142, i64 272
  %150 = load double, ptr %148, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %151 = load double, ptr %149, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %152 = insertelement <2 x double> poison, double %150, i64 0
  %153 = insertelement <2 x double> %152, double %151, i64 1
  %154 = fadd <2 x double> %147, %153
  %155 = getelementptr inbounds nuw i8, ptr %140, i64 136
  %156 = getelementptr i8, ptr %142, i64 264
  %157 = load double, ptr %155, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %158 = load double, ptr %156, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %159 = insertelement <2 x double> poison, double %157, i64 0
  %160 = insertelement <2 x double> %159, double %158, i64 1
  %161 = getelementptr inbounds nuw i8, ptr %140, i64 152
  %162 = getelementptr i8, ptr %142, i64 280
  %163 = load double, ptr %161, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %164 = load double, ptr %162, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %165 = insertelement <2 x double> poison, double %163, i64 0
  %166 = insertelement <2 x double> %165, double %164, i64 1
  %167 = fadd <2 x double> %160, %166
  %168 = fsub <2 x double> %147, %153
  %169 = fsub <2 x double> %160, %166
  %170 = getelementptr inbounds nuw i8, ptr %140, i64 160
  %171 = getelementptr i8, ptr %142, i64 288
  %172 = load double, ptr %170, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %173 = load double, ptr %171, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %174 = insertelement <2 x double> poison, double %172, i64 0
  %175 = insertelement <2 x double> %174, double %173, i64 1
  %176 = getelementptr inbounds nuw i8, ptr %140, i64 176
  %177 = getelementptr i8, ptr %142, i64 304
  %178 = load double, ptr %176, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %179 = load double, ptr %177, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %180 = insertelement <2 x double> poison, double %178, i64 0
  %181 = insertelement <2 x double> %180, double %179, i64 1
  %182 = fadd <2 x double> %175, %181
  %183 = getelementptr inbounds nuw i8, ptr %140, i64 168
  %184 = getelementptr i8, ptr %142, i64 296
  %185 = load double, ptr %183, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %186 = load double, ptr %184, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %187 = insertelement <2 x double> poison, double %185, i64 0
  %188 = insertelement <2 x double> %187, double %186, i64 1
  %189 = getelementptr inbounds nuw i8, ptr %140, i64 184
  %190 = getelementptr i8, ptr %142, i64 312
  %191 = load double, ptr %189, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %192 = load double, ptr %190, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %193 = insertelement <2 x double> poison, double %191, i64 0
  %194 = insertelement <2 x double> %193, double %192, i64 1
  %195 = fadd <2 x double> %188, %194
  %196 = fsub <2 x double> %175, %181
  %197 = fsub <2 x double> %188, %194
  %198 = fadd <2 x double> %154, %182
  %199 = extractelement <2 x double> %198, i64 0
  store double %199, ptr %141, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %200 = fadd <2 x double> %167, %195
  %201 = extractelement <2 x double> %200, i64 0
  store double %201, ptr %155, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %202 = fsub <2 x double> %154, %182
  %203 = fsub <2 x double> %167, %195
  %204 = fneg <2 x double> %203
  %205 = fmul <2 x double> %119, %204
  %206 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %118, <2 x double> %202, <2 x double> %205)
  %207 = extractelement <2 x double> %206, i64 0
  store double %207, ptr %170, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %208 = fmul <2 x double> %119, %202
  %209 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %118, <2 x double> %203, <2 x double> %208)
  %210 = extractelement <2 x double> %209, i64 0
  store double %210, ptr %183, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %211 = fsub <2 x double> %168, %197
  %212 = fadd <2 x double> %169, %196
  %213 = fneg <2 x double> %212
  %214 = fmul <2 x double> %134, %213
  %215 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %128, <2 x double> %211, <2 x double> %214)
  %216 = extractelement <2 x double> %215, i64 0
  store double %216, ptr %148, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %217 = shufflevector <2 x double> %200, <2 x double> %215, <2 x i32> <i32 1, i32 3>
  store <2 x double> %217, ptr %156, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %218 = fmul <2 x double> %134, %211
  %219 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %128, <2 x double> %212, <2 x double> %218)
  %220 = extractelement <2 x double> %219, i64 0
  store double %220, ptr %161, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %221 = shufflevector <2 x double> %219, <2 x double> %206, <2 x i32> <i32 1, i32 3>
  store <2 x double> %221, ptr %162, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %222 = fadd <2 x double> %168, %197
  %223 = fsub <2 x double> %169, %196
  %224 = fneg <2 x double> %223
  %225 = fmul <2 x double> %139, %224
  %226 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %137, <2 x double> %222, <2 x double> %225)
  %227 = extractelement <2 x double> %226, i64 0
  store double %227, ptr %176, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %228 = shufflevector <2 x double> %209, <2 x double> %226, <2 x i32> <i32 1, i32 3>
  store <2 x double> %228, ptr %184, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %229 = fmul <2 x double> %139, %222
  %230 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %137, <2 x double> %223, <2 x double> %229)
  %231 = extractelement <2 x double> %230, i64 0
  store double %231, ptr %189, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %232 = getelementptr inbounds nuw i8, ptr %122, i64 16
  %233 = getelementptr i8, ptr %123, i64 80
  %234 = load double, ptr %232, align 8, !tbaa !9, !alias.scope !53
  %235 = load double, ptr %233, align 8, !tbaa !9, !alias.scope !53
  %236 = insertelement <2 x double> poison, double %234, i64 0
  %237 = insertelement <2 x double> %236, double %235, i64 1
  %238 = getelementptr inbounds nuw i8, ptr %122, i64 24
  %239 = getelementptr i8, ptr %123, i64 88
  %240 = load double, ptr %238, align 8, !tbaa !9, !alias.scope !53
  %241 = load double, ptr %239, align 8, !tbaa !9, !alias.scope !53
  %242 = insertelement <2 x double> poison, double %240, i64 0
  %243 = insertelement <2 x double> %242, double %241, i64 1
  %244 = fmul <2 x double> %118, splat (double 2.000000e+00)
  %245 = fneg <2 x double> %244
  %246 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %245, <2 x double> %243, <2 x double> %237)
  %247 = fneg <2 x double> %243
  %248 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %244, <2 x double> %237, <2 x double> %247)
  %249 = getelementptr inbounds nuw i8, ptr %140, i64 192
  %250 = getelementptr i8, ptr %142, i64 320
  %251 = load double, ptr %249, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %252 = load double, ptr %250, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %253 = insertelement <2 x double> poison, double %251, i64 0
  %254 = insertelement <2 x double> %253, double %252, i64 1
  %255 = getelementptr inbounds nuw i8, ptr %140, i64 208
  %256 = getelementptr i8, ptr %142, i64 336
  %257 = load double, ptr %255, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %258 = load double, ptr %256, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %259 = insertelement <2 x double> poison, double %257, i64 0
  %260 = insertelement <2 x double> %259, double %258, i64 1
  %261 = fadd <2 x double> %254, %260
  %262 = getelementptr inbounds nuw i8, ptr %140, i64 200
  %263 = getelementptr i8, ptr %142, i64 328
  %264 = load double, ptr %262, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %265 = load double, ptr %263, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %266 = insertelement <2 x double> poison, double %264, i64 0
  %267 = insertelement <2 x double> %266, double %265, i64 1
  %268 = getelementptr inbounds nuw i8, ptr %140, i64 216
  %269 = getelementptr i8, ptr %142, i64 344
  %270 = load double, ptr %268, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %271 = load double, ptr %269, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %272 = insertelement <2 x double> poison, double %270, i64 0
  %273 = insertelement <2 x double> %272, double %271, i64 1
  %274 = fadd <2 x double> %267, %273
  %275 = fsub <2 x double> %254, %260
  %276 = fsub <2 x double> %267, %273
  %277 = getelementptr inbounds nuw i8, ptr %140, i64 224
  %278 = getelementptr i8, ptr %142, i64 352
  %279 = load double, ptr %277, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %280 = load double, ptr %278, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %281 = insertelement <2 x double> poison, double %279, i64 0
  %282 = insertelement <2 x double> %281, double %280, i64 1
  %283 = getelementptr inbounds nuw i8, ptr %140, i64 240
  %284 = getelementptr i8, ptr %142, i64 368
  %285 = load double, ptr %283, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %286 = load double, ptr %284, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %287 = insertelement <2 x double> poison, double %285, i64 0
  %288 = insertelement <2 x double> %287, double %286, i64 1
  %289 = fadd <2 x double> %282, %288
  %290 = getelementptr inbounds nuw i8, ptr %140, i64 232
  %291 = getelementptr i8, ptr %142, i64 360
  %292 = load double, ptr %290, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %293 = load double, ptr %291, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %294 = insertelement <2 x double> poison, double %292, i64 0
  %295 = insertelement <2 x double> %294, double %293, i64 1
  %296 = getelementptr inbounds nuw i8, ptr %140, i64 248
  %297 = getelementptr i8, ptr %142, i64 376
  %298 = load double, ptr %296, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %299 = load double, ptr %297, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %300 = insertelement <2 x double> poison, double %298, i64 0
  %301 = insertelement <2 x double> %300, double %299, i64 1
  %302 = fadd <2 x double> %295, %301
  %303 = fsub <2 x double> %282, %288
  %304 = fsub <2 x double> %295, %301
  %305 = fadd <2 x double> %261, %289
  %306 = extractelement <2 x double> %305, i64 0
  store double %306, ptr %249, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %307 = shufflevector <2 x double> %230, <2 x double> %305, <2 x i32> <i32 1, i32 3>
  store <2 x double> %307, ptr %190, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %308 = fadd <2 x double> %274, %302
  %309 = extractelement <2 x double> %308, i64 0
  store double %309, ptr %262, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %310 = fsub <2 x double> %261, %289
  %311 = fsub <2 x double> %274, %302
  %312 = fneg <2 x double> %119
  %313 = fneg <2 x double> %311
  %314 = fmul <2 x double> %118, %313
  %315 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %312, <2 x double> %310, <2 x double> %314)
  %316 = extractelement <2 x double> %315, i64 0
  store double %316, ptr %277, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %317 = fmul <2 x double> %118, %310
  %318 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %312, <2 x double> %311, <2 x double> %317)
  %319 = extractelement <2 x double> %318, i64 0
  store double %319, ptr %290, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %320 = fsub <2 x double> %275, %304
  %321 = fadd <2 x double> %276, %303
  %322 = fneg <2 x double> %321
  %323 = fmul <2 x double> %243, %322
  %324 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %237, <2 x double> %320, <2 x double> %323)
  %325 = extractelement <2 x double> %324, i64 0
  store double %325, ptr %255, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %326 = shufflevector <2 x double> %308, <2 x double> %324, <2 x i32> <i32 1, i32 3>
  store <2 x double> %326, ptr %263, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %327 = fmul <2 x double> %243, %320
  %328 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %237, <2 x double> %321, <2 x double> %327)
  %329 = extractelement <2 x double> %328, i64 0
  store double %329, ptr %268, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %330 = shufflevector <2 x double> %328, <2 x double> %315, <2 x i32> <i32 1, i32 3>
  store <2 x double> %330, ptr %269, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %331 = fadd <2 x double> %275, %304
  %332 = fsub <2 x double> %276, %303
  %333 = fneg <2 x double> %332
  %334 = fmul <2 x double> %248, %333
  %335 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %246, <2 x double> %331, <2 x double> %334)
  %336 = extractelement <2 x double> %335, i64 0
  store double %336, ptr %283, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %337 = shufflevector <2 x double> %318, <2 x double> %335, <2 x i32> <i32 1, i32 3>
  store <2 x double> %337, ptr %291, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %338 = fmul <2 x double> %248, %331
  %339 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %246, <2 x double> %332, <2 x double> %338)
  %340 = shufflevector <2 x double> %339, <2 x double> %198, <2 x i32> <i32 0, i32 3>
  store <2 x double> %340, ptr %296, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %341 = extractelement <2 x double> %339, i64 1
  store double %341, ptr %297, align 8, !tbaa !9, !alias.scope !55, !noalias !57
  %342 = add nuw i64 %112, 2
  %343 = icmp eq i64 %342, %107
  br i1 %343, label %344, label %111, !llvm.loop !58

344:                                              ; preds = %111
  %345 = icmp eq i64 %82, %107
  br i1 %345, label %464, label %346

346:                                              ; preds = %84, %78, %344
  %347 = phi i64 [ 0, %84 ], [ 0, %78 ], [ %108, %344 ]
  %348 = phi i64 [ 16, %84 ], [ 16, %78 ], [ %110, %344 ]
  br label %349

349:                                              ; preds = %346, %349
  %350 = phi i64 [ %352, %349 ], [ %347, %346 ]
  %351 = phi i64 [ %462, %349 ], [ %348, %346 ]
  %352 = add nuw nsw i64 %350, 2
  %353 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %352
  %354 = load double, ptr %353, align 8, !tbaa !9
  %355 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %350
  %356 = getelementptr inbounds nuw i8, ptr %355, i64 24
  %357 = load double, ptr %356, align 8, !tbaa !9
  %358 = shl nuw nsw i64 %352, 4
  %359 = getelementptr inbounds nuw i8, ptr %2, i64 %358
  %360 = fmul double %357, 2.000000e+00
  %361 = fneg double %360
  %362 = load <2 x double>, ptr %359, align 8, !tbaa !9
  %363 = insertelement <2 x double> poison, double %360, i64 0
  %364 = insertelement <2 x double> %363, double %361, i64 1
  %365 = fneg <2 x double> %362
  %366 = shufflevector <2 x double> %365, <2 x double> %362, <2 x i32> <i32 1, i32 2>
  %367 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %364, <2 x double> %362, <2 x double> %366)
  %368 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %351
  %369 = getelementptr inbounds nuw i8, ptr %368, i64 16
  %370 = getelementptr inbounds nuw i8, ptr %368, i64 8
  %371 = getelementptr inbounds nuw i8, ptr %368, i64 32
  %372 = getelementptr inbounds nuw i8, ptr %368, i64 48
  %373 = load <2 x double>, ptr %368, align 8, !tbaa !9
  %374 = load <2 x double>, ptr %369, align 8, !tbaa !9
  %375 = fsub <2 x double> %373, %374
  %376 = load <2 x double>, ptr %371, align 8, !tbaa !9
  %377 = load <2 x double>, ptr %372, align 8, !tbaa !9
  %378 = fsub <2 x double> %376, %377
  %379 = shufflevector <2 x double> %378, <2 x double> poison, <2 x i32> <i32 1, i32 0>
  %380 = fadd <2 x double> %373, %374
  %381 = fadd <2 x double> %376, %377
  %382 = fadd <2 x double> %380, %381
  %383 = extractelement <2 x double> %382, i64 0
  store double %383, ptr %368, align 8, !tbaa !9
  %384 = fadd <2 x double> %380, %381
  %385 = extractelement <2 x double> %384, i64 1
  store double %385, ptr %370, align 8, !tbaa !9
  %386 = fsub <2 x double> %380, %381
  %387 = insertelement <2 x double> poison, double %357, i64 0
  %388 = shufflevector <2 x double> %387, <2 x double> poison, <2 x i32> zeroinitializer
  %389 = fneg <2 x double> %386
  %390 = shufflevector <2 x double> %389, <2 x double> %386, <2 x i32> <i32 1, i32 2>
  %391 = fmul <2 x double> %388, %390
  %392 = insertelement <2 x double> poison, double %354, i64 0
  %393 = shufflevector <2 x double> %392, <2 x double> poison, <2 x i32> zeroinitializer
  %394 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %393, <2 x double> %386, <2 x double> %391)
  store <2 x double> %394, ptr %371, align 8, !tbaa !9
  %395 = fsub <2 x double> %375, %379
  %396 = fadd <2 x double> %375, %379
  %397 = shufflevector <2 x double> %395, <2 x double> %396, <2 x i32> <i32 0, i32 3>
  %398 = shufflevector <2 x double> %362, <2 x double> poison, <2 x i32> <i32 1, i32 1>
  %399 = fneg <2 x double> %397
  %400 = shufflevector <2 x double> %399, <2 x double> %395, <2 x i32> <i32 1, i32 2>
  %401 = fmul <2 x double> %398, %400
  %402 = shufflevector <2 x double> %362, <2 x double> poison, <2 x i32> zeroinitializer
  %403 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %402, <2 x double> %397, <2 x double> %401)
  store <2 x double> %403, ptr %369, align 8, !tbaa !9
  %404 = shufflevector <2 x double> %396, <2 x double> %395, <2 x i32> <i32 0, i32 3>
  %405 = shufflevector <2 x double> %367, <2 x double> poison, <2 x i32> zeroinitializer
  %406 = fneg <2 x double> %404
  %407 = shufflevector <2 x double> %406, <2 x double> %396, <2 x i32> <i32 1, i32 2>
  %408 = fmul <2 x double> %405, %407
  %409 = shufflevector <2 x double> %367, <2 x double> poison, <2 x i32> <i32 1, i32 1>
  %410 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %409, <2 x double> %404, <2 x double> %408)
  store <2 x double> %410, ptr %372, align 8, !tbaa !9
  %411 = getelementptr inbounds nuw i8, ptr %359, i64 16
  %412 = fmul double %354, 2.000000e+00
  %413 = fneg double %412
  %414 = load <2 x double>, ptr %411, align 8, !tbaa !9
  %415 = insertelement <2 x double> poison, double %412, i64 0
  %416 = insertelement <2 x double> %415, double %413, i64 1
  %417 = fneg <2 x double> %414
  %418 = shufflevector <2 x double> %417, <2 x double> %414, <2 x i32> <i32 1, i32 2>
  %419 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %416, <2 x double> %414, <2 x double> %418)
  %420 = getelementptr inbounds nuw i8, ptr %368, i64 64
  %421 = getelementptr inbounds nuw i8, ptr %368, i64 80
  %422 = getelementptr inbounds nuw i8, ptr %368, i64 72
  %423 = getelementptr inbounds nuw i8, ptr %368, i64 96
  %424 = getelementptr inbounds nuw i8, ptr %368, i64 112
  %425 = fneg double %357
  %426 = load <2 x double>, ptr %420, align 8, !tbaa !9
  %427 = load <2 x double>, ptr %421, align 8, !tbaa !9
  %428 = fsub <2 x double> %426, %427
  %429 = load <2 x double>, ptr %423, align 8, !tbaa !9
  %430 = load <2 x double>, ptr %424, align 8, !tbaa !9
  %431 = fsub <2 x double> %429, %430
  %432 = shufflevector <2 x double> %431, <2 x double> poison, <2 x i32> <i32 1, i32 0>
  %433 = fadd <2 x double> %426, %427
  %434 = fadd <2 x double> %429, %430
  %435 = fadd <2 x double> %433, %434
  %436 = extractelement <2 x double> %435, i64 0
  store double %436, ptr %420, align 8, !tbaa !9
  %437 = fadd <2 x double> %433, %434
  %438 = extractelement <2 x double> %437, i64 1
  store double %438, ptr %422, align 8, !tbaa !9
  %439 = fsub <2 x double> %433, %434
  %440 = fneg <2 x double> %439
  %441 = shufflevector <2 x double> %440, <2 x double> %439, <2 x i32> <i32 1, i32 2>
  %442 = fmul <2 x double> %393, %441
  %443 = insertelement <2 x double> poison, double %425, i64 0
  %444 = shufflevector <2 x double> %443, <2 x double> poison, <2 x i32> zeroinitializer
  %445 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %444, <2 x double> %439, <2 x double> %442)
  store <2 x double> %445, ptr %423, align 8, !tbaa !9
  %446 = fsub <2 x double> %428, %432
  %447 = fadd <2 x double> %428, %432
  %448 = shufflevector <2 x double> %446, <2 x double> %447, <2 x i32> <i32 0, i32 3>
  %449 = shufflevector <2 x double> %414, <2 x double> poison, <2 x i32> <i32 1, i32 1>
  %450 = fneg <2 x double> %448
  %451 = shufflevector <2 x double> %450, <2 x double> %446, <2 x i32> <i32 1, i32 2>
  %452 = fmul <2 x double> %449, %451
  %453 = shufflevector <2 x double> %414, <2 x double> poison, <2 x i32> zeroinitializer
  %454 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %453, <2 x double> %448, <2 x double> %452)
  store <2 x double> %454, ptr %421, align 8, !tbaa !9
  %455 = shufflevector <2 x double> %447, <2 x double> %446, <2 x i32> <i32 0, i32 3>
  %456 = shufflevector <2 x double> %419, <2 x double> poison, <2 x i32> zeroinitializer
  %457 = fneg <2 x double> %455
  %458 = shufflevector <2 x double> %457, <2 x double> %447, <2 x i32> <i32 1, i32 2>
  %459 = fmul <2 x double> %456, %458
  %460 = shufflevector <2 x double> %419, <2 x double> poison, <2 x i32> <i32 1, i32 1>
  %461 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %460, <2 x double> %455, <2 x double> %459)
  store <2 x double> %461, ptr %424, align 8, !tbaa !9
  %462 = add nuw nsw i64 %351, 16
  %463 = icmp samesign ult i64 %462, %79
  br i1 %463, label %349, label %464, !llvm.loop !59

464:                                              ; preds = %349, %344, %3
  ret void
}

; Function Attrs: inlinehint nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define internal fastcc void @cftmdl(i32 noundef range(i32 9, -2147483648) %0, i32 noundef %1, ptr nofree noundef captures(none) %2, ptr nofree noundef readonly captures(none) %3) unnamed_addr #14 {
  %5 = shl i32 %1, 2
  %6 = icmp sgt i32 %1, 0
  br i1 %6, label %7, label %249

7:                                                ; preds = %4
  %8 = zext nneg i32 %1 to i64
  %9 = zext nneg i32 %1 to i64
  %10 = getelementptr [8 x i8], ptr %2, i64 %8
  %11 = add nsw i64 %9, -1
  %12 = lshr i64 %11, 1
  %13 = add nuw i64 %12, 1
  %14 = icmp ult i32 %1, 51
  br i1 %14, label %209, label %15

15:                                               ; preds = %7
  %16 = shl nuw nsw i64 %9, 3
  %17 = add nsw i64 %16, -8
  %18 = and i64 %17, -16
  %19 = or i64 %17, 8
  %20 = getelementptr i8, ptr %2, i64 %19
  %21 = getelementptr i8, ptr %2, i64 8
  %22 = getelementptr i8, ptr %2, i64 %18
  %23 = getelementptr i8, ptr %22, i64 16
  %24 = shl nuw nsw i64 %9, 4
  %25 = getelementptr i8, ptr %2, i64 %24
  %26 = add nsw i64 %18, %24
  %27 = getelementptr i8, ptr %2, i64 %26
  %28 = getelementptr i8, ptr %27, i64 8
  %29 = getelementptr i8, ptr %2, i64 %24
  %30 = getelementptr i8, ptr %29, i64 8
  %31 = getelementptr i8, ptr %2, i64 %26
  %32 = getelementptr i8, ptr %31, i64 16
  %33 = shl nuw nsw i64 %9, 3
  %34 = add nsw i64 %18, %33
  %35 = getelementptr i8, ptr %2, i64 %34
  %36 = getelementptr i8, ptr %35, i64 8
  %37 = getelementptr i8, ptr %2, i64 %33
  %38 = getelementptr i8, ptr %37, i64 8
  %39 = getelementptr i8, ptr %2, i64 %34
  %40 = getelementptr i8, ptr %39, i64 16
  %41 = mul nuw nsw i64 %9, 24
  %42 = getelementptr i8, ptr %2, i64 %41
  %43 = add nsw i64 %41, %18
  %44 = getelementptr i8, ptr %2, i64 %43
  %45 = getelementptr i8, ptr %44, i64 8
  %46 = getelementptr i8, ptr %2, i64 %41
  %47 = getelementptr i8, ptr %46, i64 8
  %48 = getelementptr i8, ptr %2, i64 %43
  %49 = getelementptr i8, ptr %48, i64 16
  %50 = icmp ult ptr %2, %23
  %51 = icmp ult ptr %21, %20
  %52 = and i1 %50, %51
  %53 = icmp ult ptr %2, %28
  %54 = icmp ult ptr %25, %20
  %55 = and i1 %53, %54
  %56 = or i1 %52, %55
  %57 = icmp ult ptr %2, %32
  %58 = icmp ult ptr %30, %20
  %59 = and i1 %57, %58
  %60 = or i1 %56, %59
  %61 = icmp ult ptr %2, %36
  %62 = icmp ult ptr %10, %20
  %63 = and i1 %61, %62
  %64 = or i1 %60, %63
  %65 = icmp ult ptr %2, %40
  %66 = icmp ult ptr %38, %20
  %67 = and i1 %65, %66
  %68 = or i1 %64, %67
  %69 = icmp ult ptr %2, %45
  %70 = icmp ult ptr %42, %20
  %71 = and i1 %69, %70
  %72 = or i1 %68, %71
  %73 = icmp ult ptr %2, %49
  %74 = icmp ult ptr %47, %20
  %75 = and i1 %73, %74
  %76 = or i1 %72, %75
  %77 = icmp ult ptr %21, %28
  %78 = icmp ult ptr %25, %23
  %79 = and i1 %77, %78
  %80 = or i1 %76, %79
  %81 = icmp ult ptr %21, %32
  %82 = icmp ult ptr %30, %23
  %83 = and i1 %81, %82
  %84 = or i1 %80, %83
  %85 = icmp ult ptr %21, %36
  %86 = icmp ult ptr %10, %23
  %87 = and i1 %85, %86
  %88 = or i1 %84, %87
  %89 = icmp ult ptr %21, %40
  %90 = icmp ult ptr %38, %23
  %91 = and i1 %89, %90
  %92 = or i1 %88, %91
  %93 = icmp ult ptr %21, %45
  %94 = icmp ult ptr %42, %23
  %95 = and i1 %93, %94
  %96 = or i1 %92, %95
  %97 = icmp ult ptr %21, %49
  %98 = icmp ult ptr %47, %23
  %99 = and i1 %97, %98
  %100 = or i1 %96, %99
  %101 = icmp ult ptr %25, %32
  %102 = icmp ult ptr %30, %28
  %103 = and i1 %101, %102
  %104 = or i1 %100, %103
  %105 = icmp ult ptr %25, %36
  %106 = icmp ult ptr %10, %28
  %107 = and i1 %105, %106
  %108 = or i1 %104, %107
  %109 = icmp ult ptr %25, %40
  %110 = icmp ult ptr %38, %28
  %111 = and i1 %109, %110
  %112 = or i1 %108, %111
  %113 = icmp ult ptr %25, %45
  %114 = icmp ult ptr %42, %28
  %115 = and i1 %113, %114
  %116 = or i1 %112, %115
  %117 = icmp ult ptr %25, %49
  %118 = icmp ult ptr %47, %28
  %119 = and i1 %117, %118
  %120 = or i1 %116, %119
  %121 = icmp ult ptr %30, %36
  %122 = icmp ult ptr %10, %32
  %123 = and i1 %121, %122
  %124 = or i1 %120, %123
  %125 = icmp ult ptr %30, %40
  %126 = icmp ult ptr %38, %32
  %127 = and i1 %125, %126
  %128 = or i1 %124, %127
  %129 = icmp ult ptr %30, %45
  %130 = icmp ult ptr %42, %32
  %131 = and i1 %129, %130
  %132 = or i1 %128, %131
  %133 = icmp ult ptr %30, %49
  %134 = icmp ult ptr %47, %32
  %135 = and i1 %133, %134
  %136 = or i1 %132, %135
  %137 = icmp ult ptr %10, %40
  %138 = icmp ult ptr %38, %36
  %139 = and i1 %137, %138
  %140 = or i1 %136, %139
  %141 = icmp ult ptr %10, %45
  %142 = icmp ult ptr %42, %36
  %143 = and i1 %141, %142
  %144 = or i1 %140, %143
  %145 = icmp ult ptr %10, %49
  %146 = icmp ult ptr %47, %36
  %147 = and i1 %145, %146
  %148 = or i1 %144, %147
  %149 = icmp ult ptr %38, %45
  %150 = icmp ult ptr %42, %40
  %151 = and i1 %149, %150
  %152 = or i1 %148, %151
  %153 = icmp ult ptr %38, %49
  %154 = icmp ult ptr %47, %40
  %155 = and i1 %153, %154
  %156 = or i1 %152, %155
  %157 = icmp ult ptr %42, %49
  %158 = icmp ult ptr %47, %45
  %159 = and i1 %157, %158
  %160 = or i1 %156, %159
  br i1 %160, label %209, label %161

161:                                              ; preds = %15
  %162 = and i64 %13, -2
  %163 = shl i64 %162, 1
  br label %164

164:                                              ; preds = %164, %161
  %165 = phi i64 [ 0, %161 ], [ %205, %164 ]
  %166 = shl i64 %165, 1
  %167 = add nuw nsw i64 %166, %8
  %168 = add nuw nsw i64 %167, %8
  %169 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %166
  %170 = load <4 x double>, ptr %169, align 8, !tbaa !9
  %171 = shufflevector <4 x double> %170, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %172 = shufflevector <4 x double> %170, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %173 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %167
  %174 = load <4 x double>, ptr %173, align 8, !tbaa !9
  %175 = shufflevector <4 x double> %174, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %176 = shufflevector <4 x double> %174, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %177 = fadd <2 x double> %171, %175
  %178 = fadd <2 x double> %172, %176
  %179 = fsub <2 x double> %171, %175
  %180 = fsub <2 x double> %172, %176
  %181 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %168
  %182 = load <4 x double>, ptr %181, align 8, !tbaa !9
  %183 = shufflevector <4 x double> %182, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %184 = shufflevector <4 x double> %182, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %185 = getelementptr inbounds nuw [8 x i8], ptr %10, i64 %168
  %186 = load <4 x double>, ptr %185, align 8, !tbaa !9
  %187 = shufflevector <4 x double> %186, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %188 = shufflevector <4 x double> %186, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %189 = fadd <2 x double> %183, %187
  %190 = fadd <2 x double> %184, %188
  %191 = fsub <2 x double> %183, %187
  %192 = fsub <2 x double> %184, %188
  %193 = fadd <2 x double> %177, %189
  %194 = fadd <2 x double> %178, %190
  %195 = shufflevector <2 x double> %193, <2 x double> %194, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %195, ptr %169, align 8, !tbaa !9
  %196 = fsub <2 x double> %177, %189
  %197 = fsub <2 x double> %178, %190
  %198 = shufflevector <2 x double> %196, <2 x double> %197, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %198, ptr %181, align 8, !tbaa !9
  %199 = fsub <2 x double> %179, %192
  %200 = fadd <2 x double> %180, %191
  %201 = shufflevector <2 x double> %199, <2 x double> %200, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %201, ptr %173, align 8, !tbaa !9
  %202 = fadd <2 x double> %179, %192
  %203 = fsub <2 x double> %180, %191
  %204 = shufflevector <2 x double> %202, <2 x double> %203, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %204, ptr %185, align 8, !tbaa !9
  %205 = add nuw i64 %165, 2
  %206 = icmp eq i64 %205, %162
  br i1 %206, label %207, label %164, !llvm.loop !60

207:                                              ; preds = %164
  %208 = icmp eq i64 %13, %162
  br i1 %208, label %249, label %209

209:                                              ; preds = %15, %7, %207
  %210 = phi i64 [ 0, %15 ], [ 0, %7 ], [ %163, %207 ]
  br label %211

211:                                              ; preds = %209, %211
  %212 = phi i64 [ %247, %211 ], [ %210, %209 ]
  %213 = add nuw nsw i64 %212, %8
  %214 = add nuw nsw i64 %213, %8
  %215 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %212
  %216 = load double, ptr %215, align 8, !tbaa !9
  %217 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %213
  %218 = load double, ptr %217, align 8, !tbaa !9
  %219 = fadd double %216, %218
  %220 = getelementptr inbounds nuw i8, ptr %215, i64 8
  %221 = load double, ptr %220, align 8, !tbaa !9
  %222 = getelementptr i8, ptr %217, i64 8
  %223 = load double, ptr %222, align 8, !tbaa !9
  %224 = fadd double %221, %223
  %225 = fsub double %216, %218
  %226 = fsub double %221, %223
  %227 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %214
  %228 = load double, ptr %227, align 8, !tbaa !9
  %229 = getelementptr inbounds nuw [8 x i8], ptr %10, i64 %214
  %230 = load double, ptr %229, align 8, !tbaa !9
  %231 = fadd double %228, %230
  %232 = getelementptr i8, ptr %227, i64 8
  %233 = load double, ptr %232, align 8, !tbaa !9
  %234 = getelementptr i8, ptr %229, i64 8
  %235 = load double, ptr %234, align 8, !tbaa !9
  %236 = fadd double %233, %235
  %237 = fsub double %228, %230
  %238 = fsub double %233, %235
  %239 = fadd double %219, %231
  store double %239, ptr %215, align 8, !tbaa !9
  %240 = fadd double %224, %236
  store double %240, ptr %220, align 8, !tbaa !9
  %241 = fsub double %219, %231
  store double %241, ptr %227, align 8, !tbaa !9
  %242 = fsub double %224, %236
  store double %242, ptr %232, align 8, !tbaa !9
  %243 = fsub double %225, %238
  store double %243, ptr %217, align 8, !tbaa !9
  %244 = fadd double %226, %237
  store double %244, ptr %222, align 8, !tbaa !9
  %245 = fadd double %225, %238
  store double %245, ptr %229, align 8, !tbaa !9
  %246 = fsub double %226, %237
  store double %246, ptr %234, align 8, !tbaa !9
  %247 = add nuw nsw i64 %212, 2
  %248 = icmp samesign ult i64 %247, %9
  br i1 %248, label %211, label %249, !llvm.loop !61

249:                                              ; preds = %211, %207, %4
  %250 = getelementptr inbounds nuw i8, ptr %3, i64 16
  %251 = load double, ptr %250, align 8, !tbaa !9
  %252 = mul i32 %1, 5
  %253 = icmp slt i32 %5, %252
  br i1 %253, label %254, label %529

254:                                              ; preds = %249
  %255 = sext i32 %5 to i64
  %256 = sext i32 %1 to i64
  %257 = sext i32 %252 to i64
  %258 = getelementptr [8 x i8], ptr %2, i64 %256
  %259 = xor i64 %255, -1
  %260 = add nsw i64 %259, %257
  %261 = lshr i64 %260, 1
  %262 = add nuw i64 %261, 1
  %263 = icmp ult i64 %260, 42
  br i1 %263, label %481, label %264

264:                                              ; preds = %254
  %265 = shl nsw i64 %255, 3
  %266 = getelementptr i8, ptr %2, i64 %265
  %267 = xor i64 %255, -1
  %268 = add nsw i64 %267, %257
  %269 = shl nsw i64 %268, 3
  %270 = and i64 %269, -16
  %271 = add nsw i64 %270, %265
  %272 = getelementptr i8, ptr %2, i64 %271
  %273 = getelementptr i8, ptr %272, i64 8
  %274 = getelementptr i8, ptr %2, i64 %265
  %275 = getelementptr i8, ptr %274, i64 8
  %276 = getelementptr i8, ptr %2, i64 %271
  %277 = getelementptr i8, ptr %276, i64 16
  %278 = shl nsw i64 %256, 4
  %279 = add nsw i64 %278, %265
  %280 = getelementptr i8, ptr %2, i64 %279
  %281 = add nsw i64 %270, %278
  %282 = add nsw i64 %281, %265
  %283 = getelementptr i8, ptr %2, i64 %282
  %284 = getelementptr i8, ptr %283, i64 8
  %285 = getelementptr i8, ptr %2, i64 %279
  %286 = getelementptr i8, ptr %285, i64 8
  %287 = getelementptr i8, ptr %2, i64 %282
  %288 = getelementptr i8, ptr %287, i64 16
  %289 = add nsw i64 %256, %255
  %290 = shl nsw i64 %289, 3
  %291 = getelementptr i8, ptr %2, i64 %290
  %292 = add nsw i64 %270, %290
  %293 = getelementptr i8, ptr %2, i64 %292
  %294 = getelementptr i8, ptr %293, i64 8
  %295 = getelementptr i8, ptr %2, i64 %290
  %296 = getelementptr i8, ptr %295, i64 8
  %297 = getelementptr i8, ptr %2, i64 %292
  %298 = getelementptr i8, ptr %297, i64 16
  %299 = mul nsw i64 %256, 24
  %300 = add nsw i64 %299, %265
  %301 = getelementptr i8, ptr %2, i64 %300
  %302 = add nsw i64 %299, %270
  %303 = add nsw i64 %302, %265
  %304 = getelementptr i8, ptr %2, i64 %303
  %305 = getelementptr i8, ptr %304, i64 8
  %306 = getelementptr i8, ptr %2, i64 %300
  %307 = getelementptr i8, ptr %306, i64 8
  %308 = getelementptr i8, ptr %2, i64 %303
  %309 = getelementptr i8, ptr %308, i64 16
  %310 = icmp ult ptr %266, %277
  %311 = icmp ult ptr %275, %273
  %312 = and i1 %310, %311
  %313 = icmp ult ptr %266, %284
  %314 = icmp ult ptr %280, %273
  %315 = and i1 %313, %314
  %316 = or i1 %312, %315
  %317 = icmp ult ptr %266, %288
  %318 = icmp ult ptr %286, %273
  %319 = and i1 %317, %318
  %320 = or i1 %316, %319
  %321 = icmp ult ptr %266, %294
  %322 = icmp ult ptr %291, %273
  %323 = and i1 %321, %322
  %324 = or i1 %320, %323
  %325 = icmp ult ptr %266, %298
  %326 = icmp ult ptr %296, %273
  %327 = and i1 %325, %326
  %328 = or i1 %324, %327
  %329 = icmp ult ptr %266, %305
  %330 = icmp ult ptr %301, %273
  %331 = and i1 %329, %330
  %332 = or i1 %328, %331
  %333 = icmp ult ptr %266, %309
  %334 = icmp ult ptr %307, %273
  %335 = and i1 %333, %334
  %336 = or i1 %332, %335
  %337 = icmp ult ptr %275, %284
  %338 = icmp ult ptr %280, %277
  %339 = and i1 %337, %338
  %340 = or i1 %336, %339
  %341 = icmp ult ptr %275, %288
  %342 = icmp ult ptr %286, %277
  %343 = and i1 %341, %342
  %344 = or i1 %340, %343
  %345 = icmp ult ptr %275, %294
  %346 = icmp ult ptr %291, %277
  %347 = and i1 %345, %346
  %348 = or i1 %344, %347
  %349 = icmp ult ptr %275, %298
  %350 = icmp ult ptr %296, %277
  %351 = and i1 %349, %350
  %352 = or i1 %348, %351
  %353 = icmp ult ptr %275, %305
  %354 = icmp ult ptr %301, %277
  %355 = and i1 %353, %354
  %356 = or i1 %352, %355
  %357 = icmp ult ptr %275, %309
  %358 = icmp ult ptr %307, %277
  %359 = and i1 %357, %358
  %360 = or i1 %356, %359
  %361 = icmp ult ptr %280, %288
  %362 = icmp ult ptr %286, %284
  %363 = and i1 %361, %362
  %364 = or i1 %360, %363
  %365 = icmp ult ptr %280, %294
  %366 = icmp ult ptr %291, %284
  %367 = and i1 %365, %366
  %368 = or i1 %364, %367
  %369 = icmp ult ptr %280, %298
  %370 = icmp ult ptr %296, %284
  %371 = and i1 %369, %370
  %372 = or i1 %368, %371
  %373 = icmp ult ptr %280, %305
  %374 = icmp ult ptr %301, %284
  %375 = and i1 %373, %374
  %376 = or i1 %372, %375
  %377 = icmp ult ptr %280, %309
  %378 = icmp ult ptr %307, %284
  %379 = and i1 %377, %378
  %380 = or i1 %376, %379
  %381 = icmp ult ptr %286, %294
  %382 = icmp ult ptr %291, %288
  %383 = and i1 %381, %382
  %384 = or i1 %380, %383
  %385 = icmp ult ptr %286, %298
  %386 = icmp ult ptr %296, %288
  %387 = and i1 %385, %386
  %388 = or i1 %384, %387
  %389 = icmp ult ptr %286, %305
  %390 = icmp ult ptr %301, %288
  %391 = and i1 %389, %390
  %392 = or i1 %388, %391
  %393 = icmp ult ptr %286, %309
  %394 = icmp ult ptr %307, %288
  %395 = and i1 %393, %394
  %396 = or i1 %392, %395
  %397 = icmp ult ptr %291, %298
  %398 = icmp ult ptr %296, %294
  %399 = and i1 %397, %398
  %400 = or i1 %396, %399
  %401 = icmp ult ptr %291, %305
  %402 = icmp ult ptr %301, %294
  %403 = and i1 %401, %402
  %404 = or i1 %400, %403
  %405 = icmp ult ptr %291, %309
  %406 = icmp ult ptr %307, %294
  %407 = and i1 %405, %406
  %408 = or i1 %404, %407
  %409 = icmp ult ptr %296, %305
  %410 = icmp ult ptr %301, %298
  %411 = and i1 %409, %410
  %412 = or i1 %408, %411
  %413 = icmp ult ptr %296, %309
  %414 = icmp ult ptr %307, %298
  %415 = and i1 %413, %414
  %416 = or i1 %412, %415
  %417 = icmp ult ptr %301, %309
  %418 = icmp ult ptr %307, %305
  %419 = and i1 %417, %418
  %420 = or i1 %416, %419
  br i1 %420, label %481, label %421

421:                                              ; preds = %264
  %422 = and i64 %262, -2
  %423 = shl i64 %422, 1
  %424 = add i64 %423, %255
  %425 = insertelement <2 x double> poison, double %251, i64 0
  %426 = shufflevector <2 x double> %425, <2 x double> poison, <2 x i32> zeroinitializer
  br label %427

427:                                              ; preds = %427, %421
  %428 = phi i64 [ 0, %421 ], [ %477, %427 ]
  %429 = shl i64 %428, 1
  %430 = add i64 %429, %255
  %431 = add nsw i64 %430, %256
  %432 = add nsw i64 %431, %256
  %433 = getelementptr inbounds [8 x i8], ptr %2, i64 %430
  %434 = load <4 x double>, ptr %433, align 8, !tbaa !9
  %435 = shufflevector <4 x double> %434, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %436 = shufflevector <4 x double> %434, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %437 = getelementptr inbounds [8 x i8], ptr %2, i64 %431
  %438 = load <4 x double>, ptr %437, align 8, !tbaa !9
  %439 = shufflevector <4 x double> %438, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %440 = shufflevector <4 x double> %438, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %441 = fadd <2 x double> %435, %439
  %442 = fadd <2 x double> %436, %440
  %443 = fsub <2 x double> %435, %439
  %444 = fsub <2 x double> %436, %440
  %445 = getelementptr inbounds [8 x i8], ptr %2, i64 %432
  %446 = load <4 x double>, ptr %445, align 8, !tbaa !9
  %447 = shufflevector <4 x double> %446, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %448 = shufflevector <4 x double> %446, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %449 = getelementptr [8 x i8], ptr %258, i64 %432
  %450 = load <4 x double>, ptr %449, align 8, !tbaa !9
  %451 = shufflevector <4 x double> %450, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %452 = shufflevector <4 x double> %450, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %453 = fadd <2 x double> %447, %451
  %454 = fadd <2 x double> %448, %452
  %455 = fsub <2 x double> %447, %451
  %456 = fsub <2 x double> %448, %452
  %457 = fadd <2 x double> %441, %453
  %458 = fadd <2 x double> %442, %454
  %459 = shufflevector <2 x double> %457, <2 x double> %458, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %459, ptr %433, align 8, !tbaa !9
  %460 = fsub <2 x double> %454, %442
  %461 = fsub <2 x double> %441, %453
  %462 = shufflevector <2 x double> %460, <2 x double> %461, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %462, ptr %445, align 8, !tbaa !9
  %463 = fsub <2 x double> %443, %456
  %464 = fadd <2 x double> %444, %455
  %465 = fsub <2 x double> %463, %464
  %466 = fmul <2 x double> %426, %465
  %467 = fadd <2 x double> %464, %463
  %468 = fmul <2 x double> %426, %467
  %469 = shufflevector <2 x double> %466, <2 x double> %468, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %469, ptr %437, align 8, !tbaa !9
  %470 = fadd <2 x double> %443, %456
  %471 = fsub <2 x double> %455, %444
  %472 = fsub <2 x double> %471, %470
  %473 = fmul <2 x double> %426, %472
  %474 = fadd <2 x double> %471, %470
  %475 = fmul <2 x double> %426, %474
  %476 = shufflevector <2 x double> %473, <2 x double> %475, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %476, ptr %449, align 8, !tbaa !9
  %477 = add nuw i64 %428, 2
  %478 = icmp eq i64 %477, %422
  br i1 %478, label %479, label %427, !llvm.loop !62

479:                                              ; preds = %427
  %480 = icmp eq i64 %262, %422
  br i1 %480, label %529, label %481

481:                                              ; preds = %264, %254, %479
  %482 = phi i64 [ %255, %264 ], [ %255, %254 ], [ %424, %479 ]
  br label %483

483:                                              ; preds = %481, %483
  %484 = phi i64 [ %527, %483 ], [ %482, %481 ]
  %485 = add nsw i64 %484, %256
  %486 = add nsw i64 %485, %256
  %487 = getelementptr inbounds [8 x i8], ptr %2, i64 %484
  %488 = load double, ptr %487, align 8, !tbaa !9
  %489 = getelementptr inbounds [8 x i8], ptr %2, i64 %485
  %490 = load double, ptr %489, align 8, !tbaa !9
  %491 = fadd double %488, %490
  %492 = getelementptr i8, ptr %487, i64 8
  %493 = load double, ptr %492, align 8, !tbaa !9
  %494 = getelementptr i8, ptr %489, i64 8
  %495 = load double, ptr %494, align 8, !tbaa !9
  %496 = fadd double %493, %495
  %497 = fsub double %488, %490
  %498 = fsub double %493, %495
  %499 = getelementptr inbounds [8 x i8], ptr %2, i64 %486
  %500 = load double, ptr %499, align 8, !tbaa !9
  %501 = getelementptr [8 x i8], ptr %258, i64 %486
  %502 = load double, ptr %501, align 8, !tbaa !9
  %503 = fadd double %500, %502
  %504 = getelementptr i8, ptr %499, i64 8
  %505 = load double, ptr %504, align 8, !tbaa !9
  %506 = getelementptr i8, ptr %501, i64 8
  %507 = load double, ptr %506, align 8, !tbaa !9
  %508 = fadd double %505, %507
  %509 = fsub double %500, %502
  %510 = fsub double %505, %507
  %511 = fadd double %491, %503
  store double %511, ptr %487, align 8, !tbaa !9
  %512 = fadd double %496, %508
  store double %512, ptr %492, align 8, !tbaa !9
  %513 = fsub double %508, %496
  store double %513, ptr %499, align 8, !tbaa !9
  %514 = fsub double %491, %503
  store double %514, ptr %504, align 8, !tbaa !9
  %515 = fsub double %497, %510
  %516 = fadd double %498, %509
  %517 = fsub double %515, %516
  %518 = fmul double %251, %517
  store double %518, ptr %489, align 8, !tbaa !9
  %519 = fadd double %516, %515
  %520 = fmul double %251, %519
  store double %520, ptr %494, align 8, !tbaa !9
  %521 = fadd double %497, %510
  %522 = fsub double %509, %498
  %523 = fsub double %522, %521
  %524 = fmul double %251, %523
  store double %524, ptr %501, align 8, !tbaa !9
  %525 = fadd double %522, %521
  %526 = fmul double %251, %525
  store double %526, ptr %506, align 8, !tbaa !9
  %527 = add nsw i64 %484, 2
  %528 = icmp slt i64 %527, %257
  br i1 %528, label %483, label %529, !llvm.loop !63

529:                                              ; preds = %483, %479, %249
  %530 = shl i32 %1, 3
  %531 = icmp slt i32 %530, %0
  br i1 %531, label %532, label %1237

532:                                              ; preds = %529
  %533 = sext i32 %530 to i64
  %534 = sext i32 %1 to i64
  %535 = mul i32 %1, 12
  %536 = sext i32 %5 to i64
  %537 = zext nneg i32 %0 to i64
  %538 = getelementptr [8 x i8], ptr %2, i64 %534
  %539 = add nsw i64 %536, %534
  %540 = getelementptr [8 x i8], ptr %2, i64 %534
  %541 = getelementptr i8, ptr %2, i64 8
  %542 = add nsw i64 %534, %533
  %543 = add nsw i64 %542, %536
  %544 = getelementptr i8, ptr %2, i64 8
  %545 = getelementptr i8, ptr %2, i64 16
  %546 = shl nsw i64 %534, 4
  %547 = getelementptr i8, ptr %2, i64 %546
  %548 = or disjoint i64 %546, 8
  %549 = getelementptr i8, ptr %2, i64 %548
  %550 = getelementptr i8, ptr %2, i64 %548
  %551 = getelementptr i8, ptr %2, i64 %546
  %552 = getelementptr i8, ptr %551, i64 16
  %553 = getelementptr i8, ptr %2, i64 8
  %554 = getelementptr i8, ptr %2, i64 8
  %555 = getelementptr i8, ptr %2, i64 16
  %556 = mul nsw i64 %534, 24
  %557 = getelementptr i8, ptr %2, i64 %556
  %558 = add nsw i64 %556, 8
  %559 = getelementptr i8, ptr %2, i64 %558
  %560 = getelementptr i8, ptr %2, i64 %558
  %561 = getelementptr i8, ptr %2, i64 %556
  %562 = getelementptr i8, ptr %561, i64 16
  %563 = add nsw i64 %534, %533
  %564 = or disjoint i64 %533, 2
  %565 = xor i64 %533, -1
  %566 = shl nsw i64 %533, 3
  %567 = shl nsw i64 %533, 3
  %568 = shl nsw i64 %534, 4
  %569 = shl nsw i64 %563, 3
  %570 = mul nsw i64 %534, 24
  %571 = add nsw i64 %570, %566
  %572 = shl nsw i64 %533, 3
  %573 = shl nsw i64 %533, 3
  %574 = add nsw i64 %534, %533
  %575 = or disjoint i64 %533, 2
  %576 = xor i64 %533, -1
  %577 = shl nsw i64 %534, 4
  %578 = add nsw i64 %577, %572
  %579 = shl nsw i64 %574, 3
  %580 = mul nsw i64 %534, 24
  %581 = add nsw i64 %580, %572
  %582 = add nsw i64 %534, %533
  %583 = or disjoint i64 %533, 2
  %584 = xor i64 %533, -1
  %585 = getelementptr i8, ptr %2, i64 %572
  %586 = getelementptr i8, ptr %2, i64 %572
  %587 = getelementptr i8, ptr %586, i64 8
  %588 = getelementptr i8, ptr %2, i64 %578
  %589 = getelementptr i8, ptr %2, i64 %578
  %590 = getelementptr i8, ptr %589, i64 8
  %591 = getelementptr i8, ptr %2, i64 %579
  %592 = getelementptr i8, ptr %2, i64 %579
  %593 = getelementptr i8, ptr %592, i64 8
  %594 = getelementptr i8, ptr %2, i64 %572
  %595 = getelementptr i8, ptr %594, i64 16
  %596 = getelementptr i8, ptr %2, i64 %578
  %597 = getelementptr i8, ptr %596, i64 16
  %598 = getelementptr i8, ptr %2, i64 %579
  %599 = getelementptr i8, ptr %598, i64 16
  %600 = getelementptr i8, ptr %2, i64 %581
  %601 = getelementptr i8, ptr %2, i64 %581
  %602 = getelementptr i8, ptr %601, i64 8
  %603 = getelementptr i8, ptr %2, i64 %581
  %604 = getelementptr i8, ptr %603, i64 16
  %605 = getelementptr i8, ptr %2, i64 %566
  %606 = getelementptr i8, ptr %605, i64 8
  %607 = getelementptr i8, ptr %2, i64 %568
  %608 = getelementptr i8, ptr %607, i64 %566
  %609 = getelementptr i8, ptr %608, i64 8
  %610 = getelementptr i8, ptr %2, i64 %569
  %611 = getelementptr i8, ptr %610, i64 8
  %612 = getelementptr i8, ptr %2, i64 %571
  %613 = getelementptr i8, ptr %2, i64 %571
  %614 = getelementptr i8, ptr %613, i64 8
  br label %615

615:                                              ; preds = %532, %1232
  %616 = phi i64 [ 0, %532 ], [ %1236, %1232 ]
  %617 = phi i64 [ 0, %532 ], [ %704, %1232 ]
  %618 = phi i32 [ %535, %532 ], [ %1235, %1232 ]
  %619 = phi i64 [ %533, %532 ], [ %1233, %1232 ]
  %620 = mul i64 %616, %533
  %621 = add i64 %582, %620
  %622 = add i64 %583, %620
  %623 = tail call i64 @llvm.smax.i64(i64 %621, i64 %622)
  %624 = mul i64 %616, %533
  %625 = sub i64 %584, %624
  %626 = add i64 %623, %625
  %627 = lshr i64 %626, 1
  %628 = add nuw i64 %627, 1
  %629 = mul i64 %573, %616
  %630 = getelementptr i8, ptr %585, i64 %629
  %631 = getelementptr i8, ptr %587, i64 %629
  %632 = mul i64 %616, %533
  %633 = add i64 %574, %632
  %634 = add i64 %575, %632
  %635 = tail call i64 @llvm.smax.i64(i64 %633, i64 %634)
  %636 = mul i64 %616, %533
  %637 = sub i64 %576, %636
  %638 = add i64 %635, %637
  %639 = shl i64 %638, 3
  %640 = and i64 %639, -16
  %641 = getelementptr i8, ptr %631, i64 %640
  %642 = getelementptr i8, ptr %588, i64 %629
  %643 = getelementptr i8, ptr %590, i64 %629
  %644 = getelementptr i8, ptr %643, i64 %640
  %645 = getelementptr i8, ptr %591, i64 %629
  %646 = getelementptr i8, ptr %593, i64 %629
  %647 = getelementptr i8, ptr %646, i64 %640
  %648 = getelementptr i8, ptr %595, i64 %629
  %649 = getelementptr i8, ptr %648, i64 %640
  %650 = getelementptr i8, ptr %597, i64 %629
  %651 = getelementptr i8, ptr %650, i64 %640
  %652 = getelementptr i8, ptr %599, i64 %629
  %653 = getelementptr i8, ptr %652, i64 %640
  %654 = getelementptr i8, ptr %600, i64 %629
  %655 = getelementptr i8, ptr %602, i64 %629
  %656 = getelementptr i8, ptr %655, i64 %640
  %657 = getelementptr i8, ptr %604, i64 %629
  %658 = getelementptr i8, ptr %657, i64 %640
  %659 = mul i64 %616, %533
  %660 = add i64 %563, %659
  %661 = add i64 %564, %659
  %662 = tail call i64 @llvm.smax.i64(i64 %660, i64 %661)
  %663 = mul i64 %616, %533
  %664 = sub i64 %565, %663
  %665 = add i64 %662, %664
  %666 = lshr i64 %665, 1
  %667 = mul i64 %567, %616
  %668 = getelementptr i8, ptr %606, i64 %667
  %669 = getelementptr i8, ptr %609, i64 %667
  %670 = getelementptr i8, ptr %611, i64 %667
  %671 = getelementptr i8, ptr %612, i64 %667
  %672 = getelementptr i8, ptr %614, i64 %667
  %673 = sext i32 %618 to i64
  %674 = shl nsw i64 %673, 3
  %675 = getelementptr i8, ptr %2, i64 %674
  %676 = mul i64 %616, %533
  %677 = add i64 %543, %676
  %678 = or disjoint i64 %673, 2
  %679 = tail call i64 @llvm.smax.i64(i64 %677, i64 %678)
  %680 = xor i64 %673, -1
  %681 = add i64 %679, %680
  %682 = shl i64 %681, 3
  %683 = and i64 %682, -16
  %684 = add i64 %683, %674
  %685 = getelementptr i8, ptr %541, i64 %684
  %686 = getelementptr i8, ptr %544, i64 %674
  %687 = getelementptr i8, ptr %545, i64 %684
  %688 = getelementptr i8, ptr %547, i64 %674
  %689 = getelementptr i8, ptr %549, i64 %684
  %690 = getelementptr i8, ptr %550, i64 %674
  %691 = getelementptr i8, ptr %552, i64 %684
  %692 = add nsw i64 %534, %673
  %693 = shl nsw i64 %692, 3
  %694 = getelementptr i8, ptr %2, i64 %693
  %695 = add i64 %683, %693
  %696 = getelementptr i8, ptr %553, i64 %695
  %697 = getelementptr i8, ptr %554, i64 %693
  %698 = getelementptr i8, ptr %555, i64 %695
  %699 = getelementptr i8, ptr %557, i64 %674
  %700 = getelementptr i8, ptr %559, i64 %684
  %701 = getelementptr i8, ptr %560, i64 %674
  %702 = getelementptr i8, ptr %562, i64 %684
  %703 = sext i32 %618 to i64
  %704 = add nuw nsw i64 %617, 2
  %705 = getelementptr inbounds nuw [8 x i8], ptr %3, i64 %704
  %706 = load double, ptr %705, align 8, !tbaa !9
  %707 = getelementptr inbounds nuw [8 x i8], ptr %3, i64 %617
  %708 = getelementptr inbounds nuw i8, ptr %707, i64 24
  %709 = load double, ptr %708, align 8, !tbaa !9
  %710 = shl nuw nsw i64 %704, 4
  %711 = getelementptr inbounds nuw i8, ptr %3, i64 %710
  %712 = load <2 x double>, ptr %711, align 8, !tbaa !9
  %713 = fmul double %709, 2.000000e+00
  %714 = fneg double %713
  %715 = insertelement <2 x double> poison, double %713, i64 0
  %716 = insertelement <2 x double> %715, double %714, i64 1
  %717 = shufflevector <2 x double> %712, <2 x double> poison, <2 x i32> zeroinitializer
  %718 = fneg <2 x double> %712
  %719 = shufflevector <2 x double> %718, <2 x double> %712, <2 x i32> <i32 1, i32 2>
  %720 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %716, <2 x double> %712, <2 x double> %719)
  %721 = add i64 %619, %534
  br i1 %6, label %722, label %1232

722:                                              ; preds = %615
  %723 = icmp ult i64 %626, 22
  br i1 %723, label %930, label %724

724:                                              ; preds = %722
  %725 = shl i64 %666, 4
  %726 = getelementptr i8, ptr %668, i64 %725
  %727 = icmp ult ptr %726, %668
  %728 = shl i64 %666, 4
  %729 = icmp ugt i64 %665, 2305843009213693951
  %730 = getelementptr i8, ptr %669, i64 %728
  %731 = icmp ult ptr %730, %669
  %732 = or i1 %731, %729
  %733 = shl i64 %666, 4
  %734 = getelementptr i8, ptr %670, i64 %733
  %735 = icmp ult ptr %734, %670
  %736 = shl i64 %666, 4
  %737 = getelementptr i8, ptr %671, i64 %736
  %738 = icmp ult ptr %737, %671
  %739 = shl i64 %666, 4
  %740 = getelementptr i8, ptr %672, i64 %739
  %741 = icmp ult ptr %740, %672
  %742 = or i1 %727, %732
  %743 = or i1 %735, %742
  %744 = or i1 %738, %743
  %745 = or i1 %741, %744
  br i1 %745, label %930, label %746

746:                                              ; preds = %724
  %747 = icmp ult ptr %630, %644
  %748 = icmp ult ptr %642, %641
  %749 = and i1 %747, %748
  %750 = icmp ult ptr %630, %647
  %751 = icmp ult ptr %645, %641
  %752 = and i1 %750, %751
  %753 = or i1 %749, %752
  %754 = icmp ult ptr %630, %649
  %755 = icmp ult ptr %631, %641
  %756 = and i1 %754, %755
  %757 = or i1 %753, %756
  %758 = icmp ult ptr %630, %651
  %759 = icmp ult ptr %643, %641
  %760 = and i1 %758, %759
  %761 = or i1 %757, %760
  %762 = icmp ult ptr %630, %653
  %763 = icmp ult ptr %646, %641
  %764 = and i1 %762, %763
  %765 = or i1 %761, %764
  %766 = icmp ult ptr %630, %656
  %767 = icmp ult ptr %654, %641
  %768 = and i1 %766, %767
  %769 = or i1 %765, %768
  %770 = icmp ult ptr %630, %658
  %771 = icmp ult ptr %655, %641
  %772 = and i1 %770, %771
  %773 = or i1 %769, %772
  %774 = icmp ult ptr %642, %647
  %775 = icmp ult ptr %645, %644
  %776 = and i1 %774, %775
  %777 = or i1 %773, %776
  %778 = icmp ult ptr %642, %649
  %779 = icmp ult ptr %631, %644
  %780 = and i1 %778, %779
  %781 = or i1 %777, %780
  %782 = icmp ult ptr %642, %651
  %783 = icmp ult ptr %643, %644
  %784 = and i1 %782, %783
  %785 = or i1 %781, %784
  %786 = icmp ult ptr %642, %653
  %787 = icmp ult ptr %646, %644
  %788 = and i1 %786, %787
  %789 = or i1 %785, %788
  %790 = icmp ult ptr %642, %656
  %791 = icmp ult ptr %654, %644
  %792 = and i1 %790, %791
  %793 = or i1 %789, %792
  %794 = icmp ult ptr %642, %658
  %795 = icmp ult ptr %655, %644
  %796 = and i1 %794, %795
  %797 = or i1 %793, %796
  %798 = icmp ult ptr %645, %649
  %799 = icmp ult ptr %631, %647
  %800 = and i1 %798, %799
  %801 = or i1 %797, %800
  %802 = icmp ult ptr %645, %651
  %803 = icmp ult ptr %643, %647
  %804 = and i1 %802, %803
  %805 = or i1 %801, %804
  %806 = icmp ult ptr %645, %653
  %807 = icmp ult ptr %646, %647
  %808 = and i1 %806, %807
  %809 = or i1 %805, %808
  %810 = icmp ult ptr %645, %656
  %811 = icmp ult ptr %654, %647
  %812 = and i1 %810, %811
  %813 = or i1 %809, %812
  %814 = icmp ult ptr %645, %658
  %815 = icmp ult ptr %655, %647
  %816 = and i1 %814, %815
  %817 = or i1 %813, %816
  %818 = icmp ult ptr %631, %651
  %819 = icmp ult ptr %643, %649
  %820 = and i1 %818, %819
  %821 = or i1 %817, %820
  %822 = icmp ult ptr %631, %653
  %823 = icmp ult ptr %646, %649
  %824 = and i1 %822, %823
  %825 = or i1 %821, %824
  %826 = icmp ult ptr %631, %656
  %827 = icmp ult ptr %654, %649
  %828 = and i1 %826, %827
  %829 = or i1 %825, %828
  %830 = icmp ult ptr %631, %658
  %831 = icmp ult ptr %655, %649
  %832 = and i1 %830, %831
  %833 = or i1 %829, %832
  %834 = icmp ult ptr %643, %653
  %835 = icmp ult ptr %646, %651
  %836 = and i1 %834, %835
  %837 = or i1 %833, %836
  %838 = icmp ult ptr %643, %656
  %839 = icmp ult ptr %654, %651
  %840 = and i1 %838, %839
  %841 = or i1 %837, %840
  %842 = icmp ult ptr %643, %658
  %843 = icmp ult ptr %655, %651
  %844 = and i1 %842, %843
  %845 = or i1 %841, %844
  %846 = icmp ult ptr %646, %656
  %847 = icmp ult ptr %654, %653
  %848 = and i1 %846, %847
  %849 = or i1 %845, %848
  %850 = icmp ult ptr %646, %658
  %851 = icmp ult ptr %655, %653
  %852 = and i1 %850, %851
  %853 = or i1 %849, %852
  %854 = icmp ult ptr %654, %658
  %855 = icmp ult ptr %655, %656
  %856 = and i1 %854, %855
  %857 = or i1 %853, %856
  br i1 %857, label %930, label %858

858:                                              ; preds = %746
  %859 = and i64 %628, -2
  %860 = shl i64 %859, 1
  %861 = add i64 %619, %860
  %862 = insertelement <2 x double> poison, double %709, i64 0
  %863 = shufflevector <2 x double> %862, <2 x double> poison, <2 x i32> zeroinitializer
  %864 = insertelement <2 x double> poison, double %706, i64 0
  %865 = shufflevector <2 x double> %864, <2 x double> poison, <2 x i32> zeroinitializer
  %866 = shufflevector <2 x double> %712, <2 x double> poison, <2 x i32> <i32 1, i32 1>
  %867 = shufflevector <2 x double> %720, <2 x double> poison, <2 x i32> zeroinitializer
  %868 = shufflevector <2 x double> %720, <2 x double> poison, <2 x i32> <i32 1, i32 1>
  br label %869

869:                                              ; preds = %869, %858
  %870 = phi i64 [ 0, %858 ], [ %926, %869 ]
  %871 = shl i64 %870, 1
  %872 = add i64 %619, %871
  %873 = add nsw i64 %872, %534
  %874 = add nsw i64 %873, %534
  %875 = getelementptr inbounds [8 x i8], ptr %2, i64 %872
  %876 = load <4 x double>, ptr %875, align 8, !tbaa !9
  %877 = shufflevector <4 x double> %876, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %878 = shufflevector <4 x double> %876, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %879 = getelementptr inbounds [8 x i8], ptr %2, i64 %873
  %880 = load <4 x double>, ptr %879, align 8, !tbaa !9
  %881 = shufflevector <4 x double> %880, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %882 = shufflevector <4 x double> %880, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %883 = fadd <2 x double> %877, %881
  %884 = fadd <2 x double> %878, %882
  %885 = fsub <2 x double> %877, %881
  %886 = fsub <2 x double> %878, %882
  %887 = getelementptr inbounds [8 x i8], ptr %2, i64 %874
  %888 = load <4 x double>, ptr %887, align 8, !tbaa !9
  %889 = shufflevector <4 x double> %888, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %890 = shufflevector <4 x double> %888, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %891 = getelementptr [8 x i8], ptr %538, i64 %874
  %892 = load <4 x double>, ptr %891, align 8, !tbaa !9
  %893 = shufflevector <4 x double> %892, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %894 = shufflevector <4 x double> %892, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %895 = fadd <2 x double> %889, %893
  %896 = fadd <2 x double> %890, %894
  %897 = fsub <2 x double> %889, %893
  %898 = fsub <2 x double> %890, %894
  %899 = fadd <2 x double> %883, %895
  %900 = fadd <2 x double> %884, %896
  %901 = shufflevector <2 x double> %899, <2 x double> %900, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %901, ptr %875, align 8, !tbaa !9
  %902 = fsub <2 x double> %883, %895
  %903 = fsub <2 x double> %884, %896
  %904 = fneg <2 x double> %903
  %905 = fmul <2 x double> %863, %904
  %906 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %865, <2 x double> %902, <2 x double> %905)
  %907 = fmul <2 x double> %863, %902
  %908 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %865, <2 x double> %903, <2 x double> %907)
  %909 = shufflevector <2 x double> %906, <2 x double> %908, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %909, ptr %887, align 8, !tbaa !9
  %910 = fsub <2 x double> %885, %898
  %911 = fadd <2 x double> %886, %897
  %912 = fneg <2 x double> %911
  %913 = fmul <2 x double> %866, %912
  %914 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %717, <2 x double> %910, <2 x double> %913)
  %915 = fmul <2 x double> %866, %910
  %916 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %717, <2 x double> %911, <2 x double> %915)
  %917 = shufflevector <2 x double> %914, <2 x double> %916, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %917, ptr %879, align 8, !tbaa !9
  %918 = fadd <2 x double> %885, %898
  %919 = fsub <2 x double> %886, %897
  %920 = fneg <2 x double> %919
  %921 = fmul <2 x double> %867, %920
  %922 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %868, <2 x double> %918, <2 x double> %921)
  %923 = fmul <2 x double> %867, %918
  %924 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %868, <2 x double> %919, <2 x double> %923)
  %925 = shufflevector <2 x double> %922, <2 x double> %924, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %925, ptr %891, align 8, !tbaa !9
  %926 = add nuw i64 %870, 2
  %927 = icmp eq i64 %926, %859
  br i1 %927, label %928, label %869, !llvm.loop !64

928:                                              ; preds = %869
  %929 = icmp eq i64 %628, %859
  br i1 %929, label %979, label %930

930:                                              ; preds = %746, %724, %722, %928
  %931 = phi i64 [ %619, %746 ], [ %619, %724 ], [ %619, %722 ], [ %861, %928 ]
  %932 = insertelement <2 x double> poison, double %709, i64 0
  %933 = shufflevector <2 x double> %932, <2 x double> poison, <2 x i32> zeroinitializer
  %934 = insertelement <2 x double> poison, double %706, i64 0
  %935 = shufflevector <2 x double> %934, <2 x double> poison, <2 x i32> zeroinitializer
  %936 = shufflevector <2 x double> %712, <2 x double> poison, <2 x i32> <i32 1, i32 1>
  %937 = shufflevector <2 x double> %720, <2 x double> poison, <2 x i32> zeroinitializer
  %938 = shufflevector <2 x double> %720, <2 x double> poison, <2 x i32> <i32 1, i32 1>
  br label %939

939:                                              ; preds = %930, %939
  %940 = phi i64 [ %977, %939 ], [ %931, %930 ]
  %941 = add nsw i64 %940, %534
  %942 = add nsw i64 %941, %534
  %943 = getelementptr inbounds [8 x i8], ptr %2, i64 %940
  %944 = getelementptr inbounds [8 x i8], ptr %2, i64 %941
  %945 = getelementptr i8, ptr %943, i64 8
  %946 = getelementptr inbounds [8 x i8], ptr %2, i64 %942
  %947 = getelementptr [8 x i8], ptr %538, i64 %942
  %948 = load <2 x double>, ptr %943, align 8, !tbaa !9
  %949 = load <2 x double>, ptr %944, align 8, !tbaa !9
  %950 = fsub <2 x double> %948, %949
  %951 = load <2 x double>, ptr %946, align 8, !tbaa !9
  %952 = load <2 x double>, ptr %947, align 8, !tbaa !9
  %953 = fsub <2 x double> %951, %952
  %954 = shufflevector <2 x double> %953, <2 x double> poison, <2 x i32> <i32 1, i32 0>
  %955 = fadd <2 x double> %948, %949
  %956 = fadd <2 x double> %951, %952
  %957 = fadd <2 x double> %955, %956
  %958 = extractelement <2 x double> %957, i64 0
  store double %958, ptr %943, align 8, !tbaa !9
  %959 = extractelement <2 x double> %957, i64 1
  store double %959, ptr %945, align 8, !tbaa !9
  %960 = fsub <2 x double> %955, %956
  %961 = fneg <2 x double> %960
  %962 = shufflevector <2 x double> %961, <2 x double> %960, <2 x i32> <i32 1, i32 2>
  %963 = fmul <2 x double> %933, %962
  %964 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %935, <2 x double> %960, <2 x double> %963)
  store <2 x double> %964, ptr %946, align 8, !tbaa !9
  %965 = fsub <2 x double> %950, %954
  %966 = fadd <2 x double> %950, %954
  %967 = shufflevector <2 x double> %965, <2 x double> %966, <2 x i32> <i32 0, i32 3>
  %968 = fneg <2 x double> %967
  %969 = shufflevector <2 x double> %968, <2 x double> %965, <2 x i32> <i32 1, i32 2>
  %970 = fmul <2 x double> %936, %969
  %971 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %717, <2 x double> %967, <2 x double> %970)
  store <2 x double> %971, ptr %944, align 8, !tbaa !9
  %972 = shufflevector <2 x double> %966, <2 x double> %965, <2 x i32> <i32 0, i32 3>
  %973 = fneg <2 x double> %972
  %974 = shufflevector <2 x double> %973, <2 x double> %966, <2 x i32> <i32 1, i32 2>
  %975 = fmul <2 x double> %937, %974
  %976 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %938, <2 x double> %972, <2 x double> %975)
  store <2 x double> %976, ptr %947, align 8, !tbaa !9
  %977 = add nsw i64 %940, 2
  %978 = icmp slt i64 %977, %721
  br i1 %978, label %939, label %979, !llvm.loop !65

979:                                              ; preds = %939, %928
  %980 = getelementptr inbounds nuw i8, ptr %711, i64 16
  %981 = load <2 x double>, ptr %980, align 8, !tbaa !9
  %982 = fmul double %706, 2.000000e+00
  %983 = fneg double %982
  %984 = insertelement <2 x double> poison, double %982, i64 0
  %985 = insertelement <2 x double> %984, double %983, i64 1
  %986 = shufflevector <2 x double> %981, <2 x double> poison, <2 x i32> zeroinitializer
  %987 = fneg <2 x double> %981
  %988 = shufflevector <2 x double> %987, <2 x double> %981, <2 x i32> <i32 1, i32 2>
  %989 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %985, <2 x double> %981, <2 x double> %988)
  %990 = add i64 %619, %539
  %991 = fneg double %709
  %992 = or disjoint i64 %703, 2
  %993 = tail call i64 @llvm.smax.i64(i64 %990, i64 %992)
  %994 = xor i64 %703, -1
  %995 = add i64 %993, %994
  %996 = lshr i64 %995, 1
  %997 = add nuw i64 %996, 1
  %998 = icmp ult i64 %995, 14
  br i1 %998, label %1183, label %999

999:                                              ; preds = %979
  %1000 = icmp ult ptr %675, %687
  %1001 = icmp ult ptr %686, %685
  %1002 = and i1 %1000, %1001
  %1003 = icmp ult ptr %675, %689
  %1004 = icmp ult ptr %688, %685
  %1005 = and i1 %1003, %1004
  %1006 = or i1 %1002, %1005
  %1007 = icmp ult ptr %675, %691
  %1008 = icmp ult ptr %690, %685
  %1009 = and i1 %1007, %1008
  %1010 = or i1 %1006, %1009
  %1011 = icmp ult ptr %675, %696
  %1012 = icmp ult ptr %694, %685
  %1013 = and i1 %1011, %1012
  %1014 = or i1 %1010, %1013
  %1015 = icmp ult ptr %675, %698
  %1016 = icmp ult ptr %697, %685
  %1017 = and i1 %1015, %1016
  %1018 = or i1 %1014, %1017
  %1019 = icmp ult ptr %675, %700
  %1020 = icmp ult ptr %699, %685
  %1021 = and i1 %1019, %1020
  %1022 = or i1 %1018, %1021
  %1023 = icmp ult ptr %675, %702
  %1024 = icmp ult ptr %701, %685
  %1025 = and i1 %1023, %1024
  %1026 = or i1 %1022, %1025
  %1027 = icmp ult ptr %686, %689
  %1028 = icmp ult ptr %688, %687
  %1029 = and i1 %1027, %1028
  %1030 = or i1 %1026, %1029
  %1031 = icmp ult ptr %686, %691
  %1032 = icmp ult ptr %690, %687
  %1033 = and i1 %1031, %1032
  %1034 = or i1 %1030, %1033
  %1035 = icmp ult ptr %686, %696
  %1036 = icmp ult ptr %694, %687
  %1037 = and i1 %1035, %1036
  %1038 = or i1 %1034, %1037
  %1039 = icmp ult ptr %686, %698
  %1040 = icmp ult ptr %697, %687
  %1041 = and i1 %1039, %1040
  %1042 = or i1 %1038, %1041
  %1043 = icmp ult ptr %686, %700
  %1044 = icmp ult ptr %699, %687
  %1045 = and i1 %1043, %1044
  %1046 = or i1 %1042, %1045
  %1047 = icmp ult ptr %686, %702
  %1048 = icmp ult ptr %701, %687
  %1049 = and i1 %1047, %1048
  %1050 = or i1 %1046, %1049
  %1051 = icmp ult ptr %688, %691
  %1052 = icmp ult ptr %690, %689
  %1053 = and i1 %1051, %1052
  %1054 = or i1 %1050, %1053
  %1055 = icmp ult ptr %688, %696
  %1056 = icmp ult ptr %694, %689
  %1057 = and i1 %1055, %1056
  %1058 = or i1 %1054, %1057
  %1059 = icmp ult ptr %688, %698
  %1060 = icmp ult ptr %697, %689
  %1061 = and i1 %1059, %1060
  %1062 = or i1 %1058, %1061
  %1063 = icmp ult ptr %688, %700
  %1064 = icmp ult ptr %699, %689
  %1065 = and i1 %1063, %1064
  %1066 = or i1 %1062, %1065
  %1067 = icmp ult ptr %688, %702
  %1068 = icmp ult ptr %701, %689
  %1069 = and i1 %1067, %1068
  %1070 = or i1 %1066, %1069
  %1071 = icmp ult ptr %690, %696
  %1072 = icmp ult ptr %694, %691
  %1073 = and i1 %1071, %1072
  %1074 = or i1 %1070, %1073
  %1075 = icmp ult ptr %690, %698
  %1076 = icmp ult ptr %697, %691
  %1077 = and i1 %1075, %1076
  %1078 = or i1 %1074, %1077
  %1079 = icmp ult ptr %690, %700
  %1080 = icmp ult ptr %699, %691
  %1081 = and i1 %1079, %1080
  %1082 = or i1 %1078, %1081
  %1083 = icmp ult ptr %690, %702
  %1084 = icmp ult ptr %701, %691
  %1085 = and i1 %1083, %1084
  %1086 = or i1 %1082, %1085
  %1087 = icmp ult ptr %694, %698
  %1088 = icmp ult ptr %697, %696
  %1089 = and i1 %1087, %1088
  %1090 = or i1 %1086, %1089
  %1091 = icmp ult ptr %694, %700
  %1092 = icmp ult ptr %699, %696
  %1093 = and i1 %1091, %1092
  %1094 = or i1 %1090, %1093
  %1095 = icmp ult ptr %694, %702
  %1096 = icmp ult ptr %701, %696
  %1097 = and i1 %1095, %1096
  %1098 = or i1 %1094, %1097
  %1099 = icmp ult ptr %697, %700
  %1100 = icmp ult ptr %699, %698
  %1101 = and i1 %1099, %1100
  %1102 = or i1 %1098, %1101
  %1103 = icmp ult ptr %697, %702
  %1104 = icmp ult ptr %701, %698
  %1105 = and i1 %1103, %1104
  %1106 = or i1 %1102, %1105
  %1107 = icmp ult ptr %699, %702
  %1108 = icmp ult ptr %701, %700
  %1109 = and i1 %1107, %1108
  %1110 = or i1 %1106, %1109
  br i1 %1110, label %1183, label %1111

1111:                                             ; preds = %999
  %1112 = and i64 %997, -2
  %1113 = shl i64 %1112, 1
  %1114 = add i64 %1113, %703
  %1115 = insertelement <2 x double> poison, double %991, i64 0
  %1116 = shufflevector <2 x double> %1115, <2 x double> poison, <2 x i32> zeroinitializer
  %1117 = insertelement <2 x double> poison, double %706, i64 0
  %1118 = shufflevector <2 x double> %1117, <2 x double> poison, <2 x i32> zeroinitializer
  %1119 = shufflevector <2 x double> %981, <2 x double> poison, <2 x i32> <i32 1, i32 1>
  %1120 = shufflevector <2 x double> %989, <2 x double> poison, <2 x i32> zeroinitializer
  %1121 = shufflevector <2 x double> %989, <2 x double> poison, <2 x i32> <i32 1, i32 1>
  br label %1122

1122:                                             ; preds = %1122, %1111
  %1123 = phi i64 [ 0, %1111 ], [ %1179, %1122 ]
  %1124 = shl i64 %1123, 1
  %1125 = add i64 %1124, %703
  %1126 = add nsw i64 %1125, %534
  %1127 = add nsw i64 %1126, %534
  %1128 = getelementptr inbounds [8 x i8], ptr %2, i64 %1125
  %1129 = load <4 x double>, ptr %1128, align 8, !tbaa !9
  %1130 = shufflevector <4 x double> %1129, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %1131 = shufflevector <4 x double> %1129, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %1132 = getelementptr inbounds [8 x i8], ptr %2, i64 %1126
  %1133 = load <4 x double>, ptr %1132, align 8, !tbaa !9
  %1134 = shufflevector <4 x double> %1133, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %1135 = shufflevector <4 x double> %1133, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %1136 = fadd <2 x double> %1130, %1134
  %1137 = fadd <2 x double> %1131, %1135
  %1138 = fsub <2 x double> %1130, %1134
  %1139 = fsub <2 x double> %1131, %1135
  %1140 = getelementptr inbounds [8 x i8], ptr %2, i64 %1127
  %1141 = load <4 x double>, ptr %1140, align 8, !tbaa !9
  %1142 = shufflevector <4 x double> %1141, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %1143 = shufflevector <4 x double> %1141, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %1144 = getelementptr [8 x i8], ptr %540, i64 %1127
  %1145 = load <4 x double>, ptr %1144, align 8, !tbaa !9
  %1146 = shufflevector <4 x double> %1145, <4 x double> poison, <2 x i32> <i32 0, i32 2>
  %1147 = shufflevector <4 x double> %1145, <4 x double> poison, <2 x i32> <i32 1, i32 3>
  %1148 = fadd <2 x double> %1142, %1146
  %1149 = fadd <2 x double> %1143, %1147
  %1150 = fsub <2 x double> %1142, %1146
  %1151 = fsub <2 x double> %1143, %1147
  %1152 = fadd <2 x double> %1136, %1148
  %1153 = fadd <2 x double> %1137, %1149
  %1154 = shufflevector <2 x double> %1152, <2 x double> %1153, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %1154, ptr %1128, align 8, !tbaa !9
  %1155 = fsub <2 x double> %1136, %1148
  %1156 = fsub <2 x double> %1137, %1149
  %1157 = fneg <2 x double> %1156
  %1158 = fmul <2 x double> %1118, %1157
  %1159 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %1116, <2 x double> %1155, <2 x double> %1158)
  %1160 = fmul <2 x double> %1118, %1155
  %1161 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %1116, <2 x double> %1156, <2 x double> %1160)
  %1162 = shufflevector <2 x double> %1159, <2 x double> %1161, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %1162, ptr %1140, align 8, !tbaa !9
  %1163 = fsub <2 x double> %1138, %1151
  %1164 = fadd <2 x double> %1139, %1150
  %1165 = fneg <2 x double> %1164
  %1166 = fmul <2 x double> %1119, %1165
  %1167 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %986, <2 x double> %1163, <2 x double> %1166)
  %1168 = fmul <2 x double> %1119, %1163
  %1169 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %986, <2 x double> %1164, <2 x double> %1168)
  %1170 = shufflevector <2 x double> %1167, <2 x double> %1169, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %1170, ptr %1132, align 8, !tbaa !9
  %1171 = fadd <2 x double> %1138, %1151
  %1172 = fsub <2 x double> %1139, %1150
  %1173 = fneg <2 x double> %1172
  %1174 = fmul <2 x double> %1120, %1173
  %1175 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %1121, <2 x double> %1171, <2 x double> %1174)
  %1176 = fmul <2 x double> %1120, %1171
  %1177 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %1121, <2 x double> %1172, <2 x double> %1176)
  %1178 = shufflevector <2 x double> %1175, <2 x double> %1177, <4 x i32> <i32 0, i32 2, i32 1, i32 3>
  store <4 x double> %1178, ptr %1144, align 8, !tbaa !9
  %1179 = add nuw i64 %1123, 2
  %1180 = icmp eq i64 %1179, %1112
  br i1 %1180, label %1181, label %1122, !llvm.loop !66

1181:                                             ; preds = %1122
  %1182 = icmp eq i64 %997, %1112
  br i1 %1182, label %1232, label %1183

1183:                                             ; preds = %999, %979, %1181
  %1184 = phi i64 [ %703, %999 ], [ %703, %979 ], [ %1114, %1181 ]
  %1185 = insertelement <2 x double> poison, double %706, i64 0
  %1186 = shufflevector <2 x double> %1185, <2 x double> poison, <2 x i32> zeroinitializer
  %1187 = insertelement <2 x double> poison, double %991, i64 0
  %1188 = shufflevector <2 x double> %1187, <2 x double> poison, <2 x i32> zeroinitializer
  %1189 = shufflevector <2 x double> %981, <2 x double> poison, <2 x i32> <i32 1, i32 1>
  %1190 = shufflevector <2 x double> %989, <2 x double> poison, <2 x i32> zeroinitializer
  %1191 = shufflevector <2 x double> %989, <2 x double> poison, <2 x i32> <i32 1, i32 1>
  br label %1192

1192:                                             ; preds = %1183, %1192
  %1193 = phi i64 [ %1230, %1192 ], [ %1184, %1183 ]
  %1194 = add nsw i64 %1193, %534
  %1195 = add nsw i64 %1194, %534
  %1196 = getelementptr inbounds [8 x i8], ptr %2, i64 %1193
  %1197 = getelementptr inbounds [8 x i8], ptr %2, i64 %1194
  %1198 = getelementptr i8, ptr %1196, i64 8
  %1199 = getelementptr inbounds [8 x i8], ptr %2, i64 %1195
  %1200 = getelementptr [8 x i8], ptr %540, i64 %1195
  %1201 = load <2 x double>, ptr %1196, align 8, !tbaa !9
  %1202 = load <2 x double>, ptr %1197, align 8, !tbaa !9
  %1203 = fsub <2 x double> %1201, %1202
  %1204 = load <2 x double>, ptr %1199, align 8, !tbaa !9
  %1205 = load <2 x double>, ptr %1200, align 8, !tbaa !9
  %1206 = fsub <2 x double> %1204, %1205
  %1207 = shufflevector <2 x double> %1206, <2 x double> poison, <2 x i32> <i32 1, i32 0>
  %1208 = fadd <2 x double> %1201, %1202
  %1209 = fadd <2 x double> %1204, %1205
  %1210 = fadd <2 x double> %1208, %1209
  %1211 = extractelement <2 x double> %1210, i64 0
  store double %1211, ptr %1196, align 8, !tbaa !9
  %1212 = extractelement <2 x double> %1210, i64 1
  store double %1212, ptr %1198, align 8, !tbaa !9
  %1213 = fsub <2 x double> %1208, %1209
  %1214 = fneg <2 x double> %1213
  %1215 = shufflevector <2 x double> %1214, <2 x double> %1213, <2 x i32> <i32 1, i32 2>
  %1216 = fmul <2 x double> %1186, %1215
  %1217 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %1188, <2 x double> %1213, <2 x double> %1216)
  store <2 x double> %1217, ptr %1199, align 8, !tbaa !9
  %1218 = fsub <2 x double> %1203, %1207
  %1219 = fadd <2 x double> %1203, %1207
  %1220 = shufflevector <2 x double> %1218, <2 x double> %1219, <2 x i32> <i32 0, i32 3>
  %1221 = fneg <2 x double> %1220
  %1222 = shufflevector <2 x double> %1221, <2 x double> %1218, <2 x i32> <i32 1, i32 2>
  %1223 = fmul <2 x double> %1189, %1222
  %1224 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %986, <2 x double> %1220, <2 x double> %1223)
  store <2 x double> %1224, ptr %1197, align 8, !tbaa !9
  %1225 = shufflevector <2 x double> %1219, <2 x double> %1218, <2 x i32> <i32 0, i32 3>
  %1226 = fneg <2 x double> %1225
  %1227 = shufflevector <2 x double> %1226, <2 x double> %1219, <2 x i32> <i32 1, i32 2>
  %1228 = fmul <2 x double> %1190, %1227
  %1229 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %1191, <2 x double> %1225, <2 x double> %1228)
  store <2 x double> %1229, ptr %1200, align 8, !tbaa !9
  %1230 = add nsw i64 %1193, 2
  %1231 = icmp slt i64 %1230, %990
  br i1 %1231, label %1192, label %1232, !llvm.loop !67

1232:                                             ; preds = %1192, %1181, %615
  %1233 = add nsw i64 %619, %533
  %1234 = icmp slt i64 %1233, %537
  %1235 = add i32 %618, %530
  %1236 = add i64 %616, 1
  br i1 %1234, label %615, label %1237, !llvm.loop !68

1237:                                             ; preds = %1232, %529
  ret void
}

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare <2 x double> @llvm.fmuladd.v2f64(<2 x double>, <2 x double>, <2 x double>) #15

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write)
declare void @llvm.assume(i1 noundef) #16

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.smax.i64(i64, i64) #15

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { mustprogress nofree nounwind willreturn allockind("alloc,uninitialized,aligned") allocsize(1) memory(inaccessiblemem: readwrite, errnomem: write) "alloc-family"="malloc" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nofree norecurse nosync nounwind memory(argmem: readwrite, errnomem: write) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nofree norecurse nosync nounwind memory(argmem: write) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #7 = { nofree norecurse nosync nounwind memory(argmem: read) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #8 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #9 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #10 = { cold nofree noreturn nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #11 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #12 = { mustprogress nounwind willreturn allockind("free") memory(argmem: readwrite, inaccessiblemem: readwrite) "alloc-family"="malloc" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #13 = { mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #14 = { inlinehint nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #15 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #16 = { nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write) }
attributes #17 = { nounwind }
attributes #18 = { nounwind allocsize(1) }
attributes #19 = { cold noreturn nounwind }

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
!11 = distinct !{!11, !12}
!12 = !{!"llvm.loop.mustprogress"}
!13 = distinct !{!13, !12}
!14 = distinct !{!14, !12}
!15 = distinct !{!15, !12, !16, !17}
!16 = !{!"llvm.loop.isvectorized", i32 1}
!17 = !{!"llvm.loop.unroll.runtime.disable"}
!18 = distinct !{!18, !12}
!19 = distinct !{!19, !12}
!20 = !{!21, !22, i64 0}
!21 = !{!"timeval", !22, i64 0, !22, i64 8}
!22 = !{!"long", !7, i64 0}
!23 = !{!21, !22, i64 8}
!24 = distinct !{!24, !12}
!25 = !{!6, !6, i64 0}
!26 = distinct !{!26, !12, !16, !17}
!27 = distinct !{!27, !12, !17, !16}
!28 = distinct !{!28, !12}
!29 = distinct !{!29, !12}
!30 = distinct !{!30, !12}
!31 = distinct !{!31, !12}
!32 = distinct !{!32, !12}
!33 = distinct !{!33, !12}
!34 = distinct !{!34, !12, !16, !17}
!35 = distinct !{!35, !12, !16, !17}
!36 = distinct !{!36, !12, !16}
!37 = distinct !{!37, !12, !16}
!38 = distinct !{!38, !12, !16, !17}
!39 = distinct !{!39, !12, !17, !16}
!40 = distinct !{!40, !12}
!41 = distinct !{!41, !12}
!42 = distinct !{!42, !12}
!43 = distinct !{!43, !12}
!44 = distinct !{!44, !12}
!45 = distinct !{!45, !12}
!46 = distinct !{!46, !12, !16, !17}
!47 = distinct !{!47, !12, !16, !17}
!48 = distinct !{!48, !12, !16}
!49 = distinct !{!49, !12, !16}
!50 = !{!51}
!51 = distinct !{!51, !52}
!52 = distinct !{!52, !"LVerDomain"}
!53 = !{!54}
!54 = distinct !{!54, !52}
!55 = !{!56}
!56 = distinct !{!56, !52}
!57 = !{!54, !51}
!58 = distinct !{!58, !12, !16, !17}
!59 = distinct !{!59, !12, !16}
!60 = distinct !{!60, !12, !16, !17}
!61 = distinct !{!61, !12, !16}
!62 = distinct !{!62, !12, !16, !17}
!63 = distinct !{!63, !12, !16}
!64 = distinct !{!64, !12, !16, !17}
!65 = distinct !{!65, !12, !16}
!66 = distinct !{!66, !12, !16, !17}
!67 = distinct !{!67, !12, !16}
!68 = distinct !{!68, !12}
