; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Dhrystone/dry.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Dhrystone/dry.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Dhrystone/dry.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.Record = type { ptr, i32, i32, i32, [31 x i8] }

@Version = dso_local global [4 x i8] c"1.1\00", align 1
@PtrGlbNext = dso_local global ptr null, align 8
@PtrGlb = dso_local global ptr null, align 8
@.str = private unnamed_addr constant [31 x i8] c"DHRYSTONE PROGRAM, SOME STRING\00", align 1
@.str.1 = private unnamed_addr constant [31 x i8] c"DHRYSTONE PROGRAM, 1'ST STRING\00", align 1
@Array2Glob = dso_local global [51 x [51 x i32]] zeroinitializer, align 16
@.str.2 = private unnamed_addr constant [31 x i8] c"DHRYSTONE PROGRAM, 2'ND STRING\00", align 1
@BoolGlob = dso_local global i32 0, align 4
@Array1Glob = dso_local global [51 x i32] zeroinitializer, align 16
@Char2Glob = dso_local global i8 0, align 1
@Char1Glob = dso_local global i8 0, align 1
@IntGlob = dso_local global i32 0, align 4

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  %2 = call i32 @Proc0()
  ret i32 0
}

; Function Attrs: nounwind uwtable
define dso_local i32 @Proc0() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i8, align 1
  %6 = alloca i8, align 1
  %7 = alloca i32, align 4
  %8 = alloca [31 x i8], align 16
  %9 = alloca [31 x i8], align 16
  %10 = alloca i32, align 4
  %11 = alloca i64, align 8
  %12 = alloca i64, align 8
  %13 = alloca i64, align 8
  call void @llvm.lifetime.start.p0(ptr %2) #5
  call void @llvm.lifetime.start.p0(ptr %3) #5
  call void @llvm.lifetime.start.p0(ptr %4) #5
  call void @llvm.lifetime.start.p0(ptr %5) #5
  call void @llvm.lifetime.start.p0(ptr %6) #5
  call void @llvm.lifetime.start.p0(ptr %7) #5
  call void @llvm.lifetime.start.p0(ptr %8) #5
  call void @llvm.lifetime.start.p0(ptr %9) #5
  call void @llvm.lifetime.start.p0(ptr %10) #5
  call void @llvm.lifetime.start.p0(ptr %11) #5
  call void @llvm.lifetime.start.p0(ptr %12) #5
  call void @llvm.lifetime.start.p0(ptr %13) #5
  %14 = call i64 @clock() #5
  store i64 %14, ptr %11, align 8, !tbaa !9
  store i32 0, ptr %10, align 4, !tbaa !11
  br label %15

15:                                               ; preds = %19, %0
  %16 = load i32, ptr %10, align 4, !tbaa !11
  %17 = icmp ult i32 %16, 100000000
  br i1 %17, label %18, label %22

18:                                               ; preds = %15
  br label %19

19:                                               ; preds = %18
  %20 = load i32, ptr %10, align 4, !tbaa !11
  %21 = add i32 %20, 1
  store i32 %21, ptr %10, align 4, !tbaa !11
  br label %15, !llvm.loop !12

22:                                               ; preds = %15
  %23 = call i64 @clock() #5
  %24 = load i64, ptr %11, align 8, !tbaa !9
  %25 = sub nsw i64 %23, %24
  store i64 %25, ptr %13, align 8, !tbaa !9
  %26 = call noalias ptr @malloc(i64 noundef 56) #6
  store ptr %26, ptr @PtrGlbNext, align 8, !tbaa !14
  %27 = call noalias ptr @malloc(i64 noundef 56) #6
  store ptr %27, ptr @PtrGlb, align 8, !tbaa !14
  %28 = load ptr, ptr @PtrGlbNext, align 8, !tbaa !14
  %29 = load ptr, ptr @PtrGlb, align 8, !tbaa !14
  %30 = getelementptr inbounds nuw %struct.Record, ptr %29, i32 0, i32 0
  store ptr %28, ptr %30, align 8, !tbaa !17
  %31 = load ptr, ptr @PtrGlb, align 8, !tbaa !14
  %32 = getelementptr inbounds nuw %struct.Record, ptr %31, i32 0, i32 1
  store i32 0, ptr %32, align 8, !tbaa !19
  %33 = load ptr, ptr @PtrGlb, align 8, !tbaa !14
  %34 = getelementptr inbounds nuw %struct.Record, ptr %33, i32 0, i32 2
  store i32 10001, ptr %34, align 4, !tbaa !20
  %35 = load ptr, ptr @PtrGlb, align 8, !tbaa !14
  %36 = getelementptr inbounds nuw %struct.Record, ptr %35, i32 0, i32 3
  store i32 40, ptr %36, align 8, !tbaa !21
  %37 = load ptr, ptr @PtrGlb, align 8, !tbaa !14
  %38 = getelementptr inbounds nuw %struct.Record, ptr %37, i32 0, i32 4
  %39 = getelementptr inbounds [31 x i8], ptr %38, i64 0, i64 0
  %40 = call ptr @strcpy(ptr noundef %39, ptr noundef @.str) #5
  %41 = getelementptr inbounds [31 x i8], ptr %8, i64 0, i64 0
  %42 = call ptr @strcpy(ptr noundef %41, ptr noundef @.str.1) #5
  store i32 10, ptr getelementptr inbounds nuw (i8, ptr @Array2Glob, i64 1660), align 4, !tbaa !11
  %43 = call i64 @clock() #5
  store i64 %43, ptr %11, align 8, !tbaa !9
  store i32 0, ptr %10, align 4, !tbaa !11
  br label %44

