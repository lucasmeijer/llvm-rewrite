; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/ffbench.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/ffbench.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/ffbench.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@main.nsize = internal unnamed_addr global [3 x i32] zeroinitializer, align 4
@stderr = external local_unnamed_addr global ptr, align 8
@.str = private unnamed_addr constant [28 x i8] c"Can't allocate data array.\0A\00", align 1
@.str.1 = private unnamed_addr constant [48 x i8] c"Wrong answer at (%d,%d)!  Expected %d, got %d.\0A\00", align 1
@.str.2 = private unnamed_addr constant [35 x i8] c"%d passes.  No errors in results.\0A\00", align 1
@.str.3 = private unnamed_addr constant [35 x i8] c"%d passes.  %d errors in results.\0A\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  store i32 256, ptr getelementptr inbounds nuw (i8, ptr @main.nsize, i64 8), align 4, !tbaa !9
  store i32 256, ptr getelementptr inbounds nuw (i8, ptr @main.nsize, i64 4), align 4, !tbaa !9
  %1 = tail call dereferenceable_or_null(1048592) ptr @calloc(i64 1, i64 1048592)
  %2 = icmp eq ptr %1, null
  br i1 %2, label %3, label %6

3:                                                ; preds = %0
  %4 = load ptr, ptr @stderr, align 8, !tbaa !10
  %5 = tail call i64 @fwrite(ptr nonnull @.str, i64 27, i64 1, ptr %4) #8
  tail call void @exit(i32 noundef 1) #9
  unreachable

6:                                                ; preds = %0, %29
  %7 = phi i64 [ %30, %29 ], [ 0, %0 ]
  %8 = and i64 %7, 15
  %9 = icmp eq i64 %8, 8
  %10 = shl nuw nsw i64 %7, 12
  %11 = getelementptr inbounds nuw i8, ptr %1, i64 %10
  br label %12

12:                                               ; preds = %26, %6
  %13 = phi i64 [ 0, %6 ], [ %27, %26 ]
  %14 = and i64 %13, 14
  %15 = icmp eq i64 %14, 8
  %16 = or i1 %9, %15
  br i1 %16, label %17, label %21

17:                                               ; preds = %12
  %18 = shl nuw nsw i64 %13, 4
  %19 = getelementptr inbounds nuw i8, ptr %11, i64 %18
  %20 = getelementptr inbounds nuw i8, ptr %19, i64 8
  store double 1.280000e+02, ptr %20, align 8, !tbaa !13
  br label %21

21:                                               ; preds = %12, %17
  br i1 %9, label %22, label %26

22:                                               ; preds = %21
  %23 = shl i64 %13, 4
  %24 = getelementptr inbounds nuw i8, ptr %11, i64 %23
  %25 = getelementptr inbounds nuw i8, ptr %24, i64 24
  store double 1.280000e+02, ptr %25, align 8, !tbaa !13
  br label %26

26:                                               ; preds = %22, %21
  %27 = add nuw nsw i64 %13, 2
  %28 = icmp eq i64 %27, 256
  br i1 %28, label %29, label %12, !llvm.loop !15

29:                                               ; preds = %26
  %30 = add nuw nsw i64 %7, 1
  %31 = icmp eq i64 %30, 256
  br i1 %31, label %32, label %6, !llvm.loop !17

32:                                               ; preds = %29, %32
  %33 = phi i32 [ %34, %32 ], [ 0, %29 ]
  tail call fastcc void @fourn(ptr noundef %1, i32 noundef 1)
  tail call fastcc void @fourn(ptr noundef %1, i32 noundef -1)
  %34 = add nuw nsw i32 %33, 1
  %35 = icmp eq i32 %34, 63
  br i1 %35, label %36, label %32, !llvm.loop !18

