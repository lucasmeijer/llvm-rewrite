; @source: tests/e2e/src/float/float_compare.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/float/float_compare.c'
source_filename = "tests/e2e/src/float/float_compare.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [13 x i8] c"%d%d%d%d%d%d\00", align 1
@.str.1 = private unnamed_addr constant [9 x i8] c" %d%d%d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [6 x double], align 16
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca double, align 8
  %7 = alloca double, align 8
  %8 = alloca float, align 4
  %9 = alloca float, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #5
  call void @llvm.memset.p0.i64(ptr align 16 %2, i8 0, i64 48, i1 false)
  %10 = getelementptr inbounds [6 x double], ptr %2, i32 0, i32 0
  store double -1.000000e+00, ptr %10, align 16
  %11 = getelementptr inbounds [6 x double], ptr %2, i32 0, i32 2
  store double -0.000000e+00, ptr %11, align 16
  %12 = getelementptr inbounds [6 x double], ptr %2, i32 0, i32 3
  store double 1.000000e+00, ptr %12, align 8
  %13 = getelementptr inbounds [6 x double], ptr %2, i32 0, i32 4
  store double +inf, ptr %13, align 16
  %14 = getelementptr inbounds [6 x double], ptr %2, i32 0, i32 5
  store double +qnan, ptr %14, align 8
  call void @llvm.lifetime.start.p0(ptr %3) #5
  store i32 0, ptr %3, align 4, !tbaa !9
  br label %15

15:                                               ; preds = %83, %0
  %16 = load i32, ptr %3, align 4, !tbaa !9
  %17 = icmp slt i32 %16, 6
  br i1 %17, label %19, label %18

18:                                               ; preds = %15
  store i32 2, ptr %4, align 4
  call void @llvm.lifetime.end.p0(ptr %3) #5
  br label %86

19:                                               ; preds = %15
  call void @llvm.lifetime.start.p0(ptr %5) #5
  store i32 0, ptr %5, align 4, !tbaa !9
  br label %20

20:                                               ; preds = %79, %19
  %21 = load i32, ptr %5, align 4, !tbaa !9
  %22 = icmp slt i32 %21, 6
  br i1 %22, label %24, label %23

23:                                               ; preds = %20
  store i32 5, ptr %4, align 4
  call void @llvm.lifetime.end.p0(ptr %5) #5
  br label %82

24:                                               ; preds = %20
  call void @llvm.lifetime.start.p0(ptr %6) #5
  %25 = load i32, ptr %3, align 4, !tbaa !9
  %26 = sext i32 %25 to i64
  %27 = getelementptr inbounds [6 x double], ptr %2, i64 0, i64 %26
  %28 = load double, ptr %27, align 8, !tbaa !10
  store double %28, ptr %6, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %7) #5
  %29 = load i32, ptr %5, align 4, !tbaa !9
  %30 = sext i32 %29 to i64
  %31 = getelementptr inbounds [6 x double], ptr %2, i64 0, i64 %30
  %32 = load double, ptr %31, align 8, !tbaa !10
  store double %32, ptr %7, align 8, !tbaa !10
  %33 = load double, ptr %6, align 8, !tbaa !10
  %34 = load double, ptr %7, align 8, !tbaa !10
  %35 = fcmp olt double %33, %34
  %36 = zext i1 %35 to i32
  %37 = load double, ptr %6, align 8, !tbaa !10
  %38 = load double, ptr %7, align 8, !tbaa !10
  %39 = fcmp ole double %37, %38
  %40 = zext i1 %39 to i32
  %41 = load double, ptr %6, align 8, !tbaa !10
  %42 = load double, ptr %7, align 8, !tbaa !10
  %43 = fcmp ogt double %41, %42
  %44 = zext i1 %43 to i32
  %45 = load double, ptr %6, align 8, !tbaa !10
  %46 = load double, ptr %7, align 8, !tbaa !10
  %47 = fcmp oge double %45, %46
  %48 = zext i1 %47 to i32
  %49 = load double, ptr %6, align 8, !tbaa !10
  %50 = load double, ptr %7, align 8, !tbaa !10
  %51 = fcmp oeq double %49, %50
  %52 = zext i1 %51 to i32
  %53 = load double, ptr %6, align 8, !tbaa !10
  %54 = load double, ptr %7, align 8, !tbaa !10
  %55 = fcmp une double %53, %54
  %56 = zext i1 %55 to i32
  %57 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %36, i32 noundef %40, i32 noundef %44, i32 noundef %48, i32 noundef %52, i32 noundef %56)
  call void @llvm.lifetime.start.p0(ptr %8) #5
  %58 = load double, ptr %6, align 8, !tbaa !10
  %59 = fptrunc double %58 to float
  store float %59, ptr %8, align 4, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %9) #5
  %60 = load double, ptr %7, align 8, !tbaa !10
  %61 = fptrunc double %60 to float
  store float %61, ptr %9, align 4, !tbaa !12
  %62 = load float, ptr %8, align 4, !tbaa !12
  %63 = load float, ptr %9, align 4, !tbaa !12
  %64 = fcmp olt float %62, %63
  %65 = zext i1 %64 to i32
  %66 = load float, ptr %8, align 4, !tbaa !12
  %67 = load float, ptr %9, align 4, !tbaa !12
  %68 = fcmp oeq float %66, %67
  %69 = zext i1 %68 to i32
  %70 = load float, ptr %8, align 4, !tbaa !12
  %71 = call i1 @llvm.is.fpclass.f32(float %70, /* (nan) */ i32 3)
  br i1 %71, label %75, label %72

72:                                               ; preds = %24
  %73 = load float, ptr %9, align 4, !tbaa !12
  %74 = call i1 @llvm.is.fpclass.f32(float %73, /* (nan) */ i32 3)
  br label %75

75:                                               ; preds = %72, %24
  %76 = phi i1 [ true, %24 ], [ %74, %72 ]
  %77 = zext i1 %76 to i32
  %78 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %65, i32 noundef %69, i32 noundef %77)
  call void @llvm.lifetime.end.p0(ptr %9) #5
  call void @llvm.lifetime.end.p0(ptr %8) #5
  call void @llvm.lifetime.end.p0(ptr %7) #5
  call void @llvm.lifetime.end.p0(ptr %6) #5
  br label %79

79:                                               ; preds = %75
  %80 = load i32, ptr %5, align 4, !tbaa !9
  %81 = add nsw i32 %80, 1
  store i32 %81, ptr %5, align 4, !tbaa !9
  br label %20, !llvm.loop !14

82:                                               ; preds = %23
  br label %83

83:                                               ; preds = %82
  %84 = load i32, ptr %3, align 4, !tbaa !9
  %85 = add nsw i32 %84, 1
  store i32 %85, ptr %3, align 4, !tbaa !9
  br label %15, !llvm.loop !16

86:                                               ; preds = %18
  store i32 0, ptr %1, align 4
  store i32 1, ptr %4, align 4
  call void @llvm.lifetime.end.p0(ptr %2) #5
  %87 = load i32, ptr %1, align 4
  ret i32 %87
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #2

declare i32 @printf(ptr noundef, ...) #3

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i1 @llvm.is.fpclass.f32(float, i32 immarg) #4

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #3 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #5 = { nounwind }

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
!10 = !{!11, !11, i64 0}
!11 = !{!"double", !7, i64 0}
!12 = !{!13, !13, i64 0}
!13 = !{!"float", !7, i64 0}
!14 = distinct !{!14, !15}
!15 = !{!"llvm.loop.mustprogress"}
!16 = distinct !{!16, !15}
