; @source: tests/function/src/abi/struct_shapes.c
; @opt: -O2
; @llc: -O2
; @driver: tests/function/src/abi/struct_shapes.driver.c
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/function/src/abi/struct_shapes.c'
source_filename = "tests/function/src/abi/struct_shapes.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.c1 = type { i8 }
%struct.c3 = type { i8, i8, i8 }
%struct.sh = type { i16, i8 }
%struct.ii = type { i32, i32 }
%struct.iii = type { i32, i32, i32 }
%struct.ll = type { i64, i64 }
%struct.lll = type { i64, i64, i64 }
%struct.ff = type { float, float }
%struct.fff = type { float, float, float }
%struct.dd = type { double, double }
%struct.id = type { i32, double }
%struct.di = type { double, i32 }
%struct.fi = type { float, i32 }
%struct.big = type { [10 x i32] }

; Function Attrs: nounwind uwtable
define dso_local i32 @sum_c1(i8 %0) #0 {
  %2 = alloca %struct.c1, align 1
  %3 = getelementptr inbounds nuw %struct.c1, ptr %2, i32 0, i32 0
  store i8 %0, ptr %3, align 1
  %4 = getelementptr inbounds nuw %struct.c1, ptr %2, i32 0, i32 0
  %5 = load i8, ptr %4, align 1, !tbaa !9
  %6 = sext i8 %5 to i32
  ret i32 %6
}

; Function Attrs: nounwind uwtable
define dso_local i32 @sum_c3(i24 %0) #0 {
  %2 = alloca %struct.c3, align 1
  store i24 %0, ptr %2, align 1
  %3 = getelementptr inbounds nuw %struct.c3, ptr %2, i32 0, i32 0
  %4 = load i8, ptr %3, align 1, !tbaa !11
  %5 = sext i8 %4 to i32
  %6 = getelementptr inbounds nuw %struct.c3, ptr %2, i32 0, i32 1
  %7 = load i8, ptr %6, align 1, !tbaa !13
  %8 = sext i8 %7 to i32
  %9 = mul nsw i32 %8, 3
  %10 = add nsw i32 %5, %9
  %11 = getelementptr inbounds nuw %struct.c3, ptr %2, i32 0, i32 2
  %12 = load i8, ptr %11, align 1, !tbaa !14
  %13 = sext i8 %12 to i32
  %14 = mul nsw i32 %13, 5
  %15 = add nsw i32 %10, %14
  ret i32 %15
}

; Function Attrs: nounwind uwtable
define dso_local i32 @sum_sh(i32 %0) #0 {
  %2 = alloca %struct.sh, align 2
  store i32 %0, ptr %2, align 2
  %3 = getelementptr inbounds nuw %struct.sh, ptr %2, i32 0, i32 0
  %4 = load i16, ptr %3, align 2, !tbaa !15
  %5 = sext i16 %4 to i32
  %6 = mul nsw i32 %5, 2
  %7 = getelementptr inbounds nuw %struct.sh, ptr %2, i32 0, i32 1
  %8 = load i8, ptr %7, align 2, !tbaa !18
  %9 = sext i8 %8 to i32
  %10 = add nsw i32 %6, %9
  ret i32 %10
}

; Function Attrs: nounwind uwtable
define dso_local i64 @sum_ii(i64 %0) #0 {
  %2 = alloca %struct.ii, align 4
  store i64 %0, ptr %2, align 4
  %3 = getelementptr inbounds nuw %struct.ii, ptr %2, i32 0, i32 0
  %4 = load i32, ptr %3, align 4, !tbaa !19
  %5 = sext i32 %4 to i64
  %6 = mul nsw i64 %5, 7
  %7 = getelementptr inbounds nuw %struct.ii, ptr %2, i32 0, i32 1
  %8 = load i32, ptr %7, align 4, !tbaa !21
  %9 = sext i32 %8 to i64
  %10 = add nsw i64 %6, %9
  ret i64 %10
}

