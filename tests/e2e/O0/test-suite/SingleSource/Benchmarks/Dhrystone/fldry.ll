; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Dhrystone/fldry.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Dhrystone/fldry.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Dhrystone/fldry.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.Record = type { ptr, i32, i32, double, [31 x i8] }

@Version = dso_local global [4 x i8] c"1.1\00", align 1
@.str = private unnamed_addr constant [53 x i8] c"calculate floating dhrystones using doubles size %d\0A\00", align 1
@PtrGlbNext = dso_local global ptr null, align 8
@PtrGlb = dso_local global ptr null, align 8
@.str.1 = private unnamed_addr constant [31 x i8] c"DHRYSTONE PROGRAM, SOME STRING\00", align 1
@.str.2 = private unnamed_addr constant [31 x i8] c"DHRYSTONE PROGRAM, 1'ST STRING\00", align 1
@Array2Glob = dso_local global [51 x [51 x double]] zeroinitializer, align 16
@.str.3 = private unnamed_addr constant [31 x i8] c"DHRYSTONE PROGRAM, 2'ND STRING\00", align 1
@BoolGlob = dso_local global i32 0, align 4
@Array1Glob = dso_local global [51 x double] zeroinitializer, align 16
@Char2Glob = dso_local global i8 0, align 1
@Char1Glob = dso_local global i8 0, align 1
@IntGlob = dso_local global double 0.000000e+00, align 8

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4
  store ptr %1, ptr %5, align 8
  %6 = call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef 8)
  %7 = call i32 @Proc0()
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @Proc0() #0 {
  %1 = alloca i32, align 4
  %2 = alloca double, align 8
  %3 = alloca double, align 8
  %4 = alloca double, align 8
  %5 = alloca i8, align 1
  %6 = alloca i8, align 1
  %7 = alloca i32, align 4
  %8 = alloca [31 x i8], align 16
  %9 = alloca [31 x i8], align 16
  %10 = alloca i32, align 4
  %11 = alloca i64, align 8
  %12 = alloca i64, align 8
  %13 = alloca i64, align 8
  %14 = call i64 @clock() #6
  store i64 %14, ptr %11, align 8
  store i32 0, ptr %10, align 4
  br label %15

15:                                               ; preds = %19, %0
  %16 = load i32, ptr %10, align 4
  %17 = icmp ult i32 %16, 100000000
  br i1 %17, label %18, label %22

18:                                               ; preds = %15
  br label %19

19:                                               ; preds = %18
  %20 = load i32, ptr %10, align 4
  %21 = add i32 %20, 1
  store i32 %21, ptr %10, align 4
  br label %15, !llvm.loop !5

22:                                               ; preds = %15
  %23 = call i64 @clock() #6
  %24 = load i64, ptr %11, align 8
  %25 = sub nsw i64 %23, %24
  store i64 %25, ptr %13, align 8
  %26 = call noalias ptr @malloc(i64 noundef 56) #7
  store ptr %26, ptr @PtrGlbNext, align 8
  %27 = call noalias ptr @malloc(i64 noundef 56) #7
  store ptr %27, ptr @PtrGlb, align 8
  %28 = load ptr, ptr @PtrGlbNext, align 8
  %29 = load ptr, ptr @PtrGlb, align 8
  %30 = getelementptr inbounds nuw %struct.Record, ptr %29, i32 0, i32 0
  store ptr %28, ptr %30, align 8
  %31 = load ptr, ptr @PtrGlb, align 8
  %32 = getelementptr inbounds nuw %struct.Record, ptr %31, i32 0, i32 1
  store i32 0, ptr %32, align 8
  %33 = load ptr, ptr @PtrGlb, align 8
  %34 = getelementptr inbounds nuw %struct.Record, ptr %33, i32 0, i32 2
  store i32 10001, ptr %34, align 4
  %35 = load ptr, ptr @PtrGlb, align 8
  %36 = getelementptr inbounds nuw %struct.Record, ptr %35, i32 0, i32 3
  store double 4.000000e+01, ptr %36, align 8
  %37 = load ptr, ptr @PtrGlb, align 8
  %38 = getelementptr inbounds nuw %struct.Record, ptr %37, i32 0, i32 4
  %39 = getelementptr inbounds [31 x i8], ptr %38, i64 0, i64 0
  %40 = call ptr @strcpy(ptr noundef %39, ptr noundef @.str.1) #6
  %41 = getelementptr inbounds [31 x i8], ptr %8, i64 0, i64 0
  %42 = call ptr @strcpy(ptr noundef %41, ptr noundef @.str.2) #6
  store double 1.000000e+01, ptr getelementptr inbounds nuw (i8, ptr @Array2Glob, i64 3320), align 8
  %43 = call i64 @clock() #6
  store i64 %43, ptr %11, align 8
  store i32 0, ptr %10, align 4
  br label %44

