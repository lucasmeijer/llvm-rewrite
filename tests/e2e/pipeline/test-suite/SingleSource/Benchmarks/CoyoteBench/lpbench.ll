; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/CoyoteBench/lpbench.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/CoyoteBench/lpbench.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/CoyoteBench/lpbench.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [4 x i8] c"-ga\00", align 1
@stdout = external global ptr, align 8
@.str.1 = private unnamed_addr constant [3 x i8] c"%f\00", align 1
@.str.2 = private unnamed_addr constant [33 x i8] c"\0Alpbench (Std. C) run time: %f\0A\0A\00", align 1
@seed = internal global i64 1325, align 8

; Function Attrs: nounwind uwtable
define dso_local void @matgen(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !9
  store ptr %1, ptr %4, align 8, !tbaa !13
  call void @llvm.lifetime.start.p0(ptr %5) #7
  call void @llvm.lifetime.start.p0(ptr %6) #7
  store i32 0, ptr %5, align 4, !tbaa !15
  br label %7

7:                                                ; preds = %28, %2
  %8 = load i32, ptr %5, align 4, !tbaa !15
  %9 = icmp slt i32 %8, 2000
  br i1 %9, label %10, label %31

10:                                               ; preds = %7
  store i32 0, ptr %6, align 4, !tbaa !15
  br label %11

11:                                               ; preds = %24, %10
  %12 = load i32, ptr %6, align 4, !tbaa !15
  %13 = icmp slt i32 %12, 2000
  br i1 %13, label %14, label %27

14:                                               ; preds = %11
  %15 = call double @random_double()
  %16 = load ptr, ptr %3, align 8, !tbaa !9
  %17 = load i32, ptr %6, align 4, !tbaa !15
  %18 = sext i32 %17 to i64
  %19 = getelementptr inbounds ptr, ptr %16, i64 %18
  %20 = load ptr, ptr %19, align 8, !tbaa !13
  %21 = load i32, ptr %5, align 4, !tbaa !15
  %22 = sext i32 %21 to i64
  %23 = getelementptr inbounds double, ptr %20, i64 %22
  store double %15, ptr %23, align 8, !tbaa !16
  br label %24

24:                                               ; preds = %14
  %25 = load i32, ptr %6, align 4, !tbaa !15
  %26 = add nsw i32 %25, 1
  store i32 %26, ptr %6, align 4, !tbaa !15
  br label %11, !llvm.loop !18

27:                                               ; preds = %11
  br label %28

28:                                               ; preds = %27
  %29 = load i32, ptr %5, align 4, !tbaa !15
  %30 = add nsw i32 %29, 1
  store i32 %30, ptr %5, align 4, !tbaa !15
  br label %7, !llvm.loop !20

31:                                               ; preds = %7
  store i32 0, ptr %5, align 4, !tbaa !15
  br label %32

32:                                               ; preds = %40, %31
  %33 = load i32, ptr %5, align 4, !tbaa !15
  %34 = icmp slt i32 %33, 2000
  br i1 %34, label %35, label %43

35:                                               ; preds = %32
  %36 = load ptr, ptr %4, align 8, !tbaa !13
  %37 = load i32, ptr %5, align 4, !tbaa !15
  %38 = sext i32 %37 to i64
  %39 = getelementptr inbounds double, ptr %36, i64 %38
  store double 0.000000e+00, ptr %39, align 8, !tbaa !16
  br label %40

40:                                               ; preds = %35
  %41 = load i32, ptr %5, align 4, !tbaa !15
  %42 = add nsw i32 %41, 1
  store i32 %42, ptr %5, align 4, !tbaa !15
  br label %32, !llvm.loop !21

43:                                               ; preds = %32
  store i32 0, ptr %6, align 4, !tbaa !15
  br label %44

44:                                               ; preds = %71, %43
  %45 = load i32, ptr %6, align 4, !tbaa !15
  %46 = icmp slt i32 %45, 2000
  br i1 %46, label %47, label %74

47:                                               ; preds = %44
  store i32 0, ptr %5, align 4, !tbaa !15
  br label %48

48:                                               ; preds = %67, %47
  %49 = load i32, ptr %5, align 4, !tbaa !15
  %50 = icmp slt i32 %49, 2000
  br i1 %50, label %51, label %70

51:                                               ; preds = %48
  %52 = load ptr, ptr %3, align 8, !tbaa !9
  %53 = load i32, ptr %6, align 4, !tbaa !15
  %54 = sext i32 %53 to i64
  %55 = getelementptr inbounds ptr, ptr %52, i64 %54
  %56 = load ptr, ptr %55, align 8, !tbaa !13
  %57 = load i32, ptr %5, align 4, !tbaa !15
  %58 = sext i32 %57 to i64
  %59 = getelementptr inbounds double, ptr %56, i64 %58
  %60 = load double, ptr %59, align 8, !tbaa !16
  %61 = load ptr, ptr %4, align 8, !tbaa !13
  %62 = load i32, ptr %5, align 4, !tbaa !15
  %63 = sext i32 %62 to i64
  %64 = getelementptr inbounds double, ptr %61, i64 %63
  %65 = load double, ptr %64, align 8, !tbaa !16
  %66 = fadd double %65, %60
  store double %66, ptr %64, align 8, !tbaa !16
  br label %67

67:                                               ; preds = %51
  %68 = load i32, ptr %5, align 4, !tbaa !15
  %69 = add nsw i32 %68, 1
  store i32 %69, ptr %5, align 4, !tbaa !15
  br label %48, !llvm.loop !22

70:                                               ; preds = %48
  br label %71

71:                                               ; preds = %70
  %72 = load i32, ptr %6, align 4, !tbaa !15
  %73 = add nsw i32 %72, 1
  store i32 %73, ptr %6, align 4, !tbaa !15
  br label %44, !llvm.loop !23

74:                                               ; preds = %44
  call void @llvm.lifetime.end.p0(ptr %6) #7
  call void @llvm.lifetime.end.p0(ptr %5) #7
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local i32 @idamax(i32 noundef %0, ptr noundef %1, i32 noundef %2, i32 noundef %3) #0 {
  %5 = alloca i32, align 4
  %6 = alloca ptr, align 8
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca double, align 8
  %10 = alloca double, align 8
  %11 = alloca i32, align 4
  %12 = alloca i32, align 4
  %13 = alloca i32, align 4
  store i32 %0, ptr %5, align 4, !tbaa !15
  store ptr %1, ptr %6, align 8, !tbaa !13
  store i32 %2, ptr %7, align 4, !tbaa !15
  store i32 %3, ptr %8, align 4, !tbaa !15
  call void @llvm.lifetime.start.p0(ptr %9) #7
  call void @llvm.lifetime.start.p0(ptr %10) #7
  call void @llvm.lifetime.start.p0(ptr %11) #7
  call void @llvm.lifetime.start.p0(ptr %12) #7
  call void @llvm.lifetime.start.p0(ptr %13) #7
  store i32 0, ptr %13, align 4, !tbaa !15
  %14 = load i32, ptr %5, align 4, !tbaa !15
  %15 = icmp slt i32 %14, 1
  br i1 %15, label %16, label %17

16:                                               ; preds = %4
  store i32 -1, ptr %13, align 4, !tbaa !15
  br label %93

17:                                               ; preds = %4
  %18 = load i32, ptr %5, align 4, !tbaa !15
  %19 = icmp eq i32 %18, 1
  br i1 %19, label %20, label %21

20:                                               ; preds = %17
  store i32 0, ptr %13, align 4, !tbaa !15
  br label %92

21:                                               ; preds = %17
  %22 = load i32, ptr %8, align 4, !tbaa !15
  %23 = icmp ne i32 %22, 1
  br i1 %23, label %24, label %60

24:                                               ; preds = %21
  %25 = load ptr, ptr %6, align 8, !tbaa !13
  %26 = load i32, ptr %7, align 4, !tbaa !15
  %27 = sext i32 %26 to i64
  %28 = getelementptr inbounds double, ptr %25, i64 %27
  %29 = load double, ptr %28, align 8, !tbaa !16
  %30 = call double @llvm.fabs.f64(double %29)
  store double %30, ptr %9, align 8, !tbaa !16
  %31 = load i32, ptr %8, align 4, !tbaa !15
  %32 = add nsw i32 1, %31
  store i32 %32, ptr %12, align 4, !tbaa !15
  store i32 1, ptr %11, align 4, !tbaa !15
  br label %33

33:                                               ; preds = %56, %24
  %34 = load i32, ptr %11, align 4, !tbaa !15
  %35 = load i32, ptr %5, align 4, !tbaa !15
  %36 = icmp slt i32 %34, %35
  br i1 %36, label %37, label %59

37:                                               ; preds = %33
  %38 = load ptr, ptr %6, align 8, !tbaa !13
  %39 = load i32, ptr %12, align 4, !tbaa !15
  %40 = load i32, ptr %7, align 4, !tbaa !15
  %41 = add nsw i32 %39, %40
  %42 = sext i32 %41 to i64
  %43 = getelementptr inbounds double, ptr %38, i64 %42
  %44 = load double, ptr %43, align 8, !tbaa !16
  %45 = call double @llvm.fabs.f64(double %44)
  store double %45, ptr %10, align 8, !tbaa !16
  %46 = load double, ptr %10, align 8, !tbaa !16
  %47 = load double, ptr %9, align 8, !tbaa !16
  %48 = fcmp ogt double %46, %47
  br i1 %48, label %49, label %52

49:                                               ; preds = %37
  %50 = load i32, ptr %11, align 4, !tbaa !15
  store i32 %50, ptr %13, align 4, !tbaa !15
  %51 = load double, ptr %10, align 8, !tbaa !16
  store double %51, ptr %9, align 8, !tbaa !16
  br label %52

52:                                               ; preds = %49, %37
  %53 = load i32, ptr %8, align 4, !tbaa !15
  %54 = load i32, ptr %12, align 4, !tbaa !15
  %55 = add nsw i32 %54, %53
  store i32 %55, ptr %12, align 4, !tbaa !15
  br label %56

56:                                               ; preds = %52
  %57 = load i32, ptr %11, align 4, !tbaa !15
  %58 = add nsw i32 %57, 1
  store i32 %58, ptr %11, align 4, !tbaa !15
  br label %33, !llvm.loop !24

59:                                               ; preds = %33
  br label %91

60:                                               ; preds = %21
  store i32 0, ptr %13, align 4, !tbaa !15
  %61 = load ptr, ptr %6, align 8, !tbaa !13
  %62 = load i32, ptr %7, align 4, !tbaa !15
  %63 = sext i32 %62 to i64
  %64 = getelementptr inbounds double, ptr %61, i64 %63
  %65 = load double, ptr %64, align 8, !tbaa !16
  %66 = call double @llvm.fabs.f64(double %65)
  store double %66, ptr %9, align 8, !tbaa !16
  store i32 1, ptr %11, align 4, !tbaa !15
  br label %67

67:                                               ; preds = %87, %60
  %68 = load i32, ptr %11, align 4, !tbaa !15
  %69 = load i32, ptr %5, align 4, !tbaa !15
  %70 = icmp slt i32 %68, %69
  br i1 %70, label %71, label %90

71:                                               ; preds = %67
  %72 = load ptr, ptr %6, align 8, !tbaa !13
  %73 = load i32, ptr %11, align 4, !tbaa !15
  %74 = load i32, ptr %7, align 4, !tbaa !15
  %75 = add nsw i32 %73, %74
  %76 = sext i32 %75 to i64
  %77 = getelementptr inbounds double, ptr %72, i64 %76
  %78 = load double, ptr %77, align 8, !tbaa !16
  %79 = call double @llvm.fabs.f64(double %78)
  store double %79, ptr %10, align 8, !tbaa !16
  %80 = load double, ptr %10, align 8, !tbaa !16
  %81 = load double, ptr %9, align 8, !tbaa !16
  %82 = fcmp ogt double %80, %81
  br i1 %82, label %83, label %86

83:                                               ; preds = %71
  %84 = load i32, ptr %11, align 4, !tbaa !15
  store i32 %84, ptr %13, align 4, !tbaa !15
  %85 = load double, ptr %10, align 8, !tbaa !16
  store double %85, ptr %9, align 8, !tbaa !16
  br label %86

86:                                               ; preds = %83, %71
  br label %87

87:                                               ; preds = %86
  %88 = load i32, ptr %11, align 4, !tbaa !15
  %89 = add nsw i32 %88, 1
  store i32 %89, ptr %11, align 4, !tbaa !15
  br label %67, !llvm.loop !25

90:                                               ; preds = %67
  br label %91

91:                                               ; preds = %90, %59
  br label %92

92:                                               ; preds = %91, %20
  br label %93

93:                                               ; preds = %92, %16
  %94 = load i32, ptr %13, align 4, !tbaa !15
  call void @llvm.lifetime.end.p0(ptr %13) #7
  call void @llvm.lifetime.end.p0(ptr %12) #7
  call void @llvm.lifetime.end.p0(ptr %11) #7
  call void @llvm.lifetime.end.p0(ptr %10) #7
  call void @llvm.lifetime.end.p0(ptr %9) #7
  ret i32 %94
}

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fabs.f64(double) #2