; Function Attrs: nounwind uwtable
define dso_local i64 @sum_iii(i64 %0, i32 %1) #0 {
  %3 = alloca %struct.iii, align 4
  %4 = alloca { i64, i32 }, align 4
  %5 = getelementptr inbounds nuw { i64, i32 }, ptr %4, i32 0, i32 0
  store i64 %0, ptr %5, align 4
  %6 = getelementptr inbounds nuw { i64, i32 }, ptr %4, i32 0, i32 1
  store i32 %1, ptr %6, align 4
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %3, ptr align 4 %4, i64 12, i1 false)
  %7 = getelementptr inbounds nuw %struct.iii, ptr %3, i32 0, i32 0
  %8 = load i32, ptr %7, align 4, !tbaa !22
  %9 = sext i32 %8 to i64
  %10 = getelementptr inbounds nuw %struct.iii, ptr %3, i32 0, i32 1
  %11 = load i32, ptr %10, align 4, !tbaa !24
  %12 = sext i32 %11 to i64
  %13 = mul nsw i64 %12, 2
  %14 = add nsw i64 %9, %13
  %15 = getelementptr inbounds nuw %struct.iii, ptr %3, i32 0, i32 2
  %16 = load i32, ptr %15, align 4, !tbaa !25
  %17 = sext i32 %16 to i64
  %18 = mul nsw i64 %17, 3
  %19 = add nsw i64 %14, %18
  ret i64 %19
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

; Function Attrs: nounwind uwtable
define dso_local i64 @sum_ll(i64 %0, i64 %1) #0 {
  %3 = alloca %struct.ll, align 8
  %4 = getelementptr inbounds nuw { i64, i64 }, ptr %3, i32 0, i32 0
  store i64 %0, ptr %4, align 8
  %5 = getelementptr inbounds nuw { i64, i64 }, ptr %3, i32 0, i32 1
  store i64 %1, ptr %5, align 8
  %6 = getelementptr inbounds nuw %struct.ll, ptr %3, i32 0, i32 0
  %7 = load i64, ptr %6, align 8, !tbaa !26
  %8 = getelementptr inbounds nuw %struct.ll, ptr %3, i32 0, i32 1
  %9 = load i64, ptr %8, align 8, !tbaa !29
  %10 = sub nsw i64 %7, %9
  ret i64 %10
}

; Function Attrs: nounwind uwtable
define dso_local i64 @sum_lll(ptr noundef byval(%struct.lll) align 8 %0) #0 {
  %2 = getelementptr inbounds nuw %struct.lll, ptr %0, i32 0, i32 0
  %3 = load i64, ptr %2, align 8, !tbaa !30
  %4 = getelementptr inbounds nuw %struct.lll, ptr %0, i32 0, i32 1
  %5 = load i64, ptr %4, align 8, !tbaa !32
  %6 = mul nsw i64 %5, 2
  %7 = add nsw i64 %3, %6
  %8 = getelementptr inbounds nuw %struct.lll, ptr %0, i32 0, i32 2
  %9 = load i64, ptr %8, align 8, !tbaa !33
  %10 = mul nsw i64 %9, 3
  %11 = add nsw i64 %7, %10
  ret i64 %11
}

; Function Attrs: nounwind uwtable
define dso_local double @sum_ff(<2 x float> %0) #2 {
  %2 = alloca %struct.ff, align 4
  store <2 x float> %0, ptr %2, align 4
  %3 = getelementptr inbounds nuw %struct.ff, ptr %2, i32 0, i32 0
  %4 = load float, ptr %3, align 4, !tbaa !34
  %5 = getelementptr inbounds nuw %struct.ff, ptr %2, i32 0, i32 1
  %6 = load float, ptr %5, align 4, !tbaa !37
  %7 = call float @llvm.fmuladd.f32(float %4, float 2.000000e+00, float %6)
  %8 = fpext float %7 to double
  ret double %8
}

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare float @llvm.fmuladd.f32(float, float, float) #3

