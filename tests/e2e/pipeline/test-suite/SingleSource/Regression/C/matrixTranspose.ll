; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/matrixTranspose.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/matrixTranspose.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/matrixTranspose.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@A = dso_local global [2048 x float] zeroinitializer, align 16
@.str = private unnamed_addr constant [23 x i8] c"Checksum before = %lf\0A\00", align 1
@.str.1 = private unnamed_addr constant [23 x i8] c"Checksum  after = %lf\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local void @complex_transpose(ptr noundef %0, ptr noundef %1, i32 noundef %2, i32 noundef %3, i32 noundef %4) #0 {
  %6 = alloca ptr, align 8
  %7 = alloca ptr, align 8
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  %11 = alloca i32, align 4
  %12 = alloca i32, align 4
  %13 = alloca float, align 4
  %14 = alloca float, align 4
  %15 = alloca float, align 4
  %16 = alloca float, align 4
  store ptr %0, ptr %6, align 8, !tbaa !9
  store ptr %1, ptr %7, align 8, !tbaa !9
  store i32 %2, ptr %8, align 4, !tbaa !12
  store i32 %3, ptr %9, align 4, !tbaa !12
  store i32 %4, ptr %10, align 4, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %11) #3
  call void @llvm.lifetime.start.p0(ptr %12) #3
  store i32 1, ptr %11, align 4, !tbaa !12
  br label %17

17:                                               ; preds = %119, %5
  %18 = load i32, ptr %11, align 4, !tbaa !12
  %19 = load i32, ptr %8, align 4, !tbaa !12
  %20 = icmp slt i32 %18, %19
  br i1 %20, label %21, label %122

21:                                               ; preds = %17
  store i32 0, ptr %12, align 4, !tbaa !12
  br label %22

22:                                               ; preds = %115, %21
  %23 = load i32, ptr %12, align 4, !tbaa !12
  %24 = load i32, ptr %11, align 4, !tbaa !12
  %25 = icmp slt i32 %23, %24
  br i1 %25, label %26, label %118