44:                                               ; preds = %110, %22
  %45 = load i32, ptr %10, align 4
  %46 = icmp ult i32 %45, 100000000
  br i1 %46, label %47, label %113

47:                                               ; preds = %44
  %48 = call i32 @Proc5()
  %49 = call i32 @Proc4()
  store double 2.000000e+00, ptr %2, align 8
  store double 3.000000e+00, ptr %3, align 8
  %50 = getelementptr inbounds [31 x i8], ptr %9, i64 0, i64 0
  %51 = call ptr @strcpy(ptr noundef %50, ptr noundef @.str.3) #6
  store i32 10000, ptr %7, align 4
  %52 = getelementptr inbounds [31 x i8], ptr %8, i64 0, i64 0
  %53 = getelementptr inbounds [31 x i8], ptr %9, i64 0, i64 0
  %54 = call i32 @Func2(ptr noundef %52, ptr noundef %53)
  %55 = icmp ne i32 %54, 0
  %56 = xor i1 %55, true
  %57 = zext i1 %56 to i32
  store i32 %57, ptr @BoolGlob, align 4
  br label %58

58:                                               ; preds = %62, %47
  %59 = load double, ptr %2, align 8
  %60 = load double, ptr %3, align 8
  %61 = fcmp olt double %59, %60
  br i1 %61, label %62, label %72

62:                                               ; preds = %58
  %63 = load double, ptr %2, align 8
  %64 = load double, ptr %3, align 8
  %65 = fneg double %64
  %66 = call double @llvm.fmuladd.f64(double 5.000000e+00, double %63, double %65)
  store double %66, ptr %4, align 8
  %67 = load double, ptr %2, align 8
  %68 = load double, ptr %3, align 8
  %69 = call i32 @Proc7(double noundef %67, double noundef %68, ptr noundef %4)
  %70 = load double, ptr %2, align 8
  %71 = fadd double %70, 1.000000e+00
  store double %71, ptr %2, align 8
  br label %58, !llvm.loop !7

72:                                               ; preds = %58
  %73 = load double, ptr %2, align 8
  %74 = load double, ptr %4, align 8
  %75 = call i32 @Proc8(ptr noundef @Array1Glob, ptr noundef @Array2Glob, double noundef %73, double noundef %74)
  %76 = load ptr, ptr @PtrGlb, align 8
  %77 = call i32 @Proc1(ptr noundef %76)
  store i8 65, ptr %6, align 1
  br label %78

78:                                               ; preds = %93, %72
  %79 = load i8, ptr %6, align 1
  %80 = sext i8 %79 to i32
  %81 = load i8, ptr @Char2Glob, align 1
  %82 = sext i8 %81 to i32
  %83 = icmp sle i32 %80, %82
  br i1 %83, label %84, label %96

84:                                               ; preds = %78
  %85 = load i32, ptr %7, align 4
  %86 = load i8, ptr %6, align 1
  %87 = sext i8 %86 to i32
  %88 = call i32 @Func1(i32 noundef %87, i32 noundef 67)
  %89 = icmp eq i32 %85, %88
  br i1 %89, label %90, label %92