; Function Attrs: nounwind uwtable
define dso_local double @sum_fff(<2 x float> %0, float %1) #2 {
  %3 = alloca %struct.fff, align 4
  %4 = alloca { <2 x float>, float }, align 4
  %5 = getelementptr inbounds nuw { <2 x float>, float }, ptr %4, i32 0, i32 0
  store <2 x float> %0, ptr %5, align 4
  %6 = getelementptr inbounds nuw { <2 x float>, float }, ptr %4, i32 0, i32 1
  store float %1, ptr %6, align 4
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %3, ptr align 4 %4, i64 12, i1 false)
  %7 = getelementptr inbounds nuw %struct.fff, ptr %3, i32 0, i32 0
  %8 = load float, ptr %7, align 4, !tbaa !38
  %9 = getelementptr inbounds nuw %struct.fff, ptr %3, i32 0, i32 1
  %10 = load float, ptr %9, align 4, !tbaa !40
  %11 = call float @llvm.fmuladd.f32(float %10, float 2.000000e+00, float %8)
  %12 = getelementptr inbounds nuw %struct.fff, ptr %3, i32 0, i32 2
  %13 = load float, ptr %12, align 4, !tbaa !41
  %14 = call float @llvm.fmuladd.f32(float %13, float 3.000000e+00, float %11)
  %15 = fpext float %14 to double
  ret double %15
}

; Function Attrs: nounwind uwtable
define dso_local double @sum_dd(double %0, double %1) #0 {
  %3 = alloca %struct.dd, align 8
  %4 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 0
  store double %0, ptr %4, align 8
  %5 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 1
  store double %1, ptr %5, align 8
  %6 = getelementptr inbounds nuw %struct.dd, ptr %3, i32 0, i32 0
  %7 = load double, ptr %6, align 8, !tbaa !42
  %8 = fdiv double %7, 2.000000e+00
  %9 = getelementptr inbounds nuw %struct.dd, ptr %3, i32 0, i32 1
  %10 = load double, ptr %9, align 8, !tbaa !45
  %11 = fadd double %8, %10
  ret double %11
}

; Function Attrs: nounwind uwtable
define dso_local double @sum_id(i32 %0, double %1) #0 {
  %3 = alloca %struct.id, align 8
  %4 = getelementptr inbounds nuw { i32, double }, ptr %3, i32 0, i32 0
  store i32 %0, ptr %4, align 8
  %5 = getelementptr inbounds nuw { i32, double }, ptr %3, i32 0, i32 1
  store double %1, ptr %5, align 8
  %6 = getelementptr inbounds nuw %struct.id, ptr %3, i32 0, i32 0
  %7 = load i32, ptr %6, align 8, !tbaa !46
  %8 = sitofp i32 %7 to double
  %9 = getelementptr inbounds nuw %struct.id, ptr %3, i32 0, i32 1
  %10 = load double, ptr %9, align 8, !tbaa !48
  %11 = fadd double %8, %10
  ret double %11
}

; Function Attrs: nounwind uwtable
define dso_local double @sum_di(double %0, i32 %1) #0 {
  %3 = alloca %struct.di, align 8
  %4 = getelementptr inbounds nuw { double, i32 }, ptr %3, i32 0, i32 0
  store double %0, ptr %4, align 8
  %5 = getelementptr inbounds nuw { double, i32 }, ptr %3, i32 0, i32 1
  store i32 %1, ptr %5, align 8
  %6 = getelementptr inbounds nuw %struct.di, ptr %3, i32 0, i32 0
  %7 = load double, ptr %6, align 8, !tbaa !49
  %8 = getelementptr inbounds nuw %struct.di, ptr %3, i32 0, i32 1
  %9 = load i32, ptr %8, align 8, !tbaa !51
  %10 = sitofp i32 %9 to double
  %11 = fmul double %7, %10
  ret double %11
}

; Function Attrs: nounwind uwtable
define dso_local double @sum_fi(i64 %0) #0 {
  %2 = alloca %struct.fi, align 4
  store i64 %0, ptr %2, align 4
  %3 = getelementptr inbounds nuw %struct.fi, ptr %2, i32 0, i32 0
  %4 = load float, ptr %3, align 4, !tbaa !52
  %5 = getelementptr inbounds nuw %struct.fi, ptr %2, i32 0, i32 1
  %6 = load i32, ptr %5, align 4, !tbaa !54
  %7 = sitofp i32 %6 to float
  %8 = fsub float %4, %7
  %9 = fpext float %8 to double
  ret double %9
}

