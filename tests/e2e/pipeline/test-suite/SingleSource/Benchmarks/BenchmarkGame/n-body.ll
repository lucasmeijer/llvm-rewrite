; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/BenchmarkGame/n-body.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/BenchmarkGame/n-body.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/BenchmarkGame/n-body.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.planet = type { double, double, double, double, double, double, double }

@bodies = dso_local global [5 x %struct.planet] [%struct.planet { double 0.000000e+00, double 0.000000e+00, double 0.000000e+00, double 0.000000e+00, double 0.000000e+00, double 0.000000e+00, double f0x4043BD3CC9BE45DE }, %struct.planet { double f0x40135DA0343CD92C, double f0xBFF290ABC01FDB7C, double f0xBFBA86F96C25EBF0, double f0x3FE367069B93CCBC, double f0x40067EF2F57D949B, double f0xBF99D2D79A5A0715, double f0x3FA34C95D9AB33D8 }, %struct.planet { double f0x4020AFCDC332CA67, double f0x40107FCB31DE01B0, double f0xBFD9D353E1EB467C, double f0xBFF02C21B8879442, double f0x3FFD35E9BF1F8F13, double f0x3F813C485F1123B4, double f0x3F871D490D07C637 }, %struct.planet { double f0x4029C9EACEA7D9CF, double f0xC02E38E8D626667E, double f0xBFCC9557BE257DA0, double f0x3FF1531CA9911BEF, double f0x3FEBCC7F3E54BBC5, double f0xBF862F6BFAF23E7C, double f0x3F5C3DD29CF41EB3 }, %struct.planet { double f0x402EC267A905572A, double f0xC039EB5833C8A220, double f0x3FC6F1F393ABE540, double f0x3FEF54B61659BC4A, double f0x3FE307C631C4FBA3, double f0xBFA1CB88587665F6, double f0x3F60A8F3531799AC }], align 16
@.str = private unnamed_addr constant [6 x i8] c"%.9f\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local void @advance(i32 noundef %0, ptr noundef %1, double noundef %2) #0 {
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca double, align 8
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca ptr, align 8
  %10 = alloca ptr, align 8
  %11 = alloca double, align 8
  %12 = alloca double, align 8
  %13 = alloca double, align 8
  %14 = alloca double, align 8
  %15 = alloca double, align 8
  %16 = alloca ptr, align 8
  store i32 %0, ptr %4, align 4, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !10
  store double %2, ptr %6, align 8, !tbaa !13
  call void @llvm.lifetime.start.p0(ptr %7) #5
  call void @llvm.lifetime.start.p0(ptr %8) #5
  store i32 0, ptr %7, align 4, !tbaa !9
  br label %17

17:                                               ; preds = %142, %3
  %18 = load i32, ptr %7, align 4, !tbaa !9
  %19 = load i32, ptr %4, align 4, !tbaa !9
  %20 = icmp slt i32 %18, %19
  br i1 %20, label %21, label %145

21:                                               ; preds = %17
  call void @llvm.lifetime.start.p0(ptr %9) #5
  %22 = load ptr, ptr %5, align 8, !tbaa !10
  %23 = load i32, ptr %7, align 4, !tbaa !9
  %24 = sext i32 %23 to i64
  %25 = getelementptr inbounds %struct.planet, ptr %22, i64 %24
  store ptr %25, ptr %9, align 8, !tbaa !10
  %26 = load i32, ptr %7, align 4, !tbaa !9
  %27 = add nsw i32 %26, 1
  store i32 %27, ptr %8, align 4, !tbaa !9
  br label %28

28:                                               ; preds = %138, %21
  %29 = load i32, ptr %8, align 4, !tbaa !9
  %30 = load i32, ptr %4, align 4, !tbaa !9
  %31 = icmp slt i32 %29, %30
  br i1 %31, label %32, label %141