44:                                               ; preds = %110, %22
  %45 = load i32, ptr %10, align 4, !tbaa !11
  %46 = icmp ult i32 %45, 100000000
  br i1 %46, label %47, label %113

47:                                               ; preds = %44
  %48 = call i32 @Proc5()
  %49 = call i32 @Proc4()
  store i32 2, ptr %2, align 4, !tbaa !11
  store i32 3, ptr %3, align 4, !tbaa !11
  %50 = getelementptr inbounds [31 x i8], ptr %9, i64 0, i64 0
  %51 = call ptr @strcpy(ptr noundef %50, ptr noundef @.str.2) #5
  store i32 10000, ptr %7, align 4, !tbaa !11
  %52 = getelementptr inbounds [31 x i8], ptr %8, i64 0, i64 0
  %53 = getelementptr inbounds [31 x i8], ptr %9, i64 0, i64 0
  %54 = call i32 @Func2(ptr noundef %52, ptr noundef %53)
  %55 = icmp ne i32 %54, 0
  %56 = xor i1 %55, true
  %57 = zext i1 %56 to i32
  store i32 %57, ptr @BoolGlob, align 4, !tbaa !11
  br label %58

58:                                               ; preds = %62, %47
  %59 = load i32, ptr %2, align 4, !tbaa !11
  %60 = load i32, ptr %3, align 4, !tbaa !11
  %61 = icmp slt i32 %59, %60
  br i1 %61, label %62, label %72

62:                                               ; preds = %58
  %63 = load i32, ptr %2, align 4, !tbaa !11
  %64 = mul nsw i32 5, %63
  %65 = load i32, ptr %3, align 4, !tbaa !11
  %66 = sub nsw i32 %64, %65
  store i32 %66, ptr %4, align 4, !tbaa !11
  %67 = load i32, ptr %2, align 4, !tbaa !11
  %68 = load i32, ptr %3, align 4, !tbaa !11
  %69 = call i32 @Proc7(i32 noundef %67, i32 noundef %68, ptr noundef %4)
  %70 = load i32, ptr %2, align 4, !tbaa !11
  %71 = add nsw i32 %70, 1
  store i32 %71, ptr %2, align 4, !tbaa !11
  br label %58, !llvm.loop !22

72:                                               ; preds = %58
  %73 = load i32, ptr %2, align 4, !tbaa !11
  %74 = load i32, ptr %4, align 4, !tbaa !11
  %75 = call i32 @Proc8(ptr noundef @Array1Glob, ptr noundef @Array2Glob, i32 noundef %73, i32 noundef %74)
  %76 = load ptr, ptr @PtrGlb, align 8, !tbaa !14
  %77 = call i32 @Proc1(ptr noundef %76)
  store i8 65, ptr %6, align 1, !tbaa !23
  br label %78

78:                                               ; preds = %93, %72
  %79 = load i8, ptr %6, align 1, !tbaa !23
  %80 = sext i8 %79 to i32
  %81 = load i8, ptr @Char2Glob, align 1, !tbaa !23
  %82 = sext i8 %81 to i32
  %83 = icmp sle i32 %80, %82
  br i1 %83, label %84, label %96