; Function Attrs: nounwind uwtable
define dso_local void @dscal(i32 noundef %0, double noundef %1, ptr noundef %2, i32 noundef %3, i32 noundef %4) #0 {
  %6 = alloca i32, align 4
  %7 = alloca double, align 8
  %8 = alloca ptr, align 8
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  %11 = alloca i32, align 4
  %12 = alloca i32, align 4
  store i32 %0, ptr %6, align 4, !tbaa !15
  store double %1, ptr %7, align 8, !tbaa !16
  store ptr %2, ptr %8, align 8, !tbaa !13
  store i32 %3, ptr %9, align 4, !tbaa !15
  store i32 %4, ptr %10, align 4, !tbaa !15
  call void @llvm.lifetime.start.p0(ptr %11) #7
  %13 = load i32, ptr %6, align 4, !tbaa !15
  %14 = icmp sgt i32 %13, 0
  br i1 %14, label %15, label %61

15:                                               ; preds = %5
  %16 = load i32, ptr %10, align 4, !tbaa !15
  %17 = icmp ne i32 %16, 1
  br i1 %17, label %18, label %41

18:                                               ; preds = %15
  call void @llvm.lifetime.start.p0(ptr %12) #7
  %19 = load i32, ptr %6, align 4, !tbaa !15
  %20 = load i32, ptr %10, align 4, !tbaa !15
  %21 = mul nsw i32 %19, %20
  store i32 %21, ptr %12, align 4, !tbaa !15
  store i32 0, ptr %11, align 4, !tbaa !15
  br label %22

