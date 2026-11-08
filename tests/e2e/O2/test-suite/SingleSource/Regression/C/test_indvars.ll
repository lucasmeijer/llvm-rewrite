; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/test_indvars.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/test_indvars.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/test_indvars.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [18 x i8] c"Checksum = %.0lf\0A\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = alloca [100 x [200 x i32]], align 16
  call void @llvm.lifetime.start.p0(ptr nonnull %1) #4
  br label %2

2:                                                ; preds = %2, %0
  %3 = phi i64 [ 0, %0 ], [ %18, %2 ]
  %4 = mul nuw nsw i64 %3, 1600
  %5 = getelementptr nuw i8, ptr %1, i64 %4
  call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(800) %5, i8 0, i64 800, i1 false), !tbaa !9
  %6 = mul nuw i64 %3, 1600
  %7 = getelementptr nuw i8, ptr %1, i64 %6
  %8 = getelementptr nuw i8, ptr %7, i64 1600
  call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(800) %8, i8 0, i64 800, i1 false), !tbaa !9
  %9 = mul nuw i64 %3, 1600
  %10 = getelementptr nuw i8, ptr %1, i64 %9
  %11 = getelementptr nuw i8, ptr %10, i64 3200
  call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(800) %11, i8 0, i64 800, i1 false), !tbaa !9
  %12 = mul nuw i64 %3, 1600
  %13 = getelementptr nuw i8, ptr %1, i64 %12
  %14 = getelementptr nuw i8, ptr %13, i64 4800
  call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(800) %14, i8 0, i64 800, i1 false), !tbaa !9
  %15 = mul nuw i64 %3, 1600
  %16 = getelementptr nuw i8, ptr %1, i64 %15
  %17 = getelementptr nuw i8, ptr %16, i64 6400
  call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(800) %17, i8 0, i64 800, i1 false), !tbaa !9
  %18 = add nuw nsw i64 %3, 5
  %19 = icmp eq i64 %18, 50
  br i1 %19, label %20, label %2, !llvm.loop !10

20:                                               ; preds = %2
  %21 = getelementptr inbounds nuw i8, ptr %1, i64 2424
  store i32 12345, ptr %21, align 8, !tbaa !9
  %22 = getelementptr inbounds nuw i8, ptr %1, i64 4
  store i32 12345, ptr %22, align 4, !tbaa !9
  br label %23

23:                                               ; preds = %23, %20
  %24 = phi i64 [ 0, %20 ], [ %39, %23 ]
  %25 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %24
  %26 = trunc nuw nsw i64 %24 to i32
  store i32 %26, ptr %25, align 8, !tbaa !9
  %27 = add nuw nsw i64 %24, 2
  %28 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %27
  %29 = trunc nuw nsw i64 %27 to i32
  store i32 %29, ptr %28, align 8, !tbaa !9
  %30 = add nuw nsw i64 %24, 4
  %31 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %30
  %32 = trunc nuw nsw i64 %30 to i32
  store i32 %32, ptr %31, align 8, !tbaa !9
  %33 = add nuw nsw i64 %24, 6
  %34 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %33
  %35 = trunc nuw nsw i64 %33 to i32
  store i32 %35, ptr %34, align 8, !tbaa !9
  %36 = add nuw nsw i64 %24, 8
  %37 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %36
  %38 = trunc nuw nsw i64 %36 to i32
  store i32 %38, ptr %37, align 8, !tbaa !9
  %39 = add nuw nsw i64 %24, 10
  %40 = icmp samesign ult i64 %24, 90
  br i1 %40, label %23, label %41, !llvm.loop !12

