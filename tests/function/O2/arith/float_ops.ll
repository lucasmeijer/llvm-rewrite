; @source: tests/function/src/arith/float_ops.c
; @llc: -O2
; @driver: tests/function/src/arith/float_ops.driver.c
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/function/src/arith/float_ops.c'
source_filename = "tests/function/src/arith/float_ops.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef float @fadd(float noundef %0, float noundef %1) local_unnamed_addr #0 {
  %3 = fadd float %0, %1
  ret float %3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef float @fmul(float noundef %0, float noundef %1) local_unnamed_addr #0 {
  %3 = fmul float %0, %1
  ret float %3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef double @ddiv(double noundef %0, double noundef %1) local_unnamed_addr #0 {
  %3 = fdiv double %0, %1
  ret double %3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef double @dsub(double noundef %0, double noundef %1) local_unnamed_addr #0 {
  %3 = fsub double %0, %1
  ret double %3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef double @fma_like(double noundef %0, double noundef %1, double noundef %2) local_unnamed_addr #0 {
  %4 = tail call double @llvm.fmuladd.f64(double %0, double %1, double %2)
  ret double %4
}

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #1

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local range(i32 0, 64) i32 @fcmp_all(double noundef %0, double noundef %1) local_unnamed_addr #0 {
  %3 = fcmp olt double %0, %1
  %4 = zext i1 %3 to i32
  %5 = fcmp ole double %0, %1
  %6 = select i1 %5, i32 2, i32 0
  %7 = or disjoint i32 %6, %4
  %8 = fcmp ogt double %0, %1
  %9 = select i1 %8, i32 4, i32 0
  %10 = or disjoint i32 %7, %9
  %11 = fcmp oge double %0, %1
  %12 = select i1 %11, i32 8, i32 0
  %13 = or disjoint i32 %10, %12
  %14 = fcmp oeq double %0, %1
  %15 = select i1 %14, i32 16, i32 0
  %16 = or disjoint i32 %13, %15
  %17 = fcmp une double %0, %1
  %18 = select i1 %17, i32 32, i32 0
  %19 = or disjoint i32 %16, %18
  ret i32 %19
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef double @neg(double noundef %0) local_unnamed_addr #0 {
  %2 = fneg double %0
  ret double %2
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef float @to_float(double noundef %0) local_unnamed_addr #0 {
  %2 = fptrunc double %0 to float
  ret float %2
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef double @to_double(float noundef %0) local_unnamed_addr #0 {
  %2 = fpext float %0 to double
  ret double %2
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local i32 @d2i(double noundef %0) local_unnamed_addr #0 {
  %2 = fptosi double %0 to i32
  ret i32 %2
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local i64 @d2ll(double noundef %0) local_unnamed_addr #0 {
  %2 = fptosi double %0 to i64
  ret i64 %2
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local i32 @d2u(double noundef %0) local_unnamed_addr #0 {
  %2 = fptoui double %0 to i32
  ret i32 %2
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef double @i2d(i32 noundef %0) local_unnamed_addr #0 {
  %2 = sitofp i32 %0 to double
  ret double %2
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef double @u2d(i32 noundef %0) local_unnamed_addr #0 {
  %2 = uitofp i32 %0 to double
  ret double %2
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef double @ull2d(i64 noundef %0) local_unnamed_addr #0 {
  %2 = uitofp i64 %0 to double
  ret double %2
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef float @ll2f(i64 noundef %0) local_unnamed_addr #0 {
  %2 = sitofp i64 %0 to float
  ret float %2
}

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }

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
