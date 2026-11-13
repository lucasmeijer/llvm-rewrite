; @source: tests/lto/src/inline/helpers/vec.c
; @opt: -passes='lto-pre-link<O2>'
; @generated: clang -O2 -flto -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/lto/src/inline/helpers/vec.c'
source_filename = "tests/lto/src/inline/helpers/vec.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.vec = type { double, double, double }

; Function Attrs: nounwind uwtable
define dso_local double @dot(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8, !tbaa !9
  store ptr %1, ptr %4, align 8, !tbaa !9
  %5 = load ptr, ptr %3, align 8, !tbaa !9
  %6 = getelementptr inbounds nuw %struct.vec, ptr %5, i32 0, i32 0
  %7 = load double, ptr %6, align 8, !tbaa !12
  %8 = load ptr, ptr %4, align 8, !tbaa !9
  %9 = getelementptr inbounds nuw %struct.vec, ptr %8, i32 0, i32 0
  %10 = load double, ptr %9, align 8, !tbaa !12
  %11 = load ptr, ptr %3, align 8, !tbaa !9
  %12 = getelementptr inbounds nuw %struct.vec, ptr %11, i32 0, i32 1
  %13 = load double, ptr %12, align 8, !tbaa !15
  %14 = load ptr, ptr %4, align 8, !tbaa !9
  %15 = getelementptr inbounds nuw %struct.vec, ptr %14, i32 0, i32 1
  %16 = load double, ptr %15, align 8, !tbaa !15
  %17 = fmul double %13, %16
  %18 = call double @llvm.fmuladd.f64(double %7, double %10, double %17)
  %19 = load ptr, ptr %3, align 8, !tbaa !9
  %20 = getelementptr inbounds nuw %struct.vec, ptr %19, i32 0, i32 2
  %21 = load double, ptr %20, align 8, !tbaa !16
  %22 = load ptr, ptr %4, align 8, !tbaa !9
  %23 = getelementptr inbounds nuw %struct.vec, ptr %22, i32 0, i32 2
  %24 = load double, ptr %23, align 8, !tbaa !16
  %25 = call double @llvm.fmuladd.f64(double %21, double %24, double %18)
  ret double %25
}

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #1

; Function Attrs: nounwind uwtable
define dso_local void @scale(ptr noundef %0, double noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca double, align 8
  store ptr %0, ptr %3, align 8, !tbaa !9
  store double %1, ptr %4, align 8, !tbaa !17
  %5 = load double, ptr %4, align 8, !tbaa !17
  %6 = load ptr, ptr %3, align 8, !tbaa !9
  %7 = getelementptr inbounds nuw %struct.vec, ptr %6, i32 0, i32 0
  %8 = load double, ptr %7, align 8, !tbaa !12
  %9 = fmul double %8, %5
  store double %9, ptr %7, align 8, !tbaa !12
  %10 = load double, ptr %4, align 8, !tbaa !17
  %11 = load ptr, ptr %3, align 8, !tbaa !9
  %12 = getelementptr inbounds nuw %struct.vec, ptr %11, i32 0, i32 1
  %13 = load double, ptr %12, align 8, !tbaa !15
  %14 = fmul double %13, %10
  store double %14, ptr %12, align 8, !tbaa !15
  %15 = load double, ptr %4, align 8, !tbaa !17
  %16 = load ptr, ptr %3, align 8, !tbaa !9
  %17 = getelementptr inbounds nuw %struct.vec, ptr %16, i32 0, i32 2
  %18 = load double, ptr %17, align 8, !tbaa !16
  %19 = fmul double %18, %15
  store double %19, ptr %17, align 8, !tbaa !16
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local void @add(ptr noundef %0, ptr noundef %1, ptr noundef %2) #0 {
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  store ptr %0, ptr %4, align 8, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !9
  store ptr %2, ptr %6, align 8, !tbaa !9
  %7 = load ptr, ptr %5, align 8, !tbaa !9
  %8 = getelementptr inbounds nuw %struct.vec, ptr %7, i32 0, i32 0
  %9 = load double, ptr %8, align 8, !tbaa !12
  %10 = load ptr, ptr %6, align 8, !tbaa !9
  %11 = getelementptr inbounds nuw %struct.vec, ptr %10, i32 0, i32 0
  %12 = load double, ptr %11, align 8, !tbaa !12
  %13 = fadd double %9, %12
  %14 = load ptr, ptr %4, align 8, !tbaa !9
  %15 = getelementptr inbounds nuw %struct.vec, ptr %14, i32 0, i32 0
  store double %13, ptr %15, align 8, !tbaa !12
  %16 = load ptr, ptr %5, align 8, !tbaa !9
  %17 = getelementptr inbounds nuw %struct.vec, ptr %16, i32 0, i32 1
  %18 = load double, ptr %17, align 8, !tbaa !15
  %19 = load ptr, ptr %6, align 8, !tbaa !9
  %20 = getelementptr inbounds nuw %struct.vec, ptr %19, i32 0, i32 1
  %21 = load double, ptr %20, align 8, !tbaa !15
  %22 = fadd double %18, %21
  %23 = load ptr, ptr %4, align 8, !tbaa !9
  %24 = getelementptr inbounds nuw %struct.vec, ptr %23, i32 0, i32 1
  store double %22, ptr %24, align 8, !tbaa !15
  %25 = load ptr, ptr %5, align 8, !tbaa !9
  %26 = getelementptr inbounds nuw %struct.vec, ptr %25, i32 0, i32 2
  %27 = load double, ptr %26, align 8, !tbaa !16
  %28 = load ptr, ptr %6, align 8, !tbaa !9
  %29 = getelementptr inbounds nuw %struct.vec, ptr %28, i32 0, i32 2
  %30 = load double, ptr %29, align 8, !tbaa !16
  %31 = fadd double %27, %30
  %32 = load ptr, ptr %4, align 8, !tbaa !9
  %33 = getelementptr inbounds nuw %struct.vec, ptr %32, i32 0, i32 2
  store double %31, ptr %33, align 8, !tbaa !16
  ret void
}

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }

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
!10 = !{!"p1 _ZTS3vec", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!13, !14, i64 0}
!13 = !{!"vec", !14, i64 0, !14, i64 8, !14, i64 16}
!14 = !{!"double", !7, i64 0}
!15 = !{!13, !14, i64 8}
!16 = !{!13, !14, i64 16}
!17 = !{!14, !14, i64 0}
