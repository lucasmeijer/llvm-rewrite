; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/random.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/random.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/random.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [6 x i8] c"%.9f\0A\00", align 1
@gen_random.last = internal unnamed_addr global i64 42, align 8

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main(i32 noundef %0, ptr nofree noundef readonly captures(none) %1) local_unnamed_addr #0 {
  %3 = icmp eq i32 %0, 2
  br i1 %3, label %6, label %4

4:                                                ; preds = %2
  %5 = load i64, ptr @gen_random.last, align 8
  br label %14

6:                                                ; preds = %2
  %7 = getelementptr inbounds nuw i8, ptr %1, i64 8
  %8 = load ptr, ptr %7, align 8, !tbaa !9
  %9 = tail call i64 @strtol(ptr noundef nonnull captures(none) %8, ptr noundef null, i32 noundef 10) #3, !inline_history !12
  %10 = trunc i64 %9 to i32
  %11 = add nsw i32 %10, -1
  %12 = load i64, ptr @gen_random.last, align 8
  %13 = icmp eq i32 %11, 0
  br i1 %13, label %40, label %14

14:                                               ; preds = %4, %6
  %15 = phi i32 [ %11, %6 ], [ 399999999, %4 ]
  %16 = phi i64 [ %12, %6 ], [ %5, %4 ]
  %17 = and i32 %15, 1
  %18 = icmp eq i32 %17, 0
  br i1 %18, label %24, label %19

19:                                               ; preds = %14
  %20 = add nsw i32 %15, -1
  %21 = mul nuw nsw i64 %16, 3877
  %22 = add nuw nsw i64 %21, 29573
  %23 = urem i64 %22, 139968
  br label %24

24:                                               ; preds = %19, %14
  %25 = phi i64 [ poison, %14 ], [ %23, %19 ]
  %26 = phi i32 [ %15, %14 ], [ %20, %19 ]
  %27 = phi i64 [ %16, %14 ], [ %23, %19 ]
  %28 = icmp eq i32 %15, 1
  br i1 %28, label %40, label %29

29:                                               ; preds = %24, %29
  %30 = phi i32 [ %35, %29 ], [ %26, %24 ]
  %31 = phi i64 [ %38, %29 ], [ %27, %24 ]
  %32 = mul nuw nsw i64 %31, 3877
  %33 = add nuw nsw i64 %32, 29573
  %34 = urem i64 %33, 139968
  %35 = add nsw i32 %30, -2
  %36 = mul nuw nsw i64 %34, 3877
  %37 = add nuw nsw i64 %36, 29573
  %38 = urem i64 %37, 139968
  %39 = icmp eq i32 %35, 0
  br i1 %39, label %40, label %29, !llvm.loop !13

40:                                               ; preds = %24, %29, %6
  %41 = phi i64 [ %12, %6 ], [ %25, %24 ], [ %38, %29 ]
  %42 = mul nuw nsw i64 %41, 3877
  %43 = add nuw nsw i64 %42, 29573
  %44 = urem i64 %43, 139968
  store i64 %44, ptr @gen_random.last, align 8, !tbaa !15
  %45 = mul nuw nsw i64 %44, 100
  %46 = uitofp nneg i64 %45 to double
  %47 = fdiv double %46, 1.399680e+05
  %48 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %47)
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #1

; Function Attrs: mustprogress nocallback nofree nounwind willreturn
declare i64 @strtol(ptr noundef readonly, ptr noundef captures(none), i32 noundef) local_unnamed_addr #2

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { mustprogress nocallback nofree nounwind willreturn "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!10 = !{!"p1 omnipotent char", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = distinct !{null}
!13 = distinct !{!13, !14}
!14 = !{!"llvm.loop.mustprogress"}
!15 = !{!16, !16, i64 0}
!16 = !{!"long", !7, i64 0}
