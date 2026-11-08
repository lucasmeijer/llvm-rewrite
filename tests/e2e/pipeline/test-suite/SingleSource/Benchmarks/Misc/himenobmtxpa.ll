; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/himenobmtxpa.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/himenobmtxpa.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/himenobmtxpa.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.Mat = type { ptr, i32, i32, i32, i32 }
%struct.timeval = type { i64, i64 }

@omega = dso_local global float 8.000000e-01, align 4
@.str = private unnamed_addr constant [34 x i8] c"mimax = %d mjmax = %d mkmax = %d\0A\00", align 1
@.str.1 = private unnamed_addr constant [30 x i8] c"imax = %d jmax = %d kmax =%d\0A\00", align 1
@p = dso_local global %struct.Mat zeroinitializer, align 8
@bnd = dso_local global %struct.Mat zeroinitializer, align 8
@wrk1 = dso_local global %struct.Mat zeroinitializer, align 8
@wrk2 = dso_local global %struct.Mat zeroinitializer, align 8
@a = dso_local global %struct.Mat zeroinitializer, align 8
@b = dso_local global %struct.Mat zeroinitializer, align 8
@c = dso_local global %struct.Mat zeroinitializer, align 8
@.str.2 = private unnamed_addr constant [29 x i8] c" Loop executed for %d times\0A\00", align 1
@.str.3 = private unnamed_addr constant [13 x i8] c" Gosa : %e \0A\00", align 1
@.str.4 = private unnamed_addr constant [3 x i8] c"XS\00", align 1
@.str.5 = private unnamed_addr constant [3 x i8] c"xs\00", align 1
@.str.6 = private unnamed_addr constant [2 x i8] c"S\00", align 1
@.str.7 = private unnamed_addr constant [2 x i8] c"s\00", align 1
@.str.8 = private unnamed_addr constant [2 x i8] c"M\00", align 1
@.str.9 = private unnamed_addr constant [2 x i8] c"m\00", align 1
@.str.10 = private unnamed_addr constant [2 x i8] c"L\00", align 1
@.str.11 = private unnamed_addr constant [2 x i8] c"l\00", align 1
@.str.12 = private unnamed_addr constant [3 x i8] c"XL\00", align 1
@.str.13 = private unnamed_addr constant [3 x i8] c"xl\00", align 1
@.str.14 = private unnamed_addr constant [28 x i8] c"Invalid input character !!\0A\00", align 1
@second.base_sec = internal global i32 0, align 4
@second.base_usec = internal global i32 0, align 4

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  %11 = alloca i32, align 4
  %12 = alloca i32, align 4
  %13 = alloca i32, align 4
  %14 = alloca i32, align 4
  %15 = alloca i32, align 4
  %16 = alloca [3 x i32], align 4
  %17 = alloca float, align 4
  %18 = alloca double, align 8
  %19 = alloca double, align 8
  %20 = alloca double, align 8
  %21 = alloca double, align 8
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %6) #8
  call void @llvm.lifetime.start.p0(ptr %7) #8
  call void @llvm.lifetime.start.p0(ptr %8) #8
  call void @llvm.lifetime.start.p0(ptr %9) #8
  call void @llvm.lifetime.start.p0(ptr %10) #8
  call void @llvm.lifetime.start.p0(ptr %11) #8
  call void @llvm.lifetime.start.p0(ptr %12) #8
  call void @llvm.lifetime.start.p0(ptr %13) #8
  call void @llvm.lifetime.start.p0(ptr %14) #8
  call void @llvm.lifetime.start.p0(ptr %15) #8
  call void @llvm.lifetime.start.p0(ptr %16) #8
  call void @llvm.lifetime.start.p0(ptr %17) #8
  call void @llvm.lifetime.start.p0(ptr %18) #8
  call void @llvm.lifetime.start.p0(ptr %19) #8
  call void @llvm.lifetime.start.p0(ptr %20) #8
  call void @llvm.lifetime.start.p0(ptr %21) #8
  %22 = getelementptr inbounds [3 x i32], ptr %16, i64 0, i64 0
  store i32 64, ptr %22, align 4, !tbaa !9
  %23 = getelementptr inbounds [3 x i32], ptr %16, i64 0, i64 1
  store i32 64, ptr %23, align 4, !tbaa !9
  %24 = getelementptr inbounds [3 x i32], ptr %16, i64 0, i64 2
  store i32 128, ptr %24, align 4, !tbaa !9
  %25 = getelementptr inbounds [3 x i32], ptr %16, i64 0, i64 0
  %26 = load i32, ptr %25, align 4, !tbaa !9
  store i32 %26, ptr %13, align 4, !tbaa !9
  %27 = getelementptr inbounds [3 x i32], ptr %16, i64 0, i64 1
  %28 = load i32, ptr %27, align 4, !tbaa !9
  store i32 %28, ptr %14, align 4, !tbaa !9
  %29 = getelementptr inbounds [3 x i32], ptr %16, i64 0, i64 2
  %30 = load i32, ptr %29, align 4, !tbaa !9
  store i32 %30, ptr %15, align 4, !tbaa !9
  %31 = load i32, ptr %13, align 4, !tbaa !9
  %32 = sub nsw i32 %31, 1
  store i32 %32, ptr %10, align 4, !tbaa !9
  %33 = load i32, ptr %14, align 4, !tbaa !9
  %34 = sub nsw i32 %33, 1
  store i32 %34, ptr %11, align 4, !tbaa !9
  %35 = load i32, ptr %15, align 4, !tbaa !9
  %36 = sub nsw i32 %35, 1
  store i32 %36, ptr %12, align 4, !tbaa !9
  %37 = load i32, ptr %13, align 4, !tbaa !9
  %38 = load i32, ptr %14, align 4, !tbaa !9
  %39 = load i32, ptr %15, align 4, !tbaa !9
  %40 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %37, i32 noundef %38, i32 noundef %39)
  %41 = load i32, ptr %10, align 4, !tbaa !9
  %42 = load i32, ptr %11, align 4, !tbaa !9
  %43 = load i32, ptr %12, align 4, !tbaa !9
  %44 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %41, i32 noundef %42, i32 noundef %43)
  %45 = load i32, ptr %13, align 4, !tbaa !9
  %46 = load i32, ptr %14, align 4, !tbaa !9
  %47 = load i32, ptr %15, align 4, !tbaa !9
  %48 = call i32 @newMat(ptr noundef @p, i32 noundef 1, i32 noundef %45, i32 noundef %46, i32 noundef %47)
  %49 = load i32, ptr %13, align 4, !tbaa !9
  %50 = load i32, ptr %14, align 4, !tbaa !9
  %51 = load i32, ptr %15, align 4, !tbaa !9
  %52 = call i32 @newMat(ptr noundef @bnd, i32 noundef 1, i32 noundef %49, i32 noundef %50, i32 noundef %51)
  %53 = load i32, ptr %13, align 4, !tbaa !9
  %54 = load i32, ptr %14, align 4, !tbaa !9
  %55 = load i32, ptr %15, align 4, !tbaa !9
  %56 = call i32 @newMat(ptr noundef @wrk1, i32 noundef 1, i32 noundef %53, i32 noundef %54, i32 noundef %55)
  %57 = load i32, ptr %13, align 4, !tbaa !9
  %58 = load i32, ptr %14, align 4, !tbaa !9
  %59 = load i32, ptr %15, align 4, !tbaa !9
  %60 = call i32 @newMat(ptr noundef @wrk2, i32 noundef 1, i32 noundef %57, i32 noundef %58, i32 noundef %59)
  %61 = load i32, ptr %13, align 4, !tbaa !9
  %62 = load i32, ptr %14, align 4, !tbaa !9
  %63 = load i32, ptr %15, align 4, !tbaa !9
  %64 = call i32 @newMat(ptr noundef @a, i32 noundef 4, i32 noundef %61, i32 noundef %62, i32 noundef %63)
  %65 = load i32, ptr %13, align 4, !tbaa !9
  %66 = load i32, ptr %14, align 4, !tbaa !9
  %67 = load i32, ptr %15, align 4, !tbaa !9
  %68 = call i32 @newMat(ptr noundef @b, i32 noundef 3, i32 noundef %65, i32 noundef %66, i32 noundef %67)
  %69 = load i32, ptr %13, align 4, !tbaa !9
  %70 = load i32, ptr %14, align 4, !tbaa !9
  %71 = load i32, ptr %15, align 4, !tbaa !9
  %72 = call i32 @newMat(ptr noundef @c, i32 noundef 3, i32 noundef %69, i32 noundef %70, i32 noundef %71)
  call void @mat_set_init(ptr noundef @p)
  call void @mat_set(ptr noundef @bnd, i32 noundef 0, float noundef 1.000000e+00)
  call void @mat_set(ptr noundef @wrk1, i32 noundef 0, float noundef 0.000000e+00)
  call void @mat_set(ptr noundef @wrk2, i32 noundef 0, float noundef 0.000000e+00)
  call void @mat_set(ptr noundef @a, i32 noundef 0, float noundef 1.000000e+00)
  call void @mat_set(ptr noundef @a, i32 noundef 1, float noundef 1.000000e+00)
  call void @mat_set(ptr noundef @a, i32 noundef 2, float noundef 1.000000e+00)
  call void @mat_set(ptr noundef @a, i32 noundef 3, float noundef f0x3E2AAAAB)
  call void @mat_set(ptr noundef @b, i32 noundef 0, float noundef 0.000000e+00)
  call void @mat_set(ptr noundef @b, i32 noundef 1, float noundef 0.000000e+00)
  call void @mat_set(ptr noundef @b, i32 noundef 2, float noundef 0.000000e+00)
  call void @mat_set(ptr noundef @c, i32 noundef 0, float noundef 1.000000e+00)
  call void @mat_set(ptr noundef @c, i32 noundef 1, float noundef 1.000000e+00)
  call void @mat_set(ptr noundef @c, i32 noundef 2, float noundef 1.000000e+00)
  store i32 64, ptr %9, align 4, !tbaa !9
  %73 = load i32, ptr %9, align 4, !tbaa !9
  %74 = call float @jacobi(i32 noundef %73, ptr noundef @a, ptr noundef @b, ptr noundef @c, ptr noundef @p, ptr noundef @bnd, ptr noundef @wrk1, ptr noundef @wrk2)
  store float %74, ptr %17, align 4, !tbaa !14
  %75 = load i32, ptr %9, align 4, !tbaa !9
  %76 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i32 noundef %75)
  %77 = load float, ptr %17, align 4, !tbaa !14
  %78 = fpext float %77 to double
  %79 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, double noundef %78)
  call void @clearMat(ptr noundef @p)
  call void @clearMat(ptr noundef @bnd)
  call void @clearMat(ptr noundef @wrk1)
  call void @clearMat(ptr noundef @wrk2)
  call void @clearMat(ptr noundef @a)
  call void @clearMat(ptr noundef @b)
  call void @clearMat(ptr noundef @c)
  call void @llvm.lifetime.end.p0(ptr %21) #8
  call void @llvm.lifetime.end.p0(ptr %20) #8
  call void @llvm.lifetime.end.p0(ptr %19) #8
  call void @llvm.lifetime.end.p0(ptr %18) #8
  call void @llvm.lifetime.end.p0(ptr %17) #8
  call void @llvm.lifetime.end.p0(ptr %16) #8
  call void @llvm.lifetime.end.p0(ptr %15) #8
  call void @llvm.lifetime.end.p0(ptr %14) #8
  call void @llvm.lifetime.end.p0(ptr %13) #8
  call void @llvm.lifetime.end.p0(ptr %12) #8
  call void @llvm.lifetime.end.p0(ptr %11) #8
  call void @llvm.lifetime.end.p0(ptr %10) #8
  call void @llvm.lifetime.end.p0(ptr %9) #8
  call void @llvm.lifetime.end.p0(ptr %8) #8
  call void @llvm.lifetime.end.p0(ptr %7) #8
  call void @llvm.lifetime.end.p0(ptr %6) #8
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nounwind uwtable
define dso_local i32 @newMat(ptr noundef %0, i32 noundef %1, i32 noundef %2, i32 noundef %3, i32 noundef %4) #0 {
  %6 = alloca ptr, align 8
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  store ptr %0, ptr %6, align 8, !tbaa !16
  store i32 %1, ptr %7, align 4, !tbaa !9
  store i32 %2, ptr %8, align 4, !tbaa !9
  store i32 %3, ptr %9, align 4, !tbaa !9
  store i32 %4, ptr %10, align 4, !tbaa !9
  %11 = load i32, ptr %7, align 4, !tbaa !9
  %12 = load ptr, ptr %6, align 8, !tbaa !16
  %13 = getelementptr inbounds nuw %struct.Mat, ptr %12, i32 0, i32 1
  store i32 %11, ptr %13, align 8, !tbaa !18
  %14 = load i32, ptr %8, align 4, !tbaa !9
  %15 = load ptr, ptr %6, align 8, !tbaa !16
  %16 = getelementptr inbounds nuw %struct.Mat, ptr %15, i32 0, i32 2
  store i32 %14, ptr %16, align 4, !tbaa !21
  %17 = load i32, ptr %9, align 4, !tbaa !9
  %18 = load ptr, ptr %6, align 8, !tbaa !16
  %19 = getelementptr inbounds nuw %struct.Mat, ptr %18, i32 0, i32 3
  store i32 %17, ptr %19, align 8, !tbaa !22
  %20 = load i32, ptr %10, align 4, !tbaa !9
  %21 = load ptr, ptr %6, align 8, !tbaa !16
  %22 = getelementptr inbounds nuw %struct.Mat, ptr %21, i32 0, i32 4
  store i32 %20, ptr %22, align 4, !tbaa !23
  %23 = load ptr, ptr %6, align 8, !tbaa !16
  %24 = getelementptr inbounds nuw %struct.Mat, ptr %23, i32 0, i32 0
  store ptr null, ptr %24, align 8, !tbaa !24
  %25 = load i32, ptr %7, align 4, !tbaa !9
  %26 = load i32, ptr %8, align 4, !tbaa !9
  %27 = mul nsw i32 %25, %26
  %28 = load i32, ptr %9, align 4, !tbaa !9
  %29 = mul nsw i32 %27, %28
  %30 = load i32, ptr %10, align 4, !tbaa !9
  %31 = mul nsw i32 %29, %30
  %32 = sext i32 %31 to i64
  %33 = mul i64 %32, 4
  %34 = call noalias ptr @malloc(i64 noundef %33) #9
  %35 = load ptr, ptr %6, align 8, !tbaa !16
  %36 = getelementptr inbounds nuw %struct.Mat, ptr %35, i32 0, i32 0
  store ptr %34, ptr %36, align 8, !tbaa !24
  %37 = load ptr, ptr %6, align 8, !tbaa !16
  %38 = getelementptr inbounds nuw %struct.Mat, ptr %37, i32 0, i32 0
  %39 = load ptr, ptr %38, align 8, !tbaa !24
  %40 = icmp ne ptr %39, null
  %41 = zext i1 %40 to i64
  %42 = select i1 %40, i32 1, i32 0
  ret i32 %42
}

