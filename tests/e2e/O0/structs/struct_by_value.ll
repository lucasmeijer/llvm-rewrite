; @source: tests/e2e/src/structs/struct_by_value.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/structs/struct_by_value.c'
source_filename = "tests/e2e/src/structs/struct_by_value.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.s1 = type { i8 }
%struct.s8 = type { i32, i32 }
%struct.s16 = type { i64, i64 }
%struct.s24 = type { i64, i64, i64 }
%struct.sf = type { float, float }
%struct.sd = type { double, i64 }
%struct.s3 = type { [3 x i8] }

@__const.main.a = private unnamed_addr constant %struct.s1 { i8 21 }, align 1
@__const.main.b = private unnamed_addr constant %struct.s8 { i32 10, i32 3 }, align 4
@__const.main.c = private unnamed_addr constant %struct.s16 { i64 6, i64 7 }, align 8
@__const.main.d = private unnamed_addr constant %struct.s24 { i64 1, i64 2, i64 3 }, align 8
@__const.main.e = private unnamed_addr constant %struct.sf { float 1.500000e+00, float 4.000000e+00 }, align 4
@__const.main.g = private unnamed_addr constant %struct.sd { double 2.500000e+00, i64 4 }, align 8
@__const.main.h = private unnamed_addr constant %struct.s3 { [3 x i8] c"\01\02\03" }, align 1
@.str = private unnamed_addr constant [28 x i8] c"%d %d %ld %ld %.2f %.2f %d\0A\00", align 1
@.str.1 = private unnamed_addr constant [46 x i8] c"%d %d %ld %ld %ld %ld %ld %.2f %.2f %.2f %ld\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca %struct.s1, align 1
  %3 = alloca %struct.s8, align 4
  %4 = alloca %struct.s16, align 8
  %5 = alloca %struct.s24, align 8
  %6 = alloca %struct.sf, align 4
  %7 = alloca %struct.sd, align 8
  %8 = alloca %struct.s3, align 1
  %9 = alloca i24, align 4
  %10 = alloca %struct.s8, align 4
  %11 = alloca %struct.s16, align 8
  %12 = alloca %struct.s24, align 8
  %13 = alloca %struct.sf, align 4
  %14 = alloca %struct.sd, align 8
  store i32 0, ptr %1, align 4
  call void @llvm.memcpy.p0.p0.i64(ptr align 1 %2, ptr align 1 @__const.main.a, i64 1, i1 false)
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %3, ptr align 4 @__const.main.b, i64 8, i1 false)
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %4, ptr align 8 @__const.main.c, i64 16, i1 false)
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %5, ptr align 8 @__const.main.d, i64 24, i1 false)
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %6, ptr align 4 @__const.main.e, i64 8, i1 false)
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %7, ptr align 8 @__const.main.g, i64 16, i1 false)
  call void @llvm.memcpy.p0.p0.i64(ptr align 1 %8, ptr align 1 @__const.main.h, i64 3, i1 false)
  %15 = getelementptr inbounds nuw %struct.s1, ptr %2, i32 0, i32 0
  %16 = load i8, ptr %15, align 1
  %17 = call i32 @f1(i8 %16)
  %18 = load i64, ptr %3, align 4
  %19 = call i32 @f8(i64 %18)
  %20 = getelementptr inbounds nuw { i64, i64 }, ptr %4, i32 0, i32 0
  %21 = load i64, ptr %20, align 8
  %22 = getelementptr inbounds nuw { i64, i64 }, ptr %4, i32 0, i32 1
  %23 = load i64, ptr %22, align 8
  %24 = call i64 @f16(i64 %21, i64 %23)
  %25 = call i64 @f24(ptr noundef byval(%struct.s24) align 8 %5)
  %26 = load <2 x float>, ptr %6, align 4
  %27 = call float @ff(<2 x float> %26)
  %28 = fpext float %27 to double
  %29 = getelementptr inbounds nuw { double, i64 }, ptr %7, i32 0, i32 0
  %30 = load double, ptr %29, align 8
  %31 = getelementptr inbounds nuw { double, i64 }, ptr %7, i32 0, i32 1
  %32 = load i64, ptr %31, align 8
  %33 = call double @fd(double %30, i64 %32)
  %34 = getelementptr inbounds nuw %struct.s3, ptr %8, i32 0, i32 0
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %9, ptr align 1 %34, i64 3, i1 false)
  %35 = load i24, ptr %9, align 4
  %36 = call i32 @f3(i24 %35)
  %37 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %17, i32 noundef %19, i64 noundef %24, i64 noundef %25, double noundef %28, double noundef %33, i32 noundef %36)
  %38 = call i64 @r8(i32 noundef 5)
  store i64 %38, ptr %10, align 4
  %39 = call { i64, i64 } @r16(i64 noundef 9)
  %40 = getelementptr inbounds nuw { i64, i64 }, ptr %11, i32 0, i32 0
  %41 = extractvalue { i64, i64 } %39, 0
  store i64 %41, ptr %40, align 8
  %42 = getelementptr inbounds nuw { i64, i64 }, ptr %11, i32 0, i32 1
  %43 = extractvalue { i64, i64 } %39, 1
  store i64 %43, ptr %42, align 8
  call void @r24(ptr dead_on_unwind writable sret(%struct.s24) align 8 %12, i64 noundef 100)
  %44 = call <2 x float> @rf(float noundef 3.000000e+00)
  store <2 x float> %44, ptr %13, align 4
  %45 = call { double, i64 } @rd(double noundef 5.000000e-01)
  %46 = getelementptr inbounds nuw { double, i64 }, ptr %14, i32 0, i32 0
  %47 = extractvalue { double, i64 } %45, 0
  store double %47, ptr %46, align 8
  %48 = getelementptr inbounds nuw { double, i64 }, ptr %14, i32 0, i32 1
  %49 = extractvalue { double, i64 } %45, 1
  store i64 %49, ptr %48, align 8
  %50 = getelementptr inbounds nuw %struct.s8, ptr %10, i32 0, i32 0
  %51 = load i32, ptr %50, align 4
  %52 = getelementptr inbounds nuw %struct.s8, ptr %10, i32 0, i32 1
  %53 = load i32, ptr %52, align 4
  %54 = getelementptr inbounds nuw %struct.s16, ptr %11, i32 0, i32 0
  %55 = load i64, ptr %54, align 8
  %56 = getelementptr inbounds nuw %struct.s16, ptr %11, i32 0, i32 1
  %57 = load i64, ptr %56, align 8
  %58 = getelementptr inbounds nuw %struct.s24, ptr %12, i32 0, i32 0
  %59 = load i64, ptr %58, align 8
  %60 = getelementptr inbounds nuw %struct.s24, ptr %12, i32 0, i32 1
  %61 = load i64, ptr %60, align 8
  %62 = getelementptr inbounds nuw %struct.s24, ptr %12, i32 0, i32 2
  %63 = load i64, ptr %62, align 8
  %64 = getelementptr inbounds nuw %struct.sf, ptr %13, i32 0, i32 0
  %65 = load float, ptr %64, align 4
  %66 = fpext float %65 to double
  %67 = getelementptr inbounds nuw %struct.sf, ptr %13, i32 0, i32 1
  %68 = load float, ptr %67, align 4
  %69 = fpext float %68 to double
  %70 = getelementptr inbounds nuw %struct.sd, ptr %14, i32 0, i32 0
  %71 = load double, ptr %70, align 8
  %72 = getelementptr inbounds nuw %struct.sd, ptr %14, i32 0, i32 1
  %73 = load i64, ptr %72, align 8
  %74 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %51, i32 noundef %53, i64 noundef %55, i64 noundef %57, i64 noundef %59, i64 noundef %61, i64 noundef %63, double noundef %66, double noundef %69, double noundef %71, i64 noundef %73)
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: noinline nounwind uwtable
define internal i32 @f1(i8 %0) #3 {
  %2 = alloca %struct.s1, align 1
  %3 = getelementptr inbounds nuw %struct.s1, ptr %2, i32 0, i32 0
  store i8 %0, ptr %3, align 1
  %4 = getelementptr inbounds nuw %struct.s1, ptr %2, i32 0, i32 0
  %5 = load i8, ptr %4, align 1
  %6 = sext i8 %5 to i32
  %7 = mul nsw i32 %6, 2
  ret i32 %7
}