22:                                               ; preds = %36, %18
  %23 = load i32, ptr %11, align 4, !tbaa !15
  %24 = load i32, ptr %12, align 4, !tbaa !15
  %25 = icmp slt i32 %23, %24
  br i1 %25, label %26, label %40

26:                                               ; preds = %22
  %27 = load double, ptr %7, align 8, !tbaa !16
  %28 = load ptr, ptr %8, align 8, !tbaa !13
  %29 = load i32, ptr %11, align 4, !tbaa !15
  %30 = load i32, ptr %9, align 4, !tbaa !15
  %31 = add nsw i32 %29, %30
  %32 = sext i32 %31 to i64
  %33 = getelementptr inbounds double, ptr %28, i64 %32
  %34 = load double, ptr %33, align 8, !tbaa !16
  %35 = fmul double %34, %27
  store double %35, ptr %33, align 8, !tbaa !16
  br label %36

36:                                               ; preds = %26
  %37 = load i32, ptr %10, align 4, !tbaa !15
  %38 = load i32, ptr %11, align 4, !tbaa !15
  %39 = add nsw i32 %38, %37
  store i32 %39, ptr %11, align 4, !tbaa !15
  br label %22, !llvm.loop !26

40:                                               ; preds = %22
  call void @llvm.lifetime.end.p0(ptr %12) #7
  br label %60

41:                                               ; preds = %15
  store i32 0, ptr %11, align 4, !tbaa !15
  br label %42

42:                                               ; preds = %56, %41
  %43 = load i32, ptr %11, align 4, !tbaa !15
  %44 = load i32, ptr %6, align 4, !tbaa !15
  %45 = icmp slt i32 %43, %44
  br i1 %45, label %46, label %59

46:                                               ; preds = %42
  %47 = load double, ptr %7, align 8, !tbaa !16
  %48 = load ptr, ptr %8, align 8, !tbaa !13
  %49 = load i32, ptr %11, align 4, !tbaa !15
  %50 = load i32, ptr %9, align 4, !tbaa !15
  %51 = add nsw i32 %49, %50
  %52 = sext i32 %51 to i64
  %53 = getelementptr inbounds double, ptr %48, i64 %52
  %54 = load double, ptr %53, align 8, !tbaa !16
  %55 = fmul double %54, %47
  store double %55, ptr %53, align 8, !tbaa !16
  br label %56

56:                                               ; preds = %46
  %57 = load i32, ptr %11, align 4, !tbaa !15
  %58 = add nsw i32 %57, 1
  store i32 %58, ptr %11, align 4, !tbaa !15
  br label %42, !llvm.loop !27

59:                                               ; preds = %42
  br label %60

60:                                               ; preds = %59, %40
  br label %61

61:                                               ; preds = %60, %5
  call void @llvm.lifetime.end.p0(ptr %11) #7
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local void @daxpy(i32 noundef %0, double noundef %1, ptr noundef %2, i32 noundef %3, i32 noundef %4, ptr noundef %5, i32 noundef %6, i32 noundef %7) #0 {
  %9 = alloca i32, align 4
  %10 = alloca double, align 8
  %11 = alloca ptr, align 8
  %12 = alloca i32, align 4
  %13 = alloca i32, align 4
  %14 = alloca ptr, align 8
  %15 = alloca i32, align 4
  %16 = alloca i32, align 4
  %17 = alloca i32, align 4
  %18 = alloca i32, align 4
  %19 = alloca i32, align 4
  %20 = alloca i32, align 4
  store i32 %0, ptr %9, align 4, !tbaa !15
  store double %1, ptr %10, align 8, !tbaa !16
  store ptr %2, ptr %11, align 8, !tbaa !13
  store i32 %3, ptr %12, align 4, !tbaa !15
  store i32 %4, ptr %13, align 4, !tbaa !15
  store ptr %5, ptr %14, align 8, !tbaa !13
  store i32 %6, ptr %15, align 4, !tbaa !15
  store i32 %7, ptr %16, align 4, !tbaa !15
  call void @llvm.lifetime.start.p0(ptr %17) #7
  %21 = load i32, ptr %9, align 4, !tbaa !15
  %22 = icmp sgt i32 %21, 0
  br i1 %22, label %23, label %107

23:                                               ; preds = %8
  %24 = load double, ptr %10, align 8, !tbaa !16
  %25 = fcmp une double %24, 0.000000e+00
  br i1 %25, label %26, label %107

26:                                               ; preds = %23
  %27 = load i32, ptr %13, align 4, !tbaa !15
  %28 = icmp ne i32 %27, 1
  br i1 %28, label %32, label %29

29:                                               ; preds = %26
  %30 = load i32, ptr %16, align 4, !tbaa !15
  %31 = icmp ne i32 %30, 1
  br i1 %31, label %32, label %80

32:                                               ; preds = %29, %26
  call void @llvm.lifetime.start.p0(ptr %18) #7
  store i32 0, ptr %18, align 4, !tbaa !15
  call void @llvm.lifetime.start.p0(ptr %19) #7
  store i32 0, ptr %19, align 4, !tbaa !15
  %33 = load i32, ptr %13, align 4, !tbaa !15
  %34 = icmp slt i32 %33, 0
  br i1 %34, label %35, label %40

35:                                               ; preds = %32
  %36 = load i32, ptr %9, align 4, !tbaa !15
  %37 = sub nsw i32 1, %36
  %38 = load i32, ptr %13, align 4, !tbaa !15
  %39 = mul nsw i32 %37, %38
  store i32 %39, ptr %18, align 4, !tbaa !15
  br label %40

40:                                               ; preds = %35, %32
  %41 = load i32, ptr %16, align 4, !tbaa !15
  %42 = icmp slt i32 %41, 0
  br i1 %42, label %43, label %48

43:                                               ; preds = %40
  %44 = load i32, ptr %9, align 4, !tbaa !15
  %45 = sub nsw i32 1, %44
  %46 = load i32, ptr %16, align 4, !tbaa !15
  %47 = mul nsw i32 %45, %46
  store i32 %47, ptr %19, align 4, !tbaa !15
  br label %48

