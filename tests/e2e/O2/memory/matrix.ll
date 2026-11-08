; @source: tests/e2e/src/memory/matrix.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/memory/matrix.c'
source_filename = "tests/e2e/src/memory/matrix.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@a = internal unnamed_addr global [12 x [12 x double]] zeroinitializer, align 16
@b = internal unnamed_addr global [12 x [12 x double]] zeroinitializer, align 16
@c = internal unnamed_addr global [12 x [12 x double]] zeroinitializer, align 16
@.str = private unnamed_addr constant [11 x i8] c"%.3f %.3f\0A\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  br label %1

1:                                                ; preds = %0, %1
  %2 = phi i64 [ 0, %0 ], [ %56, %1 ]
  %3 = trunc nuw nsw i64 %2 to i32
  %4 = uitofp nneg i32 %3 to double
  %5 = getelementptr inbounds nuw [96 x i8], ptr @a, i64 %2
  %6 = getelementptr inbounds nuw [96 x i8], ptr @b, i64 %2
  store double %4, ptr %5, align 16, !tbaa !9
  %7 = icmp eq i64 %2, 0
  %8 = select i1 %7, double 2.000000e+00, double 2.500000e-01
  store double %8, ptr %6, align 16, !tbaa !9
  %9 = getelementptr inbounds nuw i8, ptr %5, i64 8
  %10 = icmp eq i64 %2, 1
  %11 = select i1 %10, double 2.000000e+00, double 2.500000e-01
  %12 = getelementptr inbounds nuw i8, ptr %6, i64 8
  store double %11, ptr %12, align 8, !tbaa !9
  %13 = insertelement <2 x double> poison, double %4, i64 0
  %14 = shufflevector <2 x double> %13, <2 x double> poison, <2 x i32> zeroinitializer
  %15 = fadd <2 x double> %14, <double 5.000000e-01, double 1.000000e+00>
  store <2 x double> %15, ptr %9, align 8, !tbaa !9
  %16 = icmp eq i64 %2, 2
  %17 = select i1 %16, double 2.000000e+00, double 2.500000e-01
  %18 = getelementptr inbounds nuw i8, ptr %6, i64 16
  store double %17, ptr %18, align 16, !tbaa !9
  %19 = getelementptr inbounds nuw i8, ptr %5, i64 24
  %20 = icmp eq i64 %2, 3
  %21 = select i1 %20, double 2.000000e+00, double 2.500000e-01
  %22 = getelementptr inbounds nuw i8, ptr %6, i64 24
  store double %21, ptr %22, align 8, !tbaa !9
  %23 = fadd <2 x double> %14, <double 1.500000e+00, double 2.000000e+00>
  store <2 x double> %23, ptr %19, align 8, !tbaa !9
  %24 = icmp eq i64 %2, 4
  %25 = select i1 %24, double 2.000000e+00, double 2.500000e-01
  %26 = getelementptr inbounds nuw i8, ptr %6, i64 32
  store double %25, ptr %26, align 16, !tbaa !9
  %27 = getelementptr inbounds nuw i8, ptr %5, i64 40
  %28 = icmp eq i64 %2, 5
  %29 = select i1 %28, double 2.000000e+00, double 2.500000e-01
  %30 = getelementptr inbounds nuw i8, ptr %6, i64 40
  store double %29, ptr %30, align 8, !tbaa !9
  %31 = fadd <2 x double> %14, <double 2.500000e+00, double 3.000000e+00>
  store <2 x double> %31, ptr %27, align 8, !tbaa !9
  %32 = icmp eq i64 %2, 6
  %33 = select i1 %32, double 2.000000e+00, double 2.500000e-01
  %34 = getelementptr inbounds nuw i8, ptr %6, i64 48
  store double %33, ptr %34, align 16, !tbaa !9
  %35 = getelementptr inbounds nuw i8, ptr %5, i64 56
  %36 = icmp eq i64 %2, 7
  %37 = select i1 %36, double 2.000000e+00, double 2.500000e-01
  %38 = getelementptr inbounds nuw i8, ptr %6, i64 56
  store double %37, ptr %38, align 8, !tbaa !9
  %39 = fadd <2 x double> %14, <double 3.500000e+00, double 4.000000e+00>
  store <2 x double> %39, ptr %35, align 8, !tbaa !9
  %40 = icmp eq i64 %2, 8
  %41 = select i1 %40, double 2.000000e+00, double 2.500000e-01
  %42 = getelementptr inbounds nuw i8, ptr %6, i64 64
  store double %41, ptr %42, align 16, !tbaa !9
  %43 = getelementptr inbounds nuw i8, ptr %5, i64 72
  %44 = icmp eq i64 %2, 9
  %45 = select i1 %44, double 2.000000e+00, double 2.500000e-01
  %46 = getelementptr inbounds nuw i8, ptr %6, i64 72
  store double %45, ptr %46, align 8, !tbaa !9
  %47 = fadd <2 x double> %14, <double 4.500000e+00, double 5.000000e+00>
  store <2 x double> %47, ptr %43, align 8, !tbaa !9
  %48 = icmp eq i64 %2, 10
  %49 = select i1 %48, double 2.000000e+00, double 2.500000e-01
  %50 = getelementptr inbounds nuw i8, ptr %6, i64 80
  store double %49, ptr %50, align 16, !tbaa !9
  %51 = fadd double %4, 5.500000e+00
  %52 = getelementptr inbounds nuw i8, ptr %5, i64 88
  store double %51, ptr %52, align 8, !tbaa !9
  %53 = icmp eq i64 %2, 11
  %54 = select i1 %53, double 2.000000e+00, double 2.500000e-01
  %55 = getelementptr inbounds nuw i8, ptr %6, i64 88
  store double %54, ptr %55, align 8, !tbaa !9
  %56 = add nuw nsw i64 %2, 1
  %57 = icmp eq i64 %56, 12
  br i1 %57, label %58, label %1, !llvm.loop !11

