; @source: tests/function/src/abi/struct_shapes.c
; @llc: -O0
; @driver: tests/function/src/abi/struct_shapes.driver.c
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
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

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @sum_c1(i8 %0) #0 {
  %2 = alloca %struct.c1, align 1
  %3 = getelementptr inbounds nuw %struct.c1, ptr %2, i32 0, i32 0
  store i8 %0, ptr %3, align 1
  %4 = getelementptr inbounds nuw %struct.c1, ptr %2, i32 0, i32 0
  %5 = load i8, ptr %4, align 1
  %6 = sext i8 %5 to i32
  ret i32 %6
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @sum_c3(i24 %0) #0 {
  %2 = alloca %struct.c3, align 1
  store i24 %0, ptr %2, align 1
  %3 = getelementptr inbounds nuw %struct.c3, ptr %2, i32 0, i32 0
  %4 = load i8, ptr %3, align 1
  %5 = sext i8 %4 to i32
  %6 = getelementptr inbounds nuw %struct.c3, ptr %2, i32 0, i32 1
  %7 = load i8, ptr %6, align 1
  %8 = sext i8 %7 to i32
  %9 = mul nsw i32 %8, 3
  %10 = add nsw i32 %5, %9
  %11 = getelementptr inbounds nuw %struct.c3, ptr %2, i32 0, i32 2
  %12 = load i8, ptr %11, align 1
  %13 = sext i8 %12 to i32
  %14 = mul nsw i32 %13, 5
  %15 = add nsw i32 %10, %14
  ret i32 %15
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @sum_sh(i32 %0) #0 {
  %2 = alloca %struct.sh, align 2
  store i32 %0, ptr %2, align 2
  %3 = getelementptr inbounds nuw %struct.sh, ptr %2, i32 0, i32 0
  %4 = load i16, ptr %3, align 2
  %5 = sext i16 %4 to i32
  %6 = mul nsw i32 %5, 2
  %7 = getelementptr inbounds nuw %struct.sh, ptr %2, i32 0, i32 1
  %8 = load i8, ptr %7, align 2
  %9 = sext i8 %8 to i32
  %10 = add nsw i32 %6, %9
  ret i32 %10
}

; Function Attrs: noinline nounwind uwtable
define dso_local i64 @sum_ii(i64 %0) #0 {
  %2 = alloca %struct.ii, align 4
  store i64 %0, ptr %2, align 4
  %3 = getelementptr inbounds nuw %struct.ii, ptr %2, i32 0, i32 0
  %4 = load i32, ptr %3, align 4
  %5 = sext i32 %4 to i64
  %6 = mul nsw i64 %5, 7
  %7 = getelementptr inbounds nuw %struct.ii, ptr %2, i32 0, i32 1
  %8 = load i32, ptr %7, align 4
  %9 = sext i32 %8 to i64
  %10 = add nsw i64 %6, %9
  ret i64 %10
}

; Function Attrs: noinline nounwind uwtable
define dso_local i64 @sum_iii(i64 %0, i32 %1) #0 {
  %3 = alloca %struct.iii, align 4
  %4 = alloca { i64, i32 }, align 4
  %5 = getelementptr inbounds nuw { i64, i32 }, ptr %4, i32 0, i32 0
  store i64 %0, ptr %5, align 4
  %6 = getelementptr inbounds nuw { i64, i32 }, ptr %4, i32 0, i32 1
  store i32 %1, ptr %6, align 4
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %3, ptr align 4 %4, i64 12, i1 false)
  %7 = getelementptr inbounds nuw %struct.iii, ptr %3, i32 0, i32 0
  %8 = load i32, ptr %7, align 4
  %9 = sext i32 %8 to i64
  %10 = getelementptr inbounds nuw %struct.iii, ptr %3, i32 0, i32 1
  %11 = load i32, ptr %10, align 4
  %12 = sext i32 %11 to i64
  %13 = mul nsw i64 %12, 2
  %14 = add nsw i64 %9, %13
  %15 = getelementptr inbounds nuw %struct.iii, ptr %3, i32 0, i32 2
  %16 = load i32, ptr %15, align 4
  %17 = sext i32 %16 to i64
  %18 = mul nsw i64 %17, 3
  %19 = add nsw i64 %14, %18
  ret i64 %19
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