48:                                               ; preds = %43, %40
  store i32 0, ptr %17, align 4, !tbaa !15
  br label %49

49:                                               ; preds = %76, %48
  %50 = load i32, ptr %17, align 4, !tbaa !15
  %51 = load i32, ptr %9, align 4, !tbaa !15
  %52 = icmp slt i32 %50, %51
  br i1 %52, label %53, label %79

53:                                               ; preds = %49
  %54 = load double, ptr %10, align 8, !tbaa !16
  %55 = load ptr, ptr %11, align 8, !tbaa !13
  %56 = load i32, ptr %18, align 4, !tbaa !15
  %57 = load i32, ptr %12, align 4, !tbaa !15
  %58 = add nsw i32 %56, %57
  %59 = sext i32 %58 to i64
  %60 = getelementptr inbounds double, ptr %55, i64 %59
  %61 = load double, ptr %60, align 8, !tbaa !16
  %62 = load ptr, ptr %14, align 8, !tbaa !13
  %63 = load i32, ptr %19, align 4, !tbaa !15
  %64 = load i32, ptr %15, align 4, !tbaa !15
  %65 = add nsw i32 %63, %64
  %66 = sext i32 %65 to i64
  %67 = getelementptr inbounds double, ptr %62, i64 %66
  %68 = load double, ptr %67, align 8, !tbaa !16
  %69 = call double @llvm.fmuladd.f64(double %54, double %61, double %68)
  store double %69, ptr %67, align 8, !tbaa !16
  %70 = load i32, ptr %13, align 4, !tbaa !15
  %71 = load i32, ptr %18, align 4, !tbaa !15
  %72 = add nsw i32 %71, %70
  store i32 %72, ptr %18, align 4, !tbaa !15
  %73 = load i32, ptr %16, align 4, !tbaa !15
  %74 = load i32, ptr %19, align 4, !tbaa !15
  %75 = add nsw i32 %74, %73
  store i32 %75, ptr %19, align 4, !tbaa !15
  br label %76

76:                                               ; preds = %53
  %77 = load i32, ptr %17, align 4, !tbaa !15
  %78 = add nsw i32 %77, 1
  store i32 %78, ptr %17, align 4, !tbaa !15
  br label %49, !llvm.loop !28

79:                                               ; preds = %49
  store i32 1, ptr %20, align 4
  call void @llvm.lifetime.end.p0(ptr %19) #7
  call void @llvm.lifetime.end.p0(ptr %18) #7
  br label %108

80:                                               ; preds = %29
  store i32 0, ptr %17, align 4, !tbaa !15
  br label %81

81:                                               ; preds = %102, %80
  %82 = load i32, ptr %17, align 4, !tbaa !15
  %83 = load i32, ptr %9, align 4, !tbaa !15
  %84 = icmp slt i32 %82, %83
  br i1 %84, label %85, label %105

85:                                               ; preds = %81
  %86 = load double, ptr %10, align 8, !tbaa !16
  %87 = load ptr, ptr %11, align 8, !tbaa !13
  %88 = load i32, ptr %17, align 4, !tbaa !15
  %89 = load i32, ptr %12, align 4, !tbaa !15
  %90 = add nsw i32 %88, %89
  %91 = sext i32 %90 to i64
  %92 = getelementptr inbounds double, ptr %87, i64 %91
  %93 = load double, ptr %92, align 8, !tbaa !16
  %94 = load ptr, ptr %14, align 8, !tbaa !13
  %95 = load i32, ptr %17, align 4, !tbaa !15
  %96 = load i32, ptr %15, align 4, !tbaa !15
  %97 = add nsw i32 %95, %96
  %98 = sext i32 %97 to i64
  %99 = getelementptr inbounds double, ptr %94, i64 %98
  %100 = load double, ptr %99, align 8, !tbaa !16
  %101 = call double @llvm.fmuladd.f64(double %86, double %93, double %100)
  store double %101, ptr %99, align 8, !tbaa !16
  br label %102

102:                                              ; preds = %85
  %103 = load i32, ptr %17, align 4, !tbaa !15
  %104 = add nsw i32 %103, 1
  store i32 %104, ptr %17, align 4, !tbaa !15
  br label %81, !llvm.loop !29

105:                                              ; preds = %81
  br label %106

106:                                              ; preds = %105
  br label %107

107:                                              ; preds = %106, %23, %8
  store i32 0, ptr %20, align 4
  br label %108

108:                                              ; preds = %107, %79
  call void @llvm.lifetime.end.p0(ptr %17) #7
  %109 = load i32, ptr %20, align 4
  switch i32 %109, label %111 [
    i32 0, label %110
    i32 1, label %110
  ]

110:                                              ; preds = %108, %108
  ret void

111:                                              ; preds = %108
  unreachable
}

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #2