; Function Attrs: noinline nounwind uwtable
define internal i32 @f8(i64 %0) #3 {
  %2 = alloca %struct.s8, align 4
  store i64 %0, ptr %2, align 4
  %3 = getelementptr inbounds nuw %struct.s8, ptr %2, i32 0, i32 0
  %4 = load i32, ptr %3, align 4
  %5 = getelementptr inbounds nuw %struct.s8, ptr %2, i32 0, i32 1
  %6 = load i32, ptr %5, align 4
  %7 = sub nsw i32 %4, %6
  ret i32 %7
}

; Function Attrs: noinline nounwind uwtable
define internal i64 @f16(i64 %0, i64 %1) #3 {
  %3 = alloca %struct.s16, align 8
  %4 = getelementptr inbounds nuw { i64, i64 }, ptr %3, i32 0, i32 0
  store i64 %0, ptr %4, align 8
  %5 = getelementptr inbounds nuw { i64, i64 }, ptr %3, i32 0, i32 1
  store i64 %1, ptr %5, align 8
  %6 = getelementptr inbounds nuw %struct.s16, ptr %3, i32 0, i32 0
  %7 = load i64, ptr %6, align 8
  %8 = getelementptr inbounds nuw %struct.s16, ptr %3, i32 0, i32 1
  %9 = load i64, ptr %8, align 8
  %10 = mul nsw i64 %7, %9
  ret i64 %10
}