32:                                               ; preds = %28
  call void @llvm.lifetime.start.p0(ptr %10) #5
  %33 = load ptr, ptr %5, align 8, !tbaa !10
  %34 = load i32, ptr %8, align 4, !tbaa !9
  %35 = sext i32 %34 to i64
  %36 = getelementptr inbounds %struct.planet, ptr %33, i64 %35
  store ptr %36, ptr %10, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %11) #5
  %37 = load ptr, ptr %9, align 8, !tbaa !10
  %38 = getelementptr inbounds nuw %struct.planet, ptr %37, i32 0, i32 0
  %39 = load double, ptr %38, align 8, !tbaa !15
  %40 = load ptr, ptr %10, align 8, !tbaa !10
  %41 = getelementptr inbounds nuw %struct.planet, ptr %40, i32 0, i32 0
  %42 = load double, ptr %41, align 8, !tbaa !15
  %43 = fsub double %39, %42
  store double %43, ptr %11, align 8, !tbaa !13
  call void @llvm.lifetime.start.p0(ptr %12) #5
  %44 = load ptr, ptr %9, align 8, !tbaa !10
  %45 = getelementptr inbounds nuw %struct.planet, ptr %44, i32 0, i32 1
  %46 = load double, ptr %45, align 8, !tbaa !17
  %47 = load ptr, ptr %10, align 8, !tbaa !10
  %48 = getelementptr inbounds nuw %struct.planet, ptr %47, i32 0, i32 1
  %49 = load double, ptr %48, align 8, !tbaa !17
  %50 = fsub double %46, %49
  store double %50, ptr %12, align 8, !tbaa !13
  call void @llvm.lifetime.start.p0(ptr %13) #5
  %51 = load ptr, ptr %9, align 8, !tbaa !10
  %52 = getelementptr inbounds nuw %struct.planet, ptr %51, i32 0, i32 2
  %53 = load double, ptr %52, align 8, !tbaa !18
  %54 = load ptr, ptr %10, align 8, !tbaa !10
  %55 = getelementptr inbounds nuw %struct.planet, ptr %54, i32 0, i32 2
  %56 = load double, ptr %55, align 8, !tbaa !18
  %57 = fsub double %53, %56
  store double %57, ptr %13, align 8, !tbaa !13
  call void @llvm.lifetime.start.p0(ptr %14) #5
  %58 = load double, ptr %11, align 8, !tbaa !13
  %59 = load double, ptr %11, align 8, !tbaa !13
  %60 = load double, ptr %12, align 8, !tbaa !13
  %61 = load double, ptr %12, align 8, !tbaa !13
  %62 = fmul double %60, %61
  %63 = call double @llvm.fmuladd.f64(double %58, double %59, double %62)
  %64 = load double, ptr %13, align 8, !tbaa !13
  %65 = load double, ptr %13, align 8, !tbaa !13
  %66 = call double @llvm.fmuladd.f64(double %64, double %65, double %63)
  %67 = call double @sqrt(double noundef %66) #5
  store double %67, ptr %14, align 8, !tbaa !13
  call void @llvm.lifetime.start.p0(ptr %15) #5
  %68 = load double, ptr %6, align 8, !tbaa !13
  %69 = load double, ptr %14, align 8, !tbaa !13
  %70 = load double, ptr %14, align 8, !tbaa !13
  %71 = fmul double %69, %70
  %72 = load double, ptr %14, align 8, !tbaa !13
  %73 = fmul double %71, %72
  %74 = fdiv double %68, %73
  store double %74, ptr %15, align 8, !tbaa !13
  %75 = load double, ptr %11, align 8, !tbaa !13
  %76 = load ptr, ptr %10, align 8, !tbaa !10
  %77 = getelementptr inbounds nuw %struct.planet, ptr %76, i32 0, i32 6
  %78 = load double, ptr %77, align 8, !tbaa !19
  %79 = fmul double %75, %78
  %80 = load double, ptr %15, align 8, !tbaa !13
  %81 = load ptr, ptr %9, align 8, !tbaa !10
  %82 = getelementptr inbounds nuw %struct.planet, ptr %81, i32 0, i32 3
  %83 = load double, ptr %82, align 8, !tbaa !20
  %84 = fneg double %79
  %85 = call double @llvm.fmuladd.f64(double %84, double %80, double %83)
  store double %85, ptr %82, align 8, !tbaa !20
  %86 = load double, ptr %12, align 8, !tbaa !13
  %87 = load ptr, ptr %10, align 8, !tbaa !10
  %88 = getelementptr inbounds nuw %struct.planet, ptr %87, i32 0, i32 6
  %89 = load double, ptr %88, align 8, !tbaa !19
  %90 = fmul double %86, %89
  %91 = load double, ptr %15, align 8, !tbaa !13
  %92 = load ptr, ptr %9, align 8, !tbaa !10
  %93 = getelementptr inbounds nuw %struct.planet, ptr %92, i32 0, i32 4
  %94 = load double, ptr %93, align 8, !tbaa !21
  %95 = fneg double %90
  %96 = call double @llvm.fmuladd.f64(double %95, double %91, double %94)
  store double %96, ptr %93, align 8, !tbaa !21
  %97 = load double, ptr %13, align 8, !tbaa !13
  %98 = load ptr, ptr %10, align 8, !tbaa !10
  %99 = getelementptr inbounds nuw %struct.planet, ptr %98, i32 0, i32 6
  %100 = load double, ptr %99, align 8, !tbaa !19
  %101 = fmul double %97, %100
  %102 = load double, ptr %15, align 8, !tbaa !13
  %103 = load ptr, ptr %9, align 8, !tbaa !10
  %104 = getelementptr inbounds nuw %struct.planet, ptr %103, i32 0, i32 5
  %105 = load double, ptr %104, align 8, !tbaa !22
  %106 = fneg double %101
  %107 = call double @llvm.fmuladd.f64(double %106, double %102, double %105)
  store double %107, ptr %104, align 8, !tbaa !22
  %108 = load double, ptr %11, align 8, !tbaa !13
  %109 = load ptr, ptr %9, align 8, !tbaa !10
  %110 = getelementptr inbounds nuw %struct.planet, ptr %109, i32 0, i32 6
  %111 = load double, ptr %110, align 8, !tbaa !19
  %112 = fmul double %108, %111
  %113 = load double, ptr %15, align 8, !tbaa !13
  %114 = load ptr, ptr %10, align 8, !tbaa !10
  %115 = getelementptr inbounds nuw %struct.planet, ptr %114, i32 0, i32 3
  %116 = load double, ptr %115, align 8, !tbaa !20
  %117 = call double @llvm.fmuladd.f64(double %112, double %113, double %116)
  store double %117, ptr %115, align 8, !tbaa !20
  %118 = load double, ptr %12, align 8, !tbaa !13
  %119 = load ptr, ptr %9, align 8, !tbaa !10
  %120 = getelementptr inbounds nuw %struct.planet, ptr %119, i32 0, i32 6
  %121 = load double, ptr %120, align 8, !tbaa !19
  %122 = fmul double %118, %121
  %123 = load double, ptr %15, align 8, !tbaa !13
  %124 = load ptr, ptr %10, align 8, !tbaa !10
  %125 = getelementptr inbounds nuw %struct.planet, ptr %124, i32 0, i32 4
  %126 = load double, ptr %125, align 8, !tbaa !21
  %127 = call double @llvm.fmuladd.f64(double %122, double %123, double %126)
  store double %127, ptr %125, align 8, !tbaa !21
  %128 = load double, ptr %13, align 8, !tbaa !13
  %129 = load ptr, ptr %9, align 8, !tbaa !10
  %130 = getelementptr inbounds nuw %struct.planet, ptr %129, i32 0, i32 6
  %131 = load double, ptr %130, align 8, !tbaa !19
  %132 = fmul double %128, %131
  %133 = load double, ptr %15, align 8, !tbaa !13
  %134 = load ptr, ptr %10, align 8, !tbaa !10
  %135 = getelementptr inbounds nuw %struct.planet, ptr %134, i32 0, i32 5
  %136 = load double, ptr %135, align 8, !tbaa !22
  %137 = call double @llvm.fmuladd.f64(double %132, double %133, double %136)
  store double %137, ptr %135, align 8, !tbaa !22
  call void @llvm.lifetime.end.p0(ptr %15) #5
  call void @llvm.lifetime.end.p0(ptr %14) #5
  call void @llvm.lifetime.end.p0(ptr %13) #5
  call void @llvm.lifetime.end.p0(ptr %12) #5
  call void @llvm.lifetime.end.p0(ptr %11) #5
  call void @llvm.lifetime.end.p0(ptr %10) #5
  br label %138

