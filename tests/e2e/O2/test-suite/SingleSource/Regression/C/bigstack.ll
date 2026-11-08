; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/bigstack.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/bigstack.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/bigstack.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.Mixed_struct = type { i32, [10 x double], [10 x [10 x double]], [10 x %struct.Flat_struct] }
%struct.Flat_struct = type { i8, float }

@.str = private unnamed_addr constant [16 x i8] c"Sum(M)  = %.2f\0A\00", align 1
@.str.1 = private unnamed_addr constant [20 x i8] c"Sum(MA[%d]) = %.2f\0A\00", align 1

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: read) uwtable
define dso_local double @AddMixed(ptr nofree noundef readonly captures(none) %0) local_unnamed_addr #0 {
  %2 = getelementptr inbounds nuw i8, ptr %0, i64 8
  %3 = load double, ptr %2, align 8, !tbaa !9
  %4 = fadd double %3, 0.000000e+00
  %5 = getelementptr inbounds nuw i8, ptr %0, i64 16
  %6 = load double, ptr %5, align 8, !tbaa !9
  %7 = fadd double %4, %6
  %8 = getelementptr inbounds nuw i8, ptr %0, i64 24
  %9 = load double, ptr %8, align 8, !tbaa !9
  %10 = fadd double %7, %9
  %11 = getelementptr inbounds nuw i8, ptr %0, i64 32
  %12 = load double, ptr %11, align 8, !tbaa !9
  %13 = fadd double %10, %12
  %14 = getelementptr inbounds nuw i8, ptr %0, i64 40
  %15 = load double, ptr %14, align 8, !tbaa !9
  %16 = fadd double %13, %15
  %17 = getelementptr inbounds nuw i8, ptr %0, i64 48
  %18 = load double, ptr %17, align 8, !tbaa !9
  %19 = fadd double %16, %18
  %20 = getelementptr inbounds nuw i8, ptr %0, i64 56
  %21 = load double, ptr %20, align 8, !tbaa !9
  %22 = fadd double %19, %21
  %23 = getelementptr inbounds nuw i8, ptr %0, i64 64
  %24 = load double, ptr %23, align 8, !tbaa !9
  %25 = fadd double %22, %24
  %26 = getelementptr inbounds nuw i8, ptr %0, i64 72
  %27 = load double, ptr %26, align 8, !tbaa !9
  %28 = fadd double %25, %27
  %29 = getelementptr inbounds nuw i8, ptr %0, i64 80
  %30 = load double, ptr %29, align 8, !tbaa !9
  %31 = fadd double %28, %30
  %32 = getelementptr inbounds nuw i8, ptr %0, i64 88
  br label %33

33:                                               ; preds = %1, %33
  %34 = phi i64 [ 0, %1 ], [ %66, %33 ]
  %35 = phi double [ %31, %1 ], [ %65, %33 ]
  %36 = getelementptr inbounds nuw [80 x i8], ptr %32, i64 %34
  %37 = load double, ptr %36, align 8, !tbaa !9
  %38 = fadd double %35, %37
  %39 = getelementptr inbounds nuw i8, ptr %36, i64 8
  %40 = load double, ptr %39, align 8, !tbaa !9
  %41 = fadd double %38, %40
  %42 = getelementptr inbounds nuw i8, ptr %36, i64 16
  %43 = load double, ptr %42, align 8, !tbaa !9
  %44 = fadd double %41, %43
  %45 = getelementptr inbounds nuw i8, ptr %36, i64 24
  %46 = load double, ptr %45, align 8, !tbaa !9
  %47 = fadd double %44, %46
  %48 = getelementptr inbounds nuw i8, ptr %36, i64 32
  %49 = load double, ptr %48, align 8, !tbaa !9
  %50 = fadd double %47, %49
  %51 = getelementptr inbounds nuw i8, ptr %36, i64 40
  %52 = load double, ptr %51, align 8, !tbaa !9
  %53 = fadd double %50, %52
  %54 = getelementptr inbounds nuw i8, ptr %36, i64 48
  %55 = load double, ptr %54, align 8, !tbaa !9
  %56 = fadd double %53, %55
  %57 = getelementptr inbounds nuw i8, ptr %36, i64 56
  %58 = load double, ptr %57, align 8, !tbaa !9
  %59 = fadd double %56, %58
  %60 = getelementptr inbounds nuw i8, ptr %36, i64 64
  %61 = load double, ptr %60, align 8, !tbaa !9
  %62 = fadd double %59, %61
  %63 = getelementptr inbounds nuw i8, ptr %36, i64 72
  %64 = load double, ptr %63, align 8, !tbaa !9
  %65 = fadd double %62, %64
  %66 = add nuw nsw i64 %34, 1
  %67 = icmp eq i64 %66, 10
  br i1 %67, label %68, label %33, !llvm.loop !11