; Function Attrs: noinline nounwind uwtable
define internal i64 @f24(ptr noundef byval(%struct.s24) align 8 %0) #3 {
  %2 = getelementptr inbounds nuw %struct.s24, ptr %0, i32 0, i32 0
  %3 = load i64, ptr %2, align 8
  %4 = getelementptr inbounds nuw %struct.s24, ptr %0, i32 0, i32 1
  %5 = load i64, ptr %4, align 8
  %6 = add nsw i64 %3, %5
  %7 = getelementptr inbounds nuw %struct.s24, ptr %0, i32 0, i32 2
  %8 = load i64, ptr %7, align 8
  %9 = add nsw i64 %6, %8
  ret i64 %9
}

; Function Attrs: noinline nounwind uwtable
define internal float @ff(<2 x float> %0) #0 {
  %2 = alloca %struct.sf, align 4
  store <2 x float> %0, ptr %2, align 4
  %3 = getelementptr inbounds nuw %struct.sf, ptr %2, i32 0, i32 0
  %4 = load float, ptr %3, align 4
  %5 = getelementptr inbounds nuw %struct.sf, ptr %2, i32 0, i32 1
  %6 = load float, ptr %5, align 4
  %7 = fmul float %4, %6
  ret float %7
}

; Function Attrs: noinline nounwind uwtable
define internal double @fd(double %0, i64 %1) #3 {
  %3 = alloca %struct.sd, align 8
  %4 = getelementptr inbounds nuw { double, i64 }, ptr %3, i32 0, i32 0
  store double %0, ptr %4, align 8
  %5 = getelementptr inbounds nuw { double, i64 }, ptr %3, i32 0, i32 1
  store i64 %1, ptr %5, align 8
  %6 = getelementptr inbounds nuw %struct.sd, ptr %3, i32 0, i32 0
  %7 = load double, ptr %6, align 8
  %8 = getelementptr inbounds nuw %struct.sd, ptr %3, i32 0, i32 1
  %9 = load i64, ptr %8, align 8
  %10 = sitofp i64 %9 to double
  %11 = fmul double %7, %10
  ret double %11
}

; Function Attrs: noinline nounwind uwtable
define internal i32 @f3(i24 %0) #3 {
  %2 = alloca %struct.s3, align 1
  %3 = getelementptr inbounds nuw %struct.s3, ptr %2, i32 0, i32 0
  store i24 %0, ptr %3, align 1
  %4 = getelementptr inbounds nuw %struct.s3, ptr %2, i32 0, i32 0
  %5 = getelementptr inbounds [3 x i8], ptr %4, i64 0, i64 0
  %6 = load i8, ptr %5, align 1
  %7 = sext i8 %6 to i32
  %8 = getelementptr inbounds nuw %struct.s3, ptr %2, i32 0, i32 0
  %9 = getelementptr inbounds [3 x i8], ptr %8, i64 0, i64 1
  %10 = load i8, ptr %9, align 1
  %11 = sext i8 %10 to i32
  %12 = mul nsw i32 %11, 2
  %13 = add nsw i32 %7, %12
  %14 = getelementptr inbounds nuw %struct.s3, ptr %2, i32 0, i32 0
  %15 = getelementptr inbounds [3 x i8], ptr %14, i64 0, i64 2
  %16 = load i8, ptr %15, align 1
  %17 = sext i8 %16 to i32
  %18 = mul nsw i32 %17, 3
  %19 = add nsw i32 %13, %18
  ret i32 %19
}