138:                                              ; preds = %32
  %139 = load i32, ptr %8, align 4, !tbaa !9
  %140 = add nsw i32 %139, 1
  store i32 %140, ptr %8, align 4, !tbaa !9
  br label %28, !llvm.loop !23

141:                                              ; preds = %28
  call void @llvm.lifetime.end.p0(ptr %9) #5
  br label %142

142:                                              ; preds = %141
  %143 = load i32, ptr %7, align 4, !tbaa !9
  %144 = add nsw i32 %143, 1
  store i32 %144, ptr %7, align 4, !tbaa !9
  br label %17, !llvm.loop !25

145:                                              ; preds = %17
  store i32 0, ptr %7, align 4, !tbaa !9
  br label %146

146:                                              ; preds = %179, %145
  %147 = load i32, ptr %7, align 4, !tbaa !9
  %148 = load i32, ptr %4, align 4, !tbaa !9
  %149 = icmp slt i32 %147, %148
  br i1 %149, label %150, label %182

150:                                              ; preds = %146
  call void @llvm.lifetime.start.p0(ptr %16) #5
  %151 = load ptr, ptr %5, align 8, !tbaa !10
  %152 = load i32, ptr %7, align 4, !tbaa !9
  %153 = sext i32 %152 to i64
  %154 = getelementptr inbounds %struct.planet, ptr %151, i64 %153
  store ptr %154, ptr %16, align 8, !tbaa !10
  %155 = load double, ptr %6, align 8, !tbaa !13
  %156 = load ptr, ptr %16, align 8, !tbaa !10
  %157 = getelementptr inbounds nuw %struct.planet, ptr %156, i32 0, i32 3
  %158 = load double, ptr %157, align 8, !tbaa !20
  %159 = load ptr, ptr %16, align 8, !tbaa !10
  %160 = getelementptr inbounds nuw %struct.planet, ptr %159, i32 0, i32 0
  %161 = load double, ptr %160, align 8, !tbaa !15
  %162 = call double @llvm.fmuladd.f64(double %155, double %158, double %161)
  store double %162, ptr %160, align 8, !tbaa !15
  %163 = load double, ptr %6, align 8, !tbaa !13
  %164 = load ptr, ptr %16, align 8, !tbaa !10
  %165 = getelementptr inbounds nuw %struct.planet, ptr %164, i32 0, i32 4
  %166 = load double, ptr %165, align 8, !tbaa !21
  %167 = load ptr, ptr %16, align 8, !tbaa !10
  %168 = getelementptr inbounds nuw %struct.planet, ptr %167, i32 0, i32 1
  %169 = load double, ptr %168, align 8, !tbaa !17
  %170 = call double @llvm.fmuladd.f64(double %163, double %166, double %169)
  store double %170, ptr %168, align 8, !tbaa !17
  %171 = load double, ptr %6, align 8, !tbaa !13
  %172 = load ptr, ptr %16, align 8, !tbaa !10
  %173 = getelementptr inbounds nuw %struct.planet, ptr %172, i32 0, i32 5
  %174 = load double, ptr %173, align 8, !tbaa !22
  %175 = load ptr, ptr %16, align 8, !tbaa !10
  %176 = getelementptr inbounds nuw %struct.planet, ptr %175, i32 0, i32 2
  %177 = load double, ptr %176, align 8, !tbaa !18
  %178 = call double @llvm.fmuladd.f64(double %171, double %174, double %177)
  store double %178, ptr %176, align 8, !tbaa !18
  call void @llvm.lifetime.end.p0(ptr %16) #5
  br label %179