68:                                               ; preds = %33
  %69 = getelementptr inbounds nuw i8, ptr %0, i64 888
  %70 = load i8, ptr %69, align 8, !tbaa !13
  %71 = sitofp i8 %70 to double
  %72 = fadd double %65, %71
  %73 = getelementptr inbounds nuw i8, ptr %0, i64 892
  %74 = load float, ptr %73, align 4, !tbaa !16
  %75 = fpext float %74 to double
  %76 = fadd double %72, %75
  %77 = getelementptr inbounds nuw i8, ptr %0, i64 896
  %78 = load i8, ptr %77, align 8, !tbaa !13
  %79 = sitofp i8 %78 to double
  %80 = fadd double %76, %79
  %81 = getelementptr inbounds nuw i8, ptr %0, i64 900
  %82 = load float, ptr %81, align 4, !tbaa !16
  %83 = fpext float %82 to double
  %84 = fadd double %80, %83
  %85 = getelementptr inbounds nuw i8, ptr %0, i64 904
  %86 = load i8, ptr %85, align 8, !tbaa !13
  %87 = sitofp i8 %86 to double
  %88 = fadd double %84, %87
  %89 = getelementptr inbounds nuw i8, ptr %0, i64 908
  %90 = load float, ptr %89, align 4, !tbaa !16
  %91 = fpext float %90 to double
  %92 = fadd double %88, %91
  %93 = getelementptr inbounds nuw i8, ptr %0, i64 912
  %94 = load i8, ptr %93, align 8, !tbaa !13
  %95 = sitofp i8 %94 to double
  %96 = fadd double %92, %95
  %97 = getelementptr inbounds nuw i8, ptr %0, i64 916
  %98 = load float, ptr %97, align 4, !tbaa !16
  %99 = fpext float %98 to double
  %100 = fadd double %96, %99
  %101 = getelementptr inbounds nuw i8, ptr %0, i64 920
  %102 = load i8, ptr %101, align 8, !tbaa !13
  %103 = sitofp i8 %102 to double
  %104 = fadd double %100, %103
  %105 = getelementptr inbounds nuw i8, ptr %0, i64 924
  %106 = load float, ptr %105, align 4, !tbaa !16
  %107 = fpext float %106 to double
  %108 = fadd double %104, %107
  %109 = getelementptr inbounds nuw i8, ptr %0, i64 928
  %110 = load i8, ptr %109, align 8, !tbaa !13
  %111 = sitofp i8 %110 to double
  %112 = fadd double %108, %111
  %113 = getelementptr inbounds nuw i8, ptr %0, i64 932
  %114 = load float, ptr %113, align 4, !tbaa !16
  %115 = fpext float %114 to double
  %116 = fadd double %112, %115
  %117 = getelementptr inbounds nuw i8, ptr %0, i64 936
  %118 = load i8, ptr %117, align 8, !tbaa !13
  %119 = sitofp i8 %118 to double
  %120 = fadd double %116, %119
  %121 = getelementptr inbounds nuw i8, ptr %0, i64 940
  %122 = load float, ptr %121, align 4, !tbaa !16
  %123 = fpext float %122 to double
  %124 = fadd double %120, %123
  %125 = getelementptr inbounds nuw i8, ptr %0, i64 944
  %126 = load i8, ptr %125, align 8, !tbaa !13
  %127 = sitofp i8 %126 to double
  %128 = fadd double %124, %127
  %129 = getelementptr inbounds nuw i8, ptr %0, i64 948
  %130 = load float, ptr %129, align 4, !tbaa !16
  %131 = fpext float %130 to double
  %132 = fadd double %128, %131
  %133 = getelementptr inbounds nuw i8, ptr %0, i64 952
  %134 = load i8, ptr %133, align 8, !tbaa !13
  %135 = sitofp i8 %134 to double
  %136 = fadd double %132, %135
  %137 = getelementptr inbounds nuw i8, ptr %0, i64 956
  %138 = load float, ptr %137, align 4, !tbaa !16
  %139 = fpext float %138 to double
  %140 = fadd double %136, %139
  %141 = getelementptr inbounds nuw i8, ptr %0, i64 960
  %142 = load i8, ptr %141, align 8, !tbaa !13
  %143 = sitofp i8 %142 to double
  %144 = fadd double %140, %143
  %145 = getelementptr inbounds nuw i8, ptr %0, i64 964
  %146 = load float, ptr %145, align 4, !tbaa !16
  %147 = fpext float %146 to double
  %148 = fadd double %144, %147
  ret double %148
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: write) uwtable
define dso_local void @InitializeMixed(ptr nofree noundef writeonly captures(none) initializes((8, 88)) %0, i32 noundef %1) local_unnamed_addr #2 {
  %3 = getelementptr inbounds nuw i8, ptr %0, i64 8
  %4 = insertelement <2 x i32> poison, i32 %1, i64 0
  %5 = shufflevector <2 x i32> %4, <2 x i32> poison, <2 x i32> zeroinitializer
  %6 = add <2 x i32> %5, <i32 0, i32 1>
  %7 = sitofp <2 x i32> %6 to <2 x double>
  store <2 x double> %7, ptr %3, align 8, !tbaa !9
  %8 = add <2 x i32> %5, <i32 2, i32 3>
  %9 = getelementptr inbounds nuw i8, ptr %0, i64 24
  %10 = sitofp <2 x i32> %8 to <2 x double>
  store <2 x double> %10, ptr %9, align 8, !tbaa !9
  %11 = add <2 x i32> %5, <i32 4, i32 5>
  %12 = getelementptr inbounds nuw i8, ptr %0, i64 40
  %13 = sitofp <2 x i32> %11 to <2 x double>
  store <2 x double> %13, ptr %12, align 8, !tbaa !9
  %14 = add <2 x i32> %5, <i32 6, i32 7>
  %15 = getelementptr inbounds nuw i8, ptr %0, i64 56
  %16 = sitofp <2 x i32> %14 to <2 x double>
  store <2 x double> %16, ptr %15, align 8, !tbaa !9
  %17 = add <2 x i32> %5, <i32 8, i32 9>
  %18 = getelementptr inbounds nuw i8, ptr %0, i64 72
  %19 = sitofp <2 x i32> %17 to <2 x double>
  store <2 x double> %19, ptr %18, align 8, !tbaa !9
  %20 = getelementptr inbounds nuw i8, ptr %0, i64 88
  br label %21