84:                                               ; preds = %78
  %85 = load i32, ptr %7, align 4, !tbaa !11
  %86 = load i8, ptr %6, align 1, !tbaa !23
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
  %94 = load i8, ptr %6, align 1, !tbaa !23
  %95 = add i8 %94, 1
  store i8 %95, ptr %6, align 1, !tbaa !23
  br label %78, !llvm.loop !24

96:                                               ; preds = %78
  %97 = load i32, ptr %3, align 4, !tbaa !11
  %98 = load i32, ptr %2, align 4, !tbaa !11
  %99 = mul nsw i32 %97, %98
  store i32 %99, ptr %4, align 4, !tbaa !11
  %100 = load i32, ptr %4, align 4, !tbaa !11
  %101 = load i32, ptr %2, align 4, !tbaa !11
  %102 = sdiv i32 %100, %101
  store i32 %102, ptr %3, align 4, !tbaa !11
  %103 = load i32, ptr %4, align 4, !tbaa !11
  %104 = load i32, ptr %3, align 4, !tbaa !11
  %105 = sub nsw i32 %103, %104
  %106 = mul nsw i32 7, %105
  %107 = load i32, ptr %2, align 4, !tbaa !11
  %108 = sub nsw i32 %106, %107
  store i32 %108, ptr %3, align 4, !tbaa !11
  %109 = call i32 @Proc2(ptr noundef %2)
  br label %110

110:                                              ; preds = %96
  %111 = load i32, ptr %10, align 4, !tbaa !11
  %112 = add i32 %111, 1
  store i32 %112, ptr %10, align 4, !tbaa !11
  br label %44, !llvm.loop !25

113:                                              ; preds = %44
  call void @llvm.lifetime.end.p0(ptr %13) #5
  call void @llvm.lifetime.end.p0(ptr %12) #5
  call void @llvm.lifetime.end.p0(ptr %11) #5
  call void @llvm.lifetime.end.p0(ptr %10) #5
  call void @llvm.lifetime.end.p0(ptr %9) #5
  call void @llvm.lifetime.end.p0(ptr %8) #5
  call void @llvm.lifetime.end.p0(ptr %7) #5
  call void @llvm.lifetime.end.p0(ptr %6) #5
  call void @llvm.lifetime.end.p0(ptr %5) #5
  call void @llvm.lifetime.end.p0(ptr %4) #5
  call void @llvm.lifetime.end.p0(ptr %3) #5
  call void @llvm.lifetime.end.p0(ptr %2) #5
  %114 = load i32, ptr %1, align 4
  ret i32 %114
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nounwind
declare i64 @clock() #2

; Function Attrs: nounwind allocsize(0)
declare noalias ptr @malloc(i64 noundef) #3

; Function Attrs: nounwind
declare ptr @strcpy(ptr noundef, ptr noundef) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local i32 @Proc1(ptr noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8, !tbaa !14
  %4 = load ptr, ptr %3, align 8, !tbaa !14
  %5 = getelementptr inbounds nuw %struct.Record, ptr %4, i32 0, i32 3
  store i32 5, ptr %5, align 8, !tbaa !21
  %6 = load ptr, ptr %3, align 8, !tbaa !14
  %7 = getelementptr inbounds nuw %struct.Record, ptr %6, i32 0, i32 3
  %8 = load i32, ptr %7, align 8, !tbaa !21
  %9 = load ptr, ptr %3, align 8, !tbaa !14
  %10 = getelementptr inbounds nuw %struct.Record, ptr %9, i32 0, i32 0
  %11 = load ptr, ptr %10, align 8, !tbaa !17
  %12 = getelementptr inbounds nuw %struct.Record, ptr %11, i32 0, i32 3
  store i32 %8, ptr %12, align 8, !tbaa !21
  %13 = load ptr, ptr %3, align 8, !tbaa !14
  %14 = getelementptr inbounds nuw %struct.Record, ptr %13, i32 0, i32 0
  %15 = load ptr, ptr %14, align 8, !tbaa !17
  %16 = load ptr, ptr %3, align 8, !tbaa !14
  %17 = getelementptr inbounds nuw %struct.Record, ptr %16, i32 0, i32 0
  %18 = load ptr, ptr %17, align 8, !tbaa !17
  %19 = getelementptr inbounds nuw %struct.Record, ptr %18, i32 0, i32 0
  store ptr %15, ptr %19, align 8, !tbaa !17
  %20 = load i32, ptr %2, align 4
  ret i32 %20
}