; Function Attrs: nounwind uwtable
define dso_local void @dgefa(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca double, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca ptr, align 8
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  %11 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8, !tbaa !9
  store ptr %1, ptr %4, align 8, !tbaa !30
  call void @llvm.lifetime.start.p0(ptr %5) #7
  call void @llvm.lifetime.start.p0(ptr %6) #7
  call void @llvm.lifetime.start.p0(ptr %7) #7
  store i32 0, ptr %6, align 4, !tbaa !15
  br label %12

12:                                               ; preds = %123, %2
  %13 = load i32, ptr %6, align 4, !tbaa !15
  %14 = icmp slt i32 %13, 1999
  br i1 %14, label %15, label %126

15:                                               ; preds = %12
  call void @llvm.lifetime.start.p0(ptr %8) #7
  %16 = load ptr, ptr %3, align 8, !tbaa !9
  %17 = load i32, ptr %6, align 4, !tbaa !15
  %18 = sext i32 %17 to i64
  %19 = getelementptr inbounds ptr, ptr %16, i64 %18
  %20 = load ptr, ptr %19, align 8, !tbaa !13
  store ptr %20, ptr %8, align 8, !tbaa !13
  call void @llvm.lifetime.start.p0(ptr %9) #7
  %21 = load i32, ptr %6, align 4, !tbaa !15
  %22 = add nsw i32 %21, 1
  store i32 %22, ptr %9, align 4, !tbaa !15
  call void @llvm.lifetime.start.p0(ptr %10) #7
  %23 = load i32, ptr %6, align 4, !tbaa !15
  %24 = sub nsw i32 2000, %23
  %25 = load ptr, ptr %8, align 8, !tbaa !13
  %26 = load i32, ptr %6, align 4, !tbaa !15
  %27 = call i32 @idamax(i32 noundef %24, ptr noundef %25, i32 noundef %26, i32 noundef 1)
  %28 = load i32, ptr %6, align 4, !tbaa !15
  %29 = add nsw i32 %27, %28
  store i32 %29, ptr %10, align 4, !tbaa !15
  %30 = load i32, ptr %10, align 4, !tbaa !15
  %31 = load ptr, ptr %4, align 8, !tbaa !30
  %32 = load i32, ptr %6, align 4, !tbaa !15
  %33 = sext i32 %32 to i64
  %34 = getelementptr inbounds i32, ptr %31, i64 %33
  store i32 %30, ptr %34, align 4, !tbaa !15
  %35 = load ptr, ptr %8, align 8, !tbaa !13
  %36 = load i32, ptr %10, align 4, !tbaa !15
  %37 = sext i32 %36 to i64
  %38 = getelementptr inbounds double, ptr %35, i64 %37
  %39 = load double, ptr %38, align 8, !tbaa !16
  %40 = fcmp une double %39, 0.000000e+00
  br i1 %40, label %41, label %122

41:                                               ; preds = %15
  %42 = load i32, ptr %10, align 4, !tbaa !15
  %43 = load i32, ptr %6, align 4, !tbaa !15
  %44 = icmp ne i32 %42, %43
  br i1 %44, label %45, label %65

45:                                               ; preds = %41
  %46 = load ptr, ptr %8, align 8, !tbaa !13
  %47 = load i32, ptr %10, align 4, !tbaa !15
  %48 = sext i32 %47 to i64
  %49 = getelementptr inbounds double, ptr %46, i64 %48
  %50 = load double, ptr %49, align 8, !tbaa !16
  store double %50, ptr %5, align 8, !tbaa !16
  %51 = load ptr, ptr %8, align 8, !tbaa !13
  %52 = load i32, ptr %6, align 4, !tbaa !15
  %53 = sext i32 %52 to i64
  %54 = getelementptr inbounds double, ptr %51, i64 %53
  %55 = load double, ptr %54, align 8, !tbaa !16
  %56 = load ptr, ptr %8, align 8, !tbaa !13
  %57 = load i32, ptr %10, align 4, !tbaa !15
  %58 = sext i32 %57 to i64
  %59 = getelementptr inbounds double, ptr %56, i64 %58
  store double %55, ptr %59, align 8, !tbaa !16
  %60 = load double, ptr %5, align 8, !tbaa !16
  %61 = load ptr, ptr %8, align 8, !tbaa !13
  %62 = load i32, ptr %6, align 4, !tbaa !15
  %63 = sext i32 %62 to i64
  %64 = getelementptr inbounds double, ptr %61, i64 %63
  store double %60, ptr %64, align 8, !tbaa !16
  br label %65

65:                                               ; preds = %45, %41
  %66 = load ptr, ptr %8, align 8, !tbaa !13
  %67 = load i32, ptr %6, align 4, !tbaa !15
  %68 = sext i32 %67 to i64
  %69 = getelementptr inbounds double, ptr %66, i64 %68
  %70 = load double, ptr %69, align 8, !tbaa !16
  %71 = fdiv double -1.000000e+00, %70
  store double %71, ptr %5, align 8, !tbaa !16
  %72 = load i32, ptr %9, align 4, !tbaa !15
  %73 = sub nsw i32 2000, %72
  %74 = load double, ptr %5, align 8, !tbaa !16
  %75 = load ptr, ptr %8, align 8, !tbaa !13
  %76 = load i32, ptr %9, align 4, !tbaa !15
  call void @dscal(i32 noundef %73, double noundef %74, ptr noundef %75, i32 noundef %76, i32 noundef 1)
  %77 = load i32, ptr %9, align 4, !tbaa !15
  store i32 %77, ptr %7, align 4, !tbaa !15
  br label %78

78:                                               ; preds = %118, %65
  %79 = load i32, ptr %7, align 4, !tbaa !15
  %80 = icmp slt i32 %79, 2000
  br i1 %80, label %81, label %121

81:                                               ; preds = %78
  call void @llvm.lifetime.start.p0(ptr %11) #7
  %82 = load ptr, ptr %3, align 8, !tbaa !9
  %83 = load i32, ptr %7, align 4, !tbaa !15
  %84 = sext i32 %83 to i64
  %85 = getelementptr inbounds ptr, ptr %82, i64 %84
  %86 = load ptr, ptr %85, align 8, !tbaa !13
  store ptr %86, ptr %11, align 8, !tbaa !13
  %87 = load ptr, ptr %11, align 8, !tbaa !13
  %88 = load i32, ptr %10, align 4, !tbaa !15
  %89 = sext i32 %88 to i64
  %90 = getelementptr inbounds double, ptr %87, i64 %89
  %91 = load double, ptr %90, align 8, !tbaa !16
  store double %91, ptr %5, align 8, !tbaa !16
  %92 = load i32, ptr %10, align 4, !tbaa !15
  %93 = load i32, ptr %6, align 4, !tbaa !15
  %94 = icmp ne i32 %92, %93
  br i1 %94, label %95, label %110

95:                                               ; preds = %81
  %96 = load ptr, ptr %11, align 8, !tbaa !13
  %97 = load i32, ptr %6, align 4, !tbaa !15
  %98 = sext i32 %97 to i64
  %99 = getelementptr inbounds double, ptr %96, i64 %98
  %100 = load double, ptr %99, align 8, !tbaa !16
  %101 = load ptr, ptr %11, align 8, !tbaa !13
  %102 = load i32, ptr %10, align 4, !tbaa !15
  %103 = sext i32 %102 to i64
  %104 = getelementptr inbounds double, ptr %101, i64 %103
  store double %100, ptr %104, align 8, !tbaa !16
  %105 = load double, ptr %5, align 8, !tbaa !16
  %106 = load ptr, ptr %11, align 8, !tbaa !13
  %107 = load i32, ptr %6, align 4, !tbaa !15
  %108 = sext i32 %107 to i64
  %109 = getelementptr inbounds double, ptr %106, i64 %108
  store double %105, ptr %109, align 8, !tbaa !16
  br label %110

110:                                              ; preds = %95, %81
  %111 = load i32, ptr %9, align 4, !tbaa !15
  %112 = sub nsw i32 2000, %111
  %113 = load double, ptr %5, align 8, !tbaa !16
  %114 = load ptr, ptr %8, align 8, !tbaa !13
  %115 = load i32, ptr %9, align 4, !tbaa !15
  %116 = load ptr, ptr %11, align 8, !tbaa !13
  %117 = load i32, ptr %9, align 4, !tbaa !15
  call void @daxpy(i32 noundef %112, double noundef %113, ptr noundef %114, i32 noundef %115, i32 noundef 1, ptr noundef %116, i32 noundef %117, i32 noundef 1)
  call void @llvm.lifetime.end.p0(ptr %11) #7
  br label %118

118:                                              ; preds = %110
  %119 = load i32, ptr %7, align 4, !tbaa !15
  %120 = add nsw i32 %119, 1
  store i32 %120, ptr %7, align 4, !tbaa !15
  br label %78, !llvm.loop !32

121:                                              ; preds = %78
  br label %122

122:                                              ; preds = %121, %15
  call void @llvm.lifetime.end.p0(ptr %10) #7
  call void @llvm.lifetime.end.p0(ptr %9) #7
  call void @llvm.lifetime.end.p0(ptr %8) #7
  br label %123

123:                                              ; preds = %122
  %124 = load i32, ptr %6, align 4, !tbaa !15
  %125 = add nsw i32 %124, 1
  store i32 %125, ptr %6, align 4, !tbaa !15
  br label %12, !llvm.loop !33

126:                                              ; preds = %12
  %127 = load ptr, ptr %4, align 8, !tbaa !30
  %128 = getelementptr inbounds i32, ptr %127, i64 1999
  store i32 1999, ptr %128, align 4, !tbaa !15
  call void @llvm.lifetime.end.p0(ptr %7) #7
  call void @llvm.lifetime.end.p0(ptr %6) #7
  call void @llvm.lifetime.end.p0(ptr %5) #7
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local void @dgesl(ptr noundef %0, ptr noundef %1, ptr noundef %2) #0 {
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca double, align 8
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  %11 = alloca i32, align 4
  store ptr %0, ptr %4, align 8, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !30
  store ptr %2, ptr %6, align 8, !tbaa !13
  call void @llvm.lifetime.start.p0(ptr %7) #7
  call void @llvm.lifetime.start.p0(ptr %8) #7
  call void @llvm.lifetime.start.p0(ptr %9) #7
  store i32 0, ptr %8, align 4, !tbaa !15
  br label %12

12:                                               ; preds = %58, %3
  %13 = load i32, ptr %8, align 4, !tbaa !15
  %14 = icmp slt i32 %13, 1999
  br i1 %14, label %15, label %61

15:                                               ; preds = %12
  call void @llvm.lifetime.start.p0(ptr %10) #7
  %16 = load ptr, ptr %5, align 8, !tbaa !30
  %17 = load i32, ptr %8, align 4, !tbaa !15
  %18 = sext i32 %17 to i64
  %19 = getelementptr inbounds i32, ptr %16, i64 %18
  %20 = load i32, ptr %19, align 4, !tbaa !15
  store i32 %20, ptr %10, align 4, !tbaa !15
  %21 = load ptr, ptr %6, align 8, !tbaa !13
  %22 = load i32, ptr %10, align 4, !tbaa !15
  %23 = sext i32 %22 to i64
  %24 = getelementptr inbounds double, ptr %21, i64 %23
  %25 = load double, ptr %24, align 8, !tbaa !16
  store double %25, ptr %7, align 8, !tbaa !16
  %26 = load i32, ptr %10, align 4, !tbaa !15
  %27 = load i32, ptr %8, align 4, !tbaa !15
  %28 = icmp ne i32 %26, %27
  br i1 %28, label %29, label %44

29:                                               ; preds = %15
  %30 = load ptr, ptr %6, align 8, !tbaa !13
  %31 = load i32, ptr %8, align 4, !tbaa !15
  %32 = sext i32 %31 to i64
  %33 = getelementptr inbounds double, ptr %30, i64 %32
  %34 = load double, ptr %33, align 8, !tbaa !16
  %35 = load ptr, ptr %6, align 8, !tbaa !13
  %36 = load i32, ptr %10, align 4, !tbaa !15
  %37 = sext i32 %36 to i64
  %38 = getelementptr inbounds double, ptr %35, i64 %37
  store double %34, ptr %38, align 8, !tbaa !16
  %39 = load double, ptr %7, align 8, !tbaa !16
  %40 = load ptr, ptr %6, align 8, !tbaa !13
  %41 = load i32, ptr %8, align 4, !tbaa !15
  %42 = sext i32 %41 to i64
  %43 = getelementptr inbounds double, ptr %40, i64 %42
  store double %39, ptr %43, align 8, !tbaa !16
  br label %44

44:                                               ; preds = %29, %15
  call void @llvm.lifetime.start.p0(ptr %11) #7
  %45 = load i32, ptr %8, align 4, !tbaa !15
  %46 = add nsw i32 %45, 1
  store i32 %46, ptr %11, align 4, !tbaa !15
  %47 = load i32, ptr %11, align 4, !tbaa !15
  %48 = sub nsw i32 2000, %47
  %49 = load double, ptr %7, align 8, !tbaa !16
  %50 = load ptr, ptr %4, align 8, !tbaa !9
  %51 = load i32, ptr %8, align 4, !tbaa !15
  %52 = sext i32 %51 to i64
  %53 = getelementptr inbounds ptr, ptr %50, i64 %52
  %54 = load ptr, ptr %53, align 8, !tbaa !13
  %55 = load i32, ptr %11, align 4, !tbaa !15
  %56 = load ptr, ptr %6, align 8, !tbaa !13
  %57 = load i32, ptr %11, align 4, !tbaa !15
  call void @daxpy(i32 noundef %48, double noundef %49, ptr noundef %54, i32 noundef %55, i32 noundef 1, ptr noundef %56, i32 noundef %57, i32 noundef 1)
  call void @llvm.lifetime.end.p0(ptr %11) #7
  call void @llvm.lifetime.end.p0(ptr %10) #7
  br label %58

58:                                               ; preds = %44
  %59 = load i32, ptr %8, align 4, !tbaa !15
  %60 = add nsw i32 %59, 1
  store i32 %60, ptr %8, align 4, !tbaa !15
  br label %12, !llvm.loop !34

61:                                               ; preds = %12
  store i32 0, ptr %9, align 4, !tbaa !15
  br label %62

62:                                               ; preds = %98, %61
  %63 = load i32, ptr %9, align 4, !tbaa !15
  %64 = icmp slt i32 %63, 2000
  br i1 %64, label %65, label %101

65:                                               ; preds = %62
  %66 = load i32, ptr %9, align 4, !tbaa !15
  %67 = add nsw i32 %66, 1
  %68 = sub nsw i32 2000, %67
  store i32 %68, ptr %8, align 4, !tbaa !15
  %69 = load ptr, ptr %4, align 8, !tbaa !9
  %70 = load i32, ptr %8, align 4, !tbaa !15
  %71 = sext i32 %70 to i64
  %72 = getelementptr inbounds ptr, ptr %69, i64 %71
  %73 = load ptr, ptr %72, align 8, !tbaa !13
  %74 = load i32, ptr %8, align 4, !tbaa !15
  %75 = sext i32 %74 to i64
  %76 = getelementptr inbounds double, ptr %73, i64 %75
  %77 = load double, ptr %76, align 8, !tbaa !16
  %78 = load ptr, ptr %6, align 8, !tbaa !13
  %79 = load i32, ptr %8, align 4, !tbaa !15
  %80 = sext i32 %79 to i64
  %81 = getelementptr inbounds double, ptr %78, i64 %80
  %82 = load double, ptr %81, align 8, !tbaa !16
  %83 = fdiv double %82, %77
  store double %83, ptr %81, align 8, !tbaa !16
  %84 = load ptr, ptr %6, align 8, !tbaa !13
  %85 = load i32, ptr %8, align 4, !tbaa !15
  %86 = sext i32 %85 to i64
  %87 = getelementptr inbounds double, ptr %84, i64 %86
  %88 = load double, ptr %87, align 8, !tbaa !16
  %89 = fneg double %88
  store double %89, ptr %7, align 8, !tbaa !16
  %90 = load i32, ptr %8, align 4, !tbaa !15
  %91 = load double, ptr %7, align 8, !tbaa !16
  %92 = load ptr, ptr %4, align 8, !tbaa !9
  %93 = load i32, ptr %8, align 4, !tbaa !15
  %94 = sext i32 %93 to i64
  %95 = getelementptr inbounds ptr, ptr %92, i64 %94
  %96 = load ptr, ptr %95, align 8, !tbaa !13
  %97 = load ptr, ptr %6, align 8, !tbaa !13
  call void @daxpy(i32 noundef %90, double noundef %91, ptr noundef %96, i32 noundef 0, i32 noundef 1, ptr noundef %97, i32 noundef 0, i32 noundef 1)
  br label %98

98:                                               ; preds = %65
  %99 = load i32, ptr %9, align 4, !tbaa !15
  %100 = add nsw i32 %99, 1
  store i32 %100, ptr %9, align 4, !tbaa !15
  br label %62, !llvm.loop !35

101:                                              ; preds = %62
  call void @llvm.lifetime.end.p0(ptr %9) #7
  call void @llvm.lifetime.end.p0(ptr %8) #7
  call void @llvm.lifetime.end.p0(ptr %7) #7
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i8, align 1
  %8 = alloca ptr, align 8
  %9 = alloca ptr, align 8
  %10 = alloca ptr, align 8
  %11 = alloca ptr, align 8
  %12 = alloca double, align 8
  %13 = alloca double, align 8
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !15
  store ptr %1, ptr %5, align 8, !tbaa !36
  call void @llvm.lifetime.start.p0(ptr %6) #7
  call void @llvm.lifetime.start.p0(ptr %7) #7
  store i8 0, ptr %7, align 1, !tbaa !38
  %14 = load i32, ptr %4, align 4, !tbaa !15
  %15 = icmp sgt i32 %14, 1
  br i1 %15, label %16, label %33

16:                                               ; preds = %2
  store i32 1, ptr %6, align 4, !tbaa !15
  br label %17

17:                                               ; preds = %29, %16
  %18 = load i32, ptr %6, align 4, !tbaa !15
  %19 = load i32, ptr %4, align 4, !tbaa !15
  %20 = icmp slt i32 %18, %19
  br i1 %20, label %21, label %32

21:                                               ; preds = %17
  %22 = load ptr, ptr %5, align 8, !tbaa !36
  %23 = getelementptr inbounds ptr, ptr %22, i64 1
  %24 = load ptr, ptr %23, align 8, !tbaa !40
  %25 = call i32 @strcmp(ptr noundef %24, ptr noundef @.str) #8
  %26 = icmp ne i32 %25, 0
  br i1 %26, label %28, label %27

27:                                               ; preds = %21
  store i8 1, ptr %7, align 1, !tbaa !38
  br label %32

28:                                               ; preds = %21
  br label %29

29:                                               ; preds = %28
  %30 = load i32, ptr %6, align 4, !tbaa !15
  %31 = add nsw i32 %30, 1
  store i32 %31, ptr %6, align 4, !tbaa !15
  br label %17, !llvm.loop !42

32:                                               ; preds = %27, %17
  br label %33

33:                                               ; preds = %32, %2
  call void @llvm.lifetime.start.p0(ptr %8) #7
  %34 = call noalias ptr @malloc(i64 noundef 16000) #9
  store ptr %34, ptr %8, align 8, !tbaa !9
  store i32 0, ptr %6, align 4, !tbaa !15
  br label %35

35:                                               ; preds = %44, %33
  %36 = load i32, ptr %6, align 4, !tbaa !15
  %37 = icmp slt i32 %36, 2000
  br i1 %37, label %38, label %47

38:                                               ; preds = %35
  %39 = call noalias ptr @malloc(i64 noundef 16008) #9
  %40 = load ptr, ptr %8, align 8, !tbaa !9
  %41 = load i32, ptr %6, align 4, !tbaa !15
  %42 = sext i32 %41 to i64
  %43 = getelementptr inbounds ptr, ptr %40, i64 %42
  store ptr %39, ptr %43, align 8, !tbaa !13
  br label %44

44:                                               ; preds = %38
  %45 = load i32, ptr %6, align 4, !tbaa !15
  %46 = add nsw i32 %45, 1
  store i32 %46, ptr %6, align 4, !tbaa !15
  br label %35, !llvm.loop !43

47:                                               ; preds = %35
  call void @llvm.lifetime.start.p0(ptr %9) #7
  %48 = call noalias ptr @malloc(i64 noundef 16000) #9
  store ptr %48, ptr %9, align 8, !tbaa !13
  call void @llvm.lifetime.start.p0(ptr %10) #7
  %49 = call noalias ptr @malloc(i64 noundef 16000) #9
  store ptr %49, ptr %10, align 8, !tbaa !13
  call void @llvm.lifetime.start.p0(ptr %11) #7
  %50 = call noalias ptr @malloc(i64 noundef 8000) #9
  store ptr %50, ptr %11, align 8, !tbaa !30
  call void @llvm.lifetime.start.p0(ptr %12) #7
  store double f0x41F3E5E475555555, ptr %12, align 8, !tbaa !16
  %51 = load ptr, ptr %8, align 8, !tbaa !9
  %52 = load ptr, ptr %9, align 8, !tbaa !13
  call void @matgen(ptr noundef %51, ptr noundef %52)
  %53 = load ptr, ptr %8, align 8, !tbaa !9
  %54 = load ptr, ptr %11, align 8, !tbaa !30
  call void @dgefa(ptr noundef %53, ptr noundef %54)
  %55 = load ptr, ptr %8, align 8, !tbaa !9
  %56 = load ptr, ptr %11, align 8, !tbaa !30
  %57 = load ptr, ptr %9, align 8, !tbaa !13
  call void @dgesl(ptr noundef %55, ptr noundef %56, ptr noundef %57)
  call void @llvm.lifetime.start.p0(ptr %13) #7
  store double 0.000000e+00, ptr %13, align 8, !tbaa !16
  %58 = load ptr, ptr %11, align 8, !tbaa !30
  call void @free(ptr noundef %58) #7
  %59 = load ptr, ptr %10, align 8, !tbaa !13
  call void @free(ptr noundef %59) #7
  %60 = load ptr, ptr %9, align 8, !tbaa !13
  call void @free(ptr noundef %60) #7
  store i32 0, ptr %6, align 4, !tbaa !15
  br label %61

61:                                               ; preds = %70, %47
  %62 = load i32, ptr %6, align 4, !tbaa !15
  %63 = icmp slt i32 %62, 2000
  br i1 %63, label %64, label %73

64:                                               ; preds = %61
  %65 = load ptr, ptr %8, align 8, !tbaa !9
  %66 = load i32, ptr %6, align 4, !tbaa !15
  %67 = sext i32 %66 to i64
  %68 = getelementptr inbounds ptr, ptr %65, i64 %67
  %69 = load ptr, ptr %68, align 8, !tbaa !13
  call void @free(ptr noundef %69) #7
  br label %70

70:                                               ; preds = %64
  %71 = load i32, ptr %6, align 4, !tbaa !15
  %72 = add nsw i32 %71, 1
  store i32 %72, ptr %6, align 4, !tbaa !15
  br label %61, !llvm.loop !44

73:                                               ; preds = %61
  %74 = load ptr, ptr %8, align 8, !tbaa !9
  call void @free(ptr noundef %74) #7
  %75 = load i8, ptr %7, align 1, !tbaa !38, !range !45, !noundef !46
  %76 = trunc i8 %75 to i1
  br i1 %76, label %77, label %81

77:                                               ; preds = %73
  %78 = load ptr, ptr @stdout, align 8, !tbaa !47
  %79 = load double, ptr %13, align 8, !tbaa !16
  %80 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %78, ptr noundef @.str.1, double noundef %79) #7
  br label %85

