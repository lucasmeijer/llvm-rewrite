; @source: tests/lto/src/inline/helpers/main.c
; @opt: -passes='lto-pre-link<O2>'
; @generated: clang -O2 -flto -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/lto/src/inline/helpers/main.c'
source_filename = "tests/lto/src/inline/helpers/main.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.vec = type { double, double, double }

@.str = private unnamed_addr constant [21 x i8] c"%.6f %.6f %.6f %.6f\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca %struct.vec, align 8
  %3 = alloca i32, align 4
  %4 = alloca %struct.vec, align 8
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #4
  call void @llvm.memset.p0.i64(ptr align 8 %2, i8 0, i64 24, i1 false)
  call void @llvm.lifetime.start.p0(ptr %3) #4
  store i32 0, ptr %3, align 4, !tbaa !9
  br label %5

5:                                                ; preds = %25, %0
  %6 = load i32, ptr %3, align 4, !tbaa !9
  %7 = icmp slt i32 %6, 100
  br i1 %7, label %9, label %8

8:                                                ; preds = %5
  call void @llvm.lifetime.end.p0(ptr %3) #4
  br label %28

9:                                                ; preds = %5
  call void @llvm.lifetime.start.p0(ptr %4) #4
  %10 = getelementptr inbounds nuw %struct.vec, ptr %4, i32 0, i32 0
  %11 = load i32, ptr %3, align 4, !tbaa !9
  %12 = sitofp i32 %11 to double
  store double %12, ptr %10, align 8, !tbaa !10
  %13 = getelementptr inbounds nuw %struct.vec, ptr %4, i32 0, i32 1
  %14 = load i32, ptr %3, align 4, !tbaa !9
  %15 = sitofp i32 %14 to double
  %16 = fmul double %15, 5.000000e-01
  store double %16, ptr %13, align 8, !tbaa !13
  %17 = getelementptr inbounds nuw %struct.vec, ptr %4, i32 0, i32 2
  %18 = load i32, ptr %3, align 4, !tbaa !9
  %19 = sub nsw i32 0, %18
  %20 = sitofp i32 %19 to double
  store double %20, ptr %17, align 8, !tbaa !14
  %21 = load i32, ptr %3, align 4, !tbaa !9
  %22 = add nsw i32 %21, 1
  %23 = sitofp i32 %22 to double
  %24 = fdiv double 1.000000e+00, %23
  call void @scale(ptr noundef %4, double noundef %24)
  call void @add(ptr noundef %2, ptr noundef %2, ptr noundef %4)
  call void @llvm.lifetime.end.p0(ptr %4) #4
  br label %25

25:                                               ; preds = %9
  %26 = load i32, ptr %3, align 4, !tbaa !9
  %27 = add nsw i32 %26, 1
  store i32 %27, ptr %3, align 4, !tbaa !9
  br label %5, !llvm.loop !15

28:                                               ; preds = %8
  %29 = getelementptr inbounds nuw %struct.vec, ptr %2, i32 0, i32 0
  %30 = load double, ptr %29, align 8, !tbaa !10
  %31 = getelementptr inbounds nuw %struct.vec, ptr %2, i32 0, i32 1
  %32 = load double, ptr %31, align 8, !tbaa !13
  %33 = getelementptr inbounds nuw %struct.vec, ptr %2, i32 0, i32 2
  %34 = load double, ptr %33, align 8, !tbaa !14
  %35 = call double @dot(ptr noundef %2, ptr noundef %2)
  %36 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %30, double noundef %32, double noundef %34, double noundef %35)
  call void @llvm.lifetime.end.p0(ptr %2) #4
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #2

declare void @scale(ptr noundef, double noundef) #3

declare void @add(ptr noundef, ptr noundef, ptr noundef) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #3

declare double @dot(ptr noundef, ptr noundef) #3

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
!10 = !{!11, !12, i64 0}
!11 = !{!"vec", !12, i64 0, !12, i64 8, !12, i64 16}
!12 = !{!"double", !7, i64 0}
!13 = !{!11, !12, i64 8}
!14 = !{!11, !12, i64 16}
!15 = distinct !{!15, !16}
!16 = !{!"llvm.loop.mustprogress"}