; Function Attrs: nounwind uwtable
define dso_local i32 @Proc2(ptr noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca ptr, align 8
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !26
  call void @llvm.lifetime.start.p0(ptr %4) #5
  call void @llvm.lifetime.start.p0(ptr %5) #5
  %6 = load ptr, ptr %3, align 8, !tbaa !26
  %7 = load i32, ptr %6, align 4, !tbaa !11
  %8 = add nsw i32 %7, 10
  store i32 %8, ptr %4, align 4, !tbaa !11
  br label %9

9:                                                ; preds = %24, %1
  %10 = load i8, ptr @Char1Glob, align 1, !tbaa !23
  %11 = sext i8 %10 to i32
  %12 = icmp eq i32 %11, 65
  br i1 %12, label %13, label %20

13:                                               ; preds = %9
  %14 = load i32, ptr %4, align 4, !tbaa !11
  %15 = add nsw i32 %14, -1
  store i32 %15, ptr %4, align 4, !tbaa !11
  %16 = load i32, ptr %4, align 4, !tbaa !11
  %17 = load i32, ptr @IntGlob, align 4, !tbaa !11
  %18 = sub nsw i32 %16, %17
  %19 = load ptr, ptr %3, align 8, !tbaa !26
  store i32 %18, ptr %19, align 4, !tbaa !11
  store i32 0, ptr %5, align 4, !tbaa !11
  br label %20

20:                                               ; preds = %13, %9
  %21 = load i32, ptr %5, align 4, !tbaa !11
  %22 = icmp eq i32 %21, 0
  br i1 %22, label %23, label %24

23:                                               ; preds = %20
  br label %25

24:                                               ; preds = %20
  br label %9

25:                                               ; preds = %23
  call void @llvm.lifetime.end.p0(ptr %5) #5
  call void @llvm.lifetime.end.p0(ptr %4) #5
  %26 = load i32, ptr %2, align 4
  ret i32 %26
}

; Function Attrs: nounwind uwtable
define dso_local i32 @Proc3(ptr noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8, !tbaa !28
  %4 = load ptr, ptr @PtrGlb, align 8, !tbaa !14
  %5 = icmp ne ptr %4, null
  br i1 %5, label %6, label %11

6:                                                ; preds = %1
  %7 = load ptr, ptr @PtrGlb, align 8, !tbaa !14
  %8 = getelementptr inbounds nuw %struct.Record, ptr %7, i32 0, i32 0
  %9 = load ptr, ptr %8, align 8, !tbaa !17
  %10 = load ptr, ptr %3, align 8, !tbaa !28
  store ptr %9, ptr %10, align 8, !tbaa !14
  br label %12

11:                                               ; preds = %1
  store i32 100, ptr @IntGlob, align 4, !tbaa !11
  br label %12

12:                                               ; preds = %11, %6
  %13 = load i32, ptr @IntGlob, align 4, !tbaa !11
  %14 = load ptr, ptr @PtrGlb, align 8, !tbaa !14
  %15 = getelementptr inbounds nuw %struct.Record, ptr %14, i32 0, i32 3
  %16 = call i32 @Proc7(i32 noundef 10, i32 noundef %13, ptr noundef %15)
  %17 = load i32, ptr %2, align 4
  ret i32 %17
}

; Function Attrs: nounwind uwtable
define dso_local i32 @Proc4() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #5
  %3 = load i8, ptr @Char1Glob, align 1, !tbaa !23
  %4 = sext i8 %3 to i32
  %5 = icmp eq i32 %4, 65
  %6 = zext i1 %5 to i32
  store i32 %6, ptr %2, align 4, !tbaa !11
  %7 = load i32, ptr @BoolGlob, align 4, !tbaa !11
  %8 = load i32, ptr %2, align 4, !tbaa !11
  %9 = or i32 %8, %7
  store i32 %9, ptr %2, align 4, !tbaa !11
  store i8 66, ptr @Char2Glob, align 1, !tbaa !23
  call void @llvm.lifetime.end.p0(ptr %2) #5
  %10 = load i32, ptr %1, align 4
  ret i32 %10
}

; Function Attrs: nounwind uwtable
define dso_local i32 @Proc5() #0 {
  %1 = alloca i32, align 4
  store i8 65, ptr @Char1Glob, align 1, !tbaa !23
  store i32 0, ptr @BoolGlob, align 4, !tbaa !11
  %2 = load i32, ptr %1, align 4
  ret i32 %2
}