81:                                               ; preds = %73
  %82 = load ptr, ptr @stdout, align 8, !tbaa !47
  %83 = load double, ptr %13, align 8, !tbaa !16
  %84 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %82, ptr noundef @.str.2, double noundef %83) #7
  br label %85

85:                                               ; preds = %81, %77
  %86 = load ptr, ptr @stdout, align 8, !tbaa !47
  %87 = call i32 @fflush(ptr noundef %86)
  call void @llvm.lifetime.end.p0(ptr %13) #7
  call void @llvm.lifetime.end.p0(ptr %12) #7
  call void @llvm.lifetime.end.p0(ptr %11) #7
  call void @llvm.lifetime.end.p0(ptr %10) #7
  call void @llvm.lifetime.end.p0(ptr %9) #7
  call void @llvm.lifetime.end.p0(ptr %8) #7
  call void @llvm.lifetime.end.p0(ptr %7) #7
  call void @llvm.lifetime.end.p0(ptr %6) #7
  ret i32 0
}

; Function Attrs: nounwind willreturn memory(read)
declare i32 @strcmp(ptr noundef, ptr noundef) #3

; Function Attrs: nounwind allocsize(0)
declare noalias ptr @malloc(i64 noundef) #4

; Function Attrs: nounwind
declare void @free(ptr noundef) #5

