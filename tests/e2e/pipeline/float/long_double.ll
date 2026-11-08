; @source: tests/e2e/src/float/long_double.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/float/long_double.c'
source_filename = "tests/e2e/src/float/long_double.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [18 x i8] c"%.18Lf %d %.18Lf\0A\00", align 1
@.str.1 = private unnamed_addr constant [15 x i8] c"%.17g %lld %d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca x86_fp80, align 16
  %3 = alloca x86_fp80, align 16
  %4 = alloca x86_fp80, align 16
  %5 = alloca i32, align 4
  %6 = alloca double, align 8
  %7 = alloca i64, align 8
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #4
  store x86_fp80 f0x3FFDAAAAAAAAAAAAAAAB, ptr %2, align 16, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #4
  %8 = load x86_fp80, ptr %2, align 16, !tbaa !9
  %9 = call x86_fp80 @llvm.fmuladd.f80(x86_fp80 %8, x86_fp80 3.000000e+00, x86_fp80 -1.000000e+00)
  store x86_fp80 %9, ptr %3, align 16, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %4) #4
  store x86_fp80 0.000000e+00, ptr %4, align 16, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %5) #4
  store i32 1, ptr %5, align 4, !tbaa !11
  br label %10

10:                                               ; preds = %23, %0
  %11 = load i32, ptr %5, align 4, !tbaa !11
  %12 = icmp sle i32 %11, 50
  br i1 %12, label %14, label %13

13:                                               ; preds = %10
  call void @llvm.lifetime.end.p0(ptr %5) #4
  br label %26

14:                                               ; preds = %10
  %15 = load i32, ptr %5, align 4, !tbaa !11
  %16 = sitofp i32 %15 to x86_fp80
  %17 = load i32, ptr %5, align 4, !tbaa !11
  %18 = sitofp i32 %17 to x86_fp80
  %19 = fmul x86_fp80 %16, %18
  %20 = fdiv x86_fp80 1.000000e+00, %19
  %21 = load x86_fp80, ptr %4, align 16, !tbaa !9
  %22 = fadd x86_fp80 %21, %20
  store x86_fp80 %22, ptr %4, align 16, !tbaa !9
  br label %23

23:                                               ; preds = %14
  %24 = load i32, ptr %5, align 4, !tbaa !11
  %25 = add nsw i32 %24, 1
  store i32 %25, ptr %5, align 4, !tbaa !11
  br label %10, !llvm.loop !12

26:                                               ; preds = %13
  %27 = load x86_fp80, ptr %2, align 16, !tbaa !9
  %28 = load x86_fp80, ptr %3, align 16, !tbaa !9
  %29 = fcmp olt x86_fp80 %28, 1.000000e-10
  br i1 %29, label %30, label %33

30:                                               ; preds = %26
  %31 = load x86_fp80, ptr %3, align 16, !tbaa !9
  %32 = fcmp ogt x86_fp80 %31, -1.000000e-10
  br label %33

33:                                               ; preds = %30, %26
  %34 = phi i1 [ false, %26 ], [ %32, %30 ]
  %35 = zext i1 %34 to i32
  %36 = load x86_fp80, ptr %4, align 16, !tbaa !9
  %37 = call i32 (ptr, ...) @printf(ptr noundef @.str, x86_fp80 noundef %27, i32 noundef %35, x86_fp80 noundef %36)
  call void @llvm.lifetime.start.p0(ptr %6) #4
  %38 = load x86_fp80, ptr %4, align 16, !tbaa !9
  %39 = fptrunc x86_fp80 %38 to double
  store double %39, ptr %6, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %7) #4
  %40 = load x86_fp80, ptr %4, align 16, !tbaa !9
  %41 = fmul x86_fp80 %40, 1.000000e+15
  %42 = fptosi x86_fp80 %41 to i64
  store i64 %42, ptr %7, align 8, !tbaa !16
  %43 = load double, ptr %6, align 8, !tbaa !14
  %44 = load i64, ptr %7, align 8, !tbaa !16
  %45 = load x86_fp80, ptr %2, align 16, !tbaa !9
  %46 = fcmp olt x86_fp80 %45, 3.400000e-01
  %47 = zext i1 %46 to i32
  %48 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, double noundef %43, i64 noundef %44, i32 noundef %47)
  call void @llvm.lifetime.end.p0(ptr %7) #4
  call void @llvm.lifetime.end.p0(ptr %6) #4
  call void @llvm.lifetime.end.p0(ptr %4) #4
  call void @llvm.lifetime.end.p0(ptr %3) #4
  call void @llvm.lifetime.end.p0(ptr %2) #4
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare x86_fp80 @llvm.fmuladd.f80(x86_fp80, x86_fp80, x86_fp80) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #3

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
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
!9 = !{!10, !10, i64 0}
!10 = !{!"long double", !7, i64 0}
!11 = !{!6, !6, i64 0}
!12 = distinct !{!12, !13}
!13 = !{!"llvm.loop.mustprogress"}
!14 = !{!15, !15, i64 0}
!15 = !{!"double", !7, i64 0}
!16 = !{!17, !17, i64 0}
!17 = !{!"long long", !7, i64 0}