179:                                              ; preds = %150
  %180 = load i32, ptr %7, align 4, !tbaa !9
  %181 = add nsw i32 %180, 1
  store i32 %181, ptr %7, align 4, !tbaa !9
  br label %146, !llvm.loop !26

182:                                              ; preds = %146
  call void @llvm.lifetime.end.p0(ptr %8) #5
  call void @llvm.lifetime.end.p0(ptr %7) #5
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nounwind
declare double @sqrt(double noundef) #2

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local double @energy(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca ptr, align 8
  %5 = alloca double, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca ptr, align 8
  %9 = alloca ptr, align 8
  %10 = alloca double, align 8
  %11 = alloca double, align 8
  %12 = alloca double, align 8
  %13 = alloca double, align 8
  store i32 %0, ptr %3, align 4, !tbaa !9
  store ptr %1, ptr %4, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %5) #5
  call void @llvm.lifetime.start.p0(ptr %6) #5
  call void @llvm.lifetime.start.p0(ptr %7) #5
  store double 0.000000e+00, ptr %5, align 8, !tbaa !13
  store i32 0, ptr %6, align 4, !tbaa !9
  br label %14

14:                                               ; preds = %107, %2
  %15 = load i32, ptr %6, align 4, !tbaa !9
  %16 = load i32, ptr %3, align 4, !tbaa !9
  %17 = icmp slt i32 %15, %16
  br i1 %17, label %18, label %110

