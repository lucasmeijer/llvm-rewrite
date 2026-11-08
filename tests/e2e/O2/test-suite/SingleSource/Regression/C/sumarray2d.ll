; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/sumarray2d.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/sumarray2d.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/sumarray2d.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [23 x i8] c"Sum(Array[%d,%d] = %d\0A\00", align 1

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: read) uwtable
define dso_local i32 @SumArray(ptr nofree noundef readonly captures(none) %0, i32 noundef %1, i32 noundef %2) local_unnamed_addr #0 {
  %4 = icmp eq i32 %1, 0
  br i1 %4, label %49, label %5

5:                                                ; preds = %3
  %6 = icmp eq i32 %2, 0
  %7 = zext i32 %1 to i64
  %8 = zext i32 %2 to i64
  %9 = icmp ult i32 %2, 8
  %10 = and i64 %8, 4294967288
  %11 = icmp eq i64 %10, %8
  br label %12

12:                                               ; preds = %5, %45
  %13 = phi i64 [ 0, %5 ], [ %47, %45 ]
  %14 = phi i32 [ 0, %5 ], [ %46, %45 ]
  br i1 %6, label %45, label %15

15:                                               ; preds = %12
  %16 = getelementptr inbounds nuw [400 x i8], ptr %0, i64 %13
  br i1 %9, label %34, label %17

17:                                               ; preds = %15
  %18 = insertelement <4 x i32> <i32 poison, i32 0, i32 0, i32 0>, i32 %14, i64 0
  br label %19

19:                                               ; preds = %19, %17
  %20 = phi i64 [ 0, %17 ], [ %29, %19 ]
  %21 = phi <4 x i32> [ %18, %17 ], [ %27, %19 ]
  %22 = phi <4 x i32> [ zeroinitializer, %17 ], [ %28, %19 ]
  %23 = getelementptr inbounds nuw [4 x i8], ptr %16, i64 %20
  %24 = getelementptr inbounds nuw i8, ptr %23, i64 16
  %25 = load <4 x i32>, ptr %23, align 4, !tbaa !9
  %26 = load <4 x i32>, ptr %24, align 4, !tbaa !9
  %27 = add <4 x i32> %25, %21
  %28 = add <4 x i32> %26, %22
  %29 = add nuw i64 %20, 8
  %30 = icmp eq i64 %29, %10
  br i1 %30, label %31, label %19, !llvm.loop !10

31:                                               ; preds = %19
  %32 = add <4 x i32> %28, %27
  %33 = tail call i32 @llvm.vector.reduce.add.v4i32(<4 x i32> %32)
  br i1 %11, label %45, label %34

34:                                               ; preds = %15, %31
  %35 = phi i64 [ 0, %15 ], [ %10, %31 ]
  %36 = phi i32 [ %14, %15 ], [ %33, %31 ]
  br label %37

37:                                               ; preds = %34, %37
  %38 = phi i64 [ %43, %37 ], [ %35, %34 ]
  %39 = phi i32 [ %42, %37 ], [ %36, %34 ]
  %40 = getelementptr inbounds nuw [4 x i8], ptr %16, i64 %38
  %41 = load i32, ptr %40, align 4, !tbaa !9
  %42 = add nsw i32 %41, %39
  %43 = add nuw nsw i64 %38, 1
  %44 = icmp eq i64 %43, %8
  br i1 %44, label %45, label %37, !llvm.loop !14

45:                                               ; preds = %37, %31, %12
  %46 = phi i32 [ %14, %12 ], [ %33, %31 ], [ %42, %37 ]
  %47 = add nuw nsw i64 %13, 1
  %48 = icmp eq i64 %47, %7
  br i1 %48, label %49, label %12, !llvm.loop !15

49:                                               ; preds = %45, %3
  %50 = phi i32 [ 0, %3 ], [ %46, %45 ]
  ret i32 %50
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #2 {
  %1 = alloca [100 x [100 x i32]], align 16
  call void @llvm.lifetime.start.p0(ptr nonnull %1) #5
  br label %2

