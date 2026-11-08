; @source: tests/e2e/src/structs/array_of_structs.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/structs/array_of_structs.c'
source_filename = "tests/e2e/src/structs/array_of_structs.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [6 x i8] c"%.2f\0A\00", align 1
@.str.2 = private unnamed_addr constant [6 x i8] c"apple\00", align 1
@.str.3 = private unnamed_addr constant [5 x i8] c"pear\00", align 1
@.str.4 = private unnamed_addr constant [4 x i8] c"fig\00", align 1
@.str.5 = private unnamed_addr constant [5 x i8] c"kiwi\00", align 1
@inv = internal unnamed_addr global [4 x { ptr, i32, [4 x i8], double }] [{ ptr, i32, [4 x i8], double } { ptr @.str.2, i32 3, [4 x i8] zeroinitializer, double 5.000000e-01 }, { ptr, i32, [4 x i8], double } { ptr @.str.3, i32 10, [4 x i8] zeroinitializer, double 7.500000e-01 }, { ptr, i32, [4 x i8], double } { ptr @.str.4, i32 2, [4 x i8] zeroinitializer, double 2.250000e+00 }, { ptr, i32, [4 x i8], double } { ptr @.str.5, i32 7, [4 x i8] zeroinitializer, double 3.000000e-01 }], align 16

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = load i32, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 8), align 8, !tbaa !9
  %2 = load i32, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 32), align 16, !tbaa !9
  %3 = add nsw i32 %2, 1
  store i32 %3, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 32), align 16, !tbaa !9
  %4 = load i32, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 56), align 8, !tbaa !9
  %5 = add nsw i32 %4, 2
  store i32 %5, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 56), align 8, !tbaa !9
  %6 = load i32, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 80), align 16, !tbaa !9
  %7 = add nsw i32 %6, 3
  store i32 %7, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 80), align 16, !tbaa !9
  %8 = sitofp i32 %1 to double
  %9 = load double, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 16), align 16, !tbaa !14
  %10 = tail call double @llvm.fmuladd.f64(double %8, double %9, double 0.000000e+00)
  %11 = sitofp i32 %3 to double
  %12 = load double, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 40), align 8, !tbaa !14
  %13 = tail call double @llvm.fmuladd.f64(double %11, double %12, double %10)
  %14 = sitofp i32 %5 to double
  %15 = load double, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 64), align 16, !tbaa !14
  %16 = tail call double @llvm.fmuladd.f64(double %14, double %15, double %13)
  %17 = sitofp i32 %7 to double
  %18 = load double, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 88), align 8, !tbaa !14
  %19 = tail call double @llvm.fmuladd.f64(double %17, double %18, double %16)
  %20 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %19)
  %21 = load i32, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 8), align 8, !tbaa !15
  %22 = load double, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 16), align 16, !tbaa !16
  %23 = load i32, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 32), align 16, !tbaa !9
  %24 = sitofp i32 %23 to double
  %25 = load double, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 40), align 8, !tbaa !14
  %26 = fmul double %25, %24
  %27 = sitofp i32 %21 to double
  %28 = fmul double %22, %27
  %29 = fcmp ogt double %26, %28
  %30 = select i1 %29, double %26, double %28
  %31 = select i1 %29, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 24), ptr @inv
  %32 = load i32, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 56), align 8, !tbaa !9
  %33 = sitofp i32 %32 to double
  %34 = load double, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 64), align 16, !tbaa !14
  %35 = fmul double %34, %33
  %36 = fcmp ogt double %35, %30
  %37 = select i1 %36, double %35, double %30
  %38 = select i1 %36, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 48), ptr %31
  %39 = load i32, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 80), align 16, !tbaa !9
  %40 = sitofp i32 %39 to double
  %41 = load double, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 88), align 8, !tbaa !14
  %42 = fmul double %41, %40
  %43 = fcmp ogt double %42, %37
  %44 = select i1 %43, ptr getelementptr inbounds nuw (i8, ptr @inv, i64 72), ptr %38
  %45 = load ptr, ptr %44, align 8, !tbaa !17
  %46 = tail call i32 @puts(ptr nonnull dereferenceable(1) %45)
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #1

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #2

; Function Attrs: nofree nounwind
declare noundef i32 @puts(ptr noundef readonly captures(none)) local_unnamed_addr #3

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #3 = { nofree nounwind }

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
!9 = !{!10, !6, i64 8}
!10 = !{!"item", !11, i64 0, !6, i64 8, !13, i64 16}
!11 = !{!"p1 omnipotent char", !12, i64 0}
!12 = !{!"any pointer", !7, i64 0}
!13 = !{!"double", !7, i64 0}
!14 = !{!10, !13, i64 16}
!15 = !{!6, !6, i64 0}
!16 = !{!13, !13, i64 0}
!17 = !{!11, !11, i64 0}