; Function Attrs: nounwind uwtable
define dso_local i32 @Proc6(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  store i32 %0, ptr %4, align 4, !tbaa !11
  store ptr %1, ptr %5, align 8, !tbaa !31
  %6 = load i32, ptr %4, align 4, !tbaa !11
  %7 = load ptr, ptr %5, align 8, !tbaa !31
  store i32 %6, ptr %7, align 4, !tbaa !11
  %8 = load i32, ptr %4, align 4, !tbaa !11
  %9 = call i32 @Func3(i32 noundef %8)
  %10 = icmp ne i32 %9, 0
  br i1 %10, label %13, label %11

11:                                               ; preds = %2
  %12 = load ptr, ptr %5, align 8, !tbaa !31
  store i32 10002, ptr %12, align 4, !tbaa !11
  br label %13

13:                                               ; preds = %11, %2
  %14 = load i32, ptr %4, align 4, !tbaa !11
  switch i32 %14, label %29 [
    i32 0, label %15
    i32 10000, label %17
    i32 10001, label %25
    i32 10002, label %29
    i32 10003, label %27
  ]

15:                                               ; preds = %13
  %16 = load ptr, ptr %5, align 8, !tbaa !31
  store i32 0, ptr %16, align 4, !tbaa !11
  br label %29

17:                                               ; preds = %13
  %18 = load i32, ptr @IntGlob, align 4, !tbaa !11
  %19 = icmp sgt i32 %18, 100
  br i1 %19, label %20, label %22

20:                                               ; preds = %17
  %21 = load ptr, ptr %5, align 8, !tbaa !31
  store i32 0, ptr %21, align 4, !tbaa !11
  br label %24

22:                                               ; preds = %17
  %23 = load ptr, ptr %5, align 8, !tbaa !31
  store i32 10002, ptr %23, align 4, !tbaa !11
  br label %24

24:                                               ; preds = %22, %20
  br label %29

25:                                               ; preds = %13
  %26 = load ptr, ptr %5, align 8, !tbaa !31
  store i32 10000, ptr %26, align 4, !tbaa !11
  br label %29

27:                                               ; preds = %13
  %28 = load ptr, ptr %5, align 8, !tbaa !31
  store i32 10001, ptr %28, align 4, !tbaa !11
  br label %29

29:                                               ; preds = %27, %13, %13, %25, %24, %15
  %30 = load i32, ptr %3, align 4
  ret i32 %30
}

; Function Attrs: nounwind uwtable
define dso_local i32 @Proc7(i32 noundef %0, i32 noundef %1, ptr noundef %2) #0 {
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca ptr, align 8
  %8 = alloca i32, align 4
  store i32 %0, ptr %5, align 4, !tbaa !11
  store i32 %1, ptr %6, align 4, !tbaa !11
  store ptr %2, ptr %7, align 8, !tbaa !26
  call void @llvm.lifetime.start.p0(ptr %8) #5
  %9 = load i32, ptr %5, align 4, !tbaa !11
  %10 = add nsw i32 %9, 2
  store i32 %10, ptr %8, align 4, !tbaa !11
  %11 = load i32, ptr %6, align 4, !tbaa !11
  %12 = load i32, ptr %8, align 4, !tbaa !11
  %13 = add nsw i32 %11, %12
  %14 = load ptr, ptr %7, align 8, !tbaa !26
  store i32 %13, ptr %14, align 4, !tbaa !11
  call void @llvm.lifetime.end.p0(ptr %8) #5
  %15 = load i32, ptr %4, align 4
  ret i32 %15
}

