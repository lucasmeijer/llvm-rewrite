; @source: tests/e2e/src/float/float_compare.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/float/float_compare.c'
source_filename = "tests/e2e/src/float/float_compare.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [13 x i8] c"%d%d%d%d%d%d\00", align 1
@.str.1 = private unnamed_addr constant [9 x i8] c" %d%d%d\0A\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = alloca [6 x double], align 16
  call void @llvm.lifetime.start.p0(ptr nonnull %1) #4
  call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(48) %1, i8 0, i64 16, i1 false)
  store double -1.000000e+00, ptr %1, align 16
  %2 = getelementptr inbounds nuw i8, ptr %1, i64 16
  store <2 x double> <double -0.000000e+00, double 1.000000e+00>, ptr %2, align 16
  %3 = getelementptr inbounds nuw i8, ptr %1, i64 32
  store <2 x double> <double +inf, double +qnan>, ptr %3, align 16
  br label %4

4:                                                ; preds = %0, %10
  %5 = phi i64 [ 0, %0 ], [ %11, %10 ]
  %6 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %5
  %7 = load double, ptr %6, align 8, !tbaa !9
  %8 = fptrunc double %7 to float
  br label %13

9:                                                ; preds = %10
  call void @llvm.lifetime.end.p0(ptr nonnull %1) #4
  ret i32 0

10:                                               ; preds = %13
  %11 = add nuw nsw i64 %5, 1
  %12 = icmp eq i64 %11, 6
  br i1 %12, label %9, label %4, !llvm.loop !11

13:                                               ; preds = %4, %13
  %14 = phi i64 [ 0, %4 ], [ %38, %13 ]
  %15 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %14
  %16 = load double, ptr %15, align 8, !tbaa !9
  %17 = fcmp olt double %7, %16
  %18 = zext i1 %17 to i32
  %19 = fcmp ole double %7, %16
  %20 = zext i1 %19 to i32
  %21 = fcmp ogt double %7, %16
  %22 = zext i1 %21 to i32
  %23 = fcmp oge double %7, %16
  %24 = zext i1 %23 to i32
  %25 = fcmp oeq double %7, %16
  %26 = zext i1 %25 to i32
  %27 = fcmp une double %7, %16
  %28 = zext i1 %27 to i32
  %29 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %18, i32 noundef %20, i32 noundef %22, i32 noundef %24, i32 noundef %26, i32 noundef %28)
  %30 = fptrunc double %16 to float
  %31 = fcmp olt float %8, %30
  %32 = zext i1 %31 to i32
  %33 = fcmp oeq float %8, %30
  %34 = zext i1 %33 to i32
  %35 = fcmp uno double %7, %16
  %36 = zext i1 %35 to i32
  %37 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i32 noundef %32, i32 noundef %34, i32 noundef %36)
  %38 = add nuw nsw i64 %14, 1
  %39 = icmp eq i64 %38, 6
  br i1 %39, label %10, label %13, !llvm.loop !13
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #2

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #3

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #3 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!10 = !{!"double", !7, i64 0}
!11 = distinct !{!11, !12}
!12 = !{!"llvm.loop.mustprogress"}
!13 = distinct !{!13, !12}