18:                                               ; preds = %14
  call void @llvm.lifetime.start.p0(ptr %8) #5
  %19 = load ptr, ptr %4, align 8, !tbaa !10
  %20 = load i32, ptr %6, align 4, !tbaa !9
  %21 = sext i32 %20 to i64
  %22 = getelementptr inbounds %struct.planet, ptr %19, i64 %21
  store ptr %22, ptr %8, align 8, !tbaa !10
  %23 = load ptr, ptr %8, align 8, !tbaa !10
  %24 = getelementptr inbounds nuw %struct.planet, ptr %23, i32 0, i32 6
  %25 = load double, ptr %24, align 8, !tbaa !19
  %26 = fmul double 5.000000e-01, %25
  %27 = load ptr, ptr %8, align 8, !tbaa !10
  %28 = getelementptr inbounds nuw %struct.planet, ptr %27, i32 0, i32 3
  %29 = load double, ptr %28, align 8, !tbaa !20
  %30 = load ptr, ptr %8, align 8, !tbaa !10
  %31 = getelementptr inbounds nuw %struct.planet, ptr %30, i32 0, i32 3
  %32 = load double, ptr %31, align 8, !tbaa !20
  %33 = load ptr, ptr %8, align 8, !tbaa !10
  %34 = getelementptr inbounds nuw %struct.planet, ptr %33, i32 0, i32 4
  %35 = load double, ptr %34, align 8, !tbaa !21
  %36 = load ptr, ptr %8, align 8, !tbaa !10
  %37 = getelementptr inbounds nuw %struct.planet, ptr %36, i32 0, i32 4
  %38 = load double, ptr %37, align 8, !tbaa !21
  %39 = fmul double %35, %38
  %40 = call double @llvm.fmuladd.f64(double %29, double %32, double %39)
  %41 = load ptr, ptr %8, align 8, !tbaa !10
  %42 = getelementptr inbounds nuw %struct.planet, ptr %41, i32 0, i32 5
  %43 = load double, ptr %42, align 8, !tbaa !22
  %44 = load ptr, ptr %8, align 8, !tbaa !10
  %45 = getelementptr inbounds nuw %struct.planet, ptr %44, i32 0, i32 5
  %46 = load double, ptr %45, align 8, !tbaa !22
  %47 = call double @llvm.fmuladd.f64(double %43, double %46, double %40)
  %48 = load double, ptr %5, align 8, !tbaa !13
  %49 = call double @llvm.fmuladd.f64(double %26, double %47, double %48)
  store double %49, ptr %5, align 8, !tbaa !13
  %50 = load i32, ptr %6, align 4, !tbaa !9
  %51 = add nsw i32 %50, 1
  store i32 %51, ptr %7, align 4, !tbaa !9
  br label %52

52:                                               ; preds = %103, %18
  %53 = load i32, ptr %7, align 4, !tbaa !9
  %54 = load i32, ptr %3, align 4, !tbaa !9
  %55 = icmp slt i32 %53, %54
  br i1 %55, label %56, label %106