; Function Attrs: noinline nounwind uwtable
define dso_local i64 @sum_ll(i64 %0, i64 %1) #0 {
  %3 = alloca %struct.ll, align 8
  %4 = getelementptr inbounds nuw { i64, i64 }, ptr %3, i32 0, i32 0
  store i64 %0, ptr %4, align 8
  %5 = getelementptr inbounds nuw { i64, i64 }, ptr %3, i32 0, i32 1
  store i64 %1, ptr %5, align 8
  %6 = getelementptr inbounds nuw %struct.ll, ptr %3, i32 0, i32 0
  %7 = load i64, ptr %6, align 8
  %8 = getelementptr inbounds nuw %struct.ll, ptr %3, i32 0, i32 1
  %9 = load i64, ptr %8, align 8
  %10 = sub nsw i64 %7, %9
  ret i64 %10
}

; Function Attrs: noinline nounwind uwtable
define dso_local i64 @sum_lll(ptr noundef byval(%struct.lll) align 8 %0) #0 {
  %2 = getelementptr inbounds nuw %struct.lll, ptr %0, i32 0, i32 0
  %3 = load i64, ptr %2, align 8
  %4 = getelementptr inbounds nuw %struct.lll, ptr %0, i32 0, i32 1
  %5 = load i64, ptr %4, align 8
  %6 = mul nsw i64 %5, 2
  %7 = add nsw i64 %3, %6
  %8 = getelementptr inbounds nuw %struct.lll, ptr %0, i32 0, i32 2
  %9 = load i64, ptr %8, align 8
  %10 = mul nsw i64 %9, 3
  %11 = add nsw i64 %7, %10
  ret i64 %11
}

; Function Attrs: noinline nounwind uwtable
define dso_local double @sum_ff(<2 x float> %0) #2 {
  %2 = alloca %struct.ff, align 4
  store <2 x float> %0, ptr %2, align 4
  %3 = getelementptr inbounds nuw %struct.ff, ptr %2, i32 0, i32 0
  %4 = load float, ptr %3, align 4
  %5 = getelementptr inbounds nuw %struct.ff, ptr %2, i32 0, i32 1
  %6 = load float, ptr %5, align 4
  %7 = call float @llvm.fmuladd.f32(float %4, float 2.000000e+00, float %6)
  %8 = fpext float %7 to double
  ret double %8
}

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare float @llvm.fmuladd.f32(float, float, float) #3

; Function Attrs: noinline nounwind uwtable
define dso_local double @sum_fff(<2 x float> %0, float %1) #2 {
  %3 = alloca %struct.fff, align 4
  %4 = alloca { <2 x float>, float }, align 4
  %5 = getelementptr inbounds nuw { <2 x float>, float }, ptr %4, i32 0, i32 0
  store <2 x float> %0, ptr %5, align 4
  %6 = getelementptr inbounds nuw { <2 x float>, float }, ptr %4, i32 0, i32 1
  store float %1, ptr %6, align 4
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %3, ptr align 4 %4, i64 12, i1 false)
  %7 = getelementptr inbounds nuw %struct.fff, ptr %3, i32 0, i32 0
  %8 = load float, ptr %7, align 4
  %9 = getelementptr inbounds nuw %struct.fff, ptr %3, i32 0, i32 1
  %10 = load float, ptr %9, align 4
  %11 = call float @llvm.fmuladd.f32(float %10, float 2.000000e+00, float %8)
  %12 = getelementptr inbounds nuw %struct.fff, ptr %3, i32 0, i32 2
  %13 = load float, ptr %12, align 4
  %14 = call float @llvm.fmuladd.f32(float %13, float 3.000000e+00, float %11)
  %15 = fpext float %14 to double
  ret double %15
}

; Function Attrs: noinline nounwind uwtable
define dso_local double @sum_dd(double %0, double %1) #0 {
  %3 = alloca %struct.dd, align 8
  %4 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 0
  store double %0, ptr %4, align 8
  %5 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 1
  store double %1, ptr %5, align 8
  %6 = getelementptr inbounds nuw %struct.dd, ptr %3, i32 0, i32 0
  %7 = load double, ptr %6, align 8
  %8 = fdiv double %7, 2.000000e+00
  %9 = getelementptr inbounds nuw %struct.dd, ptr %3, i32 0, i32 1
  %10 = load double, ptr %9, align 8
  %11 = fadd double %8, %10
  ret double %11
}