; Function Attrs: noinline nounwind uwtable
define internal i64 @r8(i32 noundef %0) #3 {
  %2 = alloca %struct.s8, align 4
  %3 = alloca i32, align 4
  store i32 %0, ptr %3, align 4
  %4 = getelementptr inbounds nuw %struct.s8, ptr %2, i32 0, i32 0
  %5 = load i32, ptr %3, align 4
  store i32 %5, ptr %4, align 4
  %6 = getelementptr inbounds nuw %struct.s8, ptr %2, i32 0, i32 1
  %7 = load i32, ptr %3, align 4
  %8 = mul nsw i32 %7, 2
  store i32 %8, ptr %6, align 4
  %9 = load i64, ptr %2, align 4
  ret i64 %9
}

; Function Attrs: noinline nounwind uwtable
define internal { i64, i64 } @r16(i64 noundef %0) #3 {
  %2 = alloca %struct.s16, align 8
  %3 = alloca i64, align 8
  store i64 %0, ptr %3, align 8
  %4 = getelementptr inbounds nuw %struct.s16, ptr %2, i32 0, i32 0
  %5 = load i64, ptr %3, align 8
  store i64 %5, ptr %4, align 8
  %6 = getelementptr inbounds nuw %struct.s16, ptr %2, i32 0, i32 1
  %7 = load i64, ptr %3, align 8
  %8 = sub nsw i64 0, %7
  store i64 %8, ptr %6, align 8
  %9 = load { i64, i64 }, ptr %2, align 8
  ret { i64, i64 } %9
}

; Function Attrs: noinline nounwind uwtable
define internal void @r24(ptr dead_on_unwind noalias writable sret(%struct.s24) align 8 %0, i64 noundef %1) #3 {
  %3 = alloca i64, align 8
  store i64 %1, ptr %3, align 8
  %4 = getelementptr inbounds nuw %struct.s24, ptr %0, i32 0, i32 0
  %5 = load i64, ptr %3, align 8
  store i64 %5, ptr %4, align 8
  %6 = getelementptr inbounds nuw %struct.s24, ptr %0, i32 0, i32 1
  %7 = load i64, ptr %3, align 8
  %8 = add nsw i64 %7, 1
  store i64 %8, ptr %6, align 8
  %9 = getelementptr inbounds nuw %struct.s24, ptr %0, i32 0, i32 2
  %10 = load i64, ptr %3, align 8
  %11 = add nsw i64 %10, 2
  store i64 %11, ptr %9, align 8
  ret void
}

; Function Attrs: noinline nounwind uwtable
define internal <2 x float> @rf(float noundef %0) #0 {
  %2 = alloca %struct.sf, align 4
  %3 = alloca float, align 4
  store float %0, ptr %3, align 4
  %4 = getelementptr inbounds nuw %struct.sf, ptr %2, i32 0, i32 0
  %5 = load float, ptr %3, align 4
  store float %5, ptr %4, align 4
  %6 = getelementptr inbounds nuw %struct.sf, ptr %2, i32 0, i32 1
  %7 = load float, ptr %3, align 4
  %8 = fdiv float %7, 2.000000e+00
  store float %8, ptr %6, align 4
  %9 = load <2 x float>, ptr %2, align 4
  ret <2 x float> %9
}

; Function Attrs: noinline nounwind uwtable
define internal { double, i64 } @rd(double noundef %0) #3 {
  %2 = alloca %struct.sd, align 8
  %3 = alloca double, align 8
  store double %0, ptr %3, align 8
  %4 = getelementptr inbounds nuw %struct.sd, ptr %2, i32 0, i32 0
  %5 = load double, ptr %3, align 8
  store double %5, ptr %4, align 8
  %6 = getelementptr inbounds nuw %struct.sd, ptr %2, i32 0, i32 1
  store i64 7, ptr %6, align 8
  %7 = load { double, i64 }, ptr %2, align 8
  ret { double, i64 } %7
}

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="64" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{i32 7, !"frame-pointer", i32 2}
!4 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