90:                                               ; preds = %84
  %91 = call i32 @Proc6(i32 noundef 0, ptr noundef %7)
  br label %92

92:                                               ; preds = %90, %84
  br label %93

93:                                               ; preds = %92
  %94 = load i8, ptr %6, align 1
  %95 = add i8 %94, 1
  store i8 %95, ptr %6, align 1
  br label %78, !llvm.loop !8

96:                                               ; preds = %78
  %97 = load double, ptr %3, align 8
  %98 = load double, ptr %2, align 8
  %99 = fmul double %97, %98
  store double %99, ptr %4, align 8
  %100 = load double, ptr %4, align 8
  %101 = load double, ptr %2, align 8
  %102 = fdiv double %100, %101
  store double %102, ptr %3, align 8
  %103 = load double, ptr %4, align 8
  %104 = load double, ptr %3, align 8
  %105 = fsub double %103, %104
  %106 = load double, ptr %2, align 8
  %107 = fneg double %106
  %108 = call double @llvm.fmuladd.f64(double 7.000000e+00, double %105, double %107)
  store double %108, ptr %3, align 8
  %109 = call i32 @Proc2(ptr noundef %2)
  br label %110

110:                                              ; preds = %96
  %111 = load i32, ptr %10, align 4
  %112 = add i32 %111, 1
  store i32 %112, ptr %10, align 4
  br label %44, !llvm.loop !9

113:                                              ; preds = %44
  %114 = load i32, ptr %1, align 4
  ret i32 %114
}

; Function Attrs: nounwind
declare i64 @clock() #2

; Function Attrs: nounwind allocsize(0)
declare noalias ptr @malloc(i64 noundef) #3