; Function Attrs: nounwind uwtable
define dso_local void @mat_set_init(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca float, align 4
  store ptr %0, ptr %2, align 8, !tbaa !16
  call void @llvm.lifetime.start.p0(ptr %3) #8
  call void @llvm.lifetime.start.p0(ptr %4) #8
  call void @llvm.lifetime.start.p0(ptr %5) #8
  call void @llvm.lifetime.start.p0(ptr %6) #8
  call void @llvm.lifetime.start.p0(ptr %7) #8
  store i32 0, ptr %3, align 4, !tbaa !9
  br label %8

8:                                                ; preds = %87, %1
  %9 = load i32, ptr %3, align 4, !tbaa !9
  %10 = load ptr, ptr %2, align 8, !tbaa !16
  %11 = getelementptr inbounds nuw %struct.Mat, ptr %10, i32 0, i32 2
  %12 = load i32, ptr %11, align 4, !tbaa !21
  %13 = icmp slt i32 %9, %12
  br i1 %13, label %14, label %90

14:                                               ; preds = %8
  store i32 0, ptr %4, align 4, !tbaa !9
  br label %15

15:                                               ; preds = %83, %14
  %16 = load i32, ptr %4, align 4, !tbaa !9
  %17 = load ptr, ptr %2, align 8, !tbaa !16
  %18 = getelementptr inbounds nuw %struct.Mat, ptr %17, i32 0, i32 3
  %19 = load i32, ptr %18, align 8, !tbaa !22
  %20 = icmp slt i32 %16, %19
  br i1 %20, label %21, label %86

21:                                               ; preds = %15
  store i32 0, ptr %5, align 4, !tbaa !9
  br label %22

22:                                               ; preds = %79, %21
  %23 = load i32, ptr %5, align 4, !tbaa !9
  %24 = load ptr, ptr %2, align 8, !tbaa !16
  %25 = getelementptr inbounds nuw %struct.Mat, ptr %24, i32 0, i32 4
  %26 = load i32, ptr %25, align 4, !tbaa !23
  %27 = icmp slt i32 %23, %26
  br i1 %27, label %28, label %82

28:                                               ; preds = %22
  %29 = load i32, ptr %3, align 4, !tbaa !9
  %30 = load i32, ptr %3, align 4, !tbaa !9
  %31 = mul nsw i32 %29, %30
  %32 = sitofp i32 %31 to float
  %33 = load ptr, ptr %2, align 8, !tbaa !16
  %34 = getelementptr inbounds nuw %struct.Mat, ptr %33, i32 0, i32 2
  %35 = load i32, ptr %34, align 4, !tbaa !21
  %36 = sub nsw i32 %35, 1
  %37 = load ptr, ptr %2, align 8, !tbaa !16
  %38 = getelementptr inbounds nuw %struct.Mat, ptr %37, i32 0, i32 2
  %39 = load i32, ptr %38, align 4, !tbaa !21
  %40 = sub nsw i32 %39, 1
  %41 = mul nsw i32 %36, %40
  %42 = sitofp i32 %41 to float
  %43 = fdiv float %32, %42
  %44 = load ptr, ptr %2, align 8, !tbaa !16
  %45 = getelementptr inbounds nuw %struct.Mat, ptr %44, i32 0, i32 0
  %46 = load ptr, ptr %45, align 8, !tbaa !24
  %47 = load ptr, ptr %2, align 8, !tbaa !16
  %48 = getelementptr inbounds nuw %struct.Mat, ptr %47, i32 0, i32 2
  %49 = load i32, ptr %48, align 4, !tbaa !21
  %50 = mul nsw i32 0, %49
  %51 = load ptr, ptr %2, align 8, !tbaa !16
  %52 = getelementptr inbounds nuw %struct.Mat, ptr %51, i32 0, i32 3
  %53 = load i32, ptr %52, align 8, !tbaa !22
  %54 = mul nsw i32 %50, %53
  %55 = load ptr, ptr %2, align 8, !tbaa !16
  %56 = getelementptr inbounds nuw %struct.Mat, ptr %55, i32 0, i32 4
  %57 = load i32, ptr %56, align 4, !tbaa !23
  %58 = mul nsw i32 %54, %57
  %59 = load i32, ptr %3, align 4, !tbaa !9
  %60 = load ptr, ptr %2, align 8, !tbaa !16
  %61 = getelementptr inbounds nuw %struct.Mat, ptr %60, i32 0, i32 3
  %62 = load i32, ptr %61, align 8, !tbaa !22
  %63 = mul nsw i32 %59, %62
  %64 = load ptr, ptr %2, align 8, !tbaa !16
  %65 = getelementptr inbounds nuw %struct.Mat, ptr %64, i32 0, i32 4
  %66 = load i32, ptr %65, align 4, !tbaa !23
  %67 = mul nsw i32 %63, %66
  %68 = add nsw i32 %58, %67
  %69 = load i32, ptr %4, align 4, !tbaa !9
  %70 = load ptr, ptr %2, align 8, !tbaa !16
  %71 = getelementptr inbounds nuw %struct.Mat, ptr %70, i32 0, i32 4
  %72 = load i32, ptr %71, align 4, !tbaa !23
  %73 = mul nsw i32 %69, %72
  %74 = add nsw i32 %68, %73
  %75 = load i32, ptr %5, align 4, !tbaa !9
  %76 = add nsw i32 %74, %75
  %77 = sext i32 %76 to i64
  %78 = getelementptr inbounds float, ptr %46, i64 %77
  store float %43, ptr %78, align 4, !tbaa !14
  br label %79

79:                                               ; preds = %28
  %80 = load i32, ptr %5, align 4, !tbaa !9
  %81 = add nsw i32 %80, 1
  store i32 %81, ptr %5, align 4, !tbaa !9
  br label %22, !llvm.loop !25

82:                                               ; preds = %22
  br label %83

83:                                               ; preds = %82
  %84 = load i32, ptr %4, align 4, !tbaa !9
  %85 = add nsw i32 %84, 1
  store i32 %85, ptr %4, align 4, !tbaa !9
  br label %15, !llvm.loop !27

86:                                               ; preds = %15
  br label %87

87:                                               ; preds = %86
  %88 = load i32, ptr %3, align 4, !tbaa !9
  %89 = add nsw i32 %88, 1
  store i32 %89, ptr %3, align 4, !tbaa !9
  br label %8, !llvm.loop !28

90:                                               ; preds = %8
  call void @llvm.lifetime.end.p0(ptr %7) #8
  call void @llvm.lifetime.end.p0(ptr %6) #8
  call void @llvm.lifetime.end.p0(ptr %5) #8
  call void @llvm.lifetime.end.p0(ptr %4) #8
  call void @llvm.lifetime.end.p0(ptr %3) #8
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local void @mat_set(ptr noundef %0, i32 noundef %1, float noundef %2) #0 {
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  %6 = alloca float, align 4
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  store ptr %0, ptr %4, align 8, !tbaa !16
  store i32 %1, ptr %5, align 4, !tbaa !9
  store float %2, ptr %6, align 4, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %7) #8
  call void @llvm.lifetime.start.p0(ptr %8) #8
  call void @llvm.lifetime.start.p0(ptr %9) #8
  store i32 0, ptr %7, align 4, !tbaa !9
  br label %10

10:                                               ; preds = %76, %3
  %11 = load i32, ptr %7, align 4, !tbaa !9
  %12 = load ptr, ptr %4, align 8, !tbaa !16
  %13 = getelementptr inbounds nuw %struct.Mat, ptr %12, i32 0, i32 2
  %14 = load i32, ptr %13, align 4, !tbaa !21
  %15 = icmp slt i32 %11, %14
  br i1 %15, label %16, label %79

16:                                               ; preds = %10
  store i32 0, ptr %8, align 4, !tbaa !9
  br label %17

17:                                               ; preds = %72, %16
  %18 = load i32, ptr %8, align 4, !tbaa !9
  %19 = load ptr, ptr %4, align 8, !tbaa !16
  %20 = getelementptr inbounds nuw %struct.Mat, ptr %19, i32 0, i32 3
  %21 = load i32, ptr %20, align 8, !tbaa !22
  %22 = icmp slt i32 %18, %21
  br i1 %22, label %23, label %75

23:                                               ; preds = %17
  store i32 0, ptr %9, align 4, !tbaa !9
  br label %24

24:                                               ; preds = %68, %23
  %25 = load i32, ptr %9, align 4, !tbaa !9
  %26 = load ptr, ptr %4, align 8, !tbaa !16
  %27 = getelementptr inbounds nuw %struct.Mat, ptr %26, i32 0, i32 4
  %28 = load i32, ptr %27, align 4, !tbaa !23
  %29 = icmp slt i32 %25, %28
  br i1 %29, label %30, label %71

30:                                               ; preds = %24
  %31 = load float, ptr %6, align 4, !tbaa !14
  %32 = load ptr, ptr %4, align 8, !tbaa !16
  %33 = getelementptr inbounds nuw %struct.Mat, ptr %32, i32 0, i32 0
  %34 = load ptr, ptr %33, align 8, !tbaa !24
  %35 = load i32, ptr %5, align 4, !tbaa !9
  %36 = load ptr, ptr %4, align 8, !tbaa !16
  %37 = getelementptr inbounds nuw %struct.Mat, ptr %36, i32 0, i32 2
  %38 = load i32, ptr %37, align 4, !tbaa !21
  %39 = mul nsw i32 %35, %38
  %40 = load ptr, ptr %4, align 8, !tbaa !16
  %41 = getelementptr inbounds nuw %struct.Mat, ptr %40, i32 0, i32 3
  %42 = load i32, ptr %41, align 8, !tbaa !22
  %43 = mul nsw i32 %39, %42
  %44 = load ptr, ptr %4, align 8, !tbaa !16
  %45 = getelementptr inbounds nuw %struct.Mat, ptr %44, i32 0, i32 4
  %46 = load i32, ptr %45, align 4, !tbaa !23
  %47 = mul nsw i32 %43, %46
  %48 = load i32, ptr %7, align 4, !tbaa !9
  %49 = load ptr, ptr %4, align 8, !tbaa !16
  %50 = getelementptr inbounds nuw %struct.Mat, ptr %49, i32 0, i32 3
  %51 = load i32, ptr %50, align 8, !tbaa !22
  %52 = mul nsw i32 %48, %51
  %53 = load ptr, ptr %4, align 8, !tbaa !16
  %54 = getelementptr inbounds nuw %struct.Mat, ptr %53, i32 0, i32 4
  %55 = load i32, ptr %54, align 4, !tbaa !23
  %56 = mul nsw i32 %52, %55
  %57 = add nsw i32 %47, %56
  %58 = load i32, ptr %8, align 4, !tbaa !9
  %59 = load ptr, ptr %4, align 8, !tbaa !16
  %60 = getelementptr inbounds nuw %struct.Mat, ptr %59, i32 0, i32 4
  %61 = load i32, ptr %60, align 4, !tbaa !23
  %62 = mul nsw i32 %58, %61
  %63 = add nsw i32 %57, %62
  %64 = load i32, ptr %9, align 4, !tbaa !9
  %65 = add nsw i32 %63, %64
  %66 = sext i32 %65 to i64
  %67 = getelementptr inbounds float, ptr %34, i64 %66
  store float %31, ptr %67, align 4, !tbaa !14
  br label %68

68:                                               ; preds = %30
  %69 = load i32, ptr %9, align 4, !tbaa !9
  %70 = add nsw i32 %69, 1
  store i32 %70, ptr %9, align 4, !tbaa !9
  br label %24, !llvm.loop !29

71:                                               ; preds = %24
  br label %72

72:                                               ; preds = %71
  %73 = load i32, ptr %8, align 4, !tbaa !9
  %74 = add nsw i32 %73, 1
  store i32 %74, ptr %8, align 4, !tbaa !9
  br label %17, !llvm.loop !30

75:                                               ; preds = %17
  br label %76

76:                                               ; preds = %75
  %77 = load i32, ptr %7, align 4, !tbaa !9
  %78 = add nsw i32 %77, 1
  store i32 %78, ptr %7, align 4, !tbaa !9
  br label %10, !llvm.loop !31

79:                                               ; preds = %10
  call void @llvm.lifetime.end.p0(ptr %9) #8
  call void @llvm.lifetime.end.p0(ptr %8) #8
  call void @llvm.lifetime.end.p0(ptr %7) #8
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local float @jacobi(i32 noundef %0, ptr noundef %1, ptr noundef %2, ptr noundef %3, ptr noundef %4, ptr noundef %5, ptr noundef %6, ptr noundef %7) #0 {
  %9 = alloca i32, align 4
  %10 = alloca ptr, align 8
  %11 = alloca ptr, align 8
  %12 = alloca ptr, align 8
  %13 = alloca ptr, align 8
  %14 = alloca ptr, align 8
  %15 = alloca ptr, align 8
  %16 = alloca ptr, align 8
  %17 = alloca i32, align 4
  %18 = alloca i32, align 4
  %19 = alloca i32, align 4
  %20 = alloca i32, align 4
  %21 = alloca i32, align 4
  %22 = alloca i32, align 4
  %23 = alloca i32, align 4
  %24 = alloca float, align 4
  %25 = alloca float, align 4
  %26 = alloca float, align 4
  store i32 %0, ptr %9, align 4, !tbaa !9
  store ptr %1, ptr %10, align 8, !tbaa !16
  store ptr %2, ptr %11, align 8, !tbaa !16
  store ptr %3, ptr %12, align 8, !tbaa !16
  store ptr %4, ptr %13, align 8, !tbaa !16
  store ptr %5, ptr %14, align 8, !tbaa !16
  store ptr %6, ptr %15, align 8, !tbaa !16
  store ptr %7, ptr %16, align 8, !tbaa !16
  call void @llvm.lifetime.start.p0(ptr %17) #8
  call void @llvm.lifetime.start.p0(ptr %18) #8
  call void @llvm.lifetime.start.p0(ptr %19) #8
  call void @llvm.lifetime.start.p0(ptr %20) #8
  call void @llvm.lifetime.start.p0(ptr %21) #8
  call void @llvm.lifetime.start.p0(ptr %22) #8
  call void @llvm.lifetime.start.p0(ptr %23) #8
  call void @llvm.lifetime.start.p0(ptr %24) #8
  call void @llvm.lifetime.start.p0(ptr %25) #8
  call void @llvm.lifetime.start.p0(ptr %26) #8
  %27 = load ptr, ptr %13, align 8, !tbaa !16
  %28 = getelementptr inbounds nuw %struct.Mat, ptr %27, i32 0, i32 2
  %29 = load i32, ptr %28, align 4, !tbaa !21
  %30 = sub nsw i32 %29, 1
  store i32 %30, ptr %21, align 4, !tbaa !9
  %31 = load ptr, ptr %13, align 8, !tbaa !16
  %32 = getelementptr inbounds nuw %struct.Mat, ptr %31, i32 0, i32 3
  %33 = load i32, ptr %32, align 8, !tbaa !22
  %34 = sub nsw i32 %33, 1
  store i32 %34, ptr %22, align 4, !tbaa !9
  %35 = load ptr, ptr %13, align 8, !tbaa !16
  %36 = getelementptr inbounds nuw %struct.Mat, ptr %35, i32 0, i32 4
  %37 = load i32, ptr %36, align 4, !tbaa !23
  %38 = sub nsw i32 %37, 1
  store i32 %38, ptr %23, align 4, !tbaa !9
  store i32 0, ptr %20, align 4, !tbaa !9
  br label %39

39:                                               ; preds = %1416, %8
  %40 = load i32, ptr %20, align 4, !tbaa !9
  %41 = load i32, ptr %9, align 4, !tbaa !9
  %42 = icmp slt i32 %40, %41
  br i1 %42, label %43, label %1419

43:                                               ; preds = %39
  store float 0.000000e+00, ptr %24, align 4, !tbaa !14
  store i32 1, ptr %17, align 4, !tbaa !9
  br label %44

44:                                               ; preds = %1314, %43
  %45 = load i32, ptr %17, align 4, !tbaa !9
  %46 = load i32, ptr %21, align 4, !tbaa !9
  %47 = icmp slt i32 %45, %46
  br i1 %47, label %48, label %1317

48:                                               ; preds = %44
  store i32 1, ptr %18, align 4, !tbaa !9
  br label %49

49:                                               ; preds = %1310, %48
  %50 = load i32, ptr %18, align 4, !tbaa !9
  %51 = load i32, ptr %22, align 4, !tbaa !9
  %52 = icmp slt i32 %50, %51
  br i1 %52, label %53, label %1313

53:                                               ; preds = %49
  store i32 1, ptr %19, align 4, !tbaa !9
  br label %54

54:                                               ; preds = %1306, %53
  %55 = load i32, ptr %19, align 4, !tbaa !9
  %56 = load i32, ptr %23, align 4, !tbaa !9
  %57 = icmp slt i32 %55, %56
  br i1 %57, label %58, label %1309