56:                                               ; preds = %52
  call void @llvm.lifetime.start.p0(ptr %9) #5
  %57 = load ptr, ptr %4, align 8, !tbaa !10
  %58 = load i32, ptr %7, align 4, !tbaa !9
  %59 = sext i32 %58 to i64
  %60 = getelementptr inbounds %struct.planet, ptr %57, i64 %59
  store ptr %60, ptr %9, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %10) #5
  %61 = load ptr, ptr %8, align 8, !tbaa !10
  %62 = getelementptr inbounds nuw %struct.planet, ptr %61, i32 0, i32 0
  %63 = load double, ptr %62, align 8, !tbaa !15
  %64 = load ptr, ptr %9, align 8, !tbaa !10
  %65 = getelementptr inbounds nuw %struct.planet, ptr %64, i32 0, i32 0
  %66 = load double, ptr %65, align 8, !tbaa !15
  %67 = fsub double %63, %66
  store double %67, ptr %10, align 8, !tbaa !13
  call void @llvm.lifetime.start.p0(ptr %11) #5
  %68 = load ptr, ptr %8, align 8, !tbaa !10
  %69 = getelementptr inbounds nuw %struct.planet, ptr %68, i32 0, i32 1
  %70 = load double, ptr %69, align 8, !tbaa !17
  %71 = load ptr, ptr %9, align 8, !tbaa !10
  %72 = getelementptr inbounds nuw %struct.planet, ptr %71, i32 0, i32 1
  %73 = load double, ptr %72, align 8, !tbaa !17
  %74 = fsub double %70, %73
  store double %74, ptr %11, align 8, !tbaa !13
  call void @llvm.lifetime.start.p0(ptr %12) #5
  %75 = load ptr, ptr %8, align 8, !tbaa !10
  %76 = getelementptr inbounds nuw %struct.planet, ptr %75, i32 0, i32 2
  %77 = load double, ptr %76, align 8, !tbaa !18
  %78 = load ptr, ptr %9, align 8, !tbaa !10
  %79 = getelementptr inbounds nuw %struct.planet, ptr %78, i32 0, i32 2
  %80 = load double, ptr %79, align 8, !tbaa !18
  %81 = fsub double %77, %80
  store double %81, ptr %12, align 8, !tbaa !13
  call void @llvm.lifetime.start.p0(ptr %13) #5
  %82 = load double, ptr %10, align 8, !tbaa !13
  %83 = load double, ptr %10, align 8, !tbaa !13
  %84 = load double, ptr %11, align 8, !tbaa !13
  %85 = load double, ptr %11, align 8, !tbaa !13
  %86 = fmul double %84, %85
  %87 = call double @llvm.fmuladd.f64(double %82, double %83, double %86)
  %88 = load double, ptr %12, align 8, !tbaa !13
  %89 = load double, ptr %12, align 8, !tbaa !13
  %90 = call double @llvm.fmuladd.f64(double %88, double %89, double %87)
  %91 = call double @sqrt(double noundef %90) #5
  store double %91, ptr %13, align 8, !tbaa !13
  %92 = load ptr, ptr %8, align 8, !tbaa !10
  %93 = getelementptr inbounds nuw %struct.planet, ptr %92, i32 0, i32 6
  %94 = load double, ptr %93, align 8, !tbaa !19
  %95 = load ptr, ptr %9, align 8, !tbaa !10
  %96 = getelementptr inbounds nuw %struct.planet, ptr %95, i32 0, i32 6
  %97 = load double, ptr %96, align 8, !tbaa !19
  %98 = fmul double %94, %97
  %99 = load double, ptr %13, align 8, !tbaa !13
  %100 = fdiv double %98, %99
  %101 = load double, ptr %5, align 8, !tbaa !13
  %102 = fsub double %101, %100
  store double %102, ptr %5, align 8, !tbaa !13
  call void @llvm.lifetime.end.p0(ptr %13) #5
  call void @llvm.lifetime.end.p0(ptr %12) #5
  call void @llvm.lifetime.end.p0(ptr %11) #5
  call void @llvm.lifetime.end.p0(ptr %10) #5
  call void @llvm.lifetime.end.p0(ptr %9) #5
  br label %103

103:                                              ; preds = %56
  %104 = load i32, ptr %7, align 4, !tbaa !9
  %105 = add nsw i32 %104, 1
  store i32 %105, ptr %7, align 4, !tbaa !9
  br label %52, !llvm.loop !27

106:                                              ; preds = %52
  call void @llvm.lifetime.end.p0(ptr %8) #5
  br label %107

107:                                              ; preds = %106
  %108 = load i32, ptr %6, align 4, !tbaa !9
  %109 = add nsw i32 %108, 1
  store i32 %109, ptr %6, align 4, !tbaa !9
  br label %14, !llvm.loop !28

110:                                              ; preds = %14
  %111 = load double, ptr %5, align 8, !tbaa !13
  call void @llvm.lifetime.end.p0(ptr %7) #5
  call void @llvm.lifetime.end.p0(ptr %6) #5
  call void @llvm.lifetime.end.p0(ptr %5) #5
  ret double %111
}