41:                                               ; preds = %23
  %42 = getelementptr inbounds nuw i8, ptr %1, i64 12
  %43 = getelementptr inbounds nuw i8, ptr %1, i64 28
  store <4 x i32> <i32 7, i32 8, i32 9, i32 10>, ptr %42, align 4, !tbaa !9
  store <4 x i32> <i32 11, i32 12, i32 13, i32 14>, ptr %43, align 4, !tbaa !9
  %44 = getelementptr inbounds nuw i8, ptr %1, i64 44
  %45 = getelementptr inbounds nuw i8, ptr %1, i64 60
  store <4 x i32> <i32 15, i32 16, i32 17, i32 18>, ptr %44, align 4, !tbaa !9
  store <4 x i32> <i32 19, i32 20, i32 21, i32 22>, ptr %45, align 4, !tbaa !9
  %46 = getelementptr inbounds nuw i8, ptr %1, i64 76
  %47 = getelementptr inbounds nuw i8, ptr %1, i64 92
  store <4 x i32> <i32 23, i32 24, i32 25, i32 26>, ptr %46, align 4, !tbaa !9
  store <4 x i32> <i32 27, i32 28, i32 29, i32 30>, ptr %47, align 4, !tbaa !9
  %48 = getelementptr inbounds nuw i8, ptr %1, i64 108
  %49 = getelementptr inbounds nuw i8, ptr %1, i64 124
  store <4 x i32> <i32 31, i32 32, i32 33, i32 34>, ptr %48, align 4, !tbaa !9
  store <4 x i32> <i32 35, i32 36, i32 37, i32 38>, ptr %49, align 4, !tbaa !9
  %50 = getelementptr inbounds nuw i8, ptr %1, i64 140
  %51 = getelementptr inbounds nuw i8, ptr %1, i64 156
  store <4 x i32> <i32 39, i32 40, i32 41, i32 42>, ptr %50, align 4, !tbaa !9
  store <4 x i32> <i32 43, i32 44, i32 45, i32 46>, ptr %51, align 4, !tbaa !9
  %52 = getelementptr inbounds nuw i8, ptr %1, i64 172
  %53 = getelementptr inbounds nuw i8, ptr %1, i64 188
  store <4 x i32> <i32 47, i32 48, i32 49, i32 50>, ptr %52, align 4, !tbaa !9
  store <4 x i32> <i32 51, i32 52, i32 53, i32 54>, ptr %53, align 4, !tbaa !9
  %54 = getelementptr inbounds nuw i8, ptr %1, i64 204
  %55 = getelementptr inbounds nuw i8, ptr %1, i64 220
  store <4 x i32> <i32 55, i32 56, i32 57, i32 58>, ptr %54, align 4, !tbaa !9
  store <4 x i32> <i32 59, i32 60, i32 61, i32 62>, ptr %55, align 4, !tbaa !9
  %56 = getelementptr inbounds nuw i8, ptr %1, i64 236
  %57 = getelementptr inbounds nuw i8, ptr %1, i64 252
  store <4 x i32> <i32 63, i32 64, i32 65, i32 66>, ptr %56, align 4, !tbaa !9
  store <4 x i32> <i32 67, i32 68, i32 69, i32 70>, ptr %57, align 4, !tbaa !9
  %58 = getelementptr inbounds nuw i8, ptr %1, i64 268
  %59 = getelementptr inbounds nuw i8, ptr %1, i64 284
  store <4 x i32> <i32 71, i32 72, i32 73, i32 74>, ptr %58, align 4, !tbaa !9
  store <4 x i32> <i32 75, i32 76, i32 77, i32 78>, ptr %59, align 4, !tbaa !9
  %60 = getelementptr inbounds nuw i8, ptr %1, i64 300
  %61 = getelementptr inbounds nuw i8, ptr %1, i64 316
  store <4 x i32> <i32 79, i32 80, i32 81, i32 82>, ptr %60, align 4, !tbaa !9
  store <4 x i32> <i32 83, i32 84, i32 85, i32 86>, ptr %61, align 4, !tbaa !9
  %62 = getelementptr inbounds nuw i8, ptr %1, i64 332
  %63 = getelementptr inbounds nuw i8, ptr %1, i64 348
  store <4 x i32> <i32 87, i32 88, i32 89, i32 90>, ptr %62, align 4, !tbaa !9
  store <4 x i32> <i32 91, i32 92, i32 93, i32 94>, ptr %63, align 4, !tbaa !9
  %64 = getelementptr inbounds nuw i8, ptr %1, i64 364
  %65 = getelementptr inbounds nuw i8, ptr %1, i64 380
  store <4 x i32> <i32 95, i32 96, i32 97, i32 98>, ptr %64, align 4, !tbaa !9
  store <4 x i32> <i32 99, i32 100, i32 101, i32 102>, ptr %65, align 4, !tbaa !9
  %66 = getelementptr inbounds nuw i8, ptr %1, i64 396
  store i32 103, ptr %66, align 4, !tbaa !9
  %67 = getelementptr inbounds nuw i8, ptr %1, i64 400
  store i32 104, ptr %67, align 16, !tbaa !9
  %68 = getelementptr inbounds nuw i8, ptr %1, i64 404
  store i32 105, ptr %68, align 4, !tbaa !9
  %69 = getelementptr inbounds nuw i8, ptr %1, i64 408
  store i32 106, ptr %69, align 8, !tbaa !9
  br label %70

