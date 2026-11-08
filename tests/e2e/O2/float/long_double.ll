; @source: tests/e2e/src/float/long_double.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/float/long_double.c'
source_filename = "tests/e2e/src/float/long_double.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [18 x i8] c"%.18Lf %d %.18Lf\0A\00", align 1
@.str.1 = private unnamed_addr constant [15 x i8] c"%.17g %lld %d\0A\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  br label %7

1:                                                ; preds = %7
  %2 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, x86_fp80 noundef f0x3FFDAAAAAAAAAAAAAAAB, i32 noundef 1, x86_fp80 noundef %33)
  %3 = fptrunc x86_fp80 %33 to double
  %4 = fmul x86_fp80 %33, 1.000000e+15
  %5 = fptosi x86_fp80 %4 to i64
  %6 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %3, i64 noundef %5, i32 noundef 1)
  ret i32 0

7:                                                ; preds = %7, %0
  %8 = phi x86_fp80 [ 0.000000e+00, %0 ], [ %33, %7 ]
  %9 = phi i32 [ 1, %0 ], [ %34, %7 ]
  %10 = mul nuw nsw i32 %9, %9
  %11 = uitofp nneg i32 %10 to x86_fp80
  %12 = fdiv x86_fp80 1.000000e+00, %11
  %13 = fadd x86_fp80 %8, %12
  %14 = add nuw nsw i32 %9, 1
  %15 = mul nuw nsw i32 %14, %14
  %16 = uitofp nneg i32 %15 to x86_fp80
  %17 = fdiv x86_fp80 1.000000e+00, %16
  %18 = fadd x86_fp80 %13, %17
  %19 = add nuw nsw i32 %9, 2
  %20 = mul nuw nsw i32 %19, %19
  %21 = uitofp nneg i32 %20 to x86_fp80
  %22 = fdiv x86_fp80 1.000000e+00, %21
  %23 = fadd x86_fp80 %18, %22
  %24 = add nuw nsw i32 %9, 3
  %25 = mul nuw nsw i32 %24, %24
  %26 = uitofp nneg i32 %25 to x86_fp80
  %27 = fdiv x86_fp80 1.000000e+00, %26
  %28 = fadd x86_fp80 %23, %27
  %29 = add nuw nsw i32 %9, 4
  %30 = mul nuw nsw i32 %29, %29
  %31 = uitofp nneg i32 %30 to x86_fp80
  %32 = fdiv x86_fp80 1.000000e+00, %31
  %33 = fadd x86_fp80 %28, %32
  %34 = add nuw nsw i32 %9, 5
  %35 = icmp eq i32 %34, 51
  br i1 %35, label %1, label %7, !llvm.loop !9
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