36:                                               ; preds = %32, %36
  %37 = phi i64 [ %53, %36 ], [ 1, %32 ]
  %38 = phi double [ %52, %36 ], [ -1.000000e+10, %32 ]
  %39 = phi double [ %50, %36 ], [ 1.000000e+10, %32 ]
  %40 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %37
  %41 = load double, ptr %40, align 8, !tbaa !13
  %42 = fcmp ole double %41, %39
  %43 = select i1 %42, double %41, double %39
  %44 = fcmp ogt double %41, %38
  %45 = select i1 %44, double %41, double %38
  %46 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %37
  %47 = getelementptr inbounds nuw i8, ptr %46, i64 16
  %48 = load double, ptr %47, align 8, !tbaa !13
  %49 = fcmp ole double %48, %43
  %50 = select i1 %49, double %48, double %43
  %51 = fcmp ogt double %48, %45
  %52 = select i1 %51, double %48, double %45
  %53 = add nuw nsw i64 %37, 4
  %54 = icmp samesign ult i64 %37, 65533
  br i1 %54, label %36, label %55, !llvm.loop !19

55:                                               ; preds = %36
  %56 = fsub double %52, %50
  %57 = fdiv double 2.550000e+02, %56
  br label %58

58:                                               ; preds = %55, %90
  %59 = phi i64 [ 0, %55 ], [ %91, %90 ]
  %60 = phi i32 [ 0, %55 ], [ %87, %90 ]
  %61 = trunc nuw nsw i64 %59 to i32
  %62 = and i32 %61, 15
  %63 = icmp eq i32 %62, 8
  %64 = shl nuw nsw i64 %59, 12
  %65 = getelementptr inbounds nuw i8, ptr %1, i64 %64
  br label %66

66:                                               ; preds = %58, %86
  %67 = phi i64 [ 0, %58 ], [ %88, %86 ]
  %68 = phi i32 [ %60, %58 ], [ %87, %86 ]
  %69 = shl nuw nsw i64 %67, 4
  %70 = getelementptr inbounds nuw i8, ptr %65, i64 %69
  %71 = getelementptr inbounds nuw i8, ptr %70, i64 8
  %72 = load double, ptr %71, align 8, !tbaa !13
  %73 = fsub double %72, %50
  %74 = fmul double %57, %73
  %75 = fptosi double %74 to i32
  %76 = trunc nuw nsw i64 %67 to i32
  %77 = and i32 %76, 15
  %78 = icmp eq i32 %77, 8
  %79 = or i1 %63, %78
  %80 = select i1 %79, i32 255, i32 0
  %81 = icmp eq i32 %80, %75
  br i1 %81, label %86, label %82

82:                                               ; preds = %66
  %83 = add nsw i32 %68, 1
  %84 = load ptr, ptr @stderr, align 8, !tbaa !10
  %85 = tail call i32 (ptr, ptr, ...) @fprintf(ptr noundef %84, ptr noundef nonnull @.str.1, i32 noundef %61, i32 noundef %76, i32 noundef %80, i32 noundef %75) #10
  br label %86

86:                                               ; preds = %66, %82
  %87 = phi i32 [ %83, %82 ], [ %68, %66 ]
  %88 = add nuw nsw i64 %67, 1
  %89 = icmp eq i64 %88, 256
  br i1 %89, label %90, label %66, !llvm.loop !20

90:                                               ; preds = %86
  %91 = add nuw nsw i64 %59, 1
  %92 = icmp eq i64 %91, 256
  br i1 %92, label %93, label %58, !llvm.loop !21

93:                                               ; preds = %90
  %94 = icmp eq i32 %87, 0
  %95 = load ptr, ptr @stderr, align 8, !tbaa !10
  br i1 %94, label %96, label %98

96:                                               ; preds = %93
  %97 = tail call i32 (ptr, ptr, ...) @fprintf(ptr noundef %95, ptr noundef nonnull @.str.2, i32 noundef 63) #10
  br label %100

98:                                               ; preds = %93
  %99 = tail call i32 (ptr, ptr, ...) @fprintf(ptr noundef %95, ptr noundef nonnull @.str.3, i32 noundef 63, i32 noundef %87) #10
  br label %100

100:                                              ; preds = %98, %96
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @fprintf(ptr noundef captures(none), ptr noundef readonly captures(none), ...) local_unnamed_addr #1

