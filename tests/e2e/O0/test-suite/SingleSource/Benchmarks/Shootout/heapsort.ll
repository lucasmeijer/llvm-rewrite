; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/heapsort.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/heapsort.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/heapsort.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@gen_random.last = internal global i64 42, align 8
@.str = private unnamed_addr constant [4 x i8] c"%f\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local double @gen_random(double noundef %0) #0 {
  %2 = alloca double, align 8
  store double %0, ptr %2, align 8
  %3 = load double, ptr %2, align 8
  %4 = load i64, ptr @gen_random.last, align 8
  %5 = mul nsw i64 %4, 3877
  %6 = add nsw i64 %5, 29573
  %7 = srem i64 %6, 139968
  store i64 %7, ptr @gen_random.last, align 8
  %8 = sitofp i64 %7 to double
  %9 = fmul double %3, %8
  %10 = fdiv double %9, 1.399680e+05
  ret double %10
}

; Function Attrs: noinline nounwind uwtable
define dso_local void @benchmark_heapsort(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca double, align 8
  store i32 %0, ptr %3, align 4
  store ptr %1, ptr %4, align 8
  %10 = load i32, ptr %3, align 4
  store i32 %10, ptr %7, align 4
  %11 = load i32, ptr %3, align 4
  %12 = ashr i32 %11, 1
  %13 = add nsw i32 %12, 1
  store i32 %13, ptr %8, align 4
  br label %14

14:                                               ; preds = %98, %2
  %15 = load i32, ptr %8, align 4
  %16 = icmp sgt i32 %15, 1
  br i1 %16, label %17, label %24

17:                                               ; preds = %14
  %18 = load ptr, ptr %4, align 8
  %19 = load i32, ptr %8, align 4
  %20 = add nsw i32 %19, -1
  store i32 %20, ptr %8, align 4
  %21 = sext i32 %20 to i64
  %22 = getelementptr inbounds double, ptr %18, i64 %21
  %23 = load double, ptr %22, align 8
  store double %23, ptr %9, align 8
  br label %45

24:                                               ; preds = %14
  %25 = load ptr, ptr %4, align 8
  %26 = load i32, ptr %7, align 4
  %27 = sext i32 %26 to i64
  %28 = getelementptr inbounds double, ptr %25, i64 %27
  %29 = load double, ptr %28, align 8
  store double %29, ptr %9, align 8
  %30 = load ptr, ptr %4, align 8
  %31 = getelementptr inbounds double, ptr %30, i64 1
  %32 = load double, ptr %31, align 8
  %33 = load ptr, ptr %4, align 8
  %34 = load i32, ptr %7, align 4
  %35 = sext i32 %34 to i64
  %36 = getelementptr inbounds double, ptr %33, i64 %35
  store double %32, ptr %36, align 8
  %37 = load i32, ptr %7, align 4
  %38 = add nsw i32 %37, -1
  store i32 %38, ptr %7, align 4
  %39 = icmp eq i32 %38, 1
  br i1 %39, label %40, label %44

40:                                               ; preds = %24
  %41 = load double, ptr %9, align 8
  %42 = load ptr, ptr %4, align 8
  %43 = getelementptr inbounds double, ptr %42, i64 1
  store double %41, ptr %43, align 8
  ret void

44:                                               ; preds = %24
  br label %45

45:                                               ; preds = %44, %17
  %46 = load i32, ptr %8, align 4
  store i32 %46, ptr %5, align 4
  %47 = load i32, ptr %8, align 4
  %48 = shl i32 %47, 1
  store i32 %48, ptr %6, align 4
  br label %49

49:                                               ; preds = %97, %45
  %50 = load i32, ptr %6, align 4
  %51 = load i32, ptr %7, align 4
  %52 = icmp sle i32 %50, %51
  br i1 %52, label %53, label %98

53:                                               ; preds = %49
  %54 = load i32, ptr %6, align 4
  %55 = load i32, ptr %7, align 4
  %56 = icmp slt i32 %54, %55
  br i1 %56, label %57, label %73

57:                                               ; preds = %53
  %58 = load ptr, ptr %4, align 8
  %59 = load i32, ptr %6, align 4
  %60 = sext i32 %59 to i64
  %61 = getelementptr inbounds double, ptr %58, i64 %60
  %62 = load double, ptr %61, align 8
  %63 = load ptr, ptr %4, align 8
  %64 = load i32, ptr %6, align 4
  %65 = add nsw i32 %64, 1
  %66 = sext i32 %65 to i64
  %67 = getelementptr inbounds double, ptr %63, i64 %66
  %68 = load double, ptr %67, align 8
  %69 = fcmp olt double %62, %68
  br i1 %69, label %70, label %73

70:                                               ; preds = %57
  %71 = load i32, ptr %6, align 4
  %72 = add nsw i32 %71, 1
  store i32 %72, ptr %6, align 4
  br label %73

73:                                               ; preds = %70, %57, %53
  %74 = load double, ptr %9, align 8
  %75 = load ptr, ptr %4, align 8
  %76 = load i32, ptr %6, align 4
  %77 = sext i32 %76 to i64
  %78 = getelementptr inbounds double, ptr %75, i64 %77
  %79 = load double, ptr %78, align 8
  %80 = fcmp olt double %74, %79
  br i1 %80, label %81, label %94

81:                                               ; preds = %73
  %82 = load ptr, ptr %4, align 8
  %83 = load i32, ptr %6, align 4
  %84 = sext i32 %83 to i64
  %85 = getelementptr inbounds double, ptr %82, i64 %84
  %86 = load double, ptr %85, align 8
  %87 = load ptr, ptr %4, align 8
  %88 = load i32, ptr %5, align 4
  %89 = sext i32 %88 to i64
  %90 = getelementptr inbounds double, ptr %87, i64 %89
  store double %86, ptr %90, align 8
  %91 = load i32, ptr %6, align 4
  store i32 %91, ptr %5, align 4
  %92 = load i32, ptr %6, align 4
  %93 = add nsw i32 %92, %91
  store i32 %93, ptr %6, align 4
  br label %97

94:                                               ; preds = %73
  %95 = load i32, ptr %7, align 4
  %96 = add nsw i32 %95, 1
  store i32 %96, ptr %6, align 4
  br label %97

97:                                               ; preds = %94, %81
  br label %49, !llvm.loop !5

98:                                               ; preds = %49
  %99 = load double, ptr %9, align 8
  %100 = load ptr, ptr %4, align 8
  %101 = load i32, ptr %5, align 4
  %102 = sext i32 %101 to i64
  %103 = getelementptr inbounds double, ptr %100, i64 %102
  store double %99, ptr %103, align 8
  br label %14
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca ptr, align 8
  %8 = alloca i32, align 4
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4
  store ptr %1, ptr %5, align 8
  %9 = load i32, ptr %4, align 4
  %10 = icmp eq i32 %9, 2
  br i1 %10, label %11, label %16

11:                                               ; preds = %2
  %12 = load ptr, ptr %5, align 8
  %13 = getelementptr inbounds ptr, ptr %12, i64 1
  %14 = load ptr, ptr %13, align 8
  %15 = call i32 @atoi(ptr noundef %14) #5
  br label %17

16:                                               ; preds = %2
  br label %17

17:                                               ; preds = %16, %11
  %18 = phi i32 [ %15, %11 ], [ 8000000, %16 ]
  store i32 %18, ptr %6, align 4
  %19 = load i32, ptr %6, align 4
  %20 = add nsw i32 %19, 1
  %21 = sext i32 %20 to i64
  %22 = mul i64 %21, 8
  %23 = call noalias ptr @malloc(i64 noundef %22) #6
  store ptr %23, ptr %7, align 8
  store i32 1, ptr %8, align 4
  br label %24

24:                                               ; preds = %34, %17
  %25 = load i32, ptr %8, align 4
  %26 = load i32, ptr %6, align 4
  %27 = icmp sle i32 %25, %26
  br i1 %27, label %28, label %37

28:                                               ; preds = %24
  %29 = call double @gen_random(double noundef 1.000000e+00)
  %30 = load ptr, ptr %7, align 8
  %31 = load i32, ptr %8, align 4
  %32 = sext i32 %31 to i64
  %33 = getelementptr inbounds double, ptr %30, i64 %32
  store double %29, ptr %33, align 8
  br label %34

34:                                               ; preds = %28
  %35 = load i32, ptr %8, align 4
  %36 = add nsw i32 %35, 1
  store i32 %36, ptr %8, align 4
  br label %24, !llvm.loop !7

37:                                               ; preds = %24
  %38 = load i32, ptr %6, align 4
  %39 = load ptr, ptr %7, align 8
  call void @benchmark_heapsort(i32 noundef %38, ptr noundef %39)
  %40 = load ptr, ptr %7, align 8
  %41 = load i32, ptr %6, align 4
  %42 = sext i32 %41 to i64
  %43 = getelementptr inbounds double, ptr %40, i64 %42
  %44 = load double, ptr %43, align 8
  %45 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %44)
  %46 = load ptr, ptr %7, align 8
  call void @free(ptr noundef %46) #7
  ret i32 0
}

; Function Attrs: nounwind willreturn memory(read)
declare i32 @atoi(ptr noundef) #1

; Function Attrs: nounwind allocsize(0)
declare noalias ptr @malloc(i64 noundef) #2

declare i32 @printf(ptr noundef, ...) #3

; Function Attrs: nounwind
declare void @free(ptr noundef) #4

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nounwind willreturn memory(read) "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nounwind allocsize(0) "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind willreturn memory(read) }
attributes #6 = { nounwind allocsize(0) }
attributes #7 = { nounwind }

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