58:                                               ; preds = %1, %150
  %59 = phi i64 [ %151, %150 ], [ 0, %1 ]
  %60 = getelementptr inbounds nuw [96 x i8], ptr @c, i64 %59
  %61 = getelementptr inbounds nuw [96 x i8], ptr @a, i64 %59
  %62 = getelementptr inbounds nuw i8, ptr %61, i64 88
  %63 = load double, ptr %62, align 8, !tbaa !9
  %64 = getelementptr inbounds nuw i8, ptr %61, i64 80
  %65 = load double, ptr %64, align 16, !tbaa !9
  %66 = getelementptr inbounds nuw i8, ptr %61, i64 72
  %67 = load double, ptr %66, align 8, !tbaa !9
  %68 = getelementptr inbounds nuw i8, ptr %61, i64 64
  %69 = load double, ptr %68, align 16, !tbaa !9
  %70 = getelementptr inbounds nuw i8, ptr %61, i64 56
  %71 = load double, ptr %70, align 8, !tbaa !9
  %72 = getelementptr inbounds nuw i8, ptr %61, i64 48
  %73 = load double, ptr %72, align 16, !tbaa !9
  %74 = getelementptr inbounds nuw i8, ptr %61, i64 40
  %75 = load double, ptr %74, align 8, !tbaa !9
  %76 = getelementptr inbounds nuw i8, ptr %61, i64 32
  %77 = load double, ptr %76, align 16, !tbaa !9
  %78 = getelementptr inbounds nuw i8, ptr %61, i64 24
  %79 = load double, ptr %78, align 8, !tbaa !9
  %80 = getelementptr inbounds nuw i8, ptr %61, i64 16
  %81 = load double, ptr %80, align 16, !tbaa !9
  %82 = getelementptr inbounds nuw i8, ptr %61, i64 8
  %83 = load double, ptr %82, align 8, !tbaa !9
  %84 = load double, ptr %61, align 16, !tbaa !9
  %85 = insertelement <2 x double> poison, double %84, i64 0
  %86 = shufflevector <2 x double> %85, <2 x double> poison, <2 x i32> zeroinitializer
  %87 = insertelement <2 x double> poison, double %83, i64 0
  %88 = shufflevector <2 x double> %87, <2 x double> poison, <2 x i32> zeroinitializer
  %89 = insertelement <2 x double> poison, double %81, i64 0
  %90 = shufflevector <2 x double> %89, <2 x double> poison, <2 x i32> zeroinitializer
  %91 = insertelement <2 x double> poison, double %79, i64 0
  %92 = shufflevector <2 x double> %91, <2 x double> poison, <2 x i32> zeroinitializer
  %93 = insertelement <2 x double> poison, double %77, i64 0
  %94 = shufflevector <2 x double> %93, <2 x double> poison, <2 x i32> zeroinitializer
  %95 = insertelement <2 x double> poison, double %75, i64 0
  %96 = shufflevector <2 x double> %95, <2 x double> poison, <2 x i32> zeroinitializer
  %97 = insertelement <2 x double> poison, double %73, i64 0
  %98 = shufflevector <2 x double> %97, <2 x double> poison, <2 x i32> zeroinitializer
  %99 = insertelement <2 x double> poison, double %71, i64 0
  %100 = shufflevector <2 x double> %99, <2 x double> poison, <2 x i32> zeroinitializer
  %101 = insertelement <2 x double> poison, double %69, i64 0
  %102 = shufflevector <2 x double> %101, <2 x double> poison, <2 x i32> zeroinitializer
  %103 = insertelement <2 x double> poison, double %67, i64 0
  %104 = shufflevector <2 x double> %103, <2 x double> poison, <2 x i32> zeroinitializer
  %105 = insertelement <2 x double> poison, double %65, i64 0
  %106 = shufflevector <2 x double> %105, <2 x double> poison, <2 x i32> zeroinitializer
  %107 = insertelement <2 x double> poison, double %63, i64 0
  %108 = shufflevector <2 x double> %107, <2 x double> poison, <2 x i32> zeroinitializer
  br label %109