58:                                               ; preds = %54
  %59 = load ptr, ptr %10, align 8, !tbaa !16
  %60 = getelementptr inbounds nuw %struct.Mat, ptr %59, i32 0, i32 0
  %61 = load ptr, ptr %60, align 8, !tbaa !24
  %62 = load ptr, ptr %10, align 8, !tbaa !16
  %63 = getelementptr inbounds nuw %struct.Mat, ptr %62, i32 0, i32 2
  %64 = load i32, ptr %63, align 4, !tbaa !21
  %65 = mul nsw i32 0, %64
  %66 = load ptr, ptr %10, align 8, !tbaa !16
  %67 = getelementptr inbounds nuw %struct.Mat, ptr %66, i32 0, i32 3
  %68 = load i32, ptr %67, align 8, !tbaa !22
  %69 = mul nsw i32 %65, %68
  %70 = load ptr, ptr %10, align 8, !tbaa !16
  %71 = getelementptr inbounds nuw %struct.Mat, ptr %70, i32 0, i32 4
  %72 = load i32, ptr %71, align 4, !tbaa !23
  %73 = mul nsw i32 %69, %72
  %74 = load i32, ptr %17, align 4, !tbaa !9
  %75 = load ptr, ptr %10, align 8, !tbaa !16
  %76 = getelementptr inbounds nuw %struct.Mat, ptr %75, i32 0, i32 3
  %77 = load i32, ptr %76, align 8, !tbaa !22
  %78 = mul nsw i32 %74, %77
  %79 = load ptr, ptr %10, align 8, !tbaa !16
  %80 = getelementptr inbounds nuw %struct.Mat, ptr %79, i32 0, i32 4
  %81 = load i32, ptr %80, align 4, !tbaa !23
  %82 = mul nsw i32 %78, %81
  %83 = add nsw i32 %73, %82
  %84 = load i32, ptr %18, align 4, !tbaa !9
  %85 = load ptr, ptr %10, align 8, !tbaa !16
  %86 = getelementptr inbounds nuw %struct.Mat, ptr %85, i32 0, i32 4
  %87 = load i32, ptr %86, align 4, !tbaa !23
  %88 = mul nsw i32 %84, %87
  %89 = add nsw i32 %83, %88
  %90 = load i32, ptr %19, align 4, !tbaa !9
  %91 = add nsw i32 %89, %90
  %92 = sext i32 %91 to i64
  %93 = getelementptr inbounds float, ptr %61, i64 %92
  %94 = load float, ptr %93, align 4, !tbaa !14
  %95 = load ptr, ptr %13, align 8, !tbaa !16
  %96 = getelementptr inbounds nuw %struct.Mat, ptr %95, i32 0, i32 0
  %97 = load ptr, ptr %96, align 8, !tbaa !24
  %98 = load ptr, ptr %13, align 8, !tbaa !16
  %99 = getelementptr inbounds nuw %struct.Mat, ptr %98, i32 0, i32 2
  %100 = load i32, ptr %99, align 4, !tbaa !21
  %101 = mul nsw i32 0, %100
  %102 = load ptr, ptr %13, align 8, !tbaa !16
  %103 = getelementptr inbounds nuw %struct.Mat, ptr %102, i32 0, i32 3
  %104 = load i32, ptr %103, align 8, !tbaa !22
  %105 = mul nsw i32 %101, %104
  %106 = load ptr, ptr %13, align 8, !tbaa !16
  %107 = getelementptr inbounds nuw %struct.Mat, ptr %106, i32 0, i32 4
  %108 = load i32, ptr %107, align 4, !tbaa !23
  %109 = mul nsw i32 %105, %108
  %110 = load i32, ptr %17, align 4, !tbaa !9
  %111 = add nsw i32 %110, 1
  %112 = load ptr, ptr %13, align 8, !tbaa !16
  %113 = getelementptr inbounds nuw %struct.Mat, ptr %112, i32 0, i32 3
  %114 = load i32, ptr %113, align 8, !tbaa !22
  %115 = mul nsw i32 %111, %114
  %116 = load ptr, ptr %13, align 8, !tbaa !16
  %117 = getelementptr inbounds nuw %struct.Mat, ptr %116, i32 0, i32 4
  %118 = load i32, ptr %117, align 4, !tbaa !23
  %119 = mul nsw i32 %115, %118
  %120 = add nsw i32 %109, %119
  %121 = load i32, ptr %18, align 4, !tbaa !9
  %122 = load ptr, ptr %13, align 8, !tbaa !16
  %123 = getelementptr inbounds nuw %struct.Mat, ptr %122, i32 0, i32 4
  %124 = load i32, ptr %123, align 4, !tbaa !23
  %125 = mul nsw i32 %121, %124
  %126 = add nsw i32 %120, %125
  %127 = load i32, ptr %19, align 4, !tbaa !9
  %128 = add nsw i32 %126, %127
  %129 = sext i32 %128 to i64
  %130 = getelementptr inbounds float, ptr %97, i64 %129
  %131 = load float, ptr %130, align 4, !tbaa !14
  %132 = load ptr, ptr %10, align 8, !tbaa !16
  %133 = getelementptr inbounds nuw %struct.Mat, ptr %132, i32 0, i32 0
  %134 = load ptr, ptr %133, align 8, !tbaa !24
  %135 = load ptr, ptr %10, align 8, !tbaa !16
  %136 = getelementptr inbounds nuw %struct.Mat, ptr %135, i32 0, i32 2
  %137 = load i32, ptr %136, align 4, !tbaa !21
  %138 = mul nsw i32 1, %137
  %139 = load ptr, ptr %10, align 8, !tbaa !16
  %140 = getelementptr inbounds nuw %struct.Mat, ptr %139, i32 0, i32 3
  %141 = load i32, ptr %140, align 8, !tbaa !22
  %142 = mul nsw i32 %138, %141
  %143 = load ptr, ptr %10, align 8, !tbaa !16
  %144 = getelementptr inbounds nuw %struct.Mat, ptr %143, i32 0, i32 4
  %145 = load i32, ptr %144, align 4, !tbaa !23
  %146 = mul nsw i32 %142, %145
  %147 = load i32, ptr %17, align 4, !tbaa !9
  %148 = load ptr, ptr %10, align 8, !tbaa !16
  %149 = getelementptr inbounds nuw %struct.Mat, ptr %148, i32 0, i32 3
  %150 = load i32, ptr %149, align 8, !tbaa !22
  %151 = mul nsw i32 %147, %150
  %152 = load ptr, ptr %10, align 8, !tbaa !16
  %153 = getelementptr inbounds nuw %struct.Mat, ptr %152, i32 0, i32 4
  %154 = load i32, ptr %153, align 4, !tbaa !23
  %155 = mul nsw i32 %151, %154
  %156 = add nsw i32 %146, %155
  %157 = load i32, ptr %18, align 4, !tbaa !9
  %158 = load ptr, ptr %10, align 8, !tbaa !16
  %159 = getelementptr inbounds nuw %struct.Mat, ptr %158, i32 0, i32 4
  %160 = load i32, ptr %159, align 4, !tbaa !23
  %161 = mul nsw i32 %157, %160
  %162 = add nsw i32 %156, %161
  %163 = load i32, ptr %19, align 4, !tbaa !9
  %164 = add nsw i32 %162, %163
  %165 = sext i32 %164 to i64
  %166 = getelementptr inbounds float, ptr %134, i64 %165
  %167 = load float, ptr %166, align 4, !tbaa !14
  %168 = load ptr, ptr %13, align 8, !tbaa !16
  %169 = getelementptr inbounds nuw %struct.Mat, ptr %168, i32 0, i32 0
  %170 = load ptr, ptr %169, align 8, !tbaa !24
  %171 = load ptr, ptr %13, align 8, !tbaa !16
  %172 = getelementptr inbounds nuw %struct.Mat, ptr %171, i32 0, i32 2
  %173 = load i32, ptr %172, align 4, !tbaa !21
  %174 = mul nsw i32 0, %173
  %175 = load ptr, ptr %13, align 8, !tbaa !16
  %176 = getelementptr inbounds nuw %struct.Mat, ptr %175, i32 0, i32 3
  %177 = load i32, ptr %176, align 8, !tbaa !22
  %178 = mul nsw i32 %174, %177
  %179 = load ptr, ptr %13, align 8, !tbaa !16
  %180 = getelementptr inbounds nuw %struct.Mat, ptr %179, i32 0, i32 4
  %181 = load i32, ptr %180, align 4, !tbaa !23
  %182 = mul nsw i32 %178, %181
  %183 = load i32, ptr %17, align 4, !tbaa !9
  %184 = load ptr, ptr %13, align 8, !tbaa !16
  %185 = getelementptr inbounds nuw %struct.Mat, ptr %184, i32 0, i32 3
  %186 = load i32, ptr %185, align 8, !tbaa !22
  %187 = mul nsw i32 %183, %186
  %188 = load ptr, ptr %13, align 8, !tbaa !16
  %189 = getelementptr inbounds nuw %struct.Mat, ptr %188, i32 0, i32 4
  %190 = load i32, ptr %189, align 4, !tbaa !23
  %191 = mul nsw i32 %187, %190
  %192 = add nsw i32 %182, %191
  %193 = load i32, ptr %18, align 4, !tbaa !9
  %194 = add nsw i32 %193, 1
  %195 = load ptr, ptr %13, align 8, !tbaa !16
  %196 = getelementptr inbounds nuw %struct.Mat, ptr %195, i32 0, i32 4
  %197 = load i32, ptr %196, align 4, !tbaa !23
  %198 = mul nsw i32 %194, %197
  %199 = add nsw i32 %192, %198
  %200 = load i32, ptr %19, align 4, !tbaa !9
  %201 = add nsw i32 %199, %200
  %202 = sext i32 %201 to i64
  %203 = getelementptr inbounds float, ptr %170, i64 %202
  %204 = load float, ptr %203, align 4, !tbaa !14
  %205 = fmul float %167, %204
  %206 = call float @llvm.fmuladd.f32(float %94, float %131, float %205)
  %207 = load ptr, ptr %10, align 8, !tbaa !16
  %208 = getelementptr inbounds nuw %struct.Mat, ptr %207, i32 0, i32 0
  %209 = load ptr, ptr %208, align 8, !tbaa !24
  %210 = load ptr, ptr %10, align 8, !tbaa !16
  %211 = getelementptr inbounds nuw %struct.Mat, ptr %210, i32 0, i32 2
  %212 = load i32, ptr %211, align 4, !tbaa !21
  %213 = mul nsw i32 2, %212
  %214 = load ptr, ptr %10, align 8, !tbaa !16
  %215 = getelementptr inbounds nuw %struct.Mat, ptr %214, i32 0, i32 3
  %216 = load i32, ptr %215, align 8, !tbaa !22
  %217 = mul nsw i32 %213, %216
  %218 = load ptr, ptr %10, align 8, !tbaa !16
  %219 = getelementptr inbounds nuw %struct.Mat, ptr %218, i32 0, i32 4
  %220 = load i32, ptr %219, align 4, !tbaa !23
  %221 = mul nsw i32 %217, %220
  %222 = load i32, ptr %17, align 4, !tbaa !9
  %223 = load ptr, ptr %10, align 8, !tbaa !16
  %224 = getelementptr inbounds nuw %struct.Mat, ptr %223, i32 0, i32 3
  %225 = load i32, ptr %224, align 8, !tbaa !22
  %226 = mul nsw i32 %222, %225
  %227 = load ptr, ptr %10, align 8, !tbaa !16
  %228 = getelementptr inbounds nuw %struct.Mat, ptr %227, i32 0, i32 4
  %229 = load i32, ptr %228, align 4, !tbaa !23
  %230 = mul nsw i32 %226, %229
  %231 = add nsw i32 %221, %230
  %232 = load i32, ptr %18, align 4, !tbaa !9
  %233 = load ptr, ptr %10, align 8, !tbaa !16
  %234 = getelementptr inbounds nuw %struct.Mat, ptr %233, i32 0, i32 4
  %235 = load i32, ptr %234, align 4, !tbaa !23
  %236 = mul nsw i32 %232, %235
  %237 = add nsw i32 %231, %236
  %238 = load i32, ptr %19, align 4, !tbaa !9
  %239 = add nsw i32 %237, %238
  %240 = sext i32 %239 to i64
  %241 = getelementptr inbounds float, ptr %209, i64 %240
  %242 = load float, ptr %241, align 4, !tbaa !14
  %243 = load ptr, ptr %13, align 8, !tbaa !16
  %244 = getelementptr inbounds nuw %struct.Mat, ptr %243, i32 0, i32 0
  %245 = load ptr, ptr %244, align 8, !tbaa !24
  %246 = load ptr, ptr %13, align 8, !tbaa !16
  %247 = getelementptr inbounds nuw %struct.Mat, ptr %246, i32 0, i32 2
  %248 = load i32, ptr %247, align 4, !tbaa !21
  %249 = mul nsw i32 0, %248
  %250 = load ptr, ptr %13, align 8, !tbaa !16
  %251 = getelementptr inbounds nuw %struct.Mat, ptr %250, i32 0, i32 3
  %252 = load i32, ptr %251, align 8, !tbaa !22
  %253 = mul nsw i32 %249, %252
  %254 = load ptr, ptr %13, align 8, !tbaa !16
  %255 = getelementptr inbounds nuw %struct.Mat, ptr %254, i32 0, i32 4
  %256 = load i32, ptr %255, align 4, !tbaa !23
  %257 = mul nsw i32 %253, %256
  %258 = load i32, ptr %17, align 4, !tbaa !9
  %259 = load ptr, ptr %13, align 8, !tbaa !16
  %260 = getelementptr inbounds nuw %struct.Mat, ptr %259, i32 0, i32 3
  %261 = load i32, ptr %260, align 8, !tbaa !22
  %262 = mul nsw i32 %258, %261
  %263 = load ptr, ptr %13, align 8, !tbaa !16
  %264 = getelementptr inbounds nuw %struct.Mat, ptr %263, i32 0, i32 4
  %265 = load i32, ptr %264, align 4, !tbaa !23
  %266 = mul nsw i32 %262, %265
  %267 = add nsw i32 %257, %266
  %268 = load i32, ptr %18, align 4, !tbaa !9
  %269 = load ptr, ptr %13, align 8, !tbaa !16
  %270 = getelementptr inbounds nuw %struct.Mat, ptr %269, i32 0, i32 4
  %271 = load i32, ptr %270, align 4, !tbaa !23
  %272 = mul nsw i32 %268, %271
  %273 = add nsw i32 %267, %272
  %274 = load i32, ptr %19, align 4, !tbaa !9
  %275 = add nsw i32 %274, 1
  %276 = add nsw i32 %273, %275
  %277 = sext i32 %276 to i64
  %278 = getelementptr inbounds float, ptr %245, i64 %277
  %279 = load float, ptr %278, align 4, !tbaa !14
  %280 = call float @llvm.fmuladd.f32(float %242, float %279, float %206)
  %281 = load ptr, ptr %11, align 8, !tbaa !16
  %282 = getelementptr inbounds nuw %struct.Mat, ptr %281, i32 0, i32 0
  %283 = load ptr, ptr %282, align 8, !tbaa !24
  %284 = load ptr, ptr %11, align 8, !tbaa !16
  %285 = getelementptr inbounds nuw %struct.Mat, ptr %284, i32 0, i32 2
  %286 = load i32, ptr %285, align 4, !tbaa !21
  %287 = mul nsw i32 0, %286
  %288 = load ptr, ptr %11, align 8, !tbaa !16
  %289 = getelementptr inbounds nuw %struct.Mat, ptr %288, i32 0, i32 3
  %290 = load i32, ptr %289, align 8, !tbaa !22
  %291 = mul nsw i32 %287, %290
  %292 = load ptr, ptr %11, align 8, !tbaa !16
  %293 = getelementptr inbounds nuw %struct.Mat, ptr %292, i32 0, i32 4
  %294 = load i32, ptr %293, align 4, !tbaa !23
  %295 = mul nsw i32 %291, %294
  %296 = load i32, ptr %17, align 4, !tbaa !9
  %297 = load ptr, ptr %11, align 8, !tbaa !16
  %298 = getelementptr inbounds nuw %struct.Mat, ptr %297, i32 0, i32 3
  %299 = load i32, ptr %298, align 8, !tbaa !22
  %300 = mul nsw i32 %296, %299
  %301 = load ptr, ptr %11, align 8, !tbaa !16
  %302 = getelementptr inbounds nuw %struct.Mat, ptr %301, i32 0, i32 4
  %303 = load i32, ptr %302, align 4, !tbaa !23
  %304 = mul nsw i32 %300, %303
  %305 = add nsw i32 %295, %304
  %306 = load i32, ptr %18, align 4, !tbaa !9
  %307 = load ptr, ptr %11, align 8, !tbaa !16
  %308 = getelementptr inbounds nuw %struct.Mat, ptr %307, i32 0, i32 4
  %309 = load i32, ptr %308, align 4, !tbaa !23
  %310 = mul nsw i32 %306, %309
  %311 = add nsw i32 %305, %310
  %312 = load i32, ptr %19, align 4, !tbaa !9
  %313 = add nsw i32 %311, %312
  %314 = sext i32 %313 to i64
  %315 = getelementptr inbounds float, ptr %283, i64 %314
  %316 = load float, ptr %315, align 4, !tbaa !14
  %317 = load ptr, ptr %13, align 8, !tbaa !16
  %318 = getelementptr inbounds nuw %struct.Mat, ptr %317, i32 0, i32 0
  %319 = load ptr, ptr %318, align 8, !tbaa !24
  %320 = load ptr, ptr %13, align 8, !tbaa !16
  %321 = getelementptr inbounds nuw %struct.Mat, ptr %320, i32 0, i32 2
  %322 = load i32, ptr %321, align 4, !tbaa !21
  %323 = mul nsw i32 0, %322
  %324 = load ptr, ptr %13, align 8, !tbaa !16
  %325 = getelementptr inbounds nuw %struct.Mat, ptr %324, i32 0, i32 3
  %326 = load i32, ptr %325, align 8, !tbaa !22
  %327 = mul nsw i32 %323, %326
  %328 = load ptr, ptr %13, align 8, !tbaa !16
  %329 = getelementptr inbounds nuw %struct.Mat, ptr %328, i32 0, i32 4
  %330 = load i32, ptr %329, align 4, !tbaa !23
  %331 = mul nsw i32 %327, %330
  %332 = load i32, ptr %17, align 4, !tbaa !9
  %333 = add nsw i32 %332, 1
  %334 = load ptr, ptr %13, align 8, !tbaa !16
  %335 = getelementptr inbounds nuw %struct.Mat, ptr %334, i32 0, i32 3
  %336 = load i32, ptr %335, align 8, !tbaa !22
  %337 = mul nsw i32 %333, %336
  %338 = load ptr, ptr %13, align 8, !tbaa !16
  %339 = getelementptr inbounds nuw %struct.Mat, ptr %338, i32 0, i32 4
  %340 = load i32, ptr %339, align 4, !tbaa !23
  %341 = mul nsw i32 %337, %340
  %342 = add nsw i32 %331, %341
  %343 = load i32, ptr %18, align 4, !tbaa !9
  %344 = add nsw i32 %343, 1
  %345 = load ptr, ptr %13, align 8, !tbaa !16
  %346 = getelementptr inbounds nuw %struct.Mat, ptr %345, i32 0, i32 4
  %347 = load i32, ptr %346, align 4, !tbaa !23
  %348 = mul nsw i32 %344, %347
  %349 = add nsw i32 %342, %348
  %350 = load i32, ptr %19, align 4, !tbaa !9
  %351 = add nsw i32 %349, %350
  %352 = sext i32 %351 to i64
  %353 = getelementptr inbounds float, ptr %319, i64 %352
  %354 = load float, ptr %353, align 4, !tbaa !14
  %355 = load ptr, ptr %13, align 8, !tbaa !16
  %356 = getelementptr inbounds nuw %struct.Mat, ptr %355, i32 0, i32 0
  %357 = load ptr, ptr %356, align 8, !tbaa !24
  %358 = load ptr, ptr %13, align 8, !tbaa !16
  %359 = getelementptr inbounds nuw %struct.Mat, ptr %358, i32 0, i32 2
  %360 = load i32, ptr %359, align 4, !tbaa !21
  %361 = mul nsw i32 0, %360
  %362 = load ptr, ptr %13, align 8, !tbaa !16
  %363 = getelementptr inbounds nuw %struct.Mat, ptr %362, i32 0, i32 3
  %364 = load i32, ptr %363, align 8, !tbaa !22
  %365 = mul nsw i32 %361, %364
  %366 = load ptr, ptr %13, align 8, !tbaa !16
  %367 = getelementptr inbounds nuw %struct.Mat, ptr %366, i32 0, i32 4
  %368 = load i32, ptr %367, align 4, !tbaa !23
  %369 = mul nsw i32 %365, %368
  %370 = load i32, ptr %17, align 4, !tbaa !9
  %371 = add nsw i32 %370, 1
  %372 = load ptr, ptr %13, align 8, !tbaa !16
  %373 = getelementptr inbounds nuw %struct.Mat, ptr %372, i32 0, i32 3
  %374 = load i32, ptr %373, align 8, !tbaa !22
  %375 = mul nsw i32 %371, %374
  %376 = load ptr, ptr %13, align 8, !tbaa !16
  %377 = getelementptr inbounds nuw %struct.Mat, ptr %376, i32 0, i32 4
  %378 = load i32, ptr %377, align 4, !tbaa !23
  %379 = mul nsw i32 %375, %378
  %380 = add nsw i32 %369, %379
  %381 = load i32, ptr %18, align 4, !tbaa !9
  %382 = sub nsw i32 %381, 1
  %383 = load ptr, ptr %13, align 8, !tbaa !16
  %384 = getelementptr inbounds nuw %struct.Mat, ptr %383, i32 0, i32 4
  %385 = load i32, ptr %384, align 4, !tbaa !23
  %386 = mul nsw i32 %382, %385
  %387 = add nsw i32 %380, %386
  %388 = load i32, ptr %19, align 4, !tbaa !9
  %389 = add nsw i32 %387, %388
  %390 = sext i32 %389 to i64
  %391 = getelementptr inbounds float, ptr %357, i64 %390
  %392 = load float, ptr %391, align 4, !tbaa !14
  %393 = fsub float %354, %392
  %394 = load ptr, ptr %13, align 8, !tbaa !16
  %395 = getelementptr inbounds nuw %struct.Mat, ptr %394, i32 0, i32 0
  %396 = load ptr, ptr %395, align 8, !tbaa !24
  %397 = load ptr, ptr %13, align 8, !tbaa !16
  %398 = getelementptr inbounds nuw %struct.Mat, ptr %397, i32 0, i32 2
  %399 = load i32, ptr %398, align 4, !tbaa !21
  %400 = mul nsw i32 0, %399
  %401 = load ptr, ptr %13, align 8, !tbaa !16
  %402 = getelementptr inbounds nuw %struct.Mat, ptr %401, i32 0, i32 3
  %403 = load i32, ptr %402, align 8, !tbaa !22
  %404 = mul nsw i32 %400, %403
  %405 = load ptr, ptr %13, align 8, !tbaa !16
  %406 = getelementptr inbounds nuw %struct.Mat, ptr %405, i32 0, i32 4
  %407 = load i32, ptr %406, align 4, !tbaa !23
  %408 = mul nsw i32 %404, %407
  %409 = load i32, ptr %17, align 4, !tbaa !9
  %410 = sub nsw i32 %409, 1
  %411 = load ptr, ptr %13, align 8, !tbaa !16
  %412 = getelementptr inbounds nuw %struct.Mat, ptr %411, i32 0, i32 3
  %413 = load i32, ptr %412, align 8, !tbaa !22
  %414 = mul nsw i32 %410, %413
  %415 = load ptr, ptr %13, align 8, !tbaa !16
  %416 = getelementptr inbounds nuw %struct.Mat, ptr %415, i32 0, i32 4
  %417 = load i32, ptr %416, align 4, !tbaa !23
  %418 = mul nsw i32 %414, %417
  %419 = add nsw i32 %408, %418
  %420 = load i32, ptr %18, align 4, !tbaa !9
  %421 = add nsw i32 %420, 1
  %422 = load ptr, ptr %13, align 8, !tbaa !16
  %423 = getelementptr inbounds nuw %struct.Mat, ptr %422, i32 0, i32 4
  %424 = load i32, ptr %423, align 4, !tbaa !23
  %425 = mul nsw i32 %421, %424
  %426 = add nsw i32 %419, %425
  %427 = load i32, ptr %19, align 4, !tbaa !9
  %428 = add nsw i32 %426, %427
  %429 = sext i32 %428 to i64
  %430 = getelementptr inbounds float, ptr %396, i64 %429
  %431 = load float, ptr %430, align 4, !tbaa !14
  %432 = fsub float %393, %431
  %433 = load ptr, ptr %13, align 8, !tbaa !16
  %434 = getelementptr inbounds nuw %struct.Mat, ptr %433, i32 0, i32 0
  %435 = load ptr, ptr %434, align 8, !tbaa !24
  %436 = load ptr, ptr %13, align 8, !tbaa !16
  %437 = getelementptr inbounds nuw %struct.Mat, ptr %436, i32 0, i32 2
  %438 = load i32, ptr %437, align 4, !tbaa !21
  %439 = mul nsw i32 0, %438
  %440 = load ptr, ptr %13, align 8, !tbaa !16
  %441 = getelementptr inbounds nuw %struct.Mat, ptr %440, i32 0, i32 3
  %442 = load i32, ptr %441, align 8, !tbaa !22
  %443 = mul nsw i32 %439, %442
  %444 = load ptr, ptr %13, align 8, !tbaa !16
  %445 = getelementptr inbounds nuw %struct.Mat, ptr %444, i32 0, i32 4
  %446 = load i32, ptr %445, align 4, !tbaa !23
  %447 = mul nsw i32 %443, %446
  %448 = load i32, ptr %17, align 4, !tbaa !9
  %449 = sub nsw i32 %448, 1
  %450 = load ptr, ptr %13, align 8, !tbaa !16
  %451 = getelementptr inbounds nuw %struct.Mat, ptr %450, i32 0, i32 3
  %452 = load i32, ptr %451, align 8, !tbaa !22
  %453 = mul nsw i32 %449, %452
  %454 = load ptr, ptr %13, align 8, !tbaa !16
  %455 = getelementptr inbounds nuw %struct.Mat, ptr %454, i32 0, i32 4
  %456 = load i32, ptr %455, align 4, !tbaa !23
  %457 = mul nsw i32 %453, %456
  %458 = add nsw i32 %447, %457
  %459 = load i32, ptr %18, align 4, !tbaa !9
  %460 = sub nsw i32 %459, 1
  %461 = load ptr, ptr %13, align 8, !tbaa !16
  %462 = getelementptr inbounds nuw %struct.Mat, ptr %461, i32 0, i32 4
  %463 = load i32, ptr %462, align 4, !tbaa !23
  %464 = mul nsw i32 %460, %463
  %465 = add nsw i32 %458, %464
  %466 = load i32, ptr %19, align 4, !tbaa !9
  %467 = add nsw i32 %465, %466
  %468 = sext i32 %467 to i64
  %469 = getelementptr inbounds float, ptr %435, i64 %468
  %470 = load float, ptr %469, align 4, !tbaa !14
  %471 = fadd float %432, %470
  %472 = call float @llvm.fmuladd.f32(float %316, float %471, float %280)
  %473 = load ptr, ptr %11, align 8, !tbaa !16
  %474 = getelementptr inbounds nuw %struct.Mat, ptr %473, i32 0, i32 0
  %475 = load ptr, ptr %474, align 8, !tbaa !24
  %476 = load ptr, ptr %11, align 8, !tbaa !16
  %477 = getelementptr inbounds nuw %struct.Mat, ptr %476, i32 0, i32 2
  %478 = load i32, ptr %477, align 4, !tbaa !21
  %479 = mul nsw i32 1, %478
  %480 = load ptr, ptr %11, align 8, !tbaa !16
  %481 = getelementptr inbounds nuw %struct.Mat, ptr %480, i32 0, i32 3
  %482 = load i32, ptr %481, align 8, !tbaa !22
  %483 = mul nsw i32 %479, %482
  %484 = load ptr, ptr %11, align 8, !tbaa !16
  %485 = getelementptr inbounds nuw %struct.Mat, ptr %484, i32 0, i32 4
  %486 = load i32, ptr %485, align 4, !tbaa !23
  %487 = mul nsw i32 %483, %486
  %488 = load i32, ptr %17, align 4, !tbaa !9
  %489 = load ptr, ptr %11, align 8, !tbaa !16
  %490 = getelementptr inbounds nuw %struct.Mat, ptr %489, i32 0, i32 3
  %491 = load i32, ptr %490, align 8, !tbaa !22
  %492 = mul nsw i32 %488, %491
  %493 = load ptr, ptr %11, align 8, !tbaa !16
  %494 = getelementptr inbounds nuw %struct.Mat, ptr %493, i32 0, i32 4
  %495 = load i32, ptr %494, align 4, !tbaa !23
  %496 = mul nsw i32 %492, %495
  %497 = add nsw i32 %487, %496
  %498 = load i32, ptr %18, align 4, !tbaa !9
  %499 = load ptr, ptr %11, align 8, !tbaa !16
  %500 = getelementptr inbounds nuw %struct.Mat, ptr %499, i32 0, i32 4
  %501 = load i32, ptr %500, align 4, !tbaa !23
  %502 = mul nsw i32 %498, %501
  %503 = add nsw i32 %497, %502
  %504 = load i32, ptr %19, align 4, !tbaa !9
  %505 = add nsw i32 %503, %504
  %506 = sext i32 %505 to i64
  %507 = getelementptr inbounds float, ptr %475, i64 %506
  %508 = load float, ptr %507, align 4, !tbaa !14
  %509 = load ptr, ptr %13, align 8, !tbaa !16
  %510 = getelementptr inbounds nuw %struct.Mat, ptr %509, i32 0, i32 0
  %511 = load ptr, ptr %510, align 8, !tbaa !24
  %512 = load ptr, ptr %13, align 8, !tbaa !16
  %513 = getelementptr inbounds nuw %struct.Mat, ptr %512, i32 0, i32 2
  %514 = load i32, ptr %513, align 4, !tbaa !21
  %515 = mul nsw i32 0, %514
  %516 = load ptr, ptr %13, align 8, !tbaa !16
  %517 = getelementptr inbounds nuw %struct.Mat, ptr %516, i32 0, i32 3
  %518 = load i32, ptr %517, align 8, !tbaa !22
  %519 = mul nsw i32 %515, %518
  %520 = load ptr, ptr %13, align 8, !tbaa !16
  %521 = getelementptr inbounds nuw %struct.Mat, ptr %520, i32 0, i32 4
  %522 = load i32, ptr %521, align 4, !tbaa !23
  %523 = mul nsw i32 %519, %522
  %524 = load i32, ptr %17, align 4, !tbaa !9
  %525 = load ptr, ptr %13, align 8, !tbaa !16
  %526 = getelementptr inbounds nuw %struct.Mat, ptr %525, i32 0, i32 3
  %527 = load i32, ptr %526, align 8, !tbaa !22
  %528 = mul nsw i32 %524, %527
  %529 = load ptr, ptr %13, align 8, !tbaa !16
  %530 = getelementptr inbounds nuw %struct.Mat, ptr %529, i32 0, i32 4
  %531 = load i32, ptr %530, align 4, !tbaa !23
  %532 = mul nsw i32 %528, %531
  %533 = add nsw i32 %523, %532
  %534 = load i32, ptr %18, align 4, !tbaa !9
  %535 = add nsw i32 %534, 1
  %536 = load ptr, ptr %13, align 8, !tbaa !16
  %537 = getelementptr inbounds nuw %struct.Mat, ptr %536, i32 0, i32 4
  %538 = load i32, ptr %537, align 4, !tbaa !23
  %539 = mul nsw i32 %535, %538
  %540 = add nsw i32 %533, %539
  %541 = load i32, ptr %19, align 4, !tbaa !9
  %542 = add nsw i32 %541, 1
  %543 = add nsw i32 %540, %542
  %544 = sext i32 %543 to i64
  %545 = getelementptr inbounds float, ptr %511, i64 %544
  %546 = load float, ptr %545, align 4, !tbaa !14
  %547 = load ptr, ptr %13, align 8, !tbaa !16
  %548 = getelementptr inbounds nuw %struct.Mat, ptr %547, i32 0, i32 0
  %549 = load ptr, ptr %548, align 8, !tbaa !24
  %550 = load ptr, ptr %13, align 8, !tbaa !16
  %551 = getelementptr inbounds nuw %struct.Mat, ptr %550, i32 0, i32 2
  %552 = load i32, ptr %551, align 4, !tbaa !21
  %553 = mul nsw i32 0, %552
  %554 = load ptr, ptr %13, align 8, !tbaa !16
  %555 = getelementptr inbounds nuw %struct.Mat, ptr %554, i32 0, i32 3
  %556 = load i32, ptr %555, align 8, !tbaa !22
  %557 = mul nsw i32 %553, %556
  %558 = load ptr, ptr %13, align 8, !tbaa !16
  %559 = getelementptr inbounds nuw %struct.Mat, ptr %558, i32 0, i32 4
  %560 = load i32, ptr %559, align 4, !tbaa !23
  %561 = mul nsw i32 %557, %560
  %562 = load i32, ptr %17, align 4, !tbaa !9
  %563 = load ptr, ptr %13, align 8, !tbaa !16
  %564 = getelementptr inbounds nuw %struct.Mat, ptr %563, i32 0, i32 3
  %565 = load i32, ptr %564, align 8, !tbaa !22
  %566 = mul nsw i32 %562, %565
  %567 = load ptr, ptr %13, align 8, !tbaa !16
  %568 = getelementptr inbounds nuw %struct.Mat, ptr %567, i32 0, i32 4
  %569 = load i32, ptr %568, align 4, !tbaa !23
  %570 = mul nsw i32 %566, %569
  %571 = add nsw i32 %561, %570
  %572 = load i32, ptr %18, align 4, !tbaa !9
  %573 = sub nsw i32 %572, 1
  %574 = load ptr, ptr %13, align 8, !tbaa !16
  %575 = getelementptr inbounds nuw %struct.Mat, ptr %574, i32 0, i32 4
  %576 = load i32, ptr %575, align 4, !tbaa !23
  %577 = mul nsw i32 %573, %576
  %578 = add nsw i32 %571, %577
  %579 = load i32, ptr %19, align 4, !tbaa !9
  %580 = add nsw i32 %579, 1
  %581 = add nsw i32 %578, %580
  %582 = sext i32 %581 to i64
  %583 = getelementptr inbounds float, ptr %549, i64 %582
  %584 = load float, ptr %583, align 4, !tbaa !14
  %585 = fsub float %546, %584
  %586 = load ptr, ptr %13, align 8, !tbaa !16
  %587 = getelementptr inbounds nuw %struct.Mat, ptr %586, i32 0, i32 0
  %588 = load ptr, ptr %587, align 8, !tbaa !24
  %589 = load ptr, ptr %13, align 8, !tbaa !16
  %590 = getelementptr inbounds nuw %struct.Mat, ptr %589, i32 0, i32 2
  %591 = load i32, ptr %590, align 4, !tbaa !21
  %592 = mul nsw i32 0, %591
  %593 = load ptr, ptr %13, align 8, !tbaa !16
  %594 = getelementptr inbounds nuw %struct.Mat, ptr %593, i32 0, i32 3
  %595 = load i32, ptr %594, align 8, !tbaa !22
  %596 = mul nsw i32 %592, %595
  %597 = load ptr, ptr %13, align 8, !tbaa !16
  %598 = getelementptr inbounds nuw %struct.Mat, ptr %597, i32 0, i32 4
  %599 = load i32, ptr %598, align 4, !tbaa !23
  %600 = mul nsw i32 %596, %599
  %601 = load i32, ptr %17, align 4, !tbaa !9
  %602 = load ptr, ptr %13, align 8, !tbaa !16
  %603 = getelementptr inbounds nuw %struct.Mat, ptr %602, i32 0, i32 3
  %604 = load i32, ptr %603, align 8, !tbaa !22
  %605 = mul nsw i32 %601, %604
  %606 = load ptr, ptr %13, align 8, !tbaa !16
  %607 = getelementptr inbounds nuw %struct.Mat, ptr %606, i32 0, i32 4
  %608 = load i32, ptr %607, align 4, !tbaa !23
  %609 = mul nsw i32 %605, %608
  %610 = add nsw i32 %600, %609
  %611 = load i32, ptr %18, align 4, !tbaa !9
  %612 = add nsw i32 %611, 1
  %613 = load ptr, ptr %13, align 8, !tbaa !16
  %614 = getelementptr inbounds nuw %struct.Mat, ptr %613, i32 0, i32 4
  %615 = load i32, ptr %614, align 4, !tbaa !23
  %616 = mul nsw i32 %612, %615
  %617 = add nsw i32 %610, %616
  %618 = load i32, ptr %19, align 4, !tbaa !9
  %619 = sub nsw i32 %618, 1
  %620 = add nsw i32 %617, %619
  %621 = sext i32 %620 to i64
  %622 = getelementptr inbounds float, ptr %588, i64 %621
  %623 = load float, ptr %622, align 4, !tbaa !14
  %624 = fsub float %585, %623
  %625 = load ptr, ptr %13, align 8, !tbaa !16
  %626 = getelementptr inbounds nuw %struct.Mat, ptr %625, i32 0, i32 0
  %627 = load ptr, ptr %626, align 8, !tbaa !24
  %628 = load ptr, ptr %13, align 8, !tbaa !16
  %629 = getelementptr inbounds nuw %struct.Mat, ptr %628, i32 0, i32 2
  %630 = load i32, ptr %629, align 4, !tbaa !21
  %631 = mul nsw i32 0, %630
  %632 = load ptr, ptr %13, align 8, !tbaa !16
  %633 = getelementptr inbounds nuw %struct.Mat, ptr %632, i32 0, i32 3
  %634 = load i32, ptr %633, align 8, !tbaa !22
  %635 = mul nsw i32 %631, %634
  %636 = load ptr, ptr %13, align 8, !tbaa !16
  %637 = getelementptr inbounds nuw %struct.Mat, ptr %636, i32 0, i32 4
  %638 = load i32, ptr %637, align 4, !tbaa !23
  %639 = mul nsw i32 %635, %638
  %640 = load i32, ptr %17, align 4, !tbaa !9
  %641 = load ptr, ptr %13, align 8, !tbaa !16
  %642 = getelementptr inbounds nuw %struct.Mat, ptr %641, i32 0, i32 3
  %643 = load i32, ptr %642, align 8, !tbaa !22
  %644 = mul nsw i32 %640, %643
  %645 = load ptr, ptr %13, align 8, !tbaa !16
  %646 = getelementptr inbounds nuw %struct.Mat, ptr %645, i32 0, i32 4
  %647 = load i32, ptr %646, align 4, !tbaa !23
  %648 = mul nsw i32 %644, %647
  %649 = add nsw i32 %639, %648
  %650 = load i32, ptr %18, align 4, !tbaa !9
  %651 = sub nsw i32 %650, 1
  %652 = load ptr, ptr %13, align 8, !tbaa !16
  %653 = getelementptr inbounds nuw %struct.Mat, ptr %652, i32 0, i32 4
  %654 = load i32, ptr %653, align 4, !tbaa !23
  %655 = mul nsw i32 %651, %654
  %656 = add nsw i32 %649, %655
  %657 = load i32, ptr %19, align 4, !tbaa !9
  %658 = sub nsw i32 %657, 1
  %659 = add nsw i32 %656, %658
  %660 = sext i32 %659 to i64
  %661 = getelementptr inbounds float, ptr %627, i64 %660
  %662 = load float, ptr %661, align 4, !tbaa !14
  %663 = fadd float %624, %662
  %664 = call float @llvm.fmuladd.f32(float %508, float %663, float %472)
  %665 = load ptr, ptr %11, align 8, !tbaa !16
  %666 = getelementptr inbounds nuw %struct.Mat, ptr %665, i32 0, i32 0
  %667 = load ptr, ptr %666, align 8, !tbaa !24
  %668 = load ptr, ptr %11, align 8, !tbaa !16
  %669 = getelementptr inbounds nuw %struct.Mat, ptr %668, i32 0, i32 2
  %670 = load i32, ptr %669, align 4, !tbaa !21
  %671 = mul nsw i32 2, %670
  %672 = load ptr, ptr %11, align 8, !tbaa !16
  %673 = getelementptr inbounds nuw %struct.Mat, ptr %672, i32 0, i32 3
  %674 = load i32, ptr %673, align 8, !tbaa !22
  %675 = mul nsw i32 %671, %674
  %676 = load ptr, ptr %11, align 8, !tbaa !16
  %677 = getelementptr inbounds nuw %struct.Mat, ptr %676, i32 0, i32 4
  %678 = load i32, ptr %677, align 4, !tbaa !23
  %679 = mul nsw i32 %675, %678
  %680 = load i32, ptr %17, align 4, !tbaa !9
  %681 = load ptr, ptr %11, align 8, !tbaa !16
  %682 = getelementptr inbounds nuw %struct.Mat, ptr %681, i32 0, i32 3
  %683 = load i32, ptr %682, align 8, !tbaa !22
  %684 = mul nsw i32 %680, %683
  %685 = load ptr, ptr %11, align 8, !tbaa !16
  %686 = getelementptr inbounds nuw %struct.Mat, ptr %685, i32 0, i32 4
  %687 = load i32, ptr %686, align 4, !tbaa !23
  %688 = mul nsw i32 %684, %687
  %689 = add nsw i32 %679, %688
  %690 = load i32, ptr %18, align 4, !tbaa !9
  %691 = load ptr, ptr %11, align 8, !tbaa !16
  %692 = getelementptr inbounds nuw %struct.Mat, ptr %691, i32 0, i32 4
  %693 = load i32, ptr %692, align 4, !tbaa !23
  %694 = mul nsw i32 %690, %693
  %695 = add nsw i32 %689, %694
  %696 = load i32, ptr %19, align 4, !tbaa !9
  %697 = add nsw i32 %695, %696
  %698 = sext i32 %697 to i64
  %699 = getelementptr inbounds float, ptr %667, i64 %698
  %700 = load float, ptr %699, align 4, !tbaa !14
  %701 = load ptr, ptr %13, align 8, !tbaa !16
  %702 = getelementptr inbounds nuw %struct.Mat, ptr %701, i32 0, i32 0
  %703 = load ptr, ptr %702, align 8, !tbaa !24
  %704 = load ptr, ptr %13, align 8, !tbaa !16
  %705 = getelementptr inbounds nuw %struct.Mat, ptr %704, i32 0, i32 2
  %706 = load i32, ptr %705, align 4, !tbaa !21
  %707 = mul nsw i32 0, %706
  %708 = load ptr, ptr %13, align 8, !tbaa !16
  %709 = getelementptr inbounds nuw %struct.Mat, ptr %708, i32 0, i32 3
  %710 = load i32, ptr %709, align 8, !tbaa !22
  %711 = mul nsw i32 %707, %710
  %712 = load ptr, ptr %13, align 8, !tbaa !16
  %713 = getelementptr inbounds nuw %struct.Mat, ptr %712, i32 0, i32 4
  %714 = load i32, ptr %713, align 4, !tbaa !23
  %715 = mul nsw i32 %711, %714
  %716 = load i32, ptr %17, align 4, !tbaa !9
  %717 = add nsw i32 %716, 1
  %718 = load ptr, ptr %13, align 8, !tbaa !16
  %719 = getelementptr inbounds nuw %struct.Mat, ptr %718, i32 0, i32 3
  %720 = load i32, ptr %719, align 8, !tbaa !22
  %721 = mul nsw i32 %717, %720
  %722 = load ptr, ptr %13, align 8, !tbaa !16
  %723 = getelementptr inbounds nuw %struct.Mat, ptr %722, i32 0, i32 4
  %724 = load i32, ptr %723, align 4, !tbaa !23
  %725 = mul nsw i32 %721, %724
  %726 = add nsw i32 %715, %725
  %727 = load i32, ptr %18, align 4, !tbaa !9
  %728 = load ptr, ptr %13, align 8, !tbaa !16
  %729 = getelementptr inbounds nuw %struct.Mat, ptr %728, i32 0, i32 4
  %730 = load i32, ptr %729, align 4, !tbaa !23
  %731 = mul nsw i32 %727, %730
  %732 = add nsw i32 %726, %731
  %733 = load i32, ptr %19, align 4, !tbaa !9
  %734 = add nsw i32 %733, 1
  %735 = add nsw i32 %732, %734
  %736 = sext i32 %735 to i64
  %737 = getelementptr inbounds float, ptr %703, i64 %736
  %738 = load float, ptr %737, align 4, !tbaa !14
  %739 = load ptr, ptr %13, align 8, !tbaa !16
  %740 = getelementptr inbounds nuw %struct.Mat, ptr %739, i32 0, i32 0
  %741 = load ptr, ptr %740, align 8, !tbaa !24
  %742 = load ptr, ptr %13, align 8, !tbaa !16
  %743 = getelementptr inbounds nuw %struct.Mat, ptr %742, i32 0, i32 2
  %744 = load i32, ptr %743, align 4, !tbaa !21
  %745 = mul nsw i32 0, %744
  %746 = load ptr, ptr %13, align 8, !tbaa !16
  %747 = getelementptr inbounds nuw %struct.Mat, ptr %746, i32 0, i32 3
  %748 = load i32, ptr %747, align 8, !tbaa !22
  %749 = mul nsw i32 %745, %748
  %750 = load ptr, ptr %13, align 8, !tbaa !16
  %751 = getelementptr inbounds nuw %struct.Mat, ptr %750, i32 0, i32 4
  %752 = load i32, ptr %751, align 4, !tbaa !23
  %753 = mul nsw i32 %749, %752
  %754 = load i32, ptr %17, align 4, !tbaa !9
  %755 = sub nsw i32 %754, 1
  %756 = load ptr, ptr %13, align 8, !tbaa !16
  %757 = getelementptr inbounds nuw %struct.Mat, ptr %756, i32 0, i32 3
  %758 = load i32, ptr %757, align 8, !tbaa !22
  %759 = mul nsw i32 %755, %758
  %760 = load ptr, ptr %13, align 8, !tbaa !16
  %761 = getelementptr inbounds nuw %struct.Mat, ptr %760, i32 0, i32 4
  %762 = load i32, ptr %761, align 4, !tbaa !23
  %763 = mul nsw i32 %759, %762
  %764 = add nsw i32 %753, %763
  %765 = load i32, ptr %18, align 4, !tbaa !9
  %766 = load ptr, ptr %13, align 8, !tbaa !16
  %767 = getelementptr inbounds nuw %struct.Mat, ptr %766, i32 0, i32 4
  %768 = load i32, ptr %767, align 4, !tbaa !23
  %769 = mul nsw i32 %765, %768
  %770 = add nsw i32 %764, %769
  %771 = load i32, ptr %19, align 4, !tbaa !9
  %772 = add nsw i32 %771, 1
  %773 = add nsw i32 %770, %772
  %774 = sext i32 %773 to i64
  %775 = getelementptr inbounds float, ptr %741, i64 %774
  %776 = load float, ptr %775, align 4, !tbaa !14
  %777 = fsub float %738, %776
  %778 = load ptr, ptr %13, align 8, !tbaa !16
  %779 = getelementptr inbounds nuw %struct.Mat, ptr %778, i32 0, i32 0
  %780 = load ptr, ptr %779, align 8, !tbaa !24
  %781 = load ptr, ptr %13, align 8, !tbaa !16
  %782 = getelementptr inbounds nuw %struct.Mat, ptr %781, i32 0, i32 2
  %783 = load i32, ptr %782, align 4, !tbaa !21
  %784 = mul nsw i32 0, %783
  %785 = load ptr, ptr %13, align 8, !tbaa !16
  %786 = getelementptr inbounds nuw %struct.Mat, ptr %785, i32 0, i32 3
  %787 = load i32, ptr %786, align 8, !tbaa !22
  %788 = mul nsw i32 %784, %787
  %789 = load ptr, ptr %13, align 8, !tbaa !16
  %790 = getelementptr inbounds nuw %struct.Mat, ptr %789, i32 0, i32 4
  %791 = load i32, ptr %790, align 4, !tbaa !23
  %792 = mul nsw i32 %788, %791
  %793 = load i32, ptr %17, align 4, !tbaa !9
  %794 = add nsw i32 %793, 1
  %795 = load ptr, ptr %13, align 8, !tbaa !16
  %796 = getelementptr inbounds nuw %struct.Mat, ptr %795, i32 0, i32 3
  %797 = load i32, ptr %796, align 8, !tbaa !22
  %798 = mul nsw i32 %794, %797
  %799 = load ptr, ptr %13, align 8, !tbaa !16
  %800 = getelementptr inbounds nuw %struct.Mat, ptr %799, i32 0, i32 4
  %801 = load i32, ptr %800, align 4, !tbaa !23
  %802 = mul nsw i32 %798, %801
  %803 = add nsw i32 %792, %802
  %804 = load i32, ptr %18, align 4, !tbaa !9
  %805 = load ptr, ptr %13, align 8, !tbaa !16
  %806 = getelementptr inbounds nuw %struct.Mat, ptr %805, i32 0, i32 4
  %807 = load i32, ptr %806, align 4, !tbaa !23
  %808 = mul nsw i32 %804, %807
  %809 = add nsw i32 %803, %808
  %810 = load i32, ptr %19, align 4, !tbaa !9
  %811 = sub nsw i32 %810, 1
  %812 = add nsw i32 %809, %811
  %813 = sext i32 %812 to i64
  %814 = getelementptr inbounds float, ptr %780, i64 %813
  %815 = load float, ptr %814, align 4, !tbaa !14
  %816 = fsub float %777, %815
  %817 = load ptr, ptr %13, align 8, !tbaa !16
  %818 = getelementptr inbounds nuw %struct.Mat, ptr %817, i32 0, i32 0
  %819 = load ptr, ptr %818, align 8, !tbaa !24
  %820 = load ptr, ptr %13, align 8, !tbaa !16
  %821 = getelementptr inbounds nuw %struct.Mat, ptr %820, i32 0, i32 2
  %822 = load i32, ptr %821, align 4, !tbaa !21
  %823 = mul nsw i32 0, %822
  %824 = load ptr, ptr %13, align 8, !tbaa !16
  %825 = getelementptr inbounds nuw %struct.Mat, ptr %824, i32 0, i32 3
  %826 = load i32, ptr %825, align 8, !tbaa !22
  %827 = mul nsw i32 %823, %826
  %828 = load ptr, ptr %13, align 8, !tbaa !16
  %829 = getelementptr inbounds nuw %struct.Mat, ptr %828, i32 0, i32 4
  %830 = load i32, ptr %829, align 4, !tbaa !23
  %831 = mul nsw i32 %827, %830
  %832 = load i32, ptr %17, align 4, !tbaa !9
  %833 = sub nsw i32 %832, 1
  %834 = load ptr, ptr %13, align 8, !tbaa !16
  %835 = getelementptr inbounds nuw %struct.Mat, ptr %834, i32 0, i32 3
  %836 = load i32, ptr %835, align 8, !tbaa !22
  %837 = mul nsw i32 %833, %836
  %838 = load ptr, ptr %13, align 8, !tbaa !16
  %839 = getelementptr inbounds nuw %struct.Mat, ptr %838, i32 0, i32 4
  %840 = load i32, ptr %839, align 4, !tbaa !23
  %841 = mul nsw i32 %837, %840
  %842 = add nsw i32 %831, %841
  %843 = load i32, ptr %18, align 4, !tbaa !9
  %844 = load ptr, ptr %13, align 8, !tbaa !16
  %845 = getelementptr inbounds nuw %struct.Mat, ptr %844, i32 0, i32 4
  %846 = load i32, ptr %845, align 4, !tbaa !23
  %847 = mul nsw i32 %843, %846
  %848 = add nsw i32 %842, %847
  %849 = load i32, ptr %19, align 4, !tbaa !9
  %850 = sub nsw i32 %849, 1
  %851 = add nsw i32 %848, %850
  %852 = sext i32 %851 to i64
  %853 = getelementptr inbounds float, ptr %819, i64 %852
  %854 = load float, ptr %853, align 4, !tbaa !14
  %855 = fadd float %816, %854
  %856 = call float @llvm.fmuladd.f32(float %700, float %855, float %664)
  %857 = load ptr, ptr %12, align 8, !tbaa !16
  %858 = getelementptr inbounds nuw %struct.Mat, ptr %857, i32 0, i32 0
  %859 = load ptr, ptr %858, align 8, !tbaa !24
  %860 = load ptr, ptr %12, align 8, !tbaa !16
  %861 = getelementptr inbounds nuw %struct.Mat, ptr %860, i32 0, i32 2
  %862 = load i32, ptr %861, align 4, !tbaa !21
  %863 = mul nsw i32 0, %862
  %864 = load ptr, ptr %12, align 8, !tbaa !16
  %865 = getelementptr inbounds nuw %struct.Mat, ptr %864, i32 0, i32 3
  %866 = load i32, ptr %865, align 8, !tbaa !22
  %867 = mul nsw i32 %863, %866
  %868 = load ptr, ptr %12, align 8, !tbaa !16
  %869 = getelementptr inbounds nuw %struct.Mat, ptr %868, i32 0, i32 4
  %870 = load i32, ptr %869, align 4, !tbaa !23
  %871 = mul nsw i32 %867, %870
  %872 = load i32, ptr %17, align 4, !tbaa !9
  %873 = load ptr, ptr %12, align 8, !tbaa !16
  %874 = getelementptr inbounds nuw %struct.Mat, ptr %873, i32 0, i32 3
  %875 = load i32, ptr %874, align 8, !tbaa !22
  %876 = mul nsw i32 %872, %875
  %877 = load ptr, ptr %12, align 8, !tbaa !16
  %878 = getelementptr inbounds nuw %struct.Mat, ptr %877, i32 0, i32 4
  %879 = load i32, ptr %878, align 4, !tbaa !23
  %880 = mul nsw i32 %876, %879
  %881 = add nsw i32 %871, %880
  %882 = load i32, ptr %18, align 4, !tbaa !9
  %883 = load ptr, ptr %12, align 8, !tbaa !16
  %884 = getelementptr inbounds nuw %struct.Mat, ptr %883, i32 0, i32 4
  %885 = load i32, ptr %884, align 4, !tbaa !23
  %886 = mul nsw i32 %882, %885
  %887 = add nsw i32 %881, %886
  %888 = load i32, ptr %19, align 4, !tbaa !9
  %889 = add nsw i32 %887, %888
  %890 = sext i32 %889 to i64
  %891 = getelementptr inbounds float, ptr %859, i64 %890
  %892 = load float, ptr %891, align 4, !tbaa !14
  %893 = load ptr, ptr %13, align 8, !tbaa !16
  %894 = getelementptr inbounds nuw %struct.Mat, ptr %893, i32 0, i32 0
  %895 = load ptr, ptr %894, align 8, !tbaa !24
  %896 = load ptr, ptr %13, align 8, !tbaa !16
  %897 = getelementptr inbounds nuw %struct.Mat, ptr %896, i32 0, i32 2
  %898 = load i32, ptr %897, align 4, !tbaa !21
  %899 = mul nsw i32 0, %898
  %900 = load ptr, ptr %13, align 8, !tbaa !16
  %901 = getelementptr inbounds nuw %struct.Mat, ptr %900, i32 0, i32 3
  %902 = load i32, ptr %901, align 8, !tbaa !22
  %903 = mul nsw i32 %899, %902
  %904 = load ptr, ptr %13, align 8, !tbaa !16
  %905 = getelementptr inbounds nuw %struct.Mat, ptr %904, i32 0, i32 4
  %906 = load i32, ptr %905, align 4, !tbaa !23
  %907 = mul nsw i32 %903, %906
  %908 = load i32, ptr %17, align 4, !tbaa !9
  %909 = sub nsw i32 %908, 1
  %910 = load ptr, ptr %13, align 8, !tbaa !16
  %911 = getelementptr inbounds nuw %struct.Mat, ptr %910, i32 0, i32 3
  %912 = load i32, ptr %911, align 8, !tbaa !22
  %913 = mul nsw i32 %909, %912
  %914 = load ptr, ptr %13, align 8, !tbaa !16
  %915 = getelementptr inbounds nuw %struct.Mat, ptr %914, i32 0, i32 4
  %916 = load i32, ptr %915, align 4, !tbaa !23
  %917 = mul nsw i32 %913, %916
  %918 = add nsw i32 %907, %917
  %919 = load i32, ptr %18, align 4, !tbaa !9
  %920 = load ptr, ptr %13, align 8, !tbaa !16
  %921 = getelementptr inbounds nuw %struct.Mat, ptr %920, i32 0, i32 4
  %922 = load i32, ptr %921, align 4, !tbaa !23
  %923 = mul nsw i32 %919, %922
  %924 = add nsw i32 %918, %923
  %925 = load i32, ptr %19, align 4, !tbaa !9
  %926 = add nsw i32 %924, %925
  %927 = sext i32 %926 to i64
  %928 = getelementptr inbounds float, ptr %895, i64 %927
  %929 = load float, ptr %928, align 4, !tbaa !14
  %930 = call float @llvm.fmuladd.f32(float %892, float %929, float %856)
  %931 = load ptr, ptr %12, align 8, !tbaa !16
  %932 = getelementptr inbounds nuw %struct.Mat, ptr %931, i32 0, i32 0
  %933 = load ptr, ptr %932, align 8, !tbaa !24
  %934 = load ptr, ptr %12, align 8, !tbaa !16
  %935 = getelementptr inbounds nuw %struct.Mat, ptr %934, i32 0, i32 2
  %936 = load i32, ptr %935, align 4, !tbaa !21
  %937 = mul nsw i32 1, %936
  %938 = load ptr, ptr %12, align 8, !tbaa !16
  %939 = getelementptr inbounds nuw %struct.Mat, ptr %938, i32 0, i32 3
  %940 = load i32, ptr %939, align 8, !tbaa !22
  %941 = mul nsw i32 %937, %940
  %942 = load ptr, ptr %12, align 8, !tbaa !16
  %943 = getelementptr inbounds nuw %struct.Mat, ptr %942, i32 0, i32 4
  %944 = load i32, ptr %943, align 4, !tbaa !23
  %945 = mul nsw i32 %941, %944
  %946 = load i32, ptr %17, align 4, !tbaa !9
  %947 = load ptr, ptr %12, align 8, !tbaa !16
  %948 = getelementptr inbounds nuw %struct.Mat, ptr %947, i32 0, i32 3
  %949 = load i32, ptr %948, align 8, !tbaa !22
  %950 = mul nsw i32 %946, %949
  %951 = load ptr, ptr %12, align 8, !tbaa !16
  %952 = getelementptr inbounds nuw %struct.Mat, ptr %951, i32 0, i32 4
  %953 = load i32, ptr %952, align 4, !tbaa !23
  %954 = mul nsw i32 %950, %953
  %955 = add nsw i32 %945, %954
  %956 = load i32, ptr %18, align 4, !tbaa !9
  %957 = load ptr, ptr %12, align 8, !tbaa !16
  %958 = getelementptr inbounds nuw %struct.Mat, ptr %957, i32 0, i32 4
  %959 = load i32, ptr %958, align 4, !tbaa !23
  %960 = mul nsw i32 %956, %959
  %961 = add nsw i32 %955, %960
  %962 = load i32, ptr %19, align 4, !tbaa !9
  %963 = add nsw i32 %961, %962
  %964 = sext i32 %963 to i64
  %965 = getelementptr inbounds float, ptr %933, i64 %964
  %966 = load float, ptr %965, align 4, !tbaa !14
  %967 = load ptr, ptr %13, align 8, !tbaa !16
  %968 = getelementptr inbounds nuw %struct.Mat, ptr %967, i32 0, i32 0
  %969 = load ptr, ptr %968, align 8, !tbaa !24
  %970 = load ptr, ptr %13, align 8, !tbaa !16
  %971 = getelementptr inbounds nuw %struct.Mat, ptr %970, i32 0, i32 2
  %972 = load i32, ptr %971, align 4, !tbaa !21
  %973 = mul nsw i32 0, %972
  %974 = load ptr, ptr %13, align 8, !tbaa !16
  %975 = getelementptr inbounds nuw %struct.Mat, ptr %974, i32 0, i32 3
  %976 = load i32, ptr %975, align 8, !tbaa !22
  %977 = mul nsw i32 %973, %976
  %978 = load ptr, ptr %13, align 8, !tbaa !16
  %979 = getelementptr inbounds nuw %struct.Mat, ptr %978, i32 0, i32 4
  %980 = load i32, ptr %979, align 4, !tbaa !23
  %981 = mul nsw i32 %977, %980
  %982 = load i32, ptr %17, align 4, !tbaa !9
  %983 = load ptr, ptr %13, align 8, !tbaa !16
  %984 = getelementptr inbounds nuw %struct.Mat, ptr %983, i32 0, i32 3
  %985 = load i32, ptr %984, align 8, !tbaa !22
  %986 = mul nsw i32 %982, %985
  %987 = load ptr, ptr %13, align 8, !tbaa !16
  %988 = getelementptr inbounds nuw %struct.Mat, ptr %987, i32 0, i32 4
  %989 = load i32, ptr %988, align 4, !tbaa !23
  %990 = mul nsw i32 %986, %989
  %991 = add nsw i32 %981, %990
  %992 = load i32, ptr %18, align 4, !tbaa !9
  %993 = sub nsw i32 %992, 1
  %994 = load ptr, ptr %13, align 8, !tbaa !16
  %995 = getelementptr inbounds nuw %struct.Mat, ptr %994, i32 0, i32 4
  %996 = load i32, ptr %995, align 4, !tbaa !23
  %997 = mul nsw i32 %993, %996
  %998 = add nsw i32 %991, %997
  %999 = load i32, ptr %19, align 4, !tbaa !9
  %1000 = add nsw i32 %998, %999
  %1001 = sext i32 %1000 to i64
  %1002 = getelementptr inbounds float, ptr %969, i64 %1001
  %1003 = load float, ptr %1002, align 4, !tbaa !14
  %1004 = call float @llvm.fmuladd.f32(float %966, float %1003, float %930)
  %1005 = load ptr, ptr %12, align 8, !tbaa !16
  %1006 = getelementptr inbounds nuw %struct.Mat, ptr %1005, i32 0, i32 0
  %1007 = load ptr, ptr %1006, align 8, !tbaa !24
  %1008 = load ptr, ptr %12, align 8, !tbaa !16
  %1009 = getelementptr inbounds nuw %struct.Mat, ptr %1008, i32 0, i32 2
  %1010 = load i32, ptr %1009, align 4, !tbaa !21
  %1011 = mul nsw i32 2, %1010
  %1012 = load ptr, ptr %12, align 8, !tbaa !16
  %1013 = getelementptr inbounds nuw %struct.Mat, ptr %1012, i32 0, i32 3
  %1014 = load i32, ptr %1013, align 8, !tbaa !22
  %1015 = mul nsw i32 %1011, %1014
  %1016 = load ptr, ptr %12, align 8, !tbaa !16
  %1017 = getelementptr inbounds nuw %struct.Mat, ptr %1016, i32 0, i32 4
  %1018 = load i32, ptr %1017, align 4, !tbaa !23
  %1019 = mul nsw i32 %1015, %1018
  %1020 = load i32, ptr %17, align 4, !tbaa !9
  %1021 = load ptr, ptr %12, align 8, !tbaa !16
  %1022 = getelementptr inbounds nuw %struct.Mat, ptr %1021, i32 0, i32 3
  %1023 = load i32, ptr %1022, align 8, !tbaa !22
  %1024 = mul nsw i32 %1020, %1023
  %1025 = load ptr, ptr %12, align 8, !tbaa !16
  %1026 = getelementptr inbounds nuw %struct.Mat, ptr %1025, i32 0, i32 4
  %1027 = load i32, ptr %1026, align 4, !tbaa !23
  %1028 = mul nsw i32 %1024, %1027
  %1029 = add nsw i32 %1019, %1028
  %1030 = load i32, ptr %18, align 4, !tbaa !9
  %1031 = load ptr, ptr %12, align 8, !tbaa !16
  %1032 = getelementptr inbounds nuw %struct.Mat, ptr %1031, i32 0, i32 4
  %1033 = load i32, ptr %1032, align 4, !tbaa !23
  %1034 = mul nsw i32 %1030, %1033
  %1035 = add nsw i32 %1029, %1034
  %1036 = load i32, ptr %19, align 4, !tbaa !9
  %1037 = add nsw i32 %1035, %1036
  %1038 = sext i32 %1037 to i64
  %1039 = getelementptr inbounds float, ptr %1007, i64 %1038
  %1040 = load float, ptr %1039, align 4, !tbaa !14
  %1041 = load ptr, ptr %13, align 8, !tbaa !16
  %1042 = getelementptr inbounds nuw %struct.Mat, ptr %1041, i32 0, i32 0
  %1043 = load ptr, ptr %1042, align 8, !tbaa !24
  %1044 = load ptr, ptr %13, align 8, !tbaa !16
  %1045 = getelementptr inbounds nuw %struct.Mat, ptr %1044, i32 0, i32 2
  %1046 = load i32, ptr %1045, align 4, !tbaa !21
  %1047 = mul nsw i32 0, %1046
  %1048 = load ptr, ptr %13, align 8, !tbaa !16
  %1049 = getelementptr inbounds nuw %struct.Mat, ptr %1048, i32 0, i32 3
  %1050 = load i32, ptr %1049, align 8, !tbaa !22
  %1051 = mul nsw i32 %1047, %1050
  %1052 = load ptr, ptr %13, align 8, !tbaa !16
  %1053 = getelementptr inbounds nuw %struct.Mat, ptr %1052, i32 0, i32 4
  %1054 = load i32, ptr %1053, align 4, !tbaa !23
  %1055 = mul nsw i32 %1051, %1054
  %1056 = load i32, ptr %17, align 4, !tbaa !9
  %1057 = load ptr, ptr %13, align 8, !tbaa !16
  %1058 = getelementptr inbounds nuw %struct.Mat, ptr %1057, i32 0, i32 3
  %1059 = load i32, ptr %1058, align 8, !tbaa !22
  %1060 = mul nsw i32 %1056, %1059
  %1061 = load ptr, ptr %13, align 8, !tbaa !16
  %1062 = getelementptr inbounds nuw %struct.Mat, ptr %1061, i32 0, i32 4
  %1063 = load i32, ptr %1062, align 4, !tbaa !23
  %1064 = mul nsw i32 %1060, %1063
  %1065 = add nsw i32 %1055, %1064
  %1066 = load i32, ptr %18, align 4, !tbaa !9
  %1067 = load ptr, ptr %13, align 8, !tbaa !16
  %1068 = getelementptr inbounds nuw %struct.Mat, ptr %1067, i32 0, i32 4
  %1069 = load i32, ptr %1068, align 4, !tbaa !23
  %1070 = mul nsw i32 %1066, %1069
  %1071 = add nsw i32 %1065, %1070
  %1072 = load i32, ptr %19, align 4, !tbaa !9
  %1073 = sub nsw i32 %1072, 1
  %1074 = add nsw i32 %1071, %1073
  %1075 = sext i32 %1074 to i64
  %1076 = getelementptr inbounds float, ptr %1043, i64 %1075
  %1077 = load float, ptr %1076, align 4, !tbaa !14
  %1078 = call float @llvm.fmuladd.f32(float %1040, float %1077, float %1004)
  %1079 = load ptr, ptr %15, align 8, !tbaa !16
  %1080 = getelementptr inbounds nuw %struct.Mat, ptr %1079, i32 0, i32 0
  %1081 = load ptr, ptr %1080, align 8, !tbaa !24
  %1082 = load ptr, ptr %15, align 8, !tbaa !16
  %1083 = getelementptr inbounds nuw %struct.Mat, ptr %1082, i32 0, i32 2
  %1084 = load i32, ptr %1083, align 4, !tbaa !21
  %1085 = mul nsw i32 0, %1084
  %1086 = load ptr, ptr %15, align 8, !tbaa !16
  %1087 = getelementptr inbounds nuw %struct.Mat, ptr %1086, i32 0, i32 3
  %1088 = load i32, ptr %1087, align 8, !tbaa !22
  %1089 = mul nsw i32 %1085, %1088
  %1090 = load ptr, ptr %15, align 8, !tbaa !16
  %1091 = getelementptr inbounds nuw %struct.Mat, ptr %1090, i32 0, i32 4
  %1092 = load i32, ptr %1091, align 4, !tbaa !23
  %1093 = mul nsw i32 %1089, %1092
  %1094 = load i32, ptr %17, align 4, !tbaa !9
  %1095 = load ptr, ptr %15, align 8, !tbaa !16
  %1096 = getelementptr inbounds nuw %struct.Mat, ptr %1095, i32 0, i32 3
  %1097 = load i32, ptr %1096, align 8, !tbaa !22
  %1098 = mul nsw i32 %1094, %1097
  %1099 = load ptr, ptr %15, align 8, !tbaa !16
  %1100 = getelementptr inbounds nuw %struct.Mat, ptr %1099, i32 0, i32 4
  %1101 = load i32, ptr %1100, align 4, !tbaa !23
  %1102 = mul nsw i32 %1098, %1101
  %1103 = add nsw i32 %1093, %1102
  %1104 = load i32, ptr %18, align 4, !tbaa !9
  %1105 = load ptr, ptr %15, align 8, !tbaa !16
  %1106 = getelementptr inbounds nuw %struct.Mat, ptr %1105, i32 0, i32 4
  %1107 = load i32, ptr %1106, align 4, !tbaa !23
  %1108 = mul nsw i32 %1104, %1107
  %1109 = add nsw i32 %1103, %1108
  %1110 = load i32, ptr %19, align 4, !tbaa !9
  %1111 = add nsw i32 %1109, %1110
  %1112 = sext i32 %1111 to i64
  %1113 = getelementptr inbounds float, ptr %1081, i64 %1112
  %1114 = load float, ptr %1113, align 4, !tbaa !14
  %1115 = fadd float %1078, %1114
  store float %1115, ptr %25, align 4, !tbaa !14
  %1116 = load float, ptr %25, align 4, !tbaa !14
  %1117 = load ptr, ptr %10, align 8, !tbaa !16
  %1118 = getelementptr inbounds nuw %struct.Mat, ptr %1117, i32 0, i32 0
  %1119 = load ptr, ptr %1118, align 8, !tbaa !24
  %1120 = load ptr, ptr %10, align 8, !tbaa !16
  %1121 = getelementptr inbounds nuw %struct.Mat, ptr %1120, i32 0, i32 2
  %1122 = load i32, ptr %1121, align 4, !tbaa !21
  %1123 = mul nsw i32 3, %1122
  %1124 = load ptr, ptr %10, align 8, !tbaa !16
  %1125 = getelementptr inbounds nuw %struct.Mat, ptr %1124, i32 0, i32 3
  %1126 = load i32, ptr %1125, align 8, !tbaa !22
  %1127 = mul nsw i32 %1123, %1126
  %1128 = load ptr, ptr %10, align 8, !tbaa !16
  %1129 = getelementptr inbounds nuw %struct.Mat, ptr %1128, i32 0, i32 4
  %1130 = load i32, ptr %1129, align 4, !tbaa !23
  %1131 = mul nsw i32 %1127, %1130
  %1132 = load i32, ptr %17, align 4, !tbaa !9
  %1133 = load ptr, ptr %10, align 8, !tbaa !16
  %1134 = getelementptr inbounds nuw %struct.Mat, ptr %1133, i32 0, i32 3
  %1135 = load i32, ptr %1134, align 8, !tbaa !22
  %1136 = mul nsw i32 %1132, %1135
  %1137 = load ptr, ptr %10, align 8, !tbaa !16
  %1138 = getelementptr inbounds nuw %struct.Mat, ptr %1137, i32 0, i32 4
  %1139 = load i32, ptr %1138, align 4, !tbaa !23
  %1140 = mul nsw i32 %1136, %1139
  %1141 = add nsw i32 %1131, %1140
  %1142 = load i32, ptr %18, align 4, !tbaa !9
  %1143 = load ptr, ptr %10, align 8, !tbaa !16
  %1144 = getelementptr inbounds nuw %struct.Mat, ptr %1143, i32 0, i32 4
  %1145 = load i32, ptr %1144, align 4, !tbaa !23
  %1146 = mul nsw i32 %1142, %1145
  %1147 = add nsw i32 %1141, %1146
  %1148 = load i32, ptr %19, align 4, !tbaa !9
  %1149 = add nsw i32 %1147, %1148
  %1150 = sext i32 %1149 to i64
  %1151 = getelementptr inbounds float, ptr %1119, i64 %1150
  %1152 = load float, ptr %1151, align 4, !tbaa !14
  %1153 = load ptr, ptr %13, align 8, !tbaa !16
  %1154 = getelementptr inbounds nuw %struct.Mat, ptr %1153, i32 0, i32 0
  %1155 = load ptr, ptr %1154, align 8, !tbaa !24
  %1156 = load ptr, ptr %13, align 8, !tbaa !16
  %1157 = getelementptr inbounds nuw %struct.Mat, ptr %1156, i32 0, i32 2
  %1158 = load i32, ptr %1157, align 4, !tbaa !21
  %1159 = mul nsw i32 0, %1158
  %1160 = load ptr, ptr %13, align 8, !tbaa !16
  %1161 = getelementptr inbounds nuw %struct.Mat, ptr %1160, i32 0, i32 3
  %1162 = load i32, ptr %1161, align 8, !tbaa !22
  %1163 = mul nsw i32 %1159, %1162
  %1164 = load ptr, ptr %13, align 8, !tbaa !16
  %1165 = getelementptr inbounds nuw %struct.Mat, ptr %1164, i32 0, i32 4
  %1166 = load i32, ptr %1165, align 4, !tbaa !23
  %1167 = mul nsw i32 %1163, %1166
  %1168 = load i32, ptr %17, align 4, !tbaa !9
  %1169 = load ptr, ptr %13, align 8, !tbaa !16
  %1170 = getelementptr inbounds nuw %struct.Mat, ptr %1169, i32 0, i32 3
  %1171 = load i32, ptr %1170, align 8, !tbaa !22
  %1172 = mul nsw i32 %1168, %1171
  %1173 = load ptr, ptr %13, align 8, !tbaa !16
  %1174 = getelementptr inbounds nuw %struct.Mat, ptr %1173, i32 0, i32 4
  %1175 = load i32, ptr %1174, align 4, !tbaa !23
  %1176 = mul nsw i32 %1172, %1175
  %1177 = add nsw i32 %1167, %1176
  %1178 = load i32, ptr %18, align 4, !tbaa !9
  %1179 = load ptr, ptr %13, align 8, !tbaa !16
  %1180 = getelementptr inbounds nuw %struct.Mat, ptr %1179, i32 0, i32 4
  %1181 = load i32, ptr %1180, align 4, !tbaa !23
  %1182 = mul nsw i32 %1178, %1181
  %1183 = add nsw i32 %1177, %1182
  %1184 = load i32, ptr %19, align 4, !tbaa !9
  %1185 = add nsw i32 %1183, %1184
  %1186 = sext i32 %1185 to i64
  %1187 = getelementptr inbounds float, ptr %1155, i64 %1186
  %1188 = load float, ptr %1187, align 4, !tbaa !14
  %1189 = fneg float %1188
  %1190 = call float @llvm.fmuladd.f32(float %1116, float %1152, float %1189)
  %1191 = load ptr, ptr %14, align 8, !tbaa !16
  %1192 = getelementptr inbounds nuw %struct.Mat, ptr %1191, i32 0, i32 0
  %1193 = load ptr, ptr %1192, align 8, !tbaa !24
  %1194 = load ptr, ptr %14, align 8, !tbaa !16
  %1195 = getelementptr inbounds nuw %struct.Mat, ptr %1194, i32 0, i32 2
  %1196 = load i32, ptr %1195, align 4, !tbaa !21
  %1197 = mul nsw i32 0, %1196
  %1198 = load ptr, ptr %14, align 8, !tbaa !16
  %1199 = getelementptr inbounds nuw %struct.Mat, ptr %1198, i32 0, i32 3
  %1200 = load i32, ptr %1199, align 8, !tbaa !22
  %1201 = mul nsw i32 %1197, %1200
  %1202 = load ptr, ptr %14, align 8, !tbaa !16
  %1203 = getelementptr inbounds nuw %struct.Mat, ptr %1202, i32 0, i32 4
  %1204 = load i32, ptr %1203, align 4, !tbaa !23
  %1205 = mul nsw i32 %1201, %1204
  %1206 = load i32, ptr %17, align 4, !tbaa !9
  %1207 = load ptr, ptr %14, align 8, !tbaa !16
  %1208 = getelementptr inbounds nuw %struct.Mat, ptr %1207, i32 0, i32 3
  %1209 = load i32, ptr %1208, align 8, !tbaa !22
  %1210 = mul nsw i32 %1206, %1209
  %1211 = load ptr, ptr %14, align 8, !tbaa !16
  %1212 = getelementptr inbounds nuw %struct.Mat, ptr %1211, i32 0, i32 4
  %1213 = load i32, ptr %1212, align 4, !tbaa !23
  %1214 = mul nsw i32 %1210, %1213
  %1215 = add nsw i32 %1205, %1214
  %1216 = load i32, ptr %18, align 4, !tbaa !9
  %1217 = load ptr, ptr %14, align 8, !tbaa !16
  %1218 = getelementptr inbounds nuw %struct.Mat, ptr %1217, i32 0, i32 4
  %1219 = load i32, ptr %1218, align 4, !tbaa !23
  %1220 = mul nsw i32 %1216, %1219
  %1221 = add nsw i32 %1215, %1220
  %1222 = load i32, ptr %19, align 4, !tbaa !9
  %1223 = add nsw i32 %1221, %1222
  %1224 = sext i32 %1223 to i64
  %1225 = getelementptr inbounds float, ptr %1193, i64 %1224
  %1226 = load float, ptr %1225, align 4, !tbaa !14
  %1227 = fmul float %1190, %1226
  store float %1227, ptr %26, align 4, !tbaa !14
  %1228 = load float, ptr %26, align 4, !tbaa !14
  %1229 = load float, ptr %26, align 4, !tbaa !14
  %1230 = load float, ptr %24, align 4, !tbaa !14
  %1231 = call float @llvm.fmuladd.f32(float %1228, float %1229, float %1230)
  store float %1231, ptr %24, align 4, !tbaa !14
  %1232 = load ptr, ptr %13, align 8, !tbaa !16
  %1233 = getelementptr inbounds nuw %struct.Mat, ptr %1232, i32 0, i32 0
  %1234 = load ptr, ptr %1233, align 8, !tbaa !24
  %1235 = load ptr, ptr %13, align 8, !tbaa !16
  %1236 = getelementptr inbounds nuw %struct.Mat, ptr %1235, i32 0, i32 2
  %1237 = load i32, ptr %1236, align 4, !tbaa !21
  %1238 = mul nsw i32 0, %1237
  %1239 = load ptr, ptr %13, align 8, !tbaa !16
  %1240 = getelementptr inbounds nuw %struct.Mat, ptr %1239, i32 0, i32 3
  %1241 = load i32, ptr %1240, align 8, !tbaa !22
  %1242 = mul nsw i32 %1238, %1241
  %1243 = load ptr, ptr %13, align 8, !tbaa !16
  %1244 = getelementptr inbounds nuw %struct.Mat, ptr %1243, i32 0, i32 4
  %1245 = load i32, ptr %1244, align 4, !tbaa !23
  %1246 = mul nsw i32 %1242, %1245
  %1247 = load i32, ptr %17, align 4, !tbaa !9
  %1248 = load ptr, ptr %13, align 8, !tbaa !16
  %1249 = getelementptr inbounds nuw %struct.Mat, ptr %1248, i32 0, i32 3
  %1250 = load i32, ptr %1249, align 8, !tbaa !22
  %1251 = mul nsw i32 %1247, %1250
  %1252 = load ptr, ptr %13, align 8, !tbaa !16
  %1253 = getelementptr inbounds nuw %struct.Mat, ptr %1252, i32 0, i32 4
  %1254 = load i32, ptr %1253, align 4, !tbaa !23
  %1255 = mul nsw i32 %1251, %1254
  %1256 = add nsw i32 %1246, %1255
  %1257 = load i32, ptr %18, align 4, !tbaa !9
  %1258 = load ptr, ptr %13, align 8, !tbaa !16
  %1259 = getelementptr inbounds nuw %struct.Mat, ptr %1258, i32 0, i32 4
  %1260 = load i32, ptr %1259, align 4, !tbaa !23
  %1261 = mul nsw i32 %1257, %1260
  %1262 = add nsw i32 %1256, %1261
  %1263 = load i32, ptr %19, align 4, !tbaa !9
  %1264 = add nsw i32 %1262, %1263
  %1265 = sext i32 %1264 to i64
  %1266 = getelementptr inbounds float, ptr %1234, i64 %1265
  %1267 = load float, ptr %1266, align 4, !tbaa !14
  %1268 = load float, ptr @omega, align 4, !tbaa !14
  %1269 = load float, ptr %26, align 4, !tbaa !14
  %1270 = call float @llvm.fmuladd.f32(float %1268, float %1269, float %1267)
  %1271 = load ptr, ptr %16, align 8, !tbaa !16
  %1272 = getelementptr inbounds nuw %struct.Mat, ptr %1271, i32 0, i32 0
  %1273 = load ptr, ptr %1272, align 8, !tbaa !24
  %1274 = load ptr, ptr %16, align 8, !tbaa !16
  %1275 = getelementptr inbounds nuw %struct.Mat, ptr %1274, i32 0, i32 2
  %1276 = load i32, ptr %1275, align 4, !tbaa !21
  %1277 = mul nsw i32 0, %1276
  %1278 = load ptr, ptr %16, align 8, !tbaa !16
  %1279 = getelementptr inbounds nuw %struct.Mat, ptr %1278, i32 0, i32 3
  %1280 = load i32, ptr %1279, align 8, !tbaa !22
  %1281 = mul nsw i32 %1277, %1280
  %1282 = load ptr, ptr %16, align 8, !tbaa !16
  %1283 = getelementptr inbounds nuw %struct.Mat, ptr %1282, i32 0, i32 4
  %1284 = load i32, ptr %1283, align 4, !tbaa !23
  %1285 = mul nsw i32 %1281, %1284
  %1286 = load i32, ptr %17, align 4, !tbaa !9
  %1287 = load ptr, ptr %16, align 8, !tbaa !16
  %1288 = getelementptr inbounds nuw %struct.Mat, ptr %1287, i32 0, i32 3
  %1289 = load i32, ptr %1288, align 8, !tbaa !22
  %1290 = mul nsw i32 %1286, %1289
  %1291 = load ptr, ptr %16, align 8, !tbaa !16
  %1292 = getelementptr inbounds nuw %struct.Mat, ptr %1291, i32 0, i32 4
  %1293 = load i32, ptr %1292, align 4, !tbaa !23
  %1294 = mul nsw i32 %1290, %1293
  %1295 = add nsw i32 %1285, %1294
  %1296 = load i32, ptr %18, align 4, !tbaa !9
  %1297 = load ptr, ptr %16, align 8, !tbaa !16
  %1298 = getelementptr inbounds nuw %struct.Mat, ptr %1297, i32 0, i32 4
  %1299 = load i32, ptr %1298, align 4, !tbaa !23
  %1300 = mul nsw i32 %1296, %1299
  %1301 = add nsw i32 %1295, %1300
  %1302 = load i32, ptr %19, align 4, !tbaa !9
  %1303 = add nsw i32 %1301, %1302
  %1304 = sext i32 %1303 to i64
  %1305 = getelementptr inbounds float, ptr %1273, i64 %1304
  store float %1270, ptr %1305, align 4, !tbaa !14
  br label %1306