70:                                               ; preds = %41, %70
  %71 = phi i64 [ %86, %70 ], [ 13, %41 ]
  %72 = getelementptr inbounds nuw [800 x i8], ptr %1, i64 %71
  %73 = getelementptr inbounds nuw [4 x i8], ptr %72, i64 %71
  %74 = load i32, ptr %73, align 4, !tbaa !9
  %75 = insertelement <4 x i32> poison, i32 %74, i64 0
  %76 = shufflevector <4 x i32> %75, <4 x i32> poison, <4 x i32> zeroinitializer
  %77 = getelementptr inbounds nuw i8, ptr %72, i64 16
  store <4 x i32> %76, ptr %72, align 16, !tbaa !9
  store <4 x i32> %76, ptr %77, align 16, !tbaa !9
  %78 = getelementptr inbounds nuw i8, ptr %72, i64 32
  %79 = getelementptr inbounds nuw i8, ptr %72, i64 48
  store <4 x i32> %76, ptr %78, align 16, !tbaa !9
  store <4 x i32> %76, ptr %79, align 16, !tbaa !9
  %80 = getelementptr inbounds nuw i8, ptr %72, i64 64
  %81 = getelementptr inbounds nuw i8, ptr %72, i64 80
  store <4 x i32> %76, ptr %80, align 16, !tbaa !9
  store <4 x i32> %76, ptr %81, align 16, !tbaa !9
  %82 = getelementptr inbounds nuw i8, ptr %72, i64 96
  %83 = getelementptr inbounds nuw i8, ptr %72, i64 112
  store <4 x i32> %76, ptr %82, align 16, !tbaa !9
  store <4 x i32> %76, ptr %83, align 16, !tbaa !9
  %84 = getelementptr inbounds nuw i8, ptr %72, i64 128
  store i32 %74, ptr %84, align 16, !tbaa !9
  %85 = getelementptr inbounds nuw i8, ptr %72, i64 132
  store i32 %74, ptr %85, align 4, !tbaa !9
  %86 = add nuw nsw i64 %71, 1
  %87 = icmp eq i64 %86, 100
  br i1 %87, label %88, label %70, !llvm.loop !13

88:                                               ; preds = %70, %121
  %89 = phi i64 [ %122, %121 ], [ 0, %70 ]
  %90 = phi double [ %118, %121 ], [ 0.000000e+00, %70 ]
  %91 = getelementptr inbounds nuw [800 x i8], ptr %1, i64 %89
  br label %92

92:                                               ; preds = %92, %88
  %93 = phi i64 [ 0, %88 ], [ %119, %92 ]
  %94 = phi double [ %90, %88 ], [ %118, %92 ]
  %95 = getelementptr inbounds nuw [4 x i8], ptr %91, i64 %93
  %96 = load i32, ptr %95, align 4, !tbaa !9
  %97 = sitofp i32 %96 to double
  %98 = fadd double %94, %97
  %99 = getelementptr inbounds nuw [4 x i8], ptr %91, i64 %93
  %100 = getelementptr inbounds nuw i8, ptr %99, i64 4
  %101 = load i32, ptr %100, align 4, !tbaa !9
  %102 = sitofp i32 %101 to double
  %103 = fadd double %98, %102
  %104 = getelementptr inbounds nuw [4 x i8], ptr %91, i64 %93
  %105 = getelementptr inbounds nuw i8, ptr %104, i64 8
  %106 = load i32, ptr %105, align 4, !tbaa !9
  %107 = sitofp i32 %106 to double
  %108 = fadd double %103, %107
  %109 = getelementptr inbounds nuw [4 x i8], ptr %91, i64 %93
  %110 = getelementptr inbounds nuw i8, ptr %109, i64 12
  %111 = load i32, ptr %110, align 4, !tbaa !9
  %112 = sitofp i32 %111 to double
  %113 = fadd double %108, %112
  %114 = getelementptr inbounds nuw [4 x i8], ptr %91, i64 %93
  %115 = getelementptr inbounds nuw i8, ptr %114, i64 16
  %116 = load i32, ptr %115, align 4, !tbaa !9
  %117 = sitofp i32 %116 to double
  %118 = fadd double %113, %117
  %119 = add nuw nsw i64 %93, 5
  %120 = icmp eq i64 %119, 200
  br i1 %120, label %121, label %92, !llvm.loop !14

121:                                              ; preds = %92
  %122 = add nuw nsw i64 %89, 2
  %123 = icmp samesign ult i64 %89, 98
  br i1 %123, label %88, label %124, !llvm.loop !15

124:                                              ; preds = %121
  %125 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %118)
  call void @llvm.lifetime.end.p0(ptr nonnull %1) #4
  ret i32 0
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #2

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #3

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
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
!10 = distinct !{!10, !11}
!11 = !{!"llvm.loop.mustprogress"}
!12 = distinct !{!12, !11}
!13 = distinct !{!13, !11}
!14 = distinct !{!14, !11}
!15 = distinct !{!15, !11}