109:                                              ; preds = %109, %58
  %110 = phi i64 [ 0, %58 ], [ %148, %109 ]
  %111 = getelementptr inbounds nuw [8 x i8], ptr @b, i64 %110
  %112 = load <2 x double>, ptr %111, align 16, !tbaa !9
  %113 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %86, <2 x double> %112, <2 x double> zeroinitializer)
  %114 = getelementptr inbounds nuw i8, ptr %111, i64 96
  %115 = load <2 x double>, ptr %114, align 16, !tbaa !9
  %116 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %88, <2 x double> %115, <2 x double> %113)
  %117 = getelementptr inbounds nuw i8, ptr %111, i64 192
  %118 = load <2 x double>, ptr %117, align 16, !tbaa !9
  %119 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %90, <2 x double> %118, <2 x double> %116)
  %120 = getelementptr inbounds nuw i8, ptr %111, i64 288
  %121 = load <2 x double>, ptr %120, align 16, !tbaa !9
  %122 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %92, <2 x double> %121, <2 x double> %119)
  %123 = getelementptr inbounds nuw i8, ptr %111, i64 384
  %124 = load <2 x double>, ptr %123, align 16, !tbaa !9
  %125 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %94, <2 x double> %124, <2 x double> %122)
  %126 = getelementptr inbounds nuw i8, ptr %111, i64 480
  %127 = load <2 x double>, ptr %126, align 16, !tbaa !9
  %128 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %96, <2 x double> %127, <2 x double> %125)
  %129 = getelementptr inbounds nuw i8, ptr %111, i64 576
  %130 = load <2 x double>, ptr %129, align 16, !tbaa !9
  %131 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %98, <2 x double> %130, <2 x double> %128)
  %132 = getelementptr inbounds nuw i8, ptr %111, i64 672
  %133 = load <2 x double>, ptr %132, align 16, !tbaa !9
  %134 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %100, <2 x double> %133, <2 x double> %131)
  %135 = getelementptr inbounds nuw i8, ptr %111, i64 768
  %136 = load <2 x double>, ptr %135, align 16, !tbaa !9
  %137 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %102, <2 x double> %136, <2 x double> %134)
  %138 = getelementptr inbounds nuw i8, ptr %111, i64 864
  %139 = load <2 x double>, ptr %138, align 16, !tbaa !9
  %140 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %104, <2 x double> %139, <2 x double> %137)
  %141 = getelementptr inbounds nuw i8, ptr %111, i64 960
  %142 = load <2 x double>, ptr %141, align 16, !tbaa !9
  %143 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %106, <2 x double> %142, <2 x double> %140)
  %144 = getelementptr inbounds nuw i8, ptr %111, i64 1056
  %145 = load <2 x double>, ptr %144, align 16, !tbaa !9
  %146 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %108, <2 x double> %145, <2 x double> %143)
  %147 = getelementptr inbounds nuw [8 x i8], ptr %60, i64 %110
  store <2 x double> %146, ptr %147, align 16, !tbaa !9
  %148 = add nuw i64 %110, 2
  %149 = icmp eq i64 %148, 12
  br i1 %149, label %150, label %109, !llvm.loop !13