1306:                                             ; preds = %58
  %1307 = load i32, ptr %19, align 4, !tbaa !9
  %1308 = add nsw i32 %1307, 1
  store i32 %1308, ptr %19, align 4, !tbaa !9
  br label %54, !llvm.loop !32

1309:                                             ; preds = %54
  br label %1310

1310:                                             ; preds = %1309
  %1311 = load i32, ptr %18, align 4, !tbaa !9
  %1312 = add nsw i32 %1311, 1
  store i32 %1312, ptr %18, align 4, !tbaa !9
  br label %49, !llvm.loop !33

1313:                                             ; preds = %49
  br label %1314

1314:                                             ; preds = %1313
  %1315 = load i32, ptr %17, align 4, !tbaa !9
  %1316 = add nsw i32 %1315, 1
  store i32 %1316, ptr %17, align 4, !tbaa !9
  br label %44, !llvm.loop !34

1317:                                             ; preds = %44
  store i32 1, ptr %17, align 4, !tbaa !9
  br label %1318

1318:                                             ; preds = %1412, %1317
  %1319 = load i32, ptr %17, align 4, !tbaa !9
  %1320 = load i32, ptr %21, align 4, !tbaa !9
  %1321 = icmp slt i32 %1319, %1320
  br i1 %1321, label %1322, label %1415