; Function Attrs: nounwind uwtable
define dso_local i64 @sum_big(ptr noundef byval(%struct.big) align 8 %0) #0 {
  %2 = alloca i64, align 8
  %3 = alloca i32, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #5
  store i64 0, ptr %2, align 8, !tbaa !55
  call void @llvm.lifetime.start.p0(ptr %3) #5
  store i32 0, ptr %3, align 4, !tbaa !56
  br label %4

4:                                                ; preds = %21, %1
  %5 = load i32, ptr %3, align 4, !tbaa !56
  %6 = icmp slt i32 %5, 10
  br i1 %6, label %8, label %7

7:                                                ; preds = %4
  call void @llvm.lifetime.end.p0(ptr %3) #5
  br label %24

8:                                                ; preds = %4
  %9 = getelementptr inbounds nuw %struct.big, ptr %0, i32 0, i32 0
  %10 = load i32, ptr %3, align 4, !tbaa !56
  %11 = sext i32 %10 to i64
  %12 = getelementptr inbounds [10 x i32], ptr %9, i64 0, i64 %11
  %13 = load i32, ptr %12, align 4, !tbaa !56
  %14 = sext i32 %13 to i64
  %15 = load i32, ptr %3, align 4, !tbaa !56
  %16 = add nsw i32 %15, 1
  %17 = sext i32 %16 to i64
  %18 = mul nsw i64 %14, %17
  %19 = load i64, ptr %2, align 8, !tbaa !55
  %20 = add nsw i64 %19, %18
  store i64 %20, ptr %2, align 8, !tbaa !55
  br label %21

21:                                               ; preds = %8
  %22 = load i32, ptr %3, align 4, !tbaa !56
  %23 = add nsw i32 %22, 1
  store i32 %23, ptr %3, align 4, !tbaa !56
  br label %4, !llvm.loop !57

24:                                               ; preds = %7
  %25 = load i64, ptr %2, align 8, !tbaa !55
  call void @llvm.lifetime.end.p0(ptr %2) #5
  ret i64 %25
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local i24 @mk_c3(i32 noundef %0) #0 {
  %2 = alloca %struct.c3, align 1
  %3 = alloca i32, align 4
  %4 = alloca i24, align 4
  store i32 %0, ptr %3, align 4, !tbaa !56
  %5 = getelementptr inbounds nuw %struct.c3, ptr %2, i32 0, i32 0
  %6 = load i32, ptr %3, align 4, !tbaa !56
  %7 = trunc i32 %6 to i8
  store i8 %7, ptr %5, align 1, !tbaa !11
  %8 = getelementptr inbounds nuw %struct.c3, ptr %2, i32 0, i32 1
  %9 = load i32, ptr %3, align 4, !tbaa !56
  %10 = add nsw i32 %9, 1
  %11 = trunc i32 %10 to i8
  store i8 %11, ptr %8, align 1, !tbaa !13
  %12 = getelementptr inbounds nuw %struct.c3, ptr %2, i32 0, i32 2
  %13 = load i32, ptr %3, align 4, !tbaa !56
  %14 = add nsw i32 %13, 2
  %15 = trunc i32 %14 to i8
  store i8 %15, ptr %12, align 1, !tbaa !14
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %4, ptr align 1 %2, i64 3, i1 false)
  %16 = load i24, ptr %4, align 4
  ret i24 %16
}

; Function Attrs: nounwind uwtable
define dso_local { i64, i32 } @mk_iii(i32 noundef %0) #0 {
  %2 = alloca %struct.iii, align 4
  %3 = alloca i32, align 4
  %4 = alloca { i64, i32 }, align 8
  store i32 %0, ptr %3, align 4, !tbaa !56
  %5 = getelementptr inbounds nuw %struct.iii, ptr %2, i32 0, i32 0
  %6 = load i32, ptr %3, align 4, !tbaa !56
  store i32 %6, ptr %5, align 4, !tbaa !22
  %7 = getelementptr inbounds nuw %struct.iii, ptr %2, i32 0, i32 1
  %8 = load i32, ptr %3, align 4, !tbaa !56
  %9 = sub nsw i32 0, %8
  store i32 %9, ptr %7, align 4, !tbaa !24
  %10 = getelementptr inbounds nuw %struct.iii, ptr %2, i32 0, i32 2
  %11 = load i32, ptr %3, align 4, !tbaa !56
  %12 = mul nsw i32 %11, 3
  store i32 %12, ptr %10, align 4, !tbaa !25
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %4, ptr align 4 %2, i64 12, i1 false)
  %13 = load { i64, i32 }, ptr %4, align 8
  ret { i64, i32 } %13
}

