; @source: tests/e2e/src/structs/array_of_structs.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/structs/array_of_structs.c'
source_filename = "tests/e2e/src/structs/array_of_structs.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.item = type { ptr, i32, double }

@.str = private unnamed_addr constant [6 x i8] c"%.2f\0A\00", align 1
@.str.1 = private unnamed_addr constant [4 x i8] c"%s\0A\00", align 1
@.str.2 = private unnamed_addr constant [6 x i8] c"apple\00", align 1
@.str.3 = private unnamed_addr constant [5 x i8] c"pear\00", align 1
@.str.4 = private unnamed_addr constant [4 x i8] c"fig\00", align 1
@.str.5 = private unnamed_addr constant [5 x i8] c"kiwi\00", align 1
@inv = internal global [4 x { ptr, i32, [4 x i8], double }] [{ ptr, i32, [4 x i8], double } { ptr @.str.2, i32 3, [4 x i8] zeroinitializer, double 5.000000e-01 }, { ptr, i32, [4 x i8], double } { ptr @.str.3, i32 10, [4 x i8] zeroinitializer, double 7.500000e-01 }, { ptr, i32, [4 x i8], double } { ptr @.str.4, i32 2, [4 x i8] zeroinitializer, double 2.250000e+00 }, { ptr, i32, [4 x i8], double } { ptr @.str.5, i32 7, [4 x i8] zeroinitializer, double 3.000000e-01 }], align 16

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca %struct.item, align 8
  %4 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store i32 0, ptr %2, align 4
  br label %5

5:                                                ; preds = %16, %0
  %6 = load i32, ptr %2, align 4
  %7 = icmp slt i32 %6, 4
  br i1 %7, label %8, label %19

8:                                                ; preds = %5
  %9 = load i32, ptr %2, align 4
  %10 = load i32, ptr %2, align 4
  %11 = sext i32 %10 to i64
  %12 = getelementptr inbounds [4 x %struct.item], ptr @inv, i64 0, i64 %11
  %13 = getelementptr inbounds nuw %struct.item, ptr %12, i32 0, i32 1
  %14 = load i32, ptr %13, align 8
  %15 = add nsw i32 %14, %9
  store i32 %15, ptr %13, align 8
  br label %16

16:                                               ; preds = %8
  %17 = load i32, ptr %2, align 4
  %18 = add nsw i32 %17, 1
  store i32 %18, ptr %2, align 4
  br label %5, !llvm.loop !5

19:                                               ; preds = %5
  %20 = call double @total(ptr noundef @inv, i32 noundef 4)
  %21 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %20)
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %3, ptr align 16 @inv, i64 24, i1 false)
  store i32 1, ptr %4, align 4
  br label %22

22:                                               ; preds = %50, %19
  %23 = load i32, ptr %4, align 4
  %24 = icmp slt i32 %23, 4
  br i1 %24, label %25, label %53

25:                                               ; preds = %22
  %26 = load i32, ptr %4, align 4
  %27 = sext i32 %26 to i64
  %28 = getelementptr inbounds [4 x %struct.item], ptr @inv, i64 0, i64 %27
  %29 = getelementptr inbounds nuw %struct.item, ptr %28, i32 0, i32 1
  %30 = load i32, ptr %29, align 8
  %31 = sitofp i32 %30 to double
  %32 = load i32, ptr %4, align 4
  %33 = sext i32 %32 to i64
  %34 = getelementptr inbounds [4 x %struct.item], ptr @inv, i64 0, i64 %33
  %35 = getelementptr inbounds nuw %struct.item, ptr %34, i32 0, i32 2
  %36 = load double, ptr %35, align 8
  %37 = fmul double %31, %36
  %38 = getelementptr inbounds nuw %struct.item, ptr %3, i32 0, i32 1
  %39 = load i32, ptr %38, align 8
  %40 = sitofp i32 %39 to double
  %41 = getelementptr inbounds nuw %struct.item, ptr %3, i32 0, i32 2
  %42 = load double, ptr %41, align 8
  %43 = fmul double %40, %42
  %44 = fcmp ogt double %37, %43
  br i1 %44, label %45, label %49

45:                                               ; preds = %25
  %46 = load i32, ptr %4, align 4
  %47 = sext i32 %46 to i64
  %48 = getelementptr inbounds [4 x %struct.item], ptr @inv, i64 0, i64 %47
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %3, ptr align 8 %48, i64 24, i1 false)
  br label %49

49:                                               ; preds = %45, %25
  br label %50

50:                                               ; preds = %49
  %51 = load i32, ptr %4, align 4
  %52 = add nsw i32 %51, 1
  store i32 %52, ptr %4, align 4
  br label %22, !llvm.loop !7

53:                                               ; preds = %22
  %54 = getelementptr inbounds nuw %struct.item, ptr %3, i32 0, i32 0
  %55 = load ptr, ptr %54, align 8
  %56 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, ptr noundef %55)
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: noinline nounwind uwtable
define internal double @total(ptr noundef %0, i32 noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca i32, align 4
  %5 = alloca double, align 8
  %6 = alloca i32, align 4
  store ptr %0, ptr %3, align 8
  store i32 %1, ptr %4, align 4
  store double 0.000000e+00, ptr %5, align 8
  store i32 0, ptr %6, align 4
  br label %7

7:                                                ; preds = %27, %2
  %8 = load i32, ptr %6, align 4
  %9 = load i32, ptr %4, align 4
  %10 = icmp slt i32 %8, %9
  br i1 %10, label %11, label %30

11:                                               ; preds = %7
  %12 = load ptr, ptr %3, align 8
  %13 = load i32, ptr %6, align 4
  %14 = sext i32 %13 to i64
  %15 = getelementptr inbounds %struct.item, ptr %12, i64 %14
  %16 = getelementptr inbounds nuw %struct.item, ptr %15, i32 0, i32 1
  %17 = load i32, ptr %16, align 8
  %18 = sitofp i32 %17 to double
  %19 = load ptr, ptr %3, align 8
  %20 = load i32, ptr %6, align 4
  %21 = sext i32 %20 to i64
  %22 = getelementptr inbounds %struct.item, ptr %19, i64 %21
  %23 = getelementptr inbounds nuw %struct.item, ptr %22, i32 0, i32 2
  %24 = load double, ptr %23, align 8
  %25 = load double, ptr %5, align 8
  %26 = call double @llvm.fmuladd.f64(double %18, double %24, double %25)
  store double %26, ptr %5, align 8
  br label %27

27:                                               ; preds = %11
  %28 = load i32, ptr %6, align 4
  %29 = add nsw i32 %28, 1
  store i32 %29, ptr %6, align 4
  br label %7, !llvm.loop !8

30:                                               ; preds = %7
  %31 = load double, ptr %5, align 8
  ret double %31
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #2

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #3

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #3 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }

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