; Function Attrs: nounwind
declare ptr @strcpy(ptr noundef, ptr noundef) #2

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #4

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @Proc1(ptr noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8
  %4 = load ptr, ptr %3, align 8
  %5 = getelementptr inbounds nuw %struct.Record, ptr %4, i32 0, i32 3
  store double 5.000000e+00, ptr %5, align 8
  %6 = load ptr, ptr %3, align 8
  %7 = getelementptr inbounds nuw %struct.Record, ptr %6, i32 0, i32 3
  %8 = load double, ptr %7, align 8
  %9 = load ptr, ptr %3, align 8
  %10 = getelementptr inbounds nuw %struct.Record, ptr %9, i32 0, i32 0
  %11 = load ptr, ptr %10, align 8
  %12 = getelementptr inbounds nuw %struct.Record, ptr %11, i32 0, i32 3
  store double %8, ptr %12, align 8
  %13 = load ptr, ptr %3, align 8
  %14 = getelementptr inbounds nuw %struct.Record, ptr %13, i32 0, i32 0
  %15 = load ptr, ptr %14, align 8
  %16 = load ptr, ptr %3, align 8
  %17 = getelementptr inbounds nuw %struct.Record, ptr %16, i32 0, i32 0
  %18 = load ptr, ptr %17, align 8
  %19 = getelementptr inbounds nuw %struct.Record, ptr %18, i32 0, i32 0
  store ptr %15, ptr %19, align 8
  %20 = load i32, ptr %2, align 4
  ret i32 %20
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @Proc2(ptr noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca ptr, align 8
  %4 = alloca double, align 8
  %5 = alloca i32, align 4
  store ptr %0, ptr %3, align 8
  %6 = load ptr, ptr %3, align 8
  %7 = load double, ptr %6, align 8
  %8 = fadd double %7, 1.000000e+01
  store double %8, ptr %4, align 8
  br label %9

9:                                                ; preds = %24, %1
  %10 = load i8, ptr @Char1Glob, align 1
  %11 = sext i8 %10 to i32
  %12 = icmp eq i32 %11, 65
  br i1 %12, label %13, label %20

13:                                               ; preds = %9
  %14 = load double, ptr %4, align 8
  %15 = fadd double %14, -1.000000e+00
  store double %15, ptr %4, align 8
  %16 = load double, ptr %4, align 8
  %17 = load double, ptr @IntGlob, align 8
  %18 = fsub double %16, %17
  %19 = load ptr, ptr %3, align 8
  store double %18, ptr %19, align 8
  store i32 0, ptr %5, align 4
  br label %20

20:                                               ; preds = %13, %9
  %21 = load i32, ptr %5, align 4
  %22 = icmp eq i32 %21, 0
  br i1 %22, label %23, label %24

23:                                               ; preds = %20
  br label %25

24:                                               ; preds = %20
  br label %9

25:                                               ; preds = %23
  %26 = load i32, ptr %2, align 4
  ret i32 %26
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @Proc3(ptr noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8
  %4 = load ptr, ptr @PtrGlb, align 8
  %5 = icmp ne ptr %4, null
  br i1 %5, label %6, label %11

6:                                                ; preds = %1
  %7 = load ptr, ptr @PtrGlb, align 8
  %8 = getelementptr inbounds nuw %struct.Record, ptr %7, i32 0, i32 0
  %9 = load ptr, ptr %8, align 8
  %10 = load ptr, ptr %3, align 8
  store ptr %9, ptr %10, align 8
  br label %12

11:                                               ; preds = %1
  store double 1.000000e+02, ptr @IntGlob, align 8
  br label %12

12:                                               ; preds = %11, %6
  %13 = load double, ptr @IntGlob, align 8
  %14 = load ptr, ptr @PtrGlb, align 8
  %15 = getelementptr inbounds nuw %struct.Record, ptr %14, i32 0, i32 3
  %16 = call i32 (i32, double, ptr, ...) @Proc7(i32 noundef 10, double noundef %13, ptr noundef %15)
  %17 = load i32, ptr %2, align 4
  ret i32 %17
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @Proc4() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = load i8, ptr @Char1Glob, align 1
  %4 = sext i8 %3 to i32
  %5 = icmp eq i32 %4, 65
  %6 = zext i1 %5 to i32
  store i32 %6, ptr %2, align 4
  %7 = load i32, ptr @BoolGlob, align 4
  %8 = load i32, ptr %2, align 4
  %9 = or i32 %8, %7
  store i32 %9, ptr %2, align 4
  store i8 66, ptr @Char2Glob, align 1
  %10 = load i32, ptr %1, align 4
  ret i32 %10
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @Proc5() #0 {
  %1 = alloca i32, align 4
  store i8 65, ptr @Char1Glob, align 1
  store i32 0, ptr @BoolGlob, align 4
  %2 = load i32, ptr %1, align 4
  ret i32 %2
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @Proc6(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  store i32 %0, ptr %4, align 4
  store ptr %1, ptr %5, align 8
  %6 = load i32, ptr %4, align 4
  %7 = load ptr, ptr %5, align 8
  store i32 %6, ptr %7, align 4
  %8 = load i32, ptr %4, align 4
  %9 = call i32 @Func3(i32 noundef %8)
  %10 = icmp ne i32 %9, 0
  br i1 %10, label %13, label %11

11:                                               ; preds = %2
  %12 = load ptr, ptr %5, align 8
  store i32 10002, ptr %12, align 4
  br label %13

13:                                               ; preds = %11, %2
  %14 = load i32, ptr %4, align 4
  switch i32 %14, label %30 [
    i32 0, label %15
    i32 10000, label %17
    i32 10001, label %25
    i32 10002, label %27
    i32 10003, label %28
  ]

15:                                               ; preds = %13
  %16 = load ptr, ptr %5, align 8
  store i32 0, ptr %16, align 4
  br label %30

17:                                               ; preds = %13
  %18 = load double, ptr @IntGlob, align 8
  %19 = fcmp ogt double %18, 1.000000e+02
  br i1 %19, label %20, label %22

20:                                               ; preds = %17
  %21 = load ptr, ptr %5, align 8
  store i32 0, ptr %21, align 4
  br label %24

22:                                               ; preds = %17
  %23 = load ptr, ptr %5, align 8
  store i32 10002, ptr %23, align 4
  br label %24

24:                                               ; preds = %22, %20
  br label %30

25:                                               ; preds = %13
  %26 = load ptr, ptr %5, align 8
  store i32 10000, ptr %26, align 4
  br label %30

27:                                               ; preds = %13
  br label %30

28:                                               ; preds = %13
  %29 = load ptr, ptr %5, align 8
  store i32 10001, ptr %29, align 4
  br label %30

30:                                               ; preds = %28, %13, %27, %25, %24, %15
  %31 = load i32, ptr %3, align 4
  ret i32 %31
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @Proc7(double noundef %0, double noundef %1, ptr noundef %2) #0 {
  %4 = alloca i32, align 4
  %5 = alloca double, align 8
  %6 = alloca double, align 8
  %7 = alloca ptr, align 8
  %8 = alloca double, align 8
  store double %0, ptr %5, align 8
  store double %1, ptr %6, align 8
  store ptr %2, ptr %7, align 8
  %9 = load double, ptr %5, align 8
  %10 = fadd double %9, 2.000000e+00
  store double %10, ptr %8, align 8
  %11 = load double, ptr %6, align 8
  %12 = load double, ptr %8, align 8
  %13 = fadd double %11, %12
  %14 = load ptr, ptr %7, align 8
  store double %13, ptr %14, align 8
  %15 = load i32, ptr %4, align 4
  ret i32 %15
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @Proc8(ptr noundef %0, ptr noundef %1, double noundef %2, double noundef %3) #0 {
  %5 = alloca i32, align 4
  %6 = alloca ptr, align 8
  %7 = alloca ptr, align 8
  %8 = alloca double, align 8
  %9 = alloca double, align 8
  %10 = alloca double, align 8
  %11 = alloca double, align 8
  store ptr %0, ptr %6, align 8
  store ptr %1, ptr %7, align 8
  store double %2, ptr %8, align 8
  store double %3, ptr %9, align 8
  %12 = load double, ptr %8, align 8
  %13 = fadd double %12, 5.000000e+00
  store double %13, ptr %10, align 8
  %14 = load double, ptr %9, align 8
  %15 = load ptr, ptr %6, align 8
  %16 = load double, ptr %10, align 8
  %17 = fptosi double %16 to i32
  %18 = sext i32 %17 to i64
  %19 = getelementptr inbounds double, ptr %15, i64 %18
  store double %14, ptr %19, align 8
  %20 = load ptr, ptr %6, align 8
  %21 = load double, ptr %10, align 8
  %22 = fptosi double %21 to i32
  %23 = sext i32 %22 to i64
  %24 = getelementptr inbounds double, ptr %20, i64 %23
  %25 = load double, ptr %24, align 8
  %26 = load ptr, ptr %6, align 8
  %27 = load double, ptr %10, align 8
  %28 = fptosi double %27 to i32
  %29 = add nsw i32 %28, 1
  %30 = sext i32 %29 to i64
  %31 = getelementptr inbounds double, ptr %26, i64 %30
  store double %25, ptr %31, align 8
  %32 = load double, ptr %10, align 8
  %33 = load ptr, ptr %6, align 8
  %34 = load double, ptr %10, align 8
  %35 = fptosi double %34 to i32
  %36 = add nsw i32 %35, 30
  %37 = sext i32 %36 to i64
  %38 = getelementptr inbounds double, ptr %33, i64 %37
  store double %32, ptr %38, align 8
  %39 = load double, ptr %10, align 8
  store double %39, ptr %11, align 8
  br label %40

40:                                               ; preds = %56, %4
  %41 = load double, ptr %11, align 8
  %42 = load double, ptr %10, align 8
  %43 = fadd double %42, 1.000000e+00
  %44 = fcmp ole double %41, %43
  br i1 %44, label %45, label %59

45:                                               ; preds = %40
  %46 = load double, ptr %10, align 8
  %47 = load ptr, ptr %7, align 8
  %48 = load double, ptr %10, align 8
  %49 = fptosi double %48 to i32
  %50 = sext i32 %49 to i64
  %51 = getelementptr inbounds [51 x double], ptr %47, i64 %50
  %52 = load double, ptr %11, align 8
  %53 = fptosi double %52 to i32
  %54 = sext i32 %53 to i64
  %55 = getelementptr inbounds [51 x double], ptr %51, i64 0, i64 %54
  store double %46, ptr %55, align 8
  br label %56

56:                                               ; preds = %45
  %57 = load double, ptr %11, align 8
  %58 = fadd double %57, 1.000000e+00
  store double %58, ptr %11, align 8
  br label %40, !llvm.loop !10

59:                                               ; preds = %40
  %60 = load ptr, ptr %7, align 8
  %61 = load double, ptr %10, align 8
  %62 = fptosi double %61 to i32
  %63 = sext i32 %62 to i64
  %64 = getelementptr inbounds [51 x double], ptr %60, i64 %63
  %65 = load double, ptr %10, align 8
  %66 = fptosi double %65 to i32
  %67 = sub nsw i32 %66, 1
  %68 = sext i32 %67 to i64
  %69 = getelementptr inbounds [51 x double], ptr %64, i64 0, i64 %68
  %70 = load double, ptr %69, align 8
  %71 = fadd double %70, 1.000000e+00
  store double %71, ptr %69, align 8
  %72 = load ptr, ptr %6, align 8
  %73 = load double, ptr %10, align 8
  %74 = fptosi double %73 to i32
  %75 = sext i32 %74 to i64
  %76 = getelementptr inbounds double, ptr %72, i64 %75
  %77 = load double, ptr %76, align 8
  %78 = load ptr, ptr %7, align 8
  %79 = load double, ptr %10, align 8
  %80 = fptosi double %79 to i32
  %81 = add nsw i32 %80, 20
  %82 = sext i32 %81 to i64
  %83 = getelementptr inbounds [51 x double], ptr %78, i64 %82
  %84 = load double, ptr %10, align 8
  %85 = fptosi double %84 to i32
  %86 = sext i32 %85 to i64
  %87 = getelementptr inbounds [51 x double], ptr %83, i64 0, i64 %86
  store double %77, ptr %87, align 8
  store double 5.000000e+00, ptr @IntGlob, align 8
  %88 = load i32, ptr %5, align 4
  ret i32 %88
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @Func1(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i8, align 1
  %5 = alloca i8, align 1
  %6 = alloca i8, align 1
  %7 = alloca i8, align 1
  %8 = trunc i32 %0 to i8
  %9 = trunc i32 %1 to i8
  store i8 %8, ptr %4, align 1
  store i8 %9, ptr %5, align 1
  %10 = load i8, ptr %4, align 1
  store i8 %10, ptr %6, align 1
  %11 = load i8, ptr %6, align 1
  store i8 %11, ptr %7, align 1
  %12 = load i8, ptr %7, align 1
  %13 = sext i8 %12 to i32
  %14 = load i8, ptr %5, align 1
  %15 = sext i8 %14 to i32
  %16 = icmp ne i32 %13, %15
  br i1 %16, label %17, label %18

17:                                               ; preds = %2
  store i32 0, ptr %3, align 4
  br label %19

18:                                               ; preds = %2
  store i32 10000, ptr %3, align 4
  br label %19

19:                                               ; preds = %18, %17
  %20 = load i32, ptr %3, align 4
  ret i32 %20
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @Func2(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  %6 = alloca double, align 8
  %7 = alloca i8, align 1
  store ptr %0, ptr %4, align 8
  store ptr %1, ptr %5, align 8
  store double 1.000000e+00, ptr %6, align 8
  br label %8

8:                                                ; preds = %32, %2
  %9 = load double, ptr %6, align 8
  %10 = fcmp ole double %9, 1.000000e+00
  br i1 %10, label %11, label %33

11:                                               ; preds = %8
  %12 = load ptr, ptr %4, align 8
  %13 = load double, ptr %6, align 8
  %14 = fptosi double %13 to i32
  %15 = sext i32 %14 to i64
  %16 = getelementptr inbounds i8, ptr %12, i64 %15
  %17 = load i8, ptr %16, align 1
  %18 = sext i8 %17 to i32
  %19 = load ptr, ptr %5, align 8
  %20 = load double, ptr %6, align 8
  %21 = fptosi double %20 to i32
  %22 = add nsw i32 %21, 1
  %23 = sext i32 %22 to i64
  %24 = getelementptr inbounds i8, ptr %19, i64 %23
  %25 = load i8, ptr %24, align 1
  %26 = sext i8 %25 to i32
  %27 = call i32 @Func1(i32 noundef %18, i32 noundef %26)
  %28 = icmp eq i32 %27, 0
  br i1 %28, label %29, label %32

29:                                               ; preds = %11
  store i8 65, ptr %7, align 1
  %30 = load double, ptr %6, align 8
  %31 = fadd double %30, 1.000000e+00
  store double %31, ptr %6, align 8
  br label %32

32:                                               ; preds = %29, %11
  br label %8, !llvm.loop !11

33:                                               ; preds = %8
  %34 = load i8, ptr %7, align 1
  %35 = sext i8 %34 to i32
  %36 = icmp sge i32 %35, 87
  br i1 %36, label %37, label %42

37:                                               ; preds = %33
  %38 = load i8, ptr %7, align 1
  %39 = sext i8 %38 to i32
  %40 = icmp sle i32 %39, 90
  br i1 %40, label %41, label %42

41:                                               ; preds = %37
  store double 7.000000e+00, ptr %6, align 8
  br label %42

42:                                               ; preds = %41, %37, %33
  %43 = load i8, ptr %7, align 1
  %44 = sext i8 %43 to i32
  %45 = icmp eq i32 %44, 88
  br i1 %45, label %46, label %47

46:                                               ; preds = %42
  store i32 1, ptr %3, align 4
  br label %56

47:                                               ; preds = %42
  %48 = load ptr, ptr %4, align 8
  %49 = load ptr, ptr %5, align 8
  %50 = call i32 @strcmp(ptr noundef %48, ptr noundef %49) #8
  %51 = icmp sgt i32 %50, 0
  br i1 %51, label %52, label %55

52:                                               ; preds = %47
  %53 = load double, ptr %6, align 8
  %54 = fadd double %53, 7.000000e+00
  store double %54, ptr %6, align 8
  store i32 1, ptr %3, align 4
  br label %56

55:                                               ; preds = %47
  store i32 0, ptr %3, align 4
  br label %56

56:                                               ; preds = %55, %52, %46
  %57 = load i32, ptr %3, align 4
  ret i32 %57
}

; Function Attrs: nounwind willreturn memory(read)
declare i32 @strcmp(ptr noundef, ptr noundef) #5

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @Func3(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 %0, ptr %3, align 4
  %5 = load i32, ptr %3, align 4
  store i32 %5, ptr %4, align 4
  %6 = load i32, ptr %4, align 4
  %7 = icmp eq i32 %6, 10001
  br i1 %7, label %8, label %9

8:                                                ; preds = %1
  store i32 1, ptr %2, align 4
  br label %10

9:                                                ; preds = %1
  store i32 0, ptr %2, align 4
  br label %10

10:                                               ; preds = %9, %8
  %11 = load i32, ptr %2, align 4
  ret i32 %11
}

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nounwind "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind allocsize(0) "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #5 = { nounwind willreturn memory(read) "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { nounwind }
attributes #7 = { nounwind allocsize(0) }
attributes #8 = { nounwind willreturn memory(read) }

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
!11 = distinct !{!11, !6}