1322:                                             ; preds = %1318
  store i32 1, ptr %18, align 4, !tbaa !9
  br label %1323

1323:                                             ; preds = %1408, %1322
  %1324 = load i32, ptr %18, align 4, !tbaa !9
  %1325 = load i32, ptr %22, align 4, !tbaa !9
  %1326 = icmp slt i32 %1324, %1325
  br i1 %1326, label %1327, label %1411

1327:                                             ; preds = %1323
  store i32 1, ptr %19, align 4, !tbaa !9
  br label %1328

1328:                                             ; preds = %1404, %1327
  %1329 = load i32, ptr %19, align 4, !tbaa !9
  %1330 = load i32, ptr %23, align 4, !tbaa !9
  %1331 = icmp slt i32 %1329, %1330
  br i1 %1331, label %1332, label %1407

1332:                                             ; preds = %1328
  %1333 = load ptr, ptr %16, align 8, !tbaa !16
  %1334 = getelementptr inbounds nuw %struct.Mat, ptr %1333, i32 0, i32 0
  %1335 = load ptr, ptr %1334, align 8, !tbaa !24
  %1336 = load ptr, ptr %16, align 8, !tbaa !16
  %1337 = getelementptr inbounds nuw %struct.Mat, ptr %1336, i32 0, i32 2
  %1338 = load i32, ptr %1337, align 4, !tbaa !21
  %1339 = mul nsw i32 0, %1338
  %1340 = load ptr, ptr %16, align 8, !tbaa !16
  %1341 = getelementptr inbounds nuw %struct.Mat, ptr %1340, i32 0, i32 3
  %1342 = load i32, ptr %1341, align 8, !tbaa !22
  %1343 = mul nsw i32 %1339, %1342
  %1344 = load ptr, ptr %16, align 8, !tbaa !16
  %1345 = getelementptr inbounds nuw %struct.Mat, ptr %1344, i32 0, i32 4
  %1346 = load i32, ptr %1345, align 4, !tbaa !23
  %1347 = mul nsw i32 %1343, %1346
  %1348 = load i32, ptr %17, align 4, !tbaa !9
  %1349 = load ptr, ptr %16, align 8, !tbaa !16
  %1350 = getelementptr inbounds nuw %struct.Mat, ptr %1349, i32 0, i32 3
  %1351 = load i32, ptr %1350, align 8, !tbaa !22
  %1352 = mul nsw i32 %1348, %1351
  %1353 = load ptr, ptr %16, align 8, !tbaa !16
  %1354 = getelementptr inbounds nuw %struct.Mat, ptr %1353, i32 0, i32 4
  %1355 = load i32, ptr %1354, align 4, !tbaa !23
  %1356 = mul nsw i32 %1352, %1355
  %1357 = add nsw i32 %1347, %1356
  %1358 = load i32, ptr %18, align 4, !tbaa !9
  %1359 = load ptr, ptr %16, align 8, !tbaa !16
  %1360 = getelementptr inbounds nuw %struct.Mat, ptr %1359, i32 0, i32 4
  %1361 = load i32, ptr %1360, align 4, !tbaa !23
  %1362 = mul nsw i32 %1358, %1361
  %1363 = add nsw i32 %1357, %1362
  %1364 = load i32, ptr %19, align 4, !tbaa !9
  %1365 = add nsw i32 %1363, %1364
  %1366 = sext i32 %1365 to i64
  %1367 = getelementptr inbounds float, ptr %1335, i64 %1366
  %1368 = load float, ptr %1367, align 4, !tbaa !14
  %1369 = load ptr, ptr %13, align 8, !tbaa !16
  %1370 = getelementptr inbounds nuw %struct.Mat, ptr %1369, i32 0, i32 0
  %1371 = load ptr, ptr %1370, align 8, !tbaa !24
  %1372 = load ptr, ptr %13, align 8, !tbaa !16
  %1373 = getelementptr inbounds nuw %struct.Mat, ptr %1372, i32 0, i32 2
  %1374 = load i32, ptr %1373, align 4, !tbaa !21
  %1375 = mul nsw i32 0, %1374
  %1376 = load ptr, ptr %13, align 8, !tbaa !16
  %1377 = getelementptr inbounds nuw %struct.Mat, ptr %1376, i32 0, i32 3
  %1378 = load i32, ptr %1377, align 8, !tbaa !22
  %1379 = mul nsw i32 %1375, %1378
  %1380 = load ptr, ptr %13, align 8, !tbaa !16
  %1381 = getelementptr inbounds nuw %struct.Mat, ptr %1380, i32 0, i32 4
  %1382 = load i32, ptr %1381, align 4, !tbaa !23
  %1383 = mul nsw i32 %1379, %1382
  %1384 = load i32, ptr %17, align 4, !tbaa !9
  %1385 = load ptr, ptr %13, align 8, !tbaa !16
  %1386 = getelementptr inbounds nuw %struct.Mat, ptr %1385, i32 0, i32 3
  %1387 = load i32, ptr %1386, align 8, !tbaa !22
  %1388 = mul nsw i32 %1384, %1387
  %1389 = load ptr, ptr %13, align 8, !tbaa !16
  %1390 = getelementptr inbounds nuw %struct.Mat, ptr %1389, i32 0, i32 4
  %1391 = load i32, ptr %1390, align 4, !tbaa !23
  %1392 = mul nsw i32 %1388, %1391
  %1393 = add nsw i32 %1383, %1392
  %1394 = load i32, ptr %18, align 4, !tbaa !9
  %1395 = load ptr, ptr %13, align 8, !tbaa !16
  %1396 = getelementptr inbounds nuw %struct.Mat, ptr %1395, i32 0, i32 4
  %1397 = load i32, ptr %1396, align 4, !tbaa !23
  %1398 = mul nsw i32 %1394, %1397
  %1399 = add nsw i32 %1393, %1398
  %1400 = load i32, ptr %19, align 4, !tbaa !9
  %1401 = add nsw i32 %1399, %1400
  %1402 = sext i32 %1401 to i64
  %1403 = getelementptr inbounds float, ptr %1371, i64 %1402
  store float %1368, ptr %1403, align 4, !tbaa !14
  br label %1404