; Function Attrs: nounwind
declare i32 @fprintf(ptr noundef, ptr noundef, ...) #5

declare i32 @fflush(ptr noundef) #6

; Function Attrs: nounwind uwtable
define internal double @random_double() #0 {
  %1 = alloca i64, align 8
  %2 = alloca double, align 8
  call void @llvm.lifetime.start.p0(ptr %1) #7
  call void @llvm.lifetime.start.p0(ptr %2) #7
  %3 = load i64, ptr @seed, align 8, !tbaa !49
  %4 = xor i64 %3, 123459876
  store i64 %4, ptr @seed, align 8, !tbaa !49
  %5 = load i64, ptr @seed, align 8, !tbaa !49
  %6 = sdiv i64 %5, 127773
  store i64 %6, ptr %1, align 8, !tbaa !49
  %7 = load i64, ptr @seed, align 8, !tbaa !49
  %8 = load i64, ptr %1, align 8, !tbaa !49
  %9 = mul nsw i64 %8, 127773
  %10 = sub nsw i64 %7, %9
  %11 = mul nsw i64 16807, %10
  %12 = load i64, ptr %1, align 8, !tbaa !49
  %13 = mul nsw i64 2836, %12
  %14 = sub nsw i64 %11, %13
  store i64 %14, ptr @seed, align 8, !tbaa !49
  %15 = load i64, ptr @seed, align 8, !tbaa !49
  %16 = icmp slt i64 %15, 0
  br i1 %16, label %17, label %20

