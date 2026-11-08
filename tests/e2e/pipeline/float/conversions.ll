; @source: tests/e2e/src/float/conversions.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/float/conversions.c'
source_filename = "tests/e2e/src/float/conversions.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [21 x i8] c"%lld %lld %.3f %.3f\0A\00", align 1
@.str.1 = private unnamed_addr constant [9 x i8] c"%u %llu\0A\00", align 1
@.str.2 = private unnamed_addr constant [21 x i8] c"%.1f %.1f %.1f %.1f\0A\00", align 1
@.str.3 = private unnamed_addr constant [16 x i8] c"%.1f %.1f %.1f\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [7 x double], align 16
  %3 = alloca i32, align 4
  %4 = alloca double, align 8
  %5 = alloca i64, align 8
  %6 = alloca i64, align 8
  %7 = alloca i32, align 4
  %8 = alloca i8, align 1
  %9 = alloca i8, align 1
  %10 = alloca i16, align 2
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #4
  call void @llvm.memset.p0.i64(ptr align 16 %2, i8 0, i64 56, i1 false)
  %11 = getelementptr inbounds [7 x double], ptr %2, i32 0, i32 1
  store double -5.000000e-01, ptr %11, align 8
  %12 = getelementptr inbounds [7 x double], ptr %2, i32 0, i32 2
  store double 1.500000e+00, ptr %12, align 16
  %13 = getelementptr inbounds [7 x double], ptr %2, i32 0, i32 3
  store double -2.750000e+00, ptr %13, align 8
  %14 = getelementptr inbounds [7 x double], ptr %2, i32 0, i32 4
  store double f0x40FE240C9FBE76C9, ptr %14, align 16
  %15 = getelementptr inbounds [7 x double], ptr %2, i32 0, i32 5
  store double f0x41EFFFFFFFE00000, ptr %15, align 8
  %16 = getelementptr inbounds [7 x double], ptr %2, i32 0, i32 6
  store double f0xC1E0000000000000, ptr %16, align 16
  call void @llvm.lifetime.start.p0(ptr %3) #4
  store i32 0, ptr %3, align 4, !tbaa !9
  br label %17

17:                                               ; preds = %46, %0
  %18 = load i32, ptr %3, align 4, !tbaa !9
  %19 = icmp slt i32 %18, 7
  br i1 %19, label %21, label %20

20:                                               ; preds = %17
  call void @llvm.lifetime.end.p0(ptr %3) #4
  br label %49

21:                                               ; preds = %17
  call void @llvm.lifetime.start.p0(ptr %4) #4
  %22 = load i32, ptr %3, align 4, !tbaa !9
  %23 = sext i32 %22 to i64
  %24 = getelementptr inbounds [7 x double], ptr %2, i64 0, i64 %23
  %25 = load double, ptr %24, align 8, !tbaa !10
  store double %25, ptr %4, align 8, !tbaa !10
  %26 = load double, ptr %4, align 8, !tbaa !10
  %27 = fptosi double %26 to i64
  %28 = load double, ptr %4, align 8, !tbaa !10
  %29 = fptosi double %28 to i64
  %30 = load double, ptr %4, align 8, !tbaa !10
  %31 = fptrunc double %30 to float
  %32 = fpext float %31 to double
  %33 = load double, ptr %4, align 8, !tbaa !10
  %34 = fptrunc double %33 to float
  %35 = fpext float %34 to double
  %36 = call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef %27, i64 noundef %29, double noundef %32, double noundef %35)
  %37 = load double, ptr %4, align 8, !tbaa !10
  %38 = fcmp oge double %37, 0.000000e+00
  br i1 %38, label %39, label %45

39:                                               ; preds = %21
  %40 = load double, ptr %4, align 8, !tbaa !10
  %41 = fptoui double %40 to i32
  %42 = load double, ptr %4, align 8, !tbaa !10
  %43 = fptoui double %42 to i64
  %44 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %41, i64 noundef %43)
  br label %45

45:                                               ; preds = %39, %21
  call void @llvm.lifetime.end.p0(ptr %4) #4
  br label %46

46:                                               ; preds = %45
  %47 = load i32, ptr %3, align 4, !tbaa !9
  %48 = add nsw i32 %47, 1
  store i32 %48, ptr %3, align 4, !tbaa !9
  br label %17, !llvm.loop !12

49:                                               ; preds = %20
  call void @llvm.lifetime.start.p0(ptr %5) #4
  store i64 -1, ptr %5, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %6) #4
  store i64 -9007199254740993, ptr %6, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %7) #4
  store i32 -1, ptr %7, align 4, !tbaa !9
  %50 = load i64, ptr %5, align 8, !tbaa !14
  %51 = uitofp i64 %50 to double
  %52 = load i64, ptr %6, align 8, !tbaa !14
  %53 = sitofp i64 %52 to double
  %54 = load i32, ptr %7, align 4, !tbaa !9
  %55 = uitofp i32 %54 to double
  %56 = load i64, ptr %5, align 8, !tbaa !14
  %57 = uitofp i64 %56 to float
  %58 = fpext float %57 to double
  %59 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, double noundef %51, double noundef %53, double noundef %55, double noundef %58)
  call void @llvm.lifetime.start.p0(ptr %8) #4
  store i8 -7, ptr %8, align 1, !tbaa !16
  call void @llvm.lifetime.start.p0(ptr %9) #4
  store i8 -6, ptr %9, align 1, !tbaa !16
  call void @llvm.lifetime.start.p0(ptr %10) #4
  store i16 -1234, ptr %10, align 2, !tbaa !17
  %60 = load i8, ptr %8, align 1, !tbaa !16
  %61 = sitofp i8 %60 to double
  %62 = load i8, ptr %9, align 1, !tbaa !16
  %63 = uitofp i8 %62 to float
  %64 = fpext float %63 to double
  %65 = load i16, ptr %10, align 2, !tbaa !17
  %66 = sitofp i16 %65 to double
  %67 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, double noundef %61, double noundef %64, double noundef %66)
  call void @llvm.lifetime.end.p0(ptr %10) #4
  call void @llvm.lifetime.end.p0(ptr %9) #4
  call void @llvm.lifetime.end.p0(ptr %8) #4
  call void @llvm.lifetime.end.p0(ptr %7) #4
  call void @llvm.lifetime.end.p0(ptr %6) #4
  call void @llvm.lifetime.end.p0(ptr %5) #4
  call void @llvm.lifetime.end.p0(ptr %2) #4
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #2

declare i32 @printf(ptr noundef, ...) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #3 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind }

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
!11 = !{!"double", !7, i64 0}
!12 = distinct !{!12, !13}
!13 = !{!"llvm.loop.mustprogress"}
!14 = !{!15, !15, i64 0}
!15 = !{!"long long", !7, i64 0}
!16 = !{!7, !7, i64 0}
!17 = !{!18, !18, i64 0}
!18 = !{!"short", !7, i64 0}