; Function Attrs: nofree noreturn nounwind
declare void @exit(i32 noundef) local_unnamed_addr #2

; Function Attrs: nofree norecurse nosync nounwind memory(read, argmem: readwrite, inaccessiblemem: none, errnomem: readwrite, target_mem: none) uwtable
define internal fastcc void @fourn(ptr nofree noundef nonnull captures(none) %0, i32 noundef range(i32 -1, 2) %1) unnamed_addr #3 {
  %3 = load i32, ptr getelementptr inbounds nuw (i8, ptr @main.nsize, i64 4), align 4, !tbaa !9
  %4 = load i32, ptr getelementptr inbounds nuw (i8, ptr @main.nsize, i64 8), align 4, !tbaa !9
  %5 = mul nsw i32 %4, %3
  %6 = sitofp i32 %1 to double
  %7 = fmul nnan double %6, f0x401921FB54442D1C
  br label %8

8:                                                ; preds = %2, %144
  %9 = phi i64 [ 2, %2 ], [ %145, %144 ]
  %10 = phi i32 [ 1, %2 ], [ %13, %144 ]
  %11 = getelementptr inbounds nuw [4 x i8], ptr @main.nsize, i64 %9
  %12 = load i32, ptr %11, align 4, !tbaa !9
  %13 = mul nsw i32 %12, %10
  %14 = sdiv i32 %5, %13
  %15 = shl i32 %10, 1
  %16 = mul nsw i32 %12, %15
  %17 = mul nsw i32 %16, %14
  %18 = icmp slt i32 %16, 1
  br i1 %18, label %24, label %19

19:                                               ; preds = %8
  %20 = add i32 %15, -2
  %21 = sext i32 %15 to i64
  %22 = zext nneg i32 %16 to i64
  %23 = sext i32 %17 to i64
  br label %29

24:                                               ; preds = %71, %8
  %25 = icmp slt i32 %15, %16
  br i1 %25, label %26, label %144

26:                                               ; preds = %24
  %27 = sext i32 %15 to i64
  %28 = sext i32 %17 to i64
  br label %78

29:                                               ; preds = %19, %71
  %30 = phi i64 [ 1, %19 ], [ %73, %71 ]
  %31 = phi i32 [ 1, %19 ], [ %72, %71 ]
  %32 = trunc i64 %30 to i32
  %33 = icmp sgt i32 %31, %32
  br i1 %33, label %34, label %62

34:                                               ; preds = %29
  %35 = add i32 %20, %32
  %36 = icmp slt i32 %35, %32
  br i1 %36, label %62, label %37

37:                                               ; preds = %34
  %38 = sub i32 %31, %32
  br label %39

39:                                               ; preds = %37, %58
  %40 = phi i64 [ %30, %37 ], [ %59, %58 ]
  %41 = trunc i64 %40 to i32
  %42 = icmp slt i32 %17, %41
  br i1 %42, label %58, label %43

43:                                               ; preds = %39, %43
  %44 = phi i64 [ %56, %43 ], [ %40, %39 ]
  %45 = trunc nsw i64 %44 to i32
  %46 = add i32 %38, %45
  %47 = getelementptr inbounds [8 x i8], ptr %0, i64 %44
  %48 = load double, ptr %47, align 8, !tbaa !13
  %49 = sext i32 %46 to i64
  %50 = getelementptr inbounds [8 x i8], ptr %0, i64 %49
  %51 = load double, ptr %50, align 8, !tbaa !13
  store double %51, ptr %47, align 8, !tbaa !13
  store double %48, ptr %50, align 8, !tbaa !13
  %52 = getelementptr i8, ptr %47, i64 8
  %53 = load double, ptr %52, align 8, !tbaa !13
  %54 = getelementptr i8, ptr %50, i64 8
  %55 = load double, ptr %54, align 8, !tbaa !13
  store double %55, ptr %52, align 8, !tbaa !13
  store double %53, ptr %54, align 8, !tbaa !13
  %56 = add nsw i64 %44, %22
  %57 = icmp sgt i64 %56, %23
  br i1 %57, label %58, label %43, !llvm.loop !22