; Function Attrs: nounwind uwtable
define dso_local i32 @Proc8(ptr noundef %0, ptr noundef %1, i32 noundef %2, i32 noundef %3) #0 {
  %5 = alloca i32, align 4
  %6 = alloca ptr, align 8
  %7 = alloca ptr, align 8
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  %11 = alloca i32, align 4
  store ptr %0, ptr %6, align 8, !tbaa !26
  store ptr %1, ptr %7, align 8, !tbaa !26
  store i32 %2, ptr %8, align 4, !tbaa !11
  store i32 %3, ptr %9, align 4, !tbaa !11
  call void @llvm.lifetime.start.p0(ptr %10) #5
  call void @llvm.lifetime.start.p0(ptr %11) #5
  %12 = load i32, ptr %8, align 4, !tbaa !11
  %13 = add nsw i32 %12, 5
  store i32 %13, ptr %10, align 4, !tbaa !11
  %14 = load i32, ptr %9, align 4, !tbaa !11
  %15 = load ptr, ptr %6, align 8, !tbaa !26
  %16 = load i32, ptr %10, align 4, !tbaa !11
  %17 = sext i32 %16 to i64
  %18 = getelementptr inbounds i32, ptr %15, i64 %17
  store i32 %14, ptr %18, align 4, !tbaa !11
  %19 = load ptr, ptr %6, align 8, !tbaa !26
  %20 = load i32, ptr %10, align 4, !tbaa !11
  %21 = sext i32 %20 to i64
  %22 = getelementptr inbounds i32, ptr %19, i64 %21
  %23 = load i32, ptr %22, align 4, !tbaa !11
  %24 = load ptr, ptr %6, align 8, !tbaa !26
  %25 = load i32, ptr %10, align 4, !tbaa !11
  %26 = add nsw i32 %25, 1
  %27 = sext i32 %26 to i64
  %28 = getelementptr inbounds i32, ptr %24, i64 %27
  store i32 %23, ptr %28, align 4, !tbaa !11
  %29 = load i32, ptr %10, align 4, !tbaa !11
  %30 = load ptr, ptr %6, align 8, !tbaa !26
  %31 = load i32, ptr %10, align 4, !tbaa !11
  %32 = add nsw i32 %31, 30
  %33 = sext i32 %32 to i64
  %34 = getelementptr inbounds i32, ptr %30, i64 %33
  store i32 %29, ptr %34, align 4, !tbaa !11
  %35 = load i32, ptr %10, align 4, !tbaa !11
  store i32 %35, ptr %11, align 4, !tbaa !11
  br label %36

36:                                               ; preds = %50, %4
  %37 = load i32, ptr %11, align 4, !tbaa !11
  %38 = load i32, ptr %10, align 4, !tbaa !11
  %39 = add nsw i32 %38, 1
  %40 = icmp sle i32 %37, %39
  br i1 %40, label %41, label %53

41:                                               ; preds = %36
  %42 = load i32, ptr %10, align 4, !tbaa !11
  %43 = load ptr, ptr %7, align 8, !tbaa !26
  %44 = load i32, ptr %10, align 4, !tbaa !11
  %45 = sext i32 %44 to i64
  %46 = getelementptr inbounds [51 x i32], ptr %43, i64 %45
  %47 = load i32, ptr %11, align 4, !tbaa !11
  %48 = sext i32 %47 to i64
  %49 = getelementptr inbounds [51 x i32], ptr %46, i64 0, i64 %48
  store i32 %42, ptr %49, align 4, !tbaa !11
  br label %50

50:                                               ; preds = %41
  %51 = load i32, ptr %11, align 4, !tbaa !11
  %52 = add nsw i32 %51, 1
  store i32 %52, ptr %11, align 4, !tbaa !11
  br label %36, !llvm.loop !32

53:                                               ; preds = %36
  %54 = load ptr, ptr %7, align 8, !tbaa !26
  %55 = load i32, ptr %10, align 4, !tbaa !11
  %56 = sext i32 %55 to i64
  %57 = getelementptr inbounds [51 x i32], ptr %54, i64 %56
  %58 = load i32, ptr %10, align 4, !tbaa !11
  %59 = sub nsw i32 %58, 1
  %60 = sext i32 %59 to i64
  %61 = getelementptr inbounds [51 x i32], ptr %57, i64 0, i64 %60
  %62 = load i32, ptr %61, align 4, !tbaa !11
  %63 = add nsw i32 %62, 1
  store i32 %63, ptr %61, align 4, !tbaa !11
  %64 = load ptr, ptr %6, align 8, !tbaa !26
  %65 = load i32, ptr %10, align 4, !tbaa !11
  %66 = sext i32 %65 to i64
  %67 = getelementptr inbounds i32, ptr %64, i64 %66
  %68 = load i32, ptr %67, align 4, !tbaa !11
  %69 = load ptr, ptr %7, align 8, !tbaa !26
  %70 = load i32, ptr %10, align 4, !tbaa !11
  %71 = add nsw i32 %70, 20
  %72 = sext i32 %71 to i64
  %73 = getelementptr inbounds [51 x i32], ptr %69, i64 %72
  %74 = load i32, ptr %10, align 4, !tbaa !11
  %75 = sext i32 %74 to i64
  %76 = getelementptr inbounds [51 x i32], ptr %73, i64 0, i64 %75
  store i32 %68, ptr %76, align 4, !tbaa !11
  store i32 5, ptr @IntGlob, align 4, !tbaa !11
  call void @llvm.lifetime.end.p0(ptr %11) #5
  call void @llvm.lifetime.end.p0(ptr %10) #5
  %77 = load i32, ptr %5, align 4
  ret i32 %77
}