; Function Attrs: nounwind uwtable
define dso_local void @offset_momentum(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca ptr, align 8
  %5 = alloca double, align 8
  %6 = alloca double, align 8
  %7 = alloca double, align 8
  %8 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !9
  store ptr %1, ptr %4, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %5) #5
  store double 0.000000e+00, ptr %5, align 8, !tbaa !13
  call void @llvm.lifetime.start.p0(ptr %6) #5
  store double 0.000000e+00, ptr %6, align 8, !tbaa !13
  call void @llvm.lifetime.start.p0(ptr %7) #5
  store double 0.000000e+00, ptr %7, align 8, !tbaa !13
  call void @llvm.lifetime.start.p0(ptr %8) #5
  store i32 0, ptr %8, align 4, !tbaa !9
  br label %9

9:                                                ; preds = %56, %2
  %10 = load i32, ptr %8, align 4, !tbaa !9
  %11 = load i32, ptr %3, align 4, !tbaa !9
  %12 = icmp slt i32 %10, %11
  br i1 %12, label %13, label %59

13:                                               ; preds = %9
  %14 = load ptr, ptr %4, align 8, !tbaa !10
  %15 = load i32, ptr %8, align 4, !tbaa !9
  %16 = sext i32 %15 to i64
  %17 = getelementptr inbounds %struct.planet, ptr %14, i64 %16
  %18 = getelementptr inbounds nuw %struct.planet, ptr %17, i32 0, i32 3
  %19 = load double, ptr %18, align 8, !tbaa !20
  %20 = load ptr, ptr %4, align 8, !tbaa !10
  %21 = load i32, ptr %8, align 4, !tbaa !9
  %22 = sext i32 %21 to i64
  %23 = getelementptr inbounds %struct.planet, ptr %20, i64 %22
  %24 = getelementptr inbounds nuw %struct.planet, ptr %23, i32 0, i32 6
  %25 = load double, ptr %24, align 8, !tbaa !19
  %26 = load double, ptr %5, align 8, !tbaa !13
  %27 = call double @llvm.fmuladd.f64(double %19, double %25, double %26)
  store double %27, ptr %5, align 8, !tbaa !13
  %28 = load ptr, ptr %4, align 8, !tbaa !10
  %29 = load i32, ptr %8, align 4, !tbaa !9
  %30 = sext i32 %29 to i64
  %31 = getelementptr inbounds %struct.planet, ptr %28, i64 %30
  %32 = getelementptr inbounds nuw %struct.planet, ptr %31, i32 0, i32 4
  %33 = load double, ptr %32, align 8, !tbaa !21
  %34 = load ptr, ptr %4, align 8, !tbaa !10
  %35 = load i32, ptr %8, align 4, !tbaa !9
  %36 = sext i32 %35 to i64
  %37 = getelementptr inbounds %struct.planet, ptr %34, i64 %36
  %38 = getelementptr inbounds nuw %struct.planet, ptr %37, i32 0, i32 6
  %39 = load double, ptr %38, align 8, !tbaa !19
  %40 = load double, ptr %6, align 8, !tbaa !13
  %41 = call double @llvm.fmuladd.f64(double %33, double %39, double %40)
  store double %41, ptr %6, align 8, !tbaa !13
  %42 = load ptr, ptr %4, align 8, !tbaa !10
  %43 = load i32, ptr %8, align 4, !tbaa !9
  %44 = sext i32 %43 to i64
  %45 = getelementptr inbounds %struct.planet, ptr %42, i64 %44
  %46 = getelementptr inbounds nuw %struct.planet, ptr %45, i32 0, i32 5
  %47 = load double, ptr %46, align 8, !tbaa !22
  %48 = load ptr, ptr %4, align 8, !tbaa !10
  %49 = load i32, ptr %8, align 4, !tbaa !9
  %50 = sext i32 %49 to i64
  %51 = getelementptr inbounds %struct.planet, ptr %48, i64 %50
  %52 = getelementptr inbounds nuw %struct.planet, ptr %51, i32 0, i32 6
  %53 = load double, ptr %52, align 8, !tbaa !19
  %54 = load double, ptr %7, align 8, !tbaa !13
  %55 = call double @llvm.fmuladd.f64(double %47, double %53, double %54)
  store double %55, ptr %7, align 8, !tbaa !13
  br label %56

56:                                               ; preds = %13
  %57 = load i32, ptr %8, align 4, !tbaa !9
  %58 = add nsw i32 %57, 1
  store i32 %58, ptr %8, align 4, !tbaa !9
  br label %9, !llvm.loop !29