58:                                               ; preds = %43, %39
  %59 = add nsw i64 %40, 2
  %60 = trunc i64 %59 to i32
  %61 = icmp slt i32 %35, %60
  br i1 %61, label %62, label %39, !llvm.loop !23

62:                                               ; preds = %58, %34, %29
  br label %63

63:                                               ; preds = %62, %63
  %64 = phi i32 [ %66, %63 ], [ %16, %62 ]
  %65 = phi i32 [ %70, %63 ], [ %31, %62 ]
  %66 = lshr i32 %64, 1
  %67 = icmp sge i32 %66, %15
  %68 = icmp sgt i32 %65, %66
  %69 = select i1 %67, i1 %68, i1 false
  %70 = sub nsw i32 %65, %66
  br i1 %69, label %63, label %71, !llvm.loop !24

71:                                               ; preds = %63
  %72 = add nsw i32 %65, %66
  %73 = add i64 %30, %21
  %74 = trunc i64 %73 to i32
  %75 = icmp slt i32 %16, %74
  br i1 %75, label %24, label %29, !llvm.loop !25

76:                                               ; preds = %138, %78
  %77 = icmp slt i32 %80, %16
  br i1 %77, label %78, label %144, !llvm.loop !26

78:                                               ; preds = %26, %76
  %79 = phi i32 [ %80, %76 ], [ %15, %26 ]
  %80 = shl i32 %79, 1
  %81 = sdiv i32 %80, %15
  %82 = sitofp i32 %81 to double
  %83 = fdiv double %7, %82
  %84 = fmul double %83, 5.000000e-01
  %85 = tail call double @sin(double noundef %84) #11
  %86 = tail call double @sin(double noundef %83) #11
  %87 = icmp slt i32 %79, 1
  br i1 %87, label %76, label %88

88:                                               ; preds = %78
  %89 = fmul double %85, -2.000000e+00
  %90 = fmul double %85, %89
  %91 = fneg double %86
  %92 = sext i32 %80 to i64
  %93 = zext nneg i32 %79 to i64
  %94 = getelementptr [8 x i8], ptr %0, i64 %93
  %95 = insertelement <2 x double> poison, double %90, i64 0
  %96 = shufflevector <2 x double> %95, <2 x double> poison, <2 x i32> zeroinitializer
  %97 = insertelement <2 x double> poison, double %91, i64 0
  %98 = insertelement <2 x double> %97, double %86, i64 1
  br label %99

99:                                               ; preds = %88, %138
  %100 = phi i64 [ 1, %88 ], [ %103, %138 ]
  %101 = phi <2 x double> [ <double 0.000000e+00, double 1.000000e+00>, %88 ], [ %142, %138 ]
  %102 = trunc i64 %100 to i32
  %103 = add i64 %100, %27
  %104 = trunc i64 %103 to i32
  %105 = add nsw i32 %104, -2
  %106 = icmp slt i32 %105, %102
  br i1 %106, label %138, label %107

107:                                              ; preds = %99
  %108 = shufflevector <2 x double> %101, <2 x double> poison, <2 x i32> zeroinitializer
  %109 = shufflevector <2 x double> %101, <2 x double> poison, <2 x i32> <i32 1, i32 1>
  br label %110

110:                                              ; preds = %107, %134
  %111 = phi i64 [ %135, %134 ], [ %100, %107 ]
  %112 = trunc i64 %111 to i32
  %113 = icmp slt i32 %17, %112
  br i1 %113, label %134, label %114