150:                                              ; preds = %109
  %151 = add nuw nsw i64 %59, 1
  %152 = icmp eq i64 %151, 12
  br i1 %152, label %153, label %58, !llvm.loop !16

153:                                              ; preds = %150
  %154 = load double, ptr @c, align 16, !tbaa !9
  %155 = fadd double %154, 0.000000e+00
  %156 = load double, ptr getelementptr inbounds nuw (i8, ptr @c, i64 104), align 8, !tbaa !9
  %157 = fadd double %155, %156
  %158 = load double, ptr getelementptr inbounds nuw (i8, ptr @c, i64 208), align 16, !tbaa !9
  %159 = fadd double %157, %158
  %160 = load double, ptr getelementptr inbounds nuw (i8, ptr @c, i64 312), align 8, !tbaa !9
  %161 = fadd double %159, %160
  %162 = load double, ptr getelementptr inbounds nuw (i8, ptr @c, i64 416), align 16, !tbaa !9
  %163 = fadd double %161, %162
  %164 = load double, ptr getelementptr inbounds nuw (i8, ptr @c, i64 520), align 8, !tbaa !9
  %165 = fadd double %163, %164
  %166 = load double, ptr getelementptr inbounds nuw (i8, ptr @c, i64 624), align 16, !tbaa !9
  %167 = fadd double %165, %166
  %168 = load double, ptr getelementptr inbounds nuw (i8, ptr @c, i64 728), align 8, !tbaa !9
  %169 = fadd double %167, %168
  %170 = load double, ptr getelementptr inbounds nuw (i8, ptr @c, i64 832), align 16, !tbaa !9
  %171 = fadd double %169, %170
  %172 = load double, ptr getelementptr inbounds nuw (i8, ptr @c, i64 936), align 8, !tbaa !9
  %173 = fadd double %171, %172
  %174 = load double, ptr getelementptr inbounds nuw (i8, ptr @c, i64 1040), align 16, !tbaa !9
  %175 = fadd double %173, %174
  %176 = load double, ptr getelementptr inbounds nuw (i8, ptr @c, i64 1144), align 8, !tbaa !9
  %177 = fadd double %175, %176
  %178 = load double, ptr getelementptr inbounds nuw (i8, ptr @c, i64 344), align 8, !tbaa !9
  %179 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %177, double noundef %178)
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #1

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare <2 x double> @llvm.fmuladd.v2f64(<2 x double>, <2 x double>, <2 x double>) #2

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }

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
!13 = distinct !{!13, !12, !14, !15}
!14 = !{!"llvm.loop.isvectorized", i32 1}
!15 = !{!"llvm.loop.unroll.runtime.disable"}
!16 = distinct !{!16, !12}