21:                                               ; preds = %2, %21
  %22 = phi i64 [ 0, %2 ], [ %45, %21 ]
  %23 = trunc i64 %22 to i32
  %24 = mul i32 %23, 10
  %25 = add i32 %24, %1
  %26 = getelementptr inbounds nuw [80 x i8], ptr %20, i64 %22
  %27 = sitofp i32 %25 to double
  store double %27, ptr %26, align 8, !tbaa !9
  %28 = getelementptr inbounds nuw i8, ptr %26, i64 8
  %29 = insertelement <2 x i32> poison, i32 %25, i64 0
  %30 = shufflevector <2 x i32> %29, <2 x i32> poison, <2 x i32> zeroinitializer
  %31 = add <2 x i32> %30, <i32 1, i32 2>
  %32 = sitofp <2 x i32> %31 to <2 x double>
  store <2 x double> %32, ptr %28, align 8, !tbaa !9
  %33 = getelementptr inbounds nuw i8, ptr %26, i64 24
  %34 = add <2 x i32> %30, <i32 3, i32 4>
  %35 = sitofp <2 x i32> %34 to <2 x double>
  store <2 x double> %35, ptr %33, align 8, !tbaa !9
  %36 = getelementptr inbounds nuw i8, ptr %26, i64 40
  %37 = add <2 x i32> %30, <i32 5, i32 6>
  %38 = sitofp <2 x i32> %37 to <2 x double>
  store <2 x double> %38, ptr %36, align 8, !tbaa !9
  %39 = getelementptr inbounds nuw i8, ptr %26, i64 56
  %40 = add <2 x i32> %30, <i32 7, i32 8>
  %41 = sitofp <2 x i32> %40 to <2 x double>
  store <2 x double> %41, ptr %39, align 8, !tbaa !9
  %42 = add i32 %25, 9
  %43 = sitofp i32 %42 to double
  %44 = getelementptr inbounds nuw i8, ptr %26, i64 72
  store double %43, ptr %44, align 8, !tbaa !9
  %45 = add nuw nsw i64 %22, 1
  %46 = icmp eq i64 %45, 10
  br i1 %46, label %47, label %21, !llvm.loop !17