; Function Attrs: nounwind uwtable
define dso_local void @mk_lll(ptr dead_on_unwind noalias writable sret(%struct.lll) align 8 %0, i64 noundef %1) #0 {
  %3 = alloca i64, align 8
  store i64 %1, ptr %3, align 8, !tbaa !55
  %4 = getelementptr inbounds nuw %struct.lll, ptr %0, i32 0, i32 0
  %5 = load i64, ptr %3, align 8, !tbaa !55
  store i64 %5, ptr %4, align 8, !tbaa !30
  %6 = getelementptr inbounds nuw %struct.lll, ptr %0, i32 0, i32 1
  %7 = load i64, ptr %3, align 8, !tbaa !55
  %8 = mul nsw i64 %7, 1048576
  store i64 %8, ptr %6, align 8, !tbaa !32
  %9 = getelementptr inbounds nuw %struct.lll, ptr %0, i32 0, i32 2
  %10 = load i64, ptr %3, align 8, !tbaa !55
  %11 = xor i64 %10, -1
  store i64 %11, ptr %9, align 8, !tbaa !33
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local { <2 x float>, float } @mk_fff(float noundef %0) #0 {
  %2 = alloca %struct.fff, align 4
  %3 = alloca float, align 4
  %4 = alloca { <2 x float>, float }, align 8
  store float %0, ptr %3, align 4, !tbaa !59
  %5 = getelementptr inbounds nuw %struct.fff, ptr %2, i32 0, i32 0
  %6 = load float, ptr %3, align 4, !tbaa !59
  store float %6, ptr %5, align 4, !tbaa !38
  %7 = getelementptr inbounds nuw %struct.fff, ptr %2, i32 0, i32 1
  %8 = load float, ptr %3, align 4, !tbaa !59
  %9 = fmul float %8, 2.000000e+00
  store float %9, ptr %7, align 4, !tbaa !40
  %10 = getelementptr inbounds nuw %struct.fff, ptr %2, i32 0, i32 2
  %11 = load float, ptr %3, align 4, !tbaa !59
  %12 = fmul float %11, 4.000000e+00
  store float %12, ptr %10, align 4, !tbaa !41
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %4, ptr align 4 %2, i64 12, i1 false)
  %13 = load { <2 x float>, float }, ptr %4, align 8
  ret { <2 x float>, float } %13
}

; Function Attrs: nounwind uwtable
define dso_local { double, double } @mk_dd(double noundef %0) #0 {
  %2 = alloca %struct.dd, align 8
  %3 = alloca double, align 8
  store double %0, ptr %3, align 8, !tbaa !60
  %4 = getelementptr inbounds nuw %struct.dd, ptr %2, i32 0, i32 0
  %5 = load double, ptr %3, align 8, !tbaa !60
  store double %5, ptr %4, align 8, !tbaa !42
  %6 = getelementptr inbounds nuw %struct.dd, ptr %2, i32 0, i32 1
  %7 = load double, ptr %3, align 8, !tbaa !60
  %8 = fneg double %7
  store double %8, ptr %6, align 8, !tbaa !45
  %9 = load { double, double }, ptr %2, align 8
  ret { double, double } %9
}

