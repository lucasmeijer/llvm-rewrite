; @source: tests/e2e/src/float/float_compare.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/float/float_compare.c'
source_filename = "tests/e2e/src/float/float_compare.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [13 x i8] c"%d%d%d%d%d%d\00", align 1
@.str.1 = private unnamed_addr constant [9 x i8] c" %d%d%d\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [6 x double], align 16
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca double, align 8
  %6 = alloca double, align 8
  %7 = alloca float, align 4
  %8 = alloca float, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.memset.p0.i64(ptr align 16 %2, i8 0, i64 48, i1 false)
  %9 = getelementptr inbounds [6 x double], ptr %2, i32 0, i32 0
  store double -1.000000e+00, ptr %9, align 16
  %10 = getelementptr inbounds [6 x double], ptr %2, i32 0, i32 2
  store double -0.000000e+00, ptr %10, align 16
  %11 = getelementptr inbounds [6 x double], ptr %2, i32 0, i32 3
  store double 1.000000e+00, ptr %11, align 8
  %12 = getelementptr inbounds [6 x double], ptr %2, i32 0, i32 4
  store double +inf, ptr %12, align 16
  %13 = getelementptr inbounds [6 x double], ptr %2, i32 0, i32 5
  store double +qnan, ptr %13, align 8
  store i32 0, ptr %3, align 4
  br label %14

14:                                               ; preds = %80, %0
  %15 = load i32, ptr %3, align 4
  %16 = icmp slt i32 %15, 6
  br i1 %16, label %17, label %83

17:                                               ; preds = %14
  store i32 0, ptr %4, align 4
  br label %18

18:                                               ; preds = %76, %17
  %19 = load i32, ptr %4, align 4
  %20 = icmp slt i32 %19, 6
  br i1 %20, label %21, label %79

21:                                               ; preds = %18
  %22 = load i32, ptr %3, align 4
  %23 = sext i32 %22 to i64
  %24 = getelementptr inbounds [6 x double], ptr %2, i64 0, i64 %23
  %25 = load double, ptr %24, align 8
  store double %25, ptr %5, align 8
  %26 = load i32, ptr %4, align 4
  %27 = sext i32 %26 to i64
  %28 = getelementptr inbounds [6 x double], ptr %2, i64 0, i64 %27
  %29 = load double, ptr %28, align 8
  store double %29, ptr %6, align 8
  %30 = load double, ptr %5, align 8
  %31 = load double, ptr %6, align 8
  %32 = fcmp olt double %30, %31
  %33 = zext i1 %32 to i32
  %34 = load double, ptr %5, align 8
  %35 = load double, ptr %6, align 8
  %36 = fcmp ole double %34, %35
  %37 = zext i1 %36 to i32
  %38 = load double, ptr %5, align 8
  %39 = load double, ptr %6, align 8
  %40 = fcmp ogt double %38, %39
  %41 = zext i1 %40 to i32
  %42 = load double, ptr %5, align 8
  %43 = load double, ptr %6, align 8
  %44 = fcmp oge double %42, %43
  %45 = zext i1 %44 to i32
  %46 = load double, ptr %5, align 8
  %47 = load double, ptr %6, align 8
  %48 = fcmp oeq double %46, %47
  %49 = zext i1 %48 to i32
  %50 = load double, ptr %5, align 8
  %51 = load double, ptr %6, align 8
  %52 = fcmp une double %50, %51
  %53 = zext i1 %52 to i32
  %54 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %33, i32 noundef %37, i32 noundef %41, i32 noundef %45, i32 noundef %49, i32 noundef %53)
  %55 = load double, ptr %5, align 8
  %56 = fptrunc double %55 to float
  store float %56, ptr %7, align 4
  %57 = load double, ptr %6, align 8
  %58 = fptrunc double %57 to float
  store float %58, ptr %8, align 4
  %59 = load float, ptr %7, align 4
  %60 = load float, ptr %8, align 4
  %61 = fcmp olt float %59, %60
  %62 = zext i1 %61 to i32
  %63 = load float, ptr %7, align 4
  %64 = load float, ptr %8, align 4
  %65 = fcmp oeq float %63, %64
  %66 = zext i1 %65 to i32
  %67 = load float, ptr %7, align 4
  %68 = call i1 @llvm.is.fpclass.f32(float %67, /* (nan) */ i32 3)
  br i1 %68, label %72, label %69

69:                                               ; preds = %21
  %70 = load float, ptr %8, align 4
  %71 = call i1 @llvm.is.fpclass.f32(float %70, /* (nan) */ i32 3)
  br label %72

72:                                               ; preds = %69, %21
  %73 = phi i1 [ true, %21 ], [ %71, %69 ]
  %74 = zext i1 %73 to i32
  %75 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %62, i32 noundef %66, i32 noundef %74)
  br label %76

76:                                               ; preds = %72
  %77 = load i32, ptr %4, align 4
  %78 = add nsw i32 %77, 1
  store i32 %78, ptr %4, align 4
  br label %18, !llvm.loop !5

79:                                               ; preds = %18
  br label %80

80:                                               ; preds = %79
  %81 = load i32, ptr %3, align 4
  %82 = add nsw i32 %81, 1
  store i32 %82, ptr %3, align 4
  br label %14, !llvm.loop !7

83:                                               ; preds = %14
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i1 @llvm.is.fpclass.f32(float, i32 immarg) #3

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #2 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