; Function Attrs: nounwind uwtable
define dso_local i32 @Func1(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i8, align 1
  %5 = alloca i8, align 1
  %6 = alloca i8, align 1
  %7 = alloca i8, align 1
  %8 = alloca i32, align 4
  %9 = trunc i32 %0 to i8
  %10 = trunc i32 %1 to i8
  store i8 %9, ptr %4, align 1, !tbaa !23
  store i8 %10, ptr %5, align 1, !tbaa !23
  call void @llvm.lifetime.start.p0(ptr %6) #5
  call void @llvm.lifetime.start.p0(ptr %7) #5
  %11 = load i8, ptr %4, align 1, !tbaa !23
  store i8 %11, ptr %6, align 1, !tbaa !23
  %12 = load i8, ptr %6, align 1, !tbaa !23
  store i8 %12, ptr %7, align 1, !tbaa !23
  %13 = load i8, ptr %7, align 1, !tbaa !23
  %14 = sext i8 %13 to i32
  %15 = load i8, ptr %5, align 1, !tbaa !23
  %16 = sext i8 %15 to i32
  %17 = icmp ne i32 %14, %16
  br i1 %17, label %18, label %19

18:                                               ; preds = %2
  store i32 0, ptr %3, align 4
  store i32 1, ptr %8, align 4
  br label %20

19:                                               ; preds = %2
  store i32 10000, ptr %3, align 4
  store i32 1, ptr %8, align 4
  br label %20

20:                                               ; preds = %19, %18
  call void @llvm.lifetime.end.p0(ptr %7) #5
  call void @llvm.lifetime.end.p0(ptr %6) #5
  %21 = load i32, ptr %3, align 4
  ret i32 %21
}

; Function Attrs: nounwind uwtable
define dso_local i32 @Func2(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i8, align 1
  %8 = alloca i32, align 4
  store ptr %0, ptr %4, align 8, !tbaa !33
  store ptr %1, ptr %5, align 8, !tbaa !33
  call void @llvm.lifetime.start.p0(ptr %6) #5
  call void @llvm.lifetime.start.p0(ptr %7) #5
  store i32 1, ptr %6, align 4, !tbaa !11
  br label %9

9:                                                ; preds = %31, %2
  %10 = load i32, ptr %6, align 4, !tbaa !11
  %11 = icmp sle i32 %10, 1
  br i1 %11, label %12, label %32

12:                                               ; preds = %9
  %13 = load ptr, ptr %4, align 8, !tbaa !33
  %14 = load i32, ptr %6, align 4, !tbaa !11
  %15 = sext i32 %14 to i64
  %16 = getelementptr inbounds i8, ptr %13, i64 %15
  %17 = load i8, ptr %16, align 1, !tbaa !23
  %18 = sext i8 %17 to i32
  %19 = load ptr, ptr %5, align 8, !tbaa !33
  %20 = load i32, ptr %6, align 4, !tbaa !11
  %21 = add nsw i32 %20, 1
  %22 = sext i32 %21 to i64
  %23 = getelementptr inbounds i8, ptr %19, i64 %22
  %24 = load i8, ptr %23, align 1, !tbaa !23
  %25 = sext i8 %24 to i32
  %26 = call i32 @Func1(i32 noundef %18, i32 noundef %25)
  %27 = icmp eq i32 %26, 0
  br i1 %27, label %28, label %31

28:                                               ; preds = %12
  store i8 65, ptr %7, align 1, !tbaa !23
  %29 = load i32, ptr %6, align 4, !tbaa !11
  %30 = add nsw i32 %29, 1
  store i32 %30, ptr %6, align 4, !tbaa !11
  br label %31

31:                                               ; preds = %28, %12
  br label %9, !llvm.loop !35

32:                                               ; preds = %9
  %33 = load i8, ptr %7, align 1, !tbaa !23
  %34 = sext i8 %33 to i32
  %35 = icmp sge i32 %34, 87
  br i1 %35, label %36, label %41

36:                                               ; preds = %32
  %37 = load i8, ptr %7, align 1, !tbaa !23
  %38 = sext i8 %37 to i32
  %39 = icmp sle i32 %38, 90
  br i1 %39, label %40, label %41

40:                                               ; preds = %36
  store i32 7, ptr %6, align 4, !tbaa !11
  br label %41

41:                                               ; preds = %40, %36, %32
  %42 = load i8, ptr %7, align 1, !tbaa !23
  %43 = sext i8 %42 to i32
  %44 = icmp eq i32 %43, 88
  br i1 %44, label %45, label %46

45:                                               ; preds = %41
  store i32 1, ptr %3, align 4
  store i32 1, ptr %8, align 4
  br label %55

46:                                               ; preds = %41
  %47 = load ptr, ptr %4, align 8, !tbaa !33
  %48 = load ptr, ptr %5, align 8, !tbaa !33
  %49 = call i32 @strcmp(ptr noundef %47, ptr noundef %48) #7
  %50 = icmp sgt i32 %49, 0
  br i1 %50, label %51, label %54

51:                                               ; preds = %46
  %52 = load i32, ptr %6, align 4, !tbaa !11
  %53 = add nsw i32 %52, 7
  store i32 %53, ptr %6, align 4, !tbaa !11
  store i32 1, ptr %3, align 4
  store i32 1, ptr %8, align 4
  br label %55

54:                                               ; preds = %46
  store i32 0, ptr %3, align 4
  store i32 1, ptr %8, align 4
  br label %55

55:                                               ; preds = %54, %51, %45
  call void @llvm.lifetime.end.p0(ptr %7) #5
  call void @llvm.lifetime.end.p0(ptr %6) #5
  %56 = load i32, ptr %3, align 4
  ret i32 %56
}