1404:                                             ; preds = %1332
  %1405 = load i32, ptr %19, align 4, !tbaa !9
  %1406 = add nsw i32 %1405, 1
  store i32 %1406, ptr %19, align 4, !tbaa !9
  br label %1328, !llvm.loop !35

1407:                                             ; preds = %1328
  br label %1408

1408:                                             ; preds = %1407
  %1409 = load i32, ptr %18, align 4, !tbaa !9
  %1410 = add nsw i32 %1409, 1
  store i32 %1410, ptr %18, align 4, !tbaa !9
  br label %1323, !llvm.loop !36

1411:                                             ; preds = %1323
  br label %1412

1412:                                             ; preds = %1411
  %1413 = load i32, ptr %17, align 4, !tbaa !9
  %1414 = add nsw i32 %1413, 1
  store i32 %1414, ptr %17, align 4, !tbaa !9
  br label %1318, !llvm.loop !37

1415:                                             ; preds = %1318
  br label %1416

1416:                                             ; preds = %1415
  %1417 = load i32, ptr %20, align 4, !tbaa !9
  %1418 = add nsw i32 %1417, 1
  store i32 %1418, ptr %20, align 4, !tbaa !9
  br label %39, !llvm.loop !38

1419:                                             ; preds = %39
  %1420 = load float, ptr %24, align 4, !tbaa !14
  call void @llvm.lifetime.end.p0(ptr %26) #8
  call void @llvm.lifetime.end.p0(ptr %25) #8
  call void @llvm.lifetime.end.p0(ptr %24) #8
  call void @llvm.lifetime.end.p0(ptr %23) #8
  call void @llvm.lifetime.end.p0(ptr %22) #8
  call void @llvm.lifetime.end.p0(ptr %21) #8
  call void @llvm.lifetime.end.p0(ptr %20) #8
  call void @llvm.lifetime.end.p0(ptr %19) #8
  call void @llvm.lifetime.end.p0(ptr %18) #8
  call void @llvm.lifetime.end.p0(ptr %17) #8
  ret float %1420
}

