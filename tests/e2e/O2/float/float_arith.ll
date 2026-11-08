; @source: tests/e2e/src/float/float_arith.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/float/float_arith.c'
source_filename = "tests/e2e/src/float/float_arith.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [21 x i8] c"%.6f %.6f %.6f %.6f\0A\00", align 1
@.str.1 = private unnamed_addr constant [17 x i8] c"%.6e %.6e %.17g\0A\00", align 1
@.str.2 = private unnamed_addr constant [6 x i8] c"%.7f\0A\00", align 1
@.str.3 = private unnamed_addr constant [12 x i8] c"%.17g %.6f\0A\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef -2.250000e+00, double noundef 4.750000e+00, double noundef -4.375000e+00, double noundef f0xBFD6DB6DC0000000)
  %2 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef f0x54CB6E83B85F253C, double noundef f0x5498623C321BAF51, double noundef f0x3FD5555555555555)
  br label %7

3:                                                ; preds = %7
  %4 = fpext float %28 to double
  %5 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.2, double noundef %4)
  %6 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.3, double noundef f0x3FF6A09E667F3BCC, double noundef -1.250000e+00)
  ret i32 0

7:                                                ; preds = %7, %0
  %8 = phi i32 [ 1, %0 ], [ %29, %7 ]
  %9 = phi float [ 0.000000e+00, %0 ], [ %28, %7 ]
  %10 = uitofp nneg i32 %8 to float
  %11 = fdiv float 1.000000e+00, %10
  %12 = fadd float %9, %11
  %13 = add nuw nsw i32 %8, 1
  %14 = uitofp nneg i32 %13 to float
  %15 = fdiv float 1.000000e+00, %14
  %16 = fadd float %12, %15
  %17 = add nuw nsw i32 %8, 2
  %18 = uitofp nneg i32 %17 to float
  %19 = fdiv float 1.000000e+00, %18
  %20 = fadd float %16, %19
  %21 = add nuw nsw i32 %8, 3
  %22 = uitofp nneg i32 %21 to float
  %23 = fdiv float 1.000000e+00, %22
  %24 = fadd float %20, %23
  %25 = add nuw nsw i32 %8, 4
  %26 = uitofp nneg i32 %25 to float
  %27 = fdiv float 1.000000e+00, %26
  %28 = fadd float %24, %27
  %29 = add nuw nsw i32 %8, 5
  %30 = icmp eq i32 %29, 101
  br i1 %30, label %3, label %7, !llvm.loop !9
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #1

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

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
!9 = distinct !{!9, !10}
!10 = !{!"llvm.loop.mustprogress"}