26:                                               ; preds = %22
  call void @llvm.lifetime.start.p0(ptr %13) #3
  call void @llvm.lifetime.start.p0(ptr %14) #3
  call void @llvm.lifetime.start.p0(ptr %15) #3
  call void @llvm.lifetime.start.p0(ptr %16) #3
  %27 = load ptr, ptr %6, align 8, !tbaa !9
  %28 = load i32, ptr %11, align 4, !tbaa !12
  %29 = load i32, ptr %9, align 4, !tbaa !12
  %30 = mul nsw i32 %28, %29
  %31 = load i32, ptr %12, align 4, !tbaa !12
  %32 = load i32, ptr %10, align 4, !tbaa !12
  %33 = mul nsw i32 %31, %32
  %34 = add nsw i32 %30, %33
  %35 = sext i32 %34 to i64
  %36 = getelementptr inbounds float, ptr %27, i64 %35
  %37 = load float, ptr %36, align 4, !tbaa !13
  store float %37, ptr %13, align 4, !tbaa !13
  %38 = load ptr, ptr %7, align 8, !tbaa !9
  %39 = load i32, ptr %11, align 4, !tbaa !12
  %40 = load i32, ptr %9, align 4, !tbaa !12
  %41 = mul nsw i32 %39, %40
  %42 = load i32, ptr %12, align 4, !tbaa !12
  %43 = load i32, ptr %10, align 4, !tbaa !12
  %44 = mul nsw i32 %42, %43
  %45 = add nsw i32 %41, %44
  %46 = sext i32 %45 to i64
  %47 = getelementptr inbounds float, ptr %38, i64 %46
  %48 = load float, ptr %47, align 4, !tbaa !13
  store float %48, ptr %14, align 4, !tbaa !13
  %49 = load ptr, ptr %6, align 8, !tbaa !9
  %50 = load i32, ptr %12, align 4, !tbaa !12
  %51 = load i32, ptr %9, align 4, !tbaa !12
  %52 = mul nsw i32 %50, %51
  %53 = load i32, ptr %11, align 4, !tbaa !12
  %54 = load i32, ptr %10, align 4, !tbaa !12
  %55 = mul nsw i32 %53, %54
  %56 = add nsw i32 %52, %55
  %57 = sext i32 %56 to i64
  %58 = getelementptr inbounds float, ptr %49, i64 %57
  %59 = load float, ptr %58, align 4, !tbaa !13
  store float %59, ptr %15, align 4, !tbaa !13
  %60 = load ptr, ptr %7, align 8, !tbaa !9
  %61 = load i32, ptr %12, align 4, !tbaa !12
  %62 = load i32, ptr %9, align 4, !tbaa !12
  %63 = mul nsw i32 %61, %62
  %64 = load i32, ptr %11, align 4, !tbaa !12
  %65 = load i32, ptr %10, align 4, !tbaa !12
  %66 = mul nsw i32 %64, %65
  %67 = add nsw i32 %63, %66
  %68 = sext i32 %67 to i64
  %69 = getelementptr inbounds float, ptr %60, i64 %68
  %70 = load float, ptr %69, align 4, !tbaa !13
  store float %70, ptr %16, align 4, !tbaa !13
  %71 = load float, ptr %13, align 4, !tbaa !13
  %72 = load ptr, ptr %6, align 8, !tbaa !9
  %73 = load i32, ptr %12, align 4, !tbaa !12
  %74 = load i32, ptr %9, align 4, !tbaa !12
  %75 = mul nsw i32 %73, %74
  %76 = load i32, ptr %11, align 4, !tbaa !12
  %77 = load i32, ptr %10, align 4, !tbaa !12
  %78 = mul nsw i32 %76, %77
  %79 = add nsw i32 %75, %78
  %80 = sext i32 %79 to i64
  %81 = getelementptr inbounds float, ptr %72, i64 %80
  store float %71, ptr %81, align 4, !tbaa !13
  %82 = load float, ptr %14, align 4, !tbaa !13
  %83 = load ptr, ptr %7, align 8, !tbaa !9
  %84 = load i32, ptr %12, align 4, !tbaa !12
  %85 = load i32, ptr %9, align 4, !tbaa !12
  %86 = mul nsw i32 %84, %85
  %87 = load i32, ptr %11, align 4, !tbaa !12
  %88 = load i32, ptr %10, align 4, !tbaa !12
  %89 = mul nsw i32 %87, %88
  %90 = add nsw i32 %86, %89
  %91 = sext i32 %90 to i64
  %92 = getelementptr inbounds float, ptr %83, i64 %91
  store float %82, ptr %92, align 4, !tbaa !13
  %93 = load float, ptr %15, align 4, !tbaa !13
  %94 = load ptr, ptr %6, align 8, !tbaa !9
  %95 = load i32, ptr %11, align 4, !tbaa !12
  %96 = load i32, ptr %9, align 4, !tbaa !12
  %97 = mul nsw i32 %95, %96
  %98 = load i32, ptr %12, align 4, !tbaa !12
  %99 = load i32, ptr %10, align 4, !tbaa !12
  %100 = mul nsw i32 %98, %99
  %101 = add nsw i32 %97, %100
  %102 = sext i32 %101 to i64
  %103 = getelementptr inbounds float, ptr %94, i64 %102
  store float %93, ptr %103, align 4, !tbaa !13
  %104 = load float, ptr %16, align 4, !tbaa !13
  %105 = load ptr, ptr %7, align 8, !tbaa !9
  %106 = load i32, ptr %11, align 4, !tbaa !12
  %107 = load i32, ptr %9, align 4, !tbaa !12
  %108 = mul nsw i32 %106, %107
  %109 = load i32, ptr %12, align 4, !tbaa !12
  %110 = load i32, ptr %10, align 4, !tbaa !12
  %111 = mul nsw i32 %109, %110
  %112 = add nsw i32 %108, %111
  %113 = sext i32 %112 to i64
  %114 = getelementptr inbounds float, ptr %105, i64 %113
  store float %104, ptr %114, align 4, !tbaa !13
  call void @llvm.lifetime.end.p0(ptr %16) #3
  call void @llvm.lifetime.end.p0(ptr %15) #3
  call void @llvm.lifetime.end.p0(ptr %14) #3
  call void @llvm.lifetime.end.p0(ptr %13) #3
  br label %115

115:                                              ; preds = %26
  %116 = load i32, ptr %12, align 4, !tbaa !12
  %117 = add nsw i32 %116, 1
  store i32 %117, ptr %12, align 4, !tbaa !12
  br label %22, !llvm.loop !15

118:                                              ; preds = %22
  br label %119

119:                                              ; preds = %118
  %120 = load i32, ptr %11, align 4, !tbaa !12
  %121 = add nsw i32 %120, 1
  store i32 %121, ptr %11, align 4, !tbaa !12
  br label %17, !llvm.loop !17