; Function Attrs: nounwind uwtable
define dso_local void @clearMat(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !16
  %3 = load ptr, ptr %2, align 8, !tbaa !16
  %4 = getelementptr inbounds nuw %struct.Mat, ptr %3, i32 0, i32 0
  %5 = load ptr, ptr %4, align 8, !tbaa !24
  %6 = icmp ne ptr %5, null
  br i1 %6, label %7, label %11

7:                                                ; preds = %1
  %8 = load ptr, ptr %2, align 8, !tbaa !16
  %9 = getelementptr inbounds nuw %struct.Mat, ptr %8, i32 0, i32 0
  %10 = load ptr, ptr %9, align 8, !tbaa !24
  call void @free(ptr noundef %10) #8
  br label %11

11:                                               ; preds = %7, %1
  %12 = load ptr, ptr %2, align 8, !tbaa !16
  %13 = getelementptr inbounds nuw %struct.Mat, ptr %12, i32 0, i32 0
  store ptr null, ptr %13, align 8, !tbaa !24
  %14 = load ptr, ptr %2, align 8, !tbaa !16
  %15 = getelementptr inbounds nuw %struct.Mat, ptr %14, i32 0, i32 1
  store i32 0, ptr %15, align 8, !tbaa !18
  %16 = load ptr, ptr %2, align 8, !tbaa !16
  %17 = getelementptr inbounds nuw %struct.Mat, ptr %16, i32 0, i32 3
  store i32 0, ptr %17, align 8, !tbaa !22
  %18 = load ptr, ptr %2, align 8, !tbaa !16
  %19 = getelementptr inbounds nuw %struct.Mat, ptr %18, i32 0, i32 2
  store i32 0, ptr %19, align 4, !tbaa !21
  %20 = load ptr, ptr %2, align 8, !tbaa !16
  %21 = getelementptr inbounds nuw %struct.Mat, ptr %20, i32 0, i32 4
  store i32 0, ptr %21, align 4, !tbaa !23
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local double @fflop(i32 noundef %0, i32 noundef %1, i32 noundef %2) #0 {
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  store i32 %0, ptr %4, align 4, !tbaa !9
  store i32 %1, ptr %5, align 4, !tbaa !9
  store i32 %2, ptr %6, align 4, !tbaa !9
  %7 = load i32, ptr %6, align 4, !tbaa !9
  %8 = sub nsw i32 %7, 2
  %9 = sitofp i32 %8 to double
  %10 = load i32, ptr %5, align 4, !tbaa !9
  %11 = sub nsw i32 %10, 2
  %12 = sitofp i32 %11 to double
  %13 = fmul double %9, %12
  %14 = load i32, ptr %4, align 4, !tbaa !9
  %15 = sub nsw i32 %14, 2
  %16 = sitofp i32 %15 to double
  %17 = fmul double %13, %16
  %18 = fmul double %17, 3.400000e+01
  ret double %18
}

