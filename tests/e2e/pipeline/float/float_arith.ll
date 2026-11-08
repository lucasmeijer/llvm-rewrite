; @source: tests/e2e/src/float/float_arith.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/float/float_arith.c'
source_filename = "tests/e2e/src/float/float_arith.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [21 x i8] c"%.6f %.6f %.6f %.6f\0A\00", align 1
@.str.1 = private unnamed_addr constant [17 x i8] c"%.6e %.6e %.17g\0A\00", align 1
@.str.2 = private unnamed_addr constant [6 x i8] c"%.7f\0A\00", align 1
@.str.3 = private unnamed_addr constant [12 x i8] c"%.17g %.6f\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca float, align 4
  %3 = alloca float, align 4
  %4 = alloca double, align 8
  %5 = alloca double, align 8
  %6 = alloca float, align 4
  %7 = alloca i32, align 4
  %8 = alloca double, align 8
  %9 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  store float 1.250000e+00, ptr %2, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #3
  store float -3.500000e+00, ptr %3, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %4) #3
  store double 1.000000e+100, ptr %4, align 8, !tbaa !11
  call void @llvm.lifetime.start.p0(ptr %5) #3
  store double 3.000000e+00, ptr %5, align 8, !tbaa !11
  %10 = load float, ptr %2, align 4, !tbaa !9
  %11 = load float, ptr %3, align 4, !tbaa !9
  %12 = fadd float %10, %11
  %13 = fpext float %12 to double
  %14 = load float, ptr %2, align 4, !tbaa !9
  %15 = load float, ptr %3, align 4, !tbaa !9
  %16 = fsub float %14, %15
  %17 = fpext float %16 to double
  %18 = load float, ptr %2, align 4, !tbaa !9
  %19 = load float, ptr %3, align 4, !tbaa !9
  %20 = fmul float %18, %19
  %21 = fpext float %20 to double
  %22 = load float, ptr %2, align 4, !tbaa !9
  %23 = load float, ptr %3, align 4, !tbaa !9
  %24 = fdiv float %22, %23
  %25 = fpext float %24 to double
  %26 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %13, double noundef %17, double noundef %21, double noundef %25)
  %27 = load double, ptr %4, align 8, !tbaa !11
  %28 = load double, ptr %5, align 8, !tbaa !11
  %29 = fmul double %27, %28
  %30 = load double, ptr %4, align 8, !tbaa !11
  %31 = load double, ptr %5, align 8, !tbaa !11
  %32 = fdiv double %30, %31
  %33 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, double noundef %29, double noundef %32, double noundef f0x3FD5555555555555)
  call void @llvm.lifetime.start.p0(ptr %6) #3
  store float 0.000000e+00, ptr %6, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %7) #3
  store i32 1, ptr %7, align 4, !tbaa !13
  br label %34

34:                                               ; preds = %44, %0
  %35 = load i32, ptr %7, align 4, !tbaa !13
  %36 = icmp sle i32 %35, 100
  br i1 %36, label %38, label %37

37:                                               ; preds = %34
  call void @llvm.lifetime.end.p0(ptr %7) #3
  br label %47

38:                                               ; preds = %34
  %39 = load i32, ptr %7, align 4, !tbaa !13
  %40 = sitofp i32 %39 to float
  %41 = fdiv float 1.000000e+00, %40
  %42 = load float, ptr %6, align 4, !tbaa !9
  %43 = fadd float %42, %41
  store float %43, ptr %6, align 4, !tbaa !9
  br label %44

44:                                               ; preds = %38
  %45 = load i32, ptr %7, align 4, !tbaa !13
  %46 = add nsw i32 %45, 1
  store i32 %46, ptr %7, align 4, !tbaa !13
  br label %34, !llvm.loop !14

47:                                               ; preds = %37
  %48 = load float, ptr %6, align 4, !tbaa !9
  %49 = fpext float %48 to double
  %50 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, double noundef %49)
  call void @llvm.lifetime.start.p0(ptr %8) #3
  store double 2.000000e+00, ptr %8, align 8, !tbaa !11
  call void @llvm.lifetime.start.p0(ptr %9) #3
  store i32 0, ptr %9, align 4, !tbaa !13
  br label %51

51:                                               ; preds = %61, %47
  %52 = load i32, ptr %9, align 4, !tbaa !13
  %53 = icmp slt i32 %52, 6
  br i1 %53, label %55, label %54

54:                                               ; preds = %51
  call void @llvm.lifetime.end.p0(ptr %9) #3
  br label %64

55:                                               ; preds = %51
  %56 = load double, ptr %8, align 8, !tbaa !11
  %57 = load double, ptr %8, align 8, !tbaa !11
  %58 = fdiv double 2.000000e+00, %57
  %59 = fadd double %56, %58
  %60 = fdiv double %59, 2.000000e+00
  store double %60, ptr %8, align 8, !tbaa !11
  br label %61

61:                                               ; preds = %55
  %62 = load i32, ptr %9, align 4, !tbaa !13
  %63 = add nsw i32 %62, 1
  store i32 %63, ptr %9, align 4, !tbaa !13
  br label %51, !llvm.loop !16

64:                                               ; preds = %54
  %65 = load double, ptr %8, align 8, !tbaa !11
  %66 = load float, ptr %2, align 4, !tbaa !9
  %67 = fneg float %66
  %68 = fpext float %67 to double
  %69 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, double noundef %65, double noundef %68)
  call void @llvm.lifetime.end.p0(ptr %8) #3
  call void @llvm.lifetime.end.p0(ptr %6) #3
  call void @llvm.lifetime.end.p0(ptr %5) #3
  call void @llvm.lifetime.end.p0(ptr %4) #3
  call void @llvm.lifetime.end.p0(ptr %3) #3
  call void @llvm.lifetime.end.p0(ptr %2) #3
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind }

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
!10 = !{!"float", !7, i64 0}
!11 = !{!12, !12, i64 0}
!12 = !{!"double", !7, i64 0}
!13 = !{!6, !6, i64 0}
!14 = distinct !{!14, !15}
!15 = !{!"llvm.loop.mustprogress"}
!16 = distinct !{!16, !15}