47:                                               ; preds = %21
  %48 = getelementptr inbounds nuw i8, ptr %0, i64 888
  %49 = sitofp i32 %1 to float
  store i8 81, ptr %48, align 8, !tbaa !13
  %50 = getelementptr inbounds nuw i8, ptr %0, i64 892
  store float %49, ptr %50, align 4, !tbaa !16
  %51 = getelementptr inbounds nuw i8, ptr %0, i64 896
  store i8 81, ptr %51, align 8, !tbaa !13
  %52 = getelementptr inbounds nuw i8, ptr %0, i64 900
  store float %49, ptr %52, align 4, !tbaa !16
  %53 = getelementptr inbounds nuw i8, ptr %0, i64 904
  store i8 81, ptr %53, align 8, !tbaa !13
  %54 = getelementptr inbounds nuw i8, ptr %0, i64 908
  store float %49, ptr %54, align 4, !tbaa !16
  %55 = getelementptr inbounds nuw i8, ptr %0, i64 912
  store i8 81, ptr %55, align 8, !tbaa !13
  %56 = getelementptr inbounds nuw i8, ptr %0, i64 916
  store float %49, ptr %56, align 4, !tbaa !16
  %57 = getelementptr inbounds nuw i8, ptr %0, i64 920
  store i8 81, ptr %57, align 8, !tbaa !13
  %58 = getelementptr inbounds nuw i8, ptr %0, i64 924
  store float %49, ptr %58, align 4, !tbaa !16
  %59 = getelementptr inbounds nuw i8, ptr %0, i64 928
  store i8 81, ptr %59, align 8, !tbaa !13
  %60 = getelementptr inbounds nuw i8, ptr %0, i64 932
  store float %49, ptr %60, align 4, !tbaa !16
  %61 = getelementptr inbounds nuw i8, ptr %0, i64 936
  store i8 81, ptr %61, align 8, !tbaa !13
  %62 = getelementptr inbounds nuw i8, ptr %0, i64 940
  store float %49, ptr %62, align 4, !tbaa !16
  %63 = getelementptr inbounds nuw i8, ptr %0, i64 944
  store i8 81, ptr %63, align 8, !tbaa !13
  %64 = getelementptr inbounds nuw i8, ptr %0, i64 948
  store float %49, ptr %64, align 4, !tbaa !16
  %65 = getelementptr inbounds nuw i8, ptr %0, i64 952
  store i8 81, ptr %65, align 8, !tbaa !13
  %66 = getelementptr inbounds nuw i8, ptr %0, i64 956
  store float %49, ptr %66, align 4, !tbaa !16
  %67 = getelementptr inbounds nuw i8, ptr %0, i64 960
  store i8 81, ptr %67, align 8, !tbaa !13
  %68 = getelementptr inbounds nuw i8, ptr %0, i64 964
  store float %49, ptr %68, align 4, !tbaa !16
  ret void
}

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main(i32 noundef %0, ptr nofree noundef readnone captures(none) %1) local_unnamed_addr #3 {
  %3 = alloca %struct.Mixed_struct, align 8
  %4 = alloca [4 x %struct.Mixed_struct], align 16
  call void @llvm.lifetime.start.p0(ptr nonnull %3) #5
  call void @llvm.lifetime.start.p0(ptr nonnull %4) #5
  call void @InitializeMixed(ptr noundef nonnull %3, i32 noundef 100)
  %5 = call double @AddMixed(ptr noundef nonnull %3)
  %6 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %5)
  call void @InitializeMixed(ptr noundef nonnull %4, i32 noundef 200)
  %7 = call double @AddMixed(ptr noundef nonnull %4)
  %8 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i32 noundef 0, double noundef %7)
  %9 = getelementptr inbounds nuw i8, ptr %4, i64 968
  call void @InitializeMixed(ptr noundef nonnull %9, i32 noundef 300)
  %10 = call double @AddMixed(ptr noundef nonnull %9)
  %11 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i32 noundef 1, double noundef %10)
  %12 = getelementptr inbounds nuw i8, ptr %4, i64 1936
  call void @InitializeMixed(ptr noundef nonnull %12, i32 noundef 400)
  %13 = call double @AddMixed(ptr noundef nonnull %12)
  %14 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i32 noundef 2, double noundef %13)
  %15 = getelementptr inbounds nuw i8, ptr %4, i64 2904
  call void @InitializeMixed(ptr noundef nonnull %15, i32 noundef 500)
  %16 = call double @AddMixed(ptr noundef nonnull %15)
  %17 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i32 noundef 3, double noundef %16)
  call void @llvm.lifetime.end.p0(ptr nonnull %4) #5
  call void @llvm.lifetime.end.p0(ptr nonnull %3) #5
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #4

attributes #0 = { nofree norecurse nosync nounwind memory(argmem: read) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nofree norecurse nosync nounwind memory(argmem: write) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!9 = !{!10, !10, i64 0}
!10 = !{!"double", !7, i64 0}
!11 = distinct !{!11, !12}
!12 = !{!"llvm.loop.mustprogress"}
!13 = !{!14, !7, i64 0}
!14 = !{!"Flat_struct", !7, i64 0, !15, i64 4}
!15 = !{!"float", !7, i64 0}
!16 = !{!14, !15, i64 4}
!17 = distinct !{!17, !12}