59:                                               ; preds = %9
  %60 = load double, ptr %5, align 8, !tbaa !13
  %61 = fneg double %60
  %62 = fdiv double %61, f0x4043BD3CC9BE45DE
  %63 = load ptr, ptr %4, align 8, !tbaa !10
  %64 = getelementptr inbounds %struct.planet, ptr %63, i64 0
  %65 = getelementptr inbounds nuw %struct.planet, ptr %64, i32 0, i32 3
  store double %62, ptr %65, align 8, !tbaa !20
  %66 = load double, ptr %6, align 8, !tbaa !13
  %67 = fneg double %66
  %68 = fdiv double %67, f0x4043BD3CC9BE45DE
  %69 = load ptr, ptr %4, align 8, !tbaa !10
  %70 = getelementptr inbounds %struct.planet, ptr %69, i64 0
  %71 = getelementptr inbounds nuw %struct.planet, ptr %70, i32 0, i32 4
  store double %68, ptr %71, align 8, !tbaa !21
  %72 = load double, ptr %7, align 8, !tbaa !13
  %73 = fneg double %72
  %74 = fdiv double %73, f0x4043BD3CC9BE45DE
  %75 = load ptr, ptr %4, align 8, !tbaa !10
  %76 = getelementptr inbounds %struct.planet, ptr %75, i64 0
  %77 = getelementptr inbounds nuw %struct.planet, ptr %76, i32 0, i32 5
  store double %74, ptr %77, align 8, !tbaa !22
  call void @llvm.lifetime.end.p0(ptr %8) #5
  call void @llvm.lifetime.end.p0(ptr %7) #5
  call void @llvm.lifetime.end.p0(ptr %6) #5
  call void @llvm.lifetime.end.p0(ptr %5) #5
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !30
  call void @llvm.lifetime.start.p0(ptr %6) #5
  store i32 5000000, ptr %6, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %7) #5
  call void @offset_momentum(i32 noundef 5, ptr noundef @bodies)
  %8 = call double @energy(i32 noundef 5, ptr noundef @bodies)
  %9 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %8)
  store i32 1, ptr %7, align 4, !tbaa !9
  br label %10

10:                                               ; preds = %15, %2
  %11 = load i32, ptr %7, align 4, !tbaa !9
  %12 = load i32, ptr %6, align 4, !tbaa !9
  %13 = icmp sle i32 %11, %12
  br i1 %13, label %14, label %18

14:                                               ; preds = %10
  call void @advance(i32 noundef 5, ptr noundef @bodies, double noundef 1.000000e-02)
  br label %15

15:                                               ; preds = %14
  %16 = load i32, ptr %7, align 4, !tbaa !9
  %17 = add nsw i32 %16, 1
  store i32 %17, ptr %7, align 4, !tbaa !9
  br label %10, !llvm.loop !33

18:                                               ; preds = %10
  %19 = call double @energy(i32 noundef 5, ptr noundef @bodies)
  %20 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %19)
  call void @llvm.lifetime.end.p0(ptr %7) #5
  call void @llvm.lifetime.end.p0(ptr %6) #5
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #4

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #4 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!9 = !{!6, !6, i64 0}
!10 = !{!11, !11, i64 0}
!11 = !{!"p1 _ZTS6planet", !12, i64 0}
!12 = !{!"any pointer", !7, i64 0}
!13 = !{!14, !14, i64 0}
!14 = !{!"double", !7, i64 0}
!15 = !{!16, !14, i64 0}
!16 = !{!"planet", !14, i64 0, !14, i64 8, !14, i64 16, !14, i64 24, !14, i64 32, !14, i64 40, !14, i64 48}
!17 = !{!16, !14, i64 8}
!18 = !{!16, !14, i64 16}
!19 = !{!16, !14, i64 48}
!20 = !{!16, !14, i64 24}
!21 = !{!16, !14, i64 32}
!22 = !{!16, !14, i64 40}
!23 = distinct !{!23, !24}
!24 = !{!"llvm.loop.mustprogress"}
!25 = distinct !{!25, !24}
!26 = distinct !{!26, !24}
!27 = distinct !{!27, !24}
!28 = distinct !{!28, !24}
!29 = distinct !{!29, !24}
!30 = !{!31, !31, i64 0}
!31 = !{!"p2 omnipotent char", !32, i64 0}
!32 = !{!"any p2 pointer", !12, i64 0}
!33 = distinct !{!33, !24}