; Function Attrs: noinline nounwind uwtable
define dso_local double @sum_id(i32 %0, double %1) #0 {
  %3 = alloca %struct.id, align 8
  %4 = getelementptr inbounds nuw { i32, double }, ptr %3, i32 0, i32 0
  store i32 %0, ptr %4, align 8
  %5 = getelementptr inbounds nuw { i32, double }, ptr %3, i32 0, i32 1
  store double %1, ptr %5, align 8
  %6 = getelementptr inbounds nuw %struct.id, ptr %3, i32 0, i32 0
  %7 = load i32, ptr %6, align 8
  %8 = sitofp i32 %7 to double
  %9 = getelementptr inbounds nuw %struct.id, ptr %3, i32 0, i32 1
  %10 = load double, ptr %9, align 8
  %11 = fadd double %8, %10
  ret double %11
}

; Function Attrs: noinline nounwind uwtable
define dso_local double @sum_di(double %0, i32 %1) #0 {
  %3 = alloca %struct.di, align 8
  %4 = getelementptr inbounds nuw { double, i32 }, ptr %3, i32 0, i32 0
  store double %0, ptr %4, align 8
  %5 = getelementptr inbounds nuw { double, i32 }, ptr %3, i32 0, i32 1
  store i32 %1, ptr %5, align 8
  %6 = getelementptr inbounds nuw %struct.di, ptr %3, i32 0, i32 0
  %7 = load double, ptr %6, align 8
  %8 = getelementptr inbounds nuw %struct.di, ptr %3, i32 0, i32 1
  %9 = load i32, ptr %8, align 8
  %10 = sitofp i32 %9 to double
  %11 = fmul double %7, %10
  ret double %11
}

; Function Attrs: noinline nounwind uwtable
define dso_local double @sum_fi(i64 %0) #0 {
  %2 = alloca %struct.fi, align 4
  store i64 %0, ptr %2, align 4
  %3 = getelementptr inbounds nuw %struct.fi, ptr %2, i32 0, i32 0
  %4 = load float, ptr %3, align 4
  %5 = getelementptr inbounds nuw %struct.fi, ptr %2, i32 0, i32 1
  %6 = load i32, ptr %5, align 4
  %7 = sitofp i32 %6 to float
  %8 = fsub float %4, %7
  %9 = fpext float %8 to double
  ret double %9
}

; Function Attrs: noinline nounwind uwtable
define dso_local i64 @sum_big(ptr noundef byval(%struct.big) align 8 %0) #0 {
  %2 = alloca i64, align 8
  %3 = alloca i32, align 4
  store i64 0, ptr %2, align 8
  store i32 0, ptr %3, align 4
  br label %4

4:                                                ; preds = %20, %1
  %5 = load i32, ptr %3, align 4
  %6 = icmp slt i32 %5, 10
  br i1 %6, label %7, label %23

7:                                                ; preds = %4
  %8 = getelementptr inbounds nuw %struct.big, ptr %0, i32 0, i32 0
  %9 = load i32, ptr %3, align 4
  %10 = sext i32 %9 to i64
  %11 = getelementptr inbounds [10 x i32], ptr %8, i64 0, i64 %10
  %12 = load i32, ptr %11, align 4
  %13 = sext i32 %12 to i64
  %14 = load i32, ptr %3, align 4
  %15 = add nsw i32 %14, 1
  %16 = sext i32 %15 to i64
  %17 = mul nsw i64 %13, %16
  %18 = load i64, ptr %2, align 8
  %19 = add nsw i64 %18, %17
  store i64 %19, ptr %2, align 8
  br label %20

20:                                               ; preds = %7
  %21 = load i32, ptr %3, align 4
  %22 = add nsw i32 %21, 1
  store i32 %22, ptr %3, align 4
  br label %4, !llvm.loop !5