; Function Attrs: nounwind uwtable
define dso_local { i32, double } @mk_id(i32 noundef %0) #0 {
  %2 = alloca %struct.id, align 8
  %3 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !56
  %4 = getelementptr inbounds nuw %struct.id, ptr %2, i32 0, i32 0
  %5 = load i32, ptr %3, align 4, !tbaa !56
  store i32 %5, ptr %4, align 8, !tbaa !46
  %6 = getelementptr i8, ptr %2, i64 4
  call void @llvm.memset.p0.i64(ptr align 4 %6, i8 0, i64 4, i1 false)
  %7 = getelementptr inbounds nuw %struct.id, ptr %2, i32 0, i32 1
  %8 = load i32, ptr %3, align 4, !tbaa !56
  %9 = sitofp i32 %8 to double
  %10 = fdiv double %9, 4.000000e+00
  store double %10, ptr %7, align 8, !tbaa !48
  %11 = load { i32, double }, ptr %2, align 8
  ret { i32, double } %11
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #4

; Function Attrs: nounwind uwtable
define dso_local { double, i32 } @mk_di(double noundef %0) #0 {
  %2 = alloca %struct.di, align 8
  %3 = alloca double, align 8
  store double %0, ptr %3, align 8, !tbaa !60
  %4 = getelementptr inbounds nuw %struct.di, ptr %2, i32 0, i32 0
  %5 = load double, ptr %3, align 8, !tbaa !60
  store double %5, ptr %4, align 8, !tbaa !49
  %6 = getelementptr inbounds nuw %struct.di, ptr %2, i32 0, i32 1
  %7 = load double, ptr %3, align 8, !tbaa !60
  %8 = fptosi double %7 to i32
  %9 = mul nsw i32 %8, 2
  store i32 %9, ptr %6, align 8, !tbaa !51
  %10 = getelementptr i8, ptr %2, i64 12
  call void @llvm.memset.p0.i64(ptr align 4 %10, i8 0, i64 4, i1 false)
  %11 = load { double, i32 }, ptr %2, align 8
  ret { double, i32 } %11
}