114:                                              ; preds = %110, %114
  %115 = phi i64 [ %132, %114 ], [ %111, %110 ]
  %116 = getelementptr [8 x i8], ptr %94, i64 %115
  %117 = getelementptr i8, ptr %116, i64 8
  %118 = getelementptr inbounds [8 x i8], ptr %0, i64 %115
  %119 = load double, ptr %117, align 8, !tbaa !13
  %120 = load <2 x double>, ptr %116, align 8, !tbaa !13
  %121 = fneg double %119
  %122 = shufflevector <2 x double> %120, <2 x double> poison, <2 x i32> <i32 poison, i32 0>
  %123 = insertelement <2 x double> %122, double %121, i64 0
  %124 = fmul <2 x double> %108, %123
  %125 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %109, <2 x double> %120, <2 x double> %124)
  %126 = load <2 x double>, ptr %118, align 8, !tbaa !13
  %127 = fsub <2 x double> %126, %125
  %128 = extractelement <2 x double> %127, i64 0
  store double %128, ptr %116, align 8, !tbaa !13
  %129 = load <2 x double>, ptr %118, align 8, !tbaa !13
  %130 = extractelement <2 x double> %127, i64 1
  store double %130, ptr %117, align 8, !tbaa !13
  %131 = fadd <2 x double> %125, %129
  store <2 x double> %131, ptr %118, align 8, !tbaa !13
  %132 = add nsw i64 %115, %92
  %133 = icmp sgt i64 %132, %28
  br i1 %133, label %134, label %114, !llvm.loop !27

134:                                              ; preds = %114, %110
  %135 = add nsw i64 %111, 2
  %136 = trunc i64 %135 to i32
  %137 = icmp slt i32 %105, %136
  br i1 %137, label %138, label %110, !llvm.loop !28

138:                                              ; preds = %134, %99
  %139 = fmul <2 x double> %101, %98
  %140 = shufflevector <2 x double> %139, <2 x double> poison, <2 x i32> <i32 1, i32 0>
  %141 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %101, <2 x double> %96, <2 x double> %140)
  %142 = fadd <2 x double> %101, %141
  %143 = icmp slt i32 %79, %104
  br i1 %143, label %76, label %99, !llvm.loop !29

144:                                              ; preds = %76, %24
  %145 = add nsw i64 %9, -1
  %146 = icmp samesign ugt i64 %9, 1
  br i1 %146, label %8, label %147, !llvm.loop !30

147:                                              ; preds = %144
  ret void
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @sin(double noundef) local_unnamed_addr #4

; Function Attrs: nofree nounwind
declare noundef i64 @fwrite(ptr noundef readonly captures(none), i64 noundef, i64 noundef, ptr noundef captures(none)) local_unnamed_addr #5

; Function Attrs: nofree nounwind willreturn allockind("alloc,zeroed") allocsize(0,1) memory(inaccessiblemem: readwrite, errnomem: write)
declare noalias noundef ptr @calloc(i64 noundef, i64 noundef) local_unnamed_addr #6

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare <2 x double> @llvm.fmuladd.v2f64(<2 x double>, <2 x double>, <2 x double>) #7

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nofree noreturn nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nofree norecurse nosync nounwind memory(read, argmem: readwrite, inaccessiblemem: none, errnomem: readwrite, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nofree nounwind }
attributes #6 = { nofree nounwind willreturn allockind("alloc,zeroed") allocsize(0,1) memory(inaccessiblemem: readwrite, errnomem: write) "alloc-family"="malloc" }
attributes #7 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #8 = { cold }
attributes #9 = { cold noreturn nounwind }
attributes #10 = { cold nounwind }
attributes #11 = { nounwind }

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
!11 = !{!"p1 _ZTS8_IO_FILE", !12, i64 0}
!12 = !{!"any pointer", !7, i64 0}
!13 = !{!14, !14, i64 0}
!14 = !{!"double", !7, i64 0}
!15 = distinct !{!15, !16}
!16 = !{!"llvm.loop.mustprogress"}
!17 = distinct !{!17, !16}
!18 = distinct !{!18, !16}
!19 = distinct !{!19, !16}
!20 = distinct !{!20, !16}
!21 = distinct !{!21, !16}
!22 = distinct !{!22, !16}
!23 = distinct !{!23, !16}
!24 = distinct !{!24, !16}
!25 = distinct !{!25, !16}
!26 = distinct !{!26, !16}
!27 = distinct !{!27, !16}
!28 = distinct !{!28, !16}
!29 = distinct !{!29, !16}
!30 = distinct !{!30, !16}