23:                                               ; preds = %4
  %24 = load i64, ptr %2, align 8
  ret i64 %24
}

; Function Attrs: noinline nounwind uwtable
define dso_local i24 @mk_c3(i32 noundef %0) #0 {
  %2 = alloca %struct.c3, align 1
  %3 = alloca i32, align 4
  %4 = alloca i24, align 4
  store i32 %0, ptr %3, align 4
  %5 = getelementptr inbounds nuw %struct.c3, ptr %2, i32 0, i32 0
  %6 = load i32, ptr %3, align 4
  %7 = trunc i32 %6 to i8
  store i8 %7, ptr %5, align 1
  %8 = getelementptr inbounds nuw %struct.c3, ptr %2, i32 0, i32 1
  %9 = load i32, ptr %3, align 4
  %10 = add nsw i32 %9, 1
  %11 = trunc i32 %10 to i8
  store i8 %11, ptr %8, align 1
  %12 = getelementptr inbounds nuw %struct.c3, ptr %2, i32 0, i32 2
  %13 = load i32, ptr %3, align 4
  %14 = add nsw i32 %13, 2
  %15 = trunc i32 %14 to i8
  store i8 %15, ptr %12, align 1
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %4, ptr align 1 %2, i64 3, i1 false)
  %16 = load i24, ptr %4, align 4
  ret i24 %16
}

; Function Attrs: noinline nounwind uwtable
define dso_local { i64, i32 } @mk_iii(i32 noundef %0) #0 {
  %2 = alloca %struct.iii, align 4
  %3 = alloca i32, align 4
  %4 = alloca { i64, i32 }, align 8
  store i32 %0, ptr %3, align 4
  %5 = getelementptr inbounds nuw %struct.iii, ptr %2, i32 0, i32 0
  %6 = load i32, ptr %3, align 4
  store i32 %6, ptr %5, align 4
  %7 = getelementptr inbounds nuw %struct.iii, ptr %2, i32 0, i32 1
  %8 = load i32, ptr %3, align 4
  %9 = sub nsw i32 0, %8
  store i32 %9, ptr %7, align 4
  %10 = getelementptr inbounds nuw %struct.iii, ptr %2, i32 0, i32 2
  %11 = load i32, ptr %3, align 4
  %12 = mul nsw i32 %11, 3
  store i32 %12, ptr %10, align 4
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %4, ptr align 4 %2, i64 12, i1 false)
  %13 = load { i64, i32 }, ptr %4, align 8
  ret { i64, i32 } %13
}

; Function Attrs: noinline nounwind uwtable
define dso_local void @mk_lll(ptr dead_on_unwind noalias writable sret(%struct.lll) align 8 %0, i64 noundef %1) #0 {
  %3 = alloca i64, align 8
  store i64 %1, ptr %3, align 8
  %4 = getelementptr inbounds nuw %struct.lll, ptr %0, i32 0, i32 0
  %5 = load i64, ptr %3, align 8
  store i64 %5, ptr %4, align 8
  %6 = getelementptr inbounds nuw %struct.lll, ptr %0, i32 0, i32 1
  %7 = load i64, ptr %3, align 8
  %8 = mul nsw i64 %7, 1048576
  store i64 %8, ptr %6, align 8
  %9 = getelementptr inbounds nuw %struct.lll, ptr %0, i32 0, i32 2
  %10 = load i64, ptr %3, align 8
  %11 = xor i64 %10, -1
  store i64 %11, ptr %9, align 8
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local { <2 x float>, float } @mk_fff(float noundef %0) #0 {
  %2 = alloca %struct.fff, align 4
  %3 = alloca float, align 4
  %4 = alloca { <2 x float>, float }, align 8
  store float %0, ptr %3, align 4
  %5 = getelementptr inbounds nuw %struct.fff, ptr %2, i32 0, i32 0
  %6 = load float, ptr %3, align 4
  store float %6, ptr %5, align 4
  %7 = getelementptr inbounds nuw %struct.fff, ptr %2, i32 0, i32 1
  %8 = load float, ptr %3, align 4
  %9 = fmul float %8, 2.000000e+00
  store float %9, ptr %7, align 4
  %10 = getelementptr inbounds nuw %struct.fff, ptr %2, i32 0, i32 2
  %11 = load float, ptr %3, align 4
  %12 = fmul float %11, 4.000000e+00
  store float %12, ptr %10, align 4
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %4, ptr align 4 %2, i64 12, i1 false)
  %13 = load { <2 x float>, float }, ptr %4, align 8
  ret { <2 x float>, float } %13
}