2:                                                ; preds = %2, %0
  %3 = phi i64 [ 0, %0 ], [ %28, %2 ]
  %4 = getelementptr inbounds nuw [400 x i8], ptr %1, i64 %3
  %5 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %3
  %6 = trunc i64 %3 to i32
  %7 = sub nsw i32 0, %6
  store i32 %7, ptr %5, align 4, !tbaa !9
  %8 = add nuw nsw i64 %3, 1
  %9 = getelementptr inbounds nuw [400 x i8], ptr %1, i64 %8
  %10 = getelementptr inbounds nuw [4 x i8], ptr %9, i64 %8
  %11 = trunc i64 %3 to i32
  %12 = xor i32 %11, -1
  store i32 %12, ptr %10, align 4, !tbaa !9
  %13 = add nuw nsw i64 %3, 2
  %14 = getelementptr inbounds nuw [400 x i8], ptr %1, i64 %13
  %15 = getelementptr inbounds nuw [4 x i8], ptr %14, i64 %13
  %16 = trunc i64 %13 to i32
  %17 = sub nsw i32 0, %16
  store i32 %17, ptr %15, align 4, !tbaa !9
  %18 = add nuw nsw i64 %3, 3
  %19 = getelementptr inbounds nuw [400 x i8], ptr %1, i64 %18
  %20 = getelementptr inbounds nuw [4 x i8], ptr %19, i64 %18
  %21 = trunc i64 %18 to i32
  %22 = sub nsw i32 0, %21
  store i32 %22, ptr %20, align 4, !tbaa !9
  %23 = add nuw nsw i64 %3, 4
  %24 = getelementptr inbounds nuw [400 x i8], ptr %1, i64 %23
  %25 = getelementptr inbounds nuw [4 x i8], ptr %24, i64 %23
  %26 = trunc i64 %23 to i32
  %27 = sub nsw i32 0, %26
  store i32 %27, ptr %25, align 4, !tbaa !9
  %28 = add nuw nsw i64 %3, 5
  %29 = icmp eq i64 %28, 100
  br i1 %29, label %30, label %2, !llvm.loop !16

30:                                               ; preds = %2, %50
  %31 = phi i64 [ %51, %50 ], [ 0, %2 ]
  %32 = getelementptr inbounds nuw [400 x i8], ptr %1, i64 %31
  br label %33

33:                                               ; preds = %47, %30
  %34 = phi i64 [ 0, %30 ], [ %48, %47 ]
  %35 = icmp eq i64 %34, %31
  br i1 %35, label %40, label %36

36:                                               ; preds = %33
  %37 = add nuw nsw i64 %34, %31
  %38 = getelementptr inbounds nuw [4 x i8], ptr %32, i64 %34
  %39 = trunc nuw nsw i64 %37 to i32
  store i32 %39, ptr %38, align 8, !tbaa !9
  br label %40

40:                                               ; preds = %33, %36
  %41 = or disjoint i64 %34, 1
  %42 = icmp eq i64 %41, %31
  br i1 %42, label %47, label %43

43:                                               ; preds = %40
  %44 = add nuw nsw i64 %41, %31
  %45 = getelementptr inbounds nuw [4 x i8], ptr %32, i64 %41
  %46 = trunc nuw nsw i64 %44 to i32
  store i32 %46, ptr %45, align 4, !tbaa !9
  br label %47

47:                                               ; preds = %43, %40
  %48 = add nuw nsw i64 %34, 2
  %49 = icmp eq i64 %48, 100
  br i1 %49, label %50, label %33, !llvm.loop !17

50:                                               ; preds = %47
  %51 = add nuw nsw i64 %31, 1
  %52 = icmp eq i64 %51, 100
  br i1 %52, label %53, label %30, !llvm.loop !18