; Function Attrs: nounwind willreturn memory(read)
declare i32 @strcmp(ptr noundef, ptr noundef) #4

; Function Attrs: nounwind uwtable
define dso_local i32 @Func3(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !11
  call void @llvm.lifetime.start.p0(ptr %4) #5
  %6 = load i32, ptr %3, align 4, !tbaa !11
  store i32 %6, ptr %4, align 4, !tbaa !11
  %7 = load i32, ptr %4, align 4, !tbaa !11
  %8 = icmp eq i32 %7, 10001
  br i1 %8, label %9, label %10

9:                                                ; preds = %1
  store i32 1, ptr %2, align 4
  store i32 1, ptr %5, align 4
  br label %11

10:                                               ; preds = %1
  store i32 0, ptr %2, align 4
  store i32 1, ptr %5, align 4
  br label %11

11:                                               ; preds = %10, %9
  call void @llvm.lifetime.end.p0(ptr %4) #5
  %12 = load i32, ptr %2, align 4
  ret i32 %12
}

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind allocsize(0) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind willreturn memory(read) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind }
attributes #6 = { nounwind allocsize(0) }
attributes #7 = { nounwind willreturn memory(read) }

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
!10 = !{!"long", !7, i64 0}
!11 = !{!6, !6, i64 0}
!12 = distinct !{!12, !13}
!13 = !{!"llvm.loop.mustprogress"}
!14 = !{!15, !15, i64 0}
!15 = !{!"p1 _ZTS6Record", !16, i64 0}
!16 = !{!"any pointer", !7, i64 0}
!17 = !{!18, !15, i64 0}
!18 = !{!"Record", !15, i64 0, !6, i64 8, !6, i64 12, !6, i64 16, !7, i64 20}
!19 = !{!18, !6, i64 8}
!20 = !{!18, !6, i64 12}
!21 = !{!18, !6, i64 16}
!22 = distinct !{!22, !13}
!23 = !{!7, !7, i64 0}
!24 = distinct !{!24, !13}
!25 = distinct !{!25, !13}
!26 = !{!27, !27, i64 0}
!27 = !{!"p1 int", !16, i64 0}
!28 = !{!29, !29, i64 0}
!29 = !{!"p2 _ZTS6Record", !30, i64 0}
!30 = !{!"any p2 pointer", !16, i64 0}
!31 = !{!16, !16, i64 0}
!32 = distinct !{!32, !13}
!33 = !{!34, !34, i64 0}
!34 = !{!"p1 omnipotent char", !16, i64 0}
!35 = distinct !{!35, !13}