; Function Attrs: noinline nounwind uwtable
define dso_local { double, double } @mk_dd(double noundef %0) #0 {
  %2 = alloca %struct.dd, align 8
  %3 = alloca double, align 8
  store double %0, ptr %3, align 8
  %4 = getelementptr inbounds nuw %struct.dd, ptr %2, i32 0, i32 0
  %5 = load double, ptr %3, align 8
  store double %5, ptr %4, align 8
  %6 = getelementptr inbounds nuw %struct.dd, ptr %2, i32 0, i32 1
  %7 = load double, ptr %3, align 8
  %8 = fneg double %7
  store double %8, ptr %6, align 8
  %9 = load { double, double }, ptr %2, align 8
  ret { double, double } %9
}

; Function Attrs: noinline nounwind uwtable
define dso_local { i32, double } @mk_id(i32 noundef %0) #0 {
  %2 = alloca %struct.id, align 8
  %3 = alloca i32, align 4
  store i32 %0, ptr %3, align 4
  %4 = getelementptr inbounds nuw %struct.id, ptr %2, i32 0, i32 0
  %5 = load i32, ptr %3, align 4
  store i32 %5, ptr %4, align 8
  %6 = getelementptr i8, ptr %2, i64 4
  call void @llvm.memset.p0.i64(ptr align 4 %6, i8 0, i64 4, i1 false)
  %7 = getelementptr inbounds nuw %struct.id, ptr %2, i32 0, i32 1
  %8 = load i32, ptr %3, align 4
  %9 = sitofp i32 %8 to double
  %10 = fdiv double %9, 4.000000e+00
  store double %10, ptr %7, align 8
  %11 = load { i32, double }, ptr %2, align 8
  ret { i32, double } %11
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #4

; Function Attrs: noinline nounwind uwtable
define dso_local { double, i32 } @mk_di(double noundef %0) #0 {
  %2 = alloca %struct.di, align 8
  %3 = alloca double, align 8
  store double %0, ptr %3, align 8
  %4 = getelementptr inbounds nuw %struct.di, ptr %2, i32 0, i32 0
  %5 = load double, ptr %3, align 8
  store double %5, ptr %4, align 8
  %6 = getelementptr inbounds nuw %struct.di, ptr %2, i32 0, i32 1
  %7 = load double, ptr %3, align 8
  %8 = fptosi double %7 to i32
  %9 = mul nsw i32 %8, 2
  store i32 %9, ptr %6, align 8
  %10 = getelementptr i8, ptr %2, i64 12
  call void @llvm.memset.p0.i64(ptr align 4 %10, i8 0, i64 4, i1 false)
  %11 = load { double, i32 }, ptr %2, align 8
  ret { double, i32 } %11
}

; Function Attrs: noinline nounwind uwtable
define dso_local void @mk_big(ptr dead_on_unwind noalias writable sret(%struct.big) align 4 %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 %1, ptr %3, align 4
  store i32 0, ptr %4, align 4
  br label %5

5:                                                ; preds = %16, %2
  %6 = load i32, ptr %4, align 4
  %7 = icmp slt i32 %6, 10
  br i1 %7, label %8, label %19

8:                                                ; preds = %5
  %9 = load i32, ptr %3, align 4
  %10 = load i32, ptr %4, align 4
  %11 = mul nsw i32 %9, %10
  %12 = getelementptr inbounds nuw %struct.big, ptr %0, i32 0, i32 0
  %13 = load i32, ptr %4, align 4
  %14 = sext i32 %13 to i64
  %15 = getelementptr inbounds [10 x i32], ptr %12, i64 0, i64 %14
  store i32 %11, ptr %15, align 4
  br label %16

16:                                               ; preds = %8
  %17 = load i32, ptr %4, align 4
  %18 = add nsw i32 %17, 1
  store i32 %18, ptr %4, align 4
  br label %5, !llvm.loop !7

19:                                               ; preds = %5
  ret void
}