53:                                               ; preds = %50, %53
  %54 = phi i64 [ %142, %53 ], [ 0, %50 ]
  %55 = phi i32 [ %141, %53 ], [ 0, %50 ]
  %56 = getelementptr inbounds nuw [400 x i8], ptr %1, i64 %54
  %57 = getelementptr inbounds nuw i8, ptr %56, i64 368
  %58 = load <4 x i32>, ptr %57, align 16, !tbaa !9
  %59 = getelementptr inbounds nuw i8, ptr %56, i64 336
  %60 = load <4 x i32>, ptr %59, align 16, !tbaa !9
  %61 = getelementptr inbounds nuw i8, ptr %56, i64 304
  %62 = load <4 x i32>, ptr %61, align 16, !tbaa !9
  %63 = getelementptr inbounds nuw i8, ptr %56, i64 272
  %64 = load <4 x i32>, ptr %63, align 16, !tbaa !9
  %65 = getelementptr inbounds nuw i8, ptr %56, i64 240
  %66 = load <4 x i32>, ptr %65, align 16, !tbaa !9
  %67 = getelementptr inbounds nuw i8, ptr %56, i64 208
  %68 = load <4 x i32>, ptr %67, align 16, !tbaa !9
  %69 = getelementptr inbounds nuw i8, ptr %56, i64 176
  %70 = load <4 x i32>, ptr %69, align 16, !tbaa !9
  %71 = getelementptr inbounds nuw i8, ptr %56, i64 144
  %72 = load <4 x i32>, ptr %71, align 16, !tbaa !9
  %73 = getelementptr inbounds nuw i8, ptr %56, i64 112
  %74 = load <4 x i32>, ptr %73, align 16, !tbaa !9
  %75 = getelementptr inbounds nuw i8, ptr %56, i64 80
  %76 = load <4 x i32>, ptr %75, align 16, !tbaa !9
  %77 = getelementptr inbounds nuw i8, ptr %56, i64 48
  %78 = load <4 x i32>, ptr %77, align 16, !tbaa !9
  %79 = getelementptr inbounds nuw i8, ptr %56, i64 16
  %80 = load <4 x i32>, ptr %79, align 16, !tbaa !9
  %81 = add <4 x i32> %78, %80
  %82 = add <4 x i32> %76, %81
  %83 = add <4 x i32> %74, %82
  %84 = add <4 x i32> %72, %83
  %85 = add <4 x i32> %70, %84
  %86 = add <4 x i32> %68, %85
  %87 = add <4 x i32> %66, %86
  %88 = add <4 x i32> %64, %87
  %89 = add <4 x i32> %62, %88
  %90 = add <4 x i32> %60, %89
  %91 = add <4 x i32> %58, %90
  %92 = getelementptr inbounds nuw i8, ptr %56, i64 352
  %93 = load <4 x i32>, ptr %92, align 16, !tbaa !9
  %94 = getelementptr inbounds nuw i8, ptr %56, i64 320
  %95 = load <4 x i32>, ptr %94, align 16, !tbaa !9
  %96 = getelementptr inbounds nuw i8, ptr %56, i64 288
  %97 = load <4 x i32>, ptr %96, align 16, !tbaa !9
  %98 = getelementptr inbounds nuw i8, ptr %56, i64 256
  %99 = load <4 x i32>, ptr %98, align 16, !tbaa !9
  %100 = getelementptr inbounds nuw i8, ptr %56, i64 224
  %101 = load <4 x i32>, ptr %100, align 16, !tbaa !9
  %102 = getelementptr inbounds nuw i8, ptr %56, i64 192
  %103 = load <4 x i32>, ptr %102, align 16, !tbaa !9
  %104 = getelementptr inbounds nuw i8, ptr %56, i64 160
  %105 = load <4 x i32>, ptr %104, align 16, !tbaa !9
  %106 = getelementptr inbounds nuw i8, ptr %56, i64 128
  %107 = load <4 x i32>, ptr %106, align 16, !tbaa !9
  %108 = getelementptr inbounds nuw i8, ptr %56, i64 96
  %109 = load <4 x i32>, ptr %108, align 16, !tbaa !9
  %110 = getelementptr inbounds nuw i8, ptr %56, i64 64
  %111 = load <4 x i32>, ptr %110, align 16, !tbaa !9
  %112 = getelementptr inbounds nuw i8, ptr %56, i64 32
  %113 = load <4 x i32>, ptr %112, align 16, !tbaa !9
  %114 = load <4 x i32>, ptr %56, align 16, !tbaa !9
  %115 = insertelement <4 x i32> <i32 poison, i32 0, i32 0, i32 0>, i32 %55, i64 0
  %116 = add <4 x i32> %114, %115
  %117 = add <4 x i32> %113, %116
  %118 = add <4 x i32> %111, %117
  %119 = add <4 x i32> %109, %118
  %120 = add <4 x i32> %107, %119
  %121 = add <4 x i32> %105, %120
  %122 = add <4 x i32> %103, %121
  %123 = add <4 x i32> %101, %122
  %124 = add <4 x i32> %99, %123
  %125 = add <4 x i32> %97, %124
  %126 = add <4 x i32> %95, %125
  %127 = add <4 x i32> %93, %126
  %128 = add <4 x i32> %91, %127
  %129 = tail call i32 @llvm.vector.reduce.add.v4i32(<4 x i32> %128)
  %130 = getelementptr inbounds nuw i8, ptr %56, i64 384
  %131 = load i32, ptr %130, align 16, !tbaa !9
  %132 = add nsw i32 %131, %129
  %133 = getelementptr inbounds nuw i8, ptr %56, i64 388
  %134 = load i32, ptr %133, align 4, !tbaa !9
  %135 = add nsw i32 %134, %132
  %136 = getelementptr inbounds nuw i8, ptr %56, i64 392
  %137 = load i32, ptr %136, align 8, !tbaa !9
  %138 = add nsw i32 %137, %135
  %139 = getelementptr inbounds nuw i8, ptr %56, i64 396
  %140 = load i32, ptr %139, align 4, !tbaa !9
  %141 = add nsw i32 %140, %138
  %142 = add nuw nsw i64 %54, 1
  %143 = icmp eq i64 %142, 100
  br i1 %143, label %144, label %53, !llvm.loop !15

144:                                              ; preds = %53
  %145 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef 100, i32 noundef 100, i32 noundef %141)
  call void @llvm.lifetime.end.p0(ptr nonnull %1) #5
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #3

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.vector.reduce.add.v4i32(<4 x i32>) #4

attributes #0 = { nofree norecurse nosync nounwind memory(argmem: read) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!10 = distinct !{!10, !11, !12, !13}
!11 = !{!"llvm.loop.mustprogress"}
!12 = !{!"llvm.loop.isvectorized", i32 1}
!13 = !{!"llvm.loop.unroll.runtime.disable"}
!14 = distinct !{!14, !11, !13, !12}
!15 = distinct !{!15, !11}
!16 = distinct !{!16, !11}
!17 = distinct !{!17, !11}
!18 = distinct !{!18, !11}