17:                                               ; preds = %0
  %18 = load i64, ptr @seed, align 8, !tbaa !49
  %19 = add nsw i64 %18, 2147483647
  store i64 %19, ptr @seed, align 8, !tbaa !49
  br label %20

20:                                               ; preds = %17, %0
  %21 = load i64, ptr @seed, align 8, !tbaa !49
  %22 = sitofp i64 %21 to double
  %23 = fmul double f0x3E00000000200FE1, %22
  store double %23, ptr %2, align 8, !tbaa !16
  %24 = load i64, ptr @seed, align 8, !tbaa !49
  %25 = xor i64 %24, 123459876
  store i64 %25, ptr @seed, align 8, !tbaa !49
  %26 = load double, ptr %2, align 8, !tbaa !16
  call void @llvm.lifetime.end.p0(ptr %2) #7
  call void @llvm.lifetime.end.p0(ptr %1) #7
  ret double %26
}

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #3 = { nounwind willreturn memory(read) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind allocsize(0) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #7 = { nounwind }
attributes #8 = { nounwind willreturn memory(read) }
attributes #9 = { nounwind allocsize(0) }

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
!10 = !{!"p2 double", !11, i64 0}
!11 = !{!"any p2 pointer", !12, i64 0}
!12 = !{!"any pointer", !7, i64 0}
!13 = !{!14, !14, i64 0}
!14 = !{!"p1 double", !12, i64 0}
!15 = !{!6, !6, i64 0}
!16 = !{!17, !17, i64 0}
!17 = !{!"double", !7, i64 0}
!18 = distinct !{!18, !19}
!19 = !{!"llvm.loop.mustprogress"}
!20 = distinct !{!20, !19}
!21 = distinct !{!21, !19}
!22 = distinct !{!22, !19}
!23 = distinct !{!23, !19}
!24 = distinct !{!24, !19}
!25 = distinct !{!25, !19}
!26 = distinct !{!26, !19}
!27 = distinct !{!27, !19}
!28 = distinct !{!28, !19}
!29 = distinct !{!29, !19}
!30 = !{!31, !31, i64 0}
!31 = !{!"p1 int", !12, i64 0}
!32 = distinct !{!32, !19}
!33 = distinct !{!33, !19}
!34 = distinct !{!34, !19}
!35 = distinct !{!35, !19}
!36 = !{!37, !37, i64 0}
!37 = !{!"p2 omnipotent char", !11, i64 0}
!38 = !{!39, !39, i64 0}
!39 = !{!"_Bool", !7, i64 0}
!40 = !{!41, !41, i64 0}
!41 = !{!"p1 omnipotent char", !12, i64 0}
!42 = distinct !{!42, !19}
!43 = distinct !{!43, !19}
!44 = distinct !{!44, !19}
!45 = !{i8 0, i8 2}
!46 = !{}
!47 = !{!48, !48, i64 0}
!48 = !{!"p1 _ZTS8_IO_FILE", !12, i64 0}
!49 = !{!50, !50, i64 0}
!50 = !{!"long", !7, i64 0}