; Function Attrs: noinline nounwind uwtable
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
  %31 = load i32, ptr %30, align 4
  %32 = getelementptr inbounds nuw %struct.ii, ptr %14, i32 0, i32 1
  %33 = load i32, ptr %32, align 4
  %34 = add nsw i32 %31, %33
  %35 = sitofp i32 %34 to double
  %36 = getelementptr inbounds nuw %struct.dd, ptr %15, i32 0, i32 0
  %37 = load double, ptr %36, align 8
  %38 = fadd double %35, %37
  %39 = getelementptr inbounds nuw %struct.dd, ptr %15, i32 0, i32 1
  %40 = load double, ptr %39, align 8
  %41 = fadd double %38, %40
  %42 = getelementptr inbounds nuw %struct.lll, ptr %3, i32 0, i32 0
  %43 = load i64, ptr %42, align 8
  %44 = sitofp i64 %43 to double
  %45 = fadd double %41, %44
  %46 = getelementptr inbounds nuw %struct.lll, ptr %3, i32 0, i32 1
  %47 = load i64, ptr %46, align 8
  %48 = sitofp i64 %47 to double
  %49 = fadd double %45, %48
  %50 = getelementptr inbounds nuw %struct.lll, ptr %3, i32 0, i32 2
  %51 = load i64, ptr %50, align 8
  %52 = sitofp i64 %51 to double
  %53 = fadd double %49, %52
  %54 = getelementptr inbounds nuw %struct.fi, ptr %16, i32 0, i32 0
  %55 = load float, ptr %54, align 4
  %56 = fpext float %55 to double
  %57 = fadd double %53, %56
  %58 = getelementptr inbounds nuw %struct.fi, ptr %16, i32 0, i32 1
  %59 = load i32, ptr %58, align 4
  %60 = sitofp i32 %59 to double
  %61 = fadd double %57, %60
  %62 = getelementptr inbounds nuw %struct.ff, ptr %17, i32 0, i32 0
  %63 = load float, ptr %62, align 4
  %64 = fpext float %63 to double
  %65 = fadd double %61, %64
  %66 = getelementptr inbounds nuw %struct.ff, ptr %17, i32 0, i32 1
  %67 = load float, ptr %66, align 4
  %68 = fpext float %67 to double
  %69 = fadd double %65, %68
  %70 = getelementptr inbounds nuw %struct.id, ptr %18, i32 0, i32 0
  %71 = load i32, ptr %70, align 8
  %72 = sitofp i32 %71 to double
  %73 = fadd double %69, %72
  %74 = getelementptr inbounds nuw %struct.id, ptr %18, i32 0, i32 1
  %75 = load double, ptr %74, align 8
  %76 = fadd double %73, %75
  %77 = getelementptr inbounds nuw %struct.ll, ptr %19, i32 0, i32 0
  %78 = load i64, ptr %77, align 8
  %79 = sitofp i64 %78 to double
  %80 = fadd double %76, %79
  %81 = getelementptr inbounds nuw %struct.ll, ptr %19, i32 0, i32 1
  %82 = load i64, ptr %81, align 8
  %83 = sitofp i64 %82 to double
  %84 = fadd double %80, %83
  %85 = getelementptr inbounds nuw %struct.dd, ptr %20, i32 0, i32 0
  %86 = load double, ptr %85, align 8
  %87 = fadd double %84, %86
  %88 = getelementptr inbounds nuw %struct.dd, ptr %20, i32 0, i32 1
  %89 = load double, ptr %88, align 8
  %90 = fadd double %87, %89
  %91 = getelementptr inbounds nuw %struct.ii, ptr %21, i32 0, i32 0
  %92 = load i32, ptr %91, align 4
  %93 = sitofp i32 %92 to double
  %94 = fadd double %90, %93
  %95 = getelementptr inbounds nuw %struct.ii, ptr %21, i32 0, i32 1
  %96 = load i32, ptr %95, align 4
  %97 = sitofp i32 %96 to double
  %98 = fadd double %94, %97
  ret double %98
}

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="64" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #4 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }

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