; Function Attrs: nounwind uwtable
define dso_local double @mflops(i32 noundef %0, double noundef %1, double noundef %2) #0 {
  %4 = alloca i32, align 4
  %5 = alloca double, align 8
  %6 = alloca double, align 8
  store i32 %0, ptr %4, align 4, !tbaa !9
  store double %1, ptr %5, align 8, !tbaa !39
  store double %2, ptr %6, align 8, !tbaa !39
  %7 = load double, ptr %6, align 8, !tbaa !39
  %8 = load double, ptr %5, align 8, !tbaa !39
  %9 = fdiv double %7, %8
  %10 = fmul double %9, f0x3EB0C6F7A0B5ED8D
  %11 = load i32, ptr %4, align 4, !tbaa !9
  %12 = sitofp i32 %11 to double
  %13 = fmul double %10, %12
  ret double %13
}

; Function Attrs: nounwind uwtable
define dso_local void @set_param(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8, !tbaa !41
  store ptr %1, ptr %4, align 8, !tbaa !43
  %5 = load ptr, ptr %4, align 8, !tbaa !43
  %6 = call i32 @strcmp(ptr noundef %5, ptr noundef @.str.4) #10
  %7 = icmp ne i32 %6, 0
  br i1 %7, label %8, label %12

8:                                                ; preds = %2
  %9 = load ptr, ptr %4, align 8, !tbaa !43
  %10 = call i32 @strcmp(ptr noundef %9, ptr noundef @.str.5) #10
  %11 = icmp ne i32 %10, 0
  br i1 %11, label %19, label %12

12:                                               ; preds = %8, %2
  %13 = load ptr, ptr %3, align 8, !tbaa !41
  %14 = getelementptr inbounds i32, ptr %13, i64 0
  store i32 32, ptr %14, align 4, !tbaa !9
  %15 = load ptr, ptr %3, align 8, !tbaa !41
  %16 = getelementptr inbounds i32, ptr %15, i64 1
  store i32 32, ptr %16, align 4, !tbaa !9
  %17 = load ptr, ptr %3, align 8, !tbaa !41
  %18 = getelementptr inbounds i32, ptr %17, i64 2
  store i32 64, ptr %18, align 4, !tbaa !9
  br label %81

19:                                               ; preds = %8
  %20 = load ptr, ptr %4, align 8, !tbaa !43
  %21 = call i32 @strcmp(ptr noundef %20, ptr noundef @.str.6) #10
  %22 = icmp ne i32 %21, 0
  br i1 %22, label %23, label %27

23:                                               ; preds = %19
  %24 = load ptr, ptr %4, align 8, !tbaa !43
  %25 = call i32 @strcmp(ptr noundef %24, ptr noundef @.str.7) #10
  %26 = icmp ne i32 %25, 0
  br i1 %26, label %34, label %27

27:                                               ; preds = %23, %19
  %28 = load ptr, ptr %3, align 8, !tbaa !41
  %29 = getelementptr inbounds i32, ptr %28, i64 0
  store i32 64, ptr %29, align 4, !tbaa !9
  %30 = load ptr, ptr %3, align 8, !tbaa !41
  %31 = getelementptr inbounds i32, ptr %30, i64 1
  store i32 64, ptr %31, align 4, !tbaa !9
  %32 = load ptr, ptr %3, align 8, !tbaa !41
  %33 = getelementptr inbounds i32, ptr %32, i64 2
  store i32 128, ptr %33, align 4, !tbaa !9
  br label %81

34:                                               ; preds = %23
  %35 = load ptr, ptr %4, align 8, !tbaa !43
  %36 = call i32 @strcmp(ptr noundef %35, ptr noundef @.str.8) #10
  %37 = icmp ne i32 %36, 0
  br i1 %37, label %38, label %42

38:                                               ; preds = %34
  %39 = load ptr, ptr %4, align 8, !tbaa !43
  %40 = call i32 @strcmp(ptr noundef %39, ptr noundef @.str.9) #10
  %41 = icmp ne i32 %40, 0
  br i1 %41, label %49, label %42

42:                                               ; preds = %38, %34
  %43 = load ptr, ptr %3, align 8, !tbaa !41
  %44 = getelementptr inbounds i32, ptr %43, i64 0
  store i32 128, ptr %44, align 4, !tbaa !9
  %45 = load ptr, ptr %3, align 8, !tbaa !41
  %46 = getelementptr inbounds i32, ptr %45, i64 1
  store i32 128, ptr %46, align 4, !tbaa !9
  %47 = load ptr, ptr %3, align 8, !tbaa !41
  %48 = getelementptr inbounds i32, ptr %47, i64 2
  store i32 256, ptr %48, align 4, !tbaa !9
  br label %81

49:                                               ; preds = %38
  %50 = load ptr, ptr %4, align 8, !tbaa !43
  %51 = call i32 @strcmp(ptr noundef %50, ptr noundef @.str.10) #10
  %52 = icmp ne i32 %51, 0
  br i1 %52, label %53, label %57

53:                                               ; preds = %49
  %54 = load ptr, ptr %4, align 8, !tbaa !43
  %55 = call i32 @strcmp(ptr noundef %54, ptr noundef @.str.11) #10
  %56 = icmp ne i32 %55, 0
  br i1 %56, label %64, label %57

57:                                               ; preds = %53, %49
  %58 = load ptr, ptr %3, align 8, !tbaa !41
  %59 = getelementptr inbounds i32, ptr %58, i64 0
  store i32 256, ptr %59, align 4, !tbaa !9
  %60 = load ptr, ptr %3, align 8, !tbaa !41
  %61 = getelementptr inbounds i32, ptr %60, i64 1
  store i32 256, ptr %61, align 4, !tbaa !9
  %62 = load ptr, ptr %3, align 8, !tbaa !41
  %63 = getelementptr inbounds i32, ptr %62, i64 2
  store i32 512, ptr %63, align 4, !tbaa !9
  br label %81

64:                                               ; preds = %53
  %65 = load ptr, ptr %4, align 8, !tbaa !43
  %66 = call i32 @strcmp(ptr noundef %65, ptr noundef @.str.12) #10
  %67 = icmp ne i32 %66, 0
  br i1 %67, label %68, label %72

68:                                               ; preds = %64
  %69 = load ptr, ptr %4, align 8, !tbaa !43
  %70 = call i32 @strcmp(ptr noundef %69, ptr noundef @.str.13) #10
  %71 = icmp ne i32 %70, 0
  br i1 %71, label %79, label %72

72:                                               ; preds = %68, %64
  %73 = load ptr, ptr %3, align 8, !tbaa !41
  %74 = getelementptr inbounds i32, ptr %73, i64 0
  store i32 512, ptr %74, align 4, !tbaa !9
  %75 = load ptr, ptr %3, align 8, !tbaa !41
  %76 = getelementptr inbounds i32, ptr %75, i64 1
  store i32 512, ptr %76, align 4, !tbaa !9
  %77 = load ptr, ptr %3, align 8, !tbaa !41
  %78 = getelementptr inbounds i32, ptr %77, i64 2
  store i32 1024, ptr %78, align 4, !tbaa !9
  br label %81

79:                                               ; preds = %68
  %80 = call i32 (ptr, ...) @printf(ptr noundef @.str.14)
  call void @exit(i32 noundef 6) #11
  unreachable

81:                                               ; preds = %72, %57, %42, %27, %12
  ret void
}

; Function Attrs: nounwind willreturn memory(read)
declare i32 @strcmp(ptr noundef, ptr noundef) #3

; Function Attrs: noreturn nounwind
declare void @exit(i32 noundef) #4

; Function Attrs: nounwind allocsize(0)
declare noalias ptr @malloc(i64 noundef) #5

; Function Attrs: nounwind
declare void @free(ptr noundef) #6

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare float @llvm.fmuladd.f32(float, float, float) #7

; Function Attrs: nounwind uwtable
define dso_local double @second() #0 {
  %1 = alloca %struct.timeval, align 8
  %2 = alloca double, align 8
  call void @llvm.lifetime.start.p0(ptr %1) #8
  call void @llvm.lifetime.start.p0(ptr %2) #8
  %3 = call i32 @gettimeofday(ptr noundef %1, ptr noundef null) #8
  %4 = load i32, ptr @second.base_sec, align 4, !tbaa !9
  %5 = icmp eq i32 %4, 0
  br i1 %5, label %6, label %16

6:                                                ; preds = %0
  %7 = load i32, ptr @second.base_usec, align 4, !tbaa !9
  %8 = icmp eq i32 %7, 0
  br i1 %8, label %9, label %16

9:                                                ; preds = %6
  %10 = getelementptr inbounds nuw %struct.timeval, ptr %1, i32 0, i32 0
  %11 = load i64, ptr %10, align 8, !tbaa !45
  %12 = trunc i64 %11 to i32
  store i32 %12, ptr @second.base_sec, align 4, !tbaa !9
  %13 = getelementptr inbounds nuw %struct.timeval, ptr %1, i32 0, i32 1
  %14 = load i64, ptr %13, align 8, !tbaa !48
  %15 = trunc i64 %14 to i32
  store i32 %15, ptr @second.base_usec, align 4, !tbaa !9
  store double 0.000000e+00, ptr %2, align 8, !tbaa !39
  br label %31

16:                                               ; preds = %6, %0
  %17 = getelementptr inbounds nuw %struct.timeval, ptr %1, i32 0, i32 0
  %18 = load i64, ptr %17, align 8, !tbaa !45
  %19 = load i32, ptr @second.base_sec, align 4, !tbaa !9
  %20 = sext i32 %19 to i64
  %21 = sub nsw i64 %18, %20
  %22 = sitofp i64 %21 to double
  %23 = getelementptr inbounds nuw %struct.timeval, ptr %1, i32 0, i32 1
  %24 = load i64, ptr %23, align 8, !tbaa !48
  %25 = load i32, ptr @second.base_usec, align 4, !tbaa !9
  %26 = sext i32 %25 to i64
  %27 = sub nsw i64 %24, %26
  %28 = sitofp i64 %27 to double
  %29 = fdiv double %28, 1.000000e+06
  %30 = fadd double %22, %29
  store double %30, ptr %2, align 8, !tbaa !39
  br label %31

31:                                               ; preds = %16, %9
  %32 = load double, ptr %2, align 8, !tbaa !39
  call void @llvm.lifetime.end.p0(ptr %2) #8
  call void @llvm.lifetime.end.p0(ptr %1) #8
  ret double %32
}

; Function Attrs: nounwind
declare i32 @gettimeofday(ptr noundef, ptr noundef) #6

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind willreturn memory(read) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { noreturn nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind allocsize(0) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #7 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #8 = { nounwind }
attributes #9 = { nounwind allocsize(0) }
attributes #10 = { nounwind willreturn memory(read) }
attributes #11 = { noreturn nounwind }

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
!15 = !{!"float", !7, i64 0}
!16 = !{!17, !17, i64 0}
!17 = !{!"p1 _ZTS3Mat", !13, i64 0}
!18 = !{!19, !6, i64 8}
!19 = !{!"Mat", !20, i64 0, !6, i64 8, !6, i64 12, !6, i64 16, !6, i64 20}
!20 = !{!"p1 float", !13, i64 0}
!21 = !{!19, !6, i64 12}
!22 = !{!19, !6, i64 16}
!23 = !{!19, !6, i64 20}
!24 = !{!19, !20, i64 0}
!25 = distinct !{!25, !26}
!26 = !{!"llvm.loop.mustprogress"}
!27 = distinct !{!27, !26}
!28 = distinct !{!28, !26}
!29 = distinct !{!29, !26}
!30 = distinct !{!30, !26}
!31 = distinct !{!31, !26}
!32 = distinct !{!32, !26}
!33 = distinct !{!33, !26}
!34 = distinct !{!34, !26}
!35 = distinct !{!35, !26}
!36 = distinct !{!36, !26}
!37 = distinct !{!37, !26}
!38 = distinct !{!38, !26}
!39 = !{!40, !40, i64 0}
!40 = !{!"double", !7, i64 0}
!41 = !{!42, !42, i64 0}
!42 = !{!"p1 int", !13, i64 0}
!43 = !{!44, !44, i64 0}
!44 = !{!"p1 omnipotent char", !13, i64 0}
!45 = !{!46, !47, i64 0}
!46 = !{!"timeval", !47, i64 0, !47, i64 8}
!47 = !{!"long", !7, i64 0}
!48 = !{!46, !47, i64 8}