122:                                              ; preds = %17
  call void @llvm.lifetime.end.p0(ptr %12) #3
  call void @llvm.lifetime.end.p0(ptr %11) #3
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca float, align 4
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !12
  store ptr %1, ptr %5, align 8, !tbaa !18
  call void @llvm.lifetime.start.p0(ptr %6) #3
  call void @llvm.lifetime.start.p0(ptr %7) #3
  store float 0.000000e+00, ptr %7, align 4, !tbaa !13
  store i32 0, ptr %6, align 4, !tbaa !12
  br label %8

8:                                                ; preds = %23, %2
  %9 = load i32, ptr %6, align 4, !tbaa !12
  %10 = icmp slt i32 %9, 2048
  br i1 %10, label %11, label %26

11:                                               ; preds = %8
  %12 = load i32, ptr %6, align 4, !tbaa !12
  %13 = sitofp i32 %12 to float
  %14 = load i32, ptr %6, align 4, !tbaa !12
  %15 = sext i32 %14 to i64
  %16 = getelementptr inbounds [2048 x float], ptr @A, i64 0, i64 %15
  store float %13, ptr %16, align 4, !tbaa !13
  %17 = load float, ptr %7, align 4, !tbaa !13
  %18 = load i32, ptr %6, align 4, !tbaa !12
  %19 = sext i32 %18 to i64
  %20 = getelementptr inbounds [2048 x float], ptr @A, i64 0, i64 %19
  %21 = load float, ptr %20, align 4, !tbaa !13
  %22 = fadd float %17, %21
  store float %22, ptr %7, align 4, !tbaa !13
  br label %23

23:                                               ; preds = %11
  %24 = load i32, ptr %6, align 4, !tbaa !12
  %25 = add nsw i32 %24, 1
  store i32 %25, ptr %6, align 4, !tbaa !12
  br label %8, !llvm.loop !21

26:                                               ; preds = %8
  %27 = load float, ptr %7, align 4, !tbaa !13
  %28 = fpext float %27 to double
  %29 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %28)
  store i32 0, ptr %6, align 4, !tbaa !12
  br label %30

30:                                               ; preds = %34, %26
  %31 = load i32, ptr %6, align 4, !tbaa !12
  %32 = icmp slt i32 %31, 10
  br i1 %32, label %33, label %37

33:                                               ; preds = %30
  call void @complex_transpose(ptr noundef @A, ptr noundef getelementptr inbounds nuw (i8, ptr @A, i64 4), i32 noundef 32, i32 noundef 2, i32 noundef 64)
  br label %34

34:                                               ; preds = %33
  %35 = load i32, ptr %6, align 4, !tbaa !12
  %36 = add nsw i32 %35, 1
  store i32 %36, ptr %6, align 4, !tbaa !12
  br label %30, !llvm.loop !22

37:                                               ; preds = %30
  store float 0.000000e+00, ptr %7, align 4, !tbaa !13
  store i32 0, ptr %6, align 4, !tbaa !12
  br label %38

38:                                               ; preds = %48, %37
  %39 = load i32, ptr %6, align 4, !tbaa !12
  %40 = icmp slt i32 %39, 2048
  br i1 %40, label %41, label %51

41:                                               ; preds = %38
  %42 = load float, ptr %7, align 4, !tbaa !13
  %43 = load i32, ptr %6, align 4, !tbaa !12
  %44 = sext i32 %43 to i64
  %45 = getelementptr inbounds [2048 x float], ptr @A, i64 0, i64 %44
  %46 = load float, ptr %45, align 4, !tbaa !13
  %47 = fadd float %42, %46
  store float %47, ptr %7, align 4, !tbaa !13
  br label %48

48:                                               ; preds = %41
  %49 = load i32, ptr %6, align 4, !tbaa !12
  %50 = add nsw i32 %49, 1
  store i32 %50, ptr %6, align 4, !tbaa !12
  br label %38, !llvm.loop !23

51:                                               ; preds = %38
  %52 = load float, ptr %7, align 4, !tbaa !13
  %53 = fpext float %52 to double
  %54 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, double noundef %53)
  call void @llvm.lifetime.end.p0(ptr %7) #3
  call void @llvm.lifetime.end.p0(ptr %6) #3
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #2

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!10 = !{!"p1 float", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!6, !6, i64 0}
!13 = !{!14, !14, i64 0}
!14 = !{!"float", !7, i64 0}
!15 = distinct !{!15, !16}
!16 = !{!"llvm.loop.mustprogress"}
!17 = distinct !{!17, !16}
!18 = !{!19, !19, i64 0}
!19 = !{!"p2 omnipotent char", !20, i64 0}
!20 = !{!"any p2 pointer", !11, i64 0}
!21 = distinct !{!21, !16}
!22 = distinct !{!22, !16}
!23 = distinct !{!23, !16}