; Function Attrs: nounwind uwtable
define dso_local void @mk_big(ptr dead_on_unwind noalias writable sret(%struct.big) align 4 %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 %1, ptr %3, align 4, !tbaa !56
  call void @llvm.lifetime.start.p0(ptr %4) #5
  store i32 0, ptr %4, align 4, !tbaa !56
  br label %5

5:                                                ; preds = %17, %2
  %6 = load i32, ptr %4, align 4, !tbaa !56
  %7 = icmp slt i32 %6, 10
  br i1 %7, label %9, label %8

8:                                                ; preds = %5
  call void @llvm.lifetime.end.p0(ptr %4) #5
  br label %20

9:                                                ; preds = %5
  %10 = load i32, ptr %3, align 4, !tbaa !56
  %11 = load i32, ptr %4, align 4, !tbaa !56
  %12 = mul nsw i32 %10, %11
  %13 = getelementptr inbounds nuw %struct.big, ptr %0, i32 0, i32 0
  %14 = load i32, ptr %4, align 4, !tbaa !56
  %15 = sext i32 %14 to i64
  %16 = getelementptr inbounds [10 x i32], ptr %13, i64 0, i64 %15
  store i32 %12, ptr %16, align 4, !tbaa !56
  br label %17

17:                                               ; preds = %9
  %18 = load i32, ptr %4, align 4, !tbaa !56
  %19 = add nsw i32 %18, 1
  store i32 %19, ptr %4, align 4, !tbaa !56
  br label %5, !llvm.loop !61

20:                                               ; preds = %8
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local double @many(i64 %0, double %1, double %2, ptr noundef byval(%struct.lll) align 8 %3, i64 %4, <2 x float> %5, i32 %6, double %7, i64 %8, i64 %9, double %10, double %11, i64 %12) #2 {
  %14 = alloca %struct.ii, align 4
  %15 = alloca %struct.dd, align 8
  %16 = alloca %struct.fi, align 4
  %17 = alloca %struct.ff, align 4
  %18 = alloca %struct.id, align 8
  %19 = alloca %struct.ll, align 8
  %20 = alloca %struct.dd, align 8
  %21 = alloca %struct.ii, align 4
  store i64 %0, ptr %14, align 4
  %22 = getelementptr inbounds nuw { double, double }, ptr %15, i32 0, i32 0
  store double %1, ptr %22, align 8
  %23 = getelementptr inbounds nuw { double, double }, ptr %15, i32 0, i32 1
  store double %2, ptr %23, align 8
  store i64 %4, ptr %16, align 4
  store <2 x float> %5, ptr %17, align 4
  %24 = getelementptr inbounds nuw { i32, double }, ptr %18, i32 0, i32 0
  store i32 %6, ptr %24, align 8
  %25 = getelementptr inbounds nuw { i32, double }, ptr %18, i32 0, i32 1
  store double %7, ptr %25, align 8
  %26 = getelementptr inbounds nuw { i64, i64 }, ptr %19, i32 0, i32 0
  store i64 %8, ptr %26, align 8
  %27 = getelementptr inbounds nuw { i64, i64 }, ptr %19, i32 0, i32 1
  store i64 %9, ptr %27, align 8
  %28 = getelementptr inbounds nuw { double, double }, ptr %20, i32 0, i32 0
  store double %10, ptr %28, align 8
  %29 = getelementptr inbounds nuw { double, double }, ptr %20, i32 0, i32 1
  store double %11, ptr %29, align 8
  store i64 %12, ptr %21, align 4
  %30 = getelementptr inbounds nuw %struct.ii, ptr %14, i32 0, i32 0
  %31 = load i32, ptr %30, align 4, !tbaa !19
  %32 = getelementptr inbounds nuw %struct.ii, ptr %14, i32 0, i32 1
  %33 = load i32, ptr %32, align 4, !tbaa !21
  %34 = add nsw i32 %31, %33
  %35 = sitofp i32 %34 to double
  %36 = getelementptr inbounds nuw %struct.dd, ptr %15, i32 0, i32 0
  %37 = load double, ptr %36, align 8, !tbaa !42
  %38 = fadd double %35, %37
  %39 = getelementptr inbounds nuw %struct.dd, ptr %15, i32 0, i32 1
  %40 = load double, ptr %39, align 8, !tbaa !45
  %41 = fadd double %38, %40
  %42 = getelementptr inbounds nuw %struct.lll, ptr %3, i32 0, i32 0
  %43 = load i64, ptr %42, align 8, !tbaa !30
  %44 = sitofp i64 %43 to double
  %45 = fadd double %41, %44
  %46 = getelementptr inbounds nuw %struct.lll, ptr %3, i32 0, i32 1
  %47 = load i64, ptr %46, align 8, !tbaa !32
  %48 = sitofp i64 %47 to double
  %49 = fadd double %45, %48
  %50 = getelementptr inbounds nuw %struct.lll, ptr %3, i32 0, i32 2
  %51 = load i64, ptr %50, align 8, !tbaa !33
  %52 = sitofp i64 %51 to double
  %53 = fadd double %49, %52
  %54 = getelementptr inbounds nuw %struct.fi, ptr %16, i32 0, i32 0
  %55 = load float, ptr %54, align 4, !tbaa !52
  %56 = fpext float %55 to double
  %57 = fadd double %53, %56
  %58 = getelementptr inbounds nuw %struct.fi, ptr %16, i32 0, i32 1
  %59 = load i32, ptr %58, align 4, !tbaa !54
  %60 = sitofp i32 %59 to double
  %61 = fadd double %57, %60
  %62 = getelementptr inbounds nuw %struct.ff, ptr %17, i32 0, i32 0
  %63 = load float, ptr %62, align 4, !tbaa !34
  %64 = fpext float %63 to double
  %65 = fadd double %61, %64
  %66 = getelementptr inbounds nuw %struct.ff, ptr %17, i32 0, i32 1
  %67 = load float, ptr %66, align 4, !tbaa !37
  %68 = fpext float %67 to double
  %69 = fadd double %65, %68
  %70 = getelementptr inbounds nuw %struct.id, ptr %18, i32 0, i32 0
  %71 = load i32, ptr %70, align 8, !tbaa !46
  %72 = sitofp i32 %71 to double
  %73 = fadd double %69, %72
  %74 = getelementptr inbounds nuw %struct.id, ptr %18, i32 0, i32 1
  %75 = load double, ptr %74, align 8, !tbaa !48
  %76 = fadd double %73, %75
  %77 = getelementptr inbounds nuw %struct.ll, ptr %19, i32 0, i32 0
  %78 = load i64, ptr %77, align 8, !tbaa !26
  %79 = sitofp i64 %78 to double
  %80 = fadd double %76, %79
  %81 = getelementptr inbounds nuw %struct.ll, ptr %19, i32 0, i32 1
  %82 = load i64, ptr %81, align 8, !tbaa !29
  %83 = sitofp i64 %82 to double
  %84 = fadd double %80, %83
  %85 = getelementptr inbounds nuw %struct.dd, ptr %20, i32 0, i32 0
  %86 = load double, ptr %85, align 8, !tbaa !42
  %87 = fadd double %84, %86
  %88 = getelementptr inbounds nuw %struct.dd, ptr %20, i32 0, i32 1
  %89 = load double, ptr %88, align 8, !tbaa !45
  %90 = fadd double %87, %89
  %91 = getelementptr inbounds nuw %struct.ii, ptr %21, i32 0, i32 0
  %92 = load i32, ptr %91, align 4, !tbaa !19
  %93 = sitofp i32 %92 to double
  %94 = fadd double %90, %93
  %95 = getelementptr inbounds nuw %struct.ii, ptr %21, i32 0, i32 1
  %96 = load i32, ptr %95, align 4, !tbaa !21
  %97 = sitofp i32 %96 to double
  %98 = fadd double %94, %97
  ret double %98
}

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind uwtable "min-legal-vector-width"="64" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #4 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
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
!9 = !{!10, !7, i64 0}
!10 = !{!"c1", !7, i64 0}
!11 = !{!12, !7, i64 0}
!12 = !{!"c3", !7, i64 0, !7, i64 1, !7, i64 2}
!13 = !{!12, !7, i64 1}
!14 = !{!12, !7, i64 2}
!15 = !{!16, !17, i64 0}
!16 = !{!"sh", !17, i64 0, !7, i64 2}
!17 = !{!"short", !7, i64 0}
!18 = !{!16, !7, i64 2}
!19 = !{!20, !6, i64 0}
!20 = !{!"ii", !6, i64 0, !6, i64 4}
!21 = !{!20, !6, i64 4}
!22 = !{!23, !6, i64 0}
!23 = !{!"iii", !6, i64 0, !6, i64 4, !6, i64 8}
!24 = !{!23, !6, i64 4}
!25 = !{!23, !6, i64 8}
!26 = !{!27, !28, i64 0}
!27 = !{!"ll", !28, i64 0, !28, i64 8}
!28 = !{!"long", !7, i64 0}
!29 = !{!27, !28, i64 8}
!30 = !{!31, !28, i64 0}
!31 = !{!"lll", !28, i64 0, !28, i64 8, !28, i64 16}
!32 = !{!31, !28, i64 8}
!33 = !{!31, !28, i64 16}
!34 = !{!35, !36, i64 0}
!35 = !{!"ff", !36, i64 0, !36, i64 4}
!36 = !{!"float", !7, i64 0}
!37 = !{!35, !36, i64 4}
!38 = !{!39, !36, i64 0}
!39 = !{!"fff", !36, i64 0, !36, i64 4, !36, i64 8}
!40 = !{!39, !36, i64 4}
!41 = !{!39, !36, i64 8}
!42 = !{!43, !44, i64 0}
!43 = !{!"dd", !44, i64 0, !44, i64 8}
!44 = !{!"double", !7, i64 0}
!45 = !{!43, !44, i64 8}
!46 = !{!47, !6, i64 0}
!47 = !{!"id", !6, i64 0, !44, i64 8}
!48 = !{!47, !44, i64 8}
!49 = !{!50, !44, i64 0}
!50 = !{!"di", !44, i64 0, !6, i64 8}
!51 = !{!50, !6, i64 8}
!52 = !{!53, !36, i64 0}
!53 = !{!"fi", !36, i64 0, !6, i64 4}
!54 = !{!53, !6, i64 4}
!55 = !{!28, !28, i64 0}
!56 = !{!6, !6, i64 0}
!57 = distinct !{!57, !58}
!58 = !{!"llvm.loop.mustprogress"}
!59 = !{!36, !36, i64 0}
!60 = !{!44, !44, i64 0}
!61 = distinct !{!61, !58}
