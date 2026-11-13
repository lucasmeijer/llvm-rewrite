; @source: tests/lto/src/split/struct_by_value/callee.c
; @opt: -passes='lto-pre-link<O2>'
; @generated: clang -O2 -flto -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/lto/src/split/struct_by_value/callee.c'
source_filename = "tests/lto/src/split/struct_by_value/callee.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.s1 = type { i8 }
%struct.s8 = type { i32, i32 }
%struct.s16 = type { i64, i64 }
%struct.s24 = type { i64, i64, i64 }
%struct.sf = type { float, float }
%struct.sd = type { double, i64 }
%struct.s3 = type { [3 x i8] }

; Function Attrs: nounwind uwtable
define dso_local i32 @f1(i8 %0) #0 {
  %2 = alloca %struct.s1, align 1
  %3 = getelementptr inbounds nuw %struct.s1, ptr %2, i32 0, i32 0
  store i8 %0, ptr %3, align 1
  %4 = getelementptr inbounds nuw %struct.s1, ptr %2, i32 0, i32 0
  %5 = load i8, ptr %4, align 1, !tbaa !9
  %6 = sext i8 %5 to i32
  %7 = mul nsw i32 %6, 2
  ret i32 %7
}

; Function Attrs: nounwind uwtable
define dso_local i32 @f8(i64 %0) #0 {
  %2 = alloca %struct.s8, align 4
  store i64 %0, ptr %2, align 4
  %3 = getelementptr inbounds nuw %struct.s8, ptr %2, i32 0, i32 0
  %4 = load i32, ptr %3, align 4, !tbaa !11
  %5 = getelementptr inbounds nuw %struct.s8, ptr %2, i32 0, i32 1
  %6 = load i32, ptr %5, align 4, !tbaa !13
  %7 = sub nsw i32 %4, %6
  ret i32 %7
}

; Function Attrs: nounwind uwtable
define dso_local i64 @f16(i64 %0, i64 %1) #0 {
  %3 = alloca %struct.s16, align 8
  %4 = getelementptr inbounds nuw { i64, i64 }, ptr %3, i32 0, i32 0
  store i64 %0, ptr %4, align 8
  %5 = getelementptr inbounds nuw { i64, i64 }, ptr %3, i32 0, i32 1
  store i64 %1, ptr %5, align 8
  %6 = getelementptr inbounds nuw %struct.s16, ptr %3, i32 0, i32 0
  %7 = load i64, ptr %6, align 8, !tbaa !14
  %8 = getelementptr inbounds nuw %struct.s16, ptr %3, i32 0, i32 1
  %9 = load i64, ptr %8, align 8, !tbaa !17
  %10 = mul nsw i64 %7, %9
  ret i64 %10
}

; Function Attrs: nounwind uwtable
define dso_local i64 @f24(ptr noundef byval(%struct.s24) align 8 %0) #0 {
  %2 = getelementptr inbounds nuw %struct.s24, ptr %0, i32 0, i32 0
  %3 = load i64, ptr %2, align 8, !tbaa !18
  %4 = getelementptr inbounds nuw %struct.s24, ptr %0, i32 0, i32 1
  %5 = load i64, ptr %4, align 8, !tbaa !20
  %6 = add nsw i64 %3, %5
  %7 = getelementptr inbounds nuw %struct.s24, ptr %0, i32 0, i32 2
  %8 = load i64, ptr %7, align 8, !tbaa !21
  %9 = add nsw i64 %6, %8
  ret i64 %9
}

; Function Attrs: nounwind uwtable
define dso_local float @ff(<2 x float> %0) #1 {
  %2 = alloca %struct.sf, align 4
  store <2 x float> %0, ptr %2, align 4
  %3 = getelementptr inbounds nuw %struct.sf, ptr %2, i32 0, i32 0
  %4 = load float, ptr %3, align 4, !tbaa !22
  %5 = getelementptr inbounds nuw %struct.sf, ptr %2, i32 0, i32 1
  %6 = load float, ptr %5, align 4, !tbaa !25
  %7 = fmul float %4, %6
  ret float %7
}

; Function Attrs: nounwind uwtable
define dso_local double @fd(double %0, i64 %1) #0 {
  %3 = alloca %struct.sd, align 8
  %4 = getelementptr inbounds nuw { double, i64 }, ptr %3, i32 0, i32 0
  store double %0, ptr %4, align 8
  %5 = getelementptr inbounds nuw { double, i64 }, ptr %3, i32 0, i32 1
  store i64 %1, ptr %5, align 8
  %6 = getelementptr inbounds nuw %struct.sd, ptr %3, i32 0, i32 0
  %7 = load double, ptr %6, align 8, !tbaa !26
  %8 = getelementptr inbounds nuw %struct.sd, ptr %3, i32 0, i32 1
  %9 = load i64, ptr %8, align 8, !tbaa !29
  %10 = sitofp i64 %9 to double
  %11 = fmul double %7, %10
  ret double %11
}

; Function Attrs: nounwind uwtable
define dso_local i32 @f3(i24 %0) #0 {
  %2 = alloca %struct.s3, align 1
  %3 = getelementptr inbounds nuw %struct.s3, ptr %2, i32 0, i32 0
  store i24 %0, ptr %3, align 1
  %4 = getelementptr inbounds nuw %struct.s3, ptr %2, i32 0, i32 0
  %5 = getelementptr inbounds [3 x i8], ptr %4, i64 0, i64 0
  %6 = load i8, ptr %5, align 1, !tbaa !30
  %7 = sext i8 %6 to i32
  %8 = getelementptr inbounds nuw %struct.s3, ptr %2, i32 0, i32 0
  %9 = getelementptr inbounds [3 x i8], ptr %8, i64 0, i64 1
  %10 = load i8, ptr %9, align 1, !tbaa !30
  %11 = sext i8 %10 to i32
  %12 = mul nsw i32 %11, 2
  %13 = add nsw i32 %7, %12
  %14 = getelementptr inbounds nuw %struct.s3, ptr %2, i32 0, i32 0
  %15 = getelementptr inbounds [3 x i8], ptr %14, i64 0, i64 2
  %16 = load i8, ptr %15, align 1, !tbaa !30
  %17 = sext i8 %16 to i32
  %18 = mul nsw i32 %17, 3
  %19 = add nsw i32 %13, %18
  ret i32 %19
}

; Function Attrs: nounwind uwtable
define dso_local i64 @r8(i32 noundef %0) #0 {
  %2 = alloca %struct.s8, align 4
  %3 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !31
  %4 = getelementptr inbounds nuw %struct.s8, ptr %2, i32 0, i32 0
  %5 = load i32, ptr %3, align 4, !tbaa !31
  store i32 %5, ptr %4, align 4, !tbaa !11
  %6 = getelementptr inbounds nuw %struct.s8, ptr %2, i32 0, i32 1
  %7 = load i32, ptr %3, align 4, !tbaa !31
  %8 = mul nsw i32 %7, 2
  store i32 %8, ptr %6, align 4, !tbaa !13
  %9 = load i64, ptr %2, align 4
  ret i64 %9
}

; Function Attrs: nounwind uwtable
define dso_local { i64, i64 } @r16(i64 noundef %0) #0 {
  %2 = alloca %struct.s16, align 8
  %3 = alloca i64, align 8
  store i64 %0, ptr %3, align 8, !tbaa !32
  %4 = getelementptr inbounds nuw %struct.s16, ptr %2, i32 0, i32 0
  %5 = load i64, ptr %3, align 8, !tbaa !32
  store i64 %5, ptr %4, align 8, !tbaa !14
  %6 = getelementptr inbounds nuw %struct.s16, ptr %2, i32 0, i32 1
  %7 = load i64, ptr %3, align 8, !tbaa !32
  %8 = sub nsw i64 0, %7
  store i64 %8, ptr %6, align 8, !tbaa !17
  %9 = load { i64, i64 }, ptr %2, align 8
  ret { i64, i64 } %9
}

; Function Attrs: nounwind uwtable
define dso_local void @r24(ptr dead_on_unwind noalias writable sret(%struct.s24) align 8 %0, i64 noundef %1) #0 {
  %3 = alloca i64, align 8
  store i64 %1, ptr %3, align 8, !tbaa !32
  %4 = getelementptr inbounds nuw %struct.s24, ptr %0, i32 0, i32 0
  %5 = load i64, ptr %3, align 8, !tbaa !32
  store i64 %5, ptr %4, align 8, !tbaa !18
  %6 = getelementptr inbounds nuw %struct.s24, ptr %0, i32 0, i32 1
  %7 = load i64, ptr %3, align 8, !tbaa !32
  %8 = add nsw i64 %7, 1
  store i64 %8, ptr %6, align 8, !tbaa !20
  %9 = getelementptr inbounds nuw %struct.s24, ptr %0, i32 0, i32 2
  %10 = load i64, ptr %3, align 8, !tbaa !32
  %11 = add nsw i64 %10, 2
  store i64 %11, ptr %9, align 8, !tbaa !21
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local <2 x float> @rf(float noundef %0) #1 {
  %2 = alloca %struct.sf, align 4
  %3 = alloca float, align 4
  store float %0, ptr %3, align 4, !tbaa !33
  %4 = getelementptr inbounds nuw %struct.sf, ptr %2, i32 0, i32 0
  %5 = load float, ptr %3, align 4, !tbaa !33
  store float %5, ptr %4, align 4, !tbaa !22
  %6 = getelementptr inbounds nuw %struct.sf, ptr %2, i32 0, i32 1
  %7 = load float, ptr %3, align 4, !tbaa !33
  %8 = fdiv float %7, 2.000000e+00
  store float %8, ptr %6, align 4, !tbaa !25
  %9 = load <2 x float>, ptr %2, align 4
  ret <2 x float> %9
}

; Function Attrs: nounwind uwtable
define dso_local { double, i64 } @rd(double noundef %0) #0 {
  %2 = alloca %struct.sd, align 8
  %3 = alloca double, align 8
  store double %0, ptr %3, align 8, !tbaa !34
  %4 = getelementptr inbounds nuw %struct.sd, ptr %2, i32 0, i32 0
  %5 = load double, ptr %3, align 8, !tbaa !34
  store double %5, ptr %4, align 8, !tbaa !26
  %6 = getelementptr inbounds nuw %struct.sd, ptr %2, i32 0, i32 1
  store i64 7, ptr %6, align 8, !tbaa !29
  %7 = load { double, i64 }, ptr %2, align 8
  ret { double, i64 } %7
}

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nounwind uwtable "min-legal-vector-width"="64" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

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
!9 = !{!10, !7, i64 0}
!10 = !{!"s1", !7, i64 0}
!11 = !{!12, !6, i64 0}
!12 = !{!"s8", !6, i64 0, !6, i64 4}
!13 = !{!12, !6, i64 4}
!14 = !{!15, !16, i64 0}
!15 = !{!"s16", !16, i64 0, !16, i64 8}
!16 = !{!"long", !7, i64 0}
!17 = !{!15, !16, i64 8}
!18 = !{!19, !16, i64 0}
!19 = !{!"s24", !16, i64 0, !16, i64 8, !16, i64 16}
!20 = !{!19, !16, i64 8}
!21 = !{!19, !16, i64 16}
!22 = !{!23, !24, i64 0}
!23 = !{!"sf", !24, i64 0, !24, i64 4}
!24 = !{!"float", !7, i64 0}
!25 = !{!23, !24, i64 4}
!26 = !{!27, !28, i64 0}
!27 = !{!"sd", !28, i64 0, !16, i64 8}
!28 = !{!"double", !7, i64 0}
!29 = !{!27, !16, i64 8}
!30 = !{!7, !7, i64 0}
!31 = !{!6, !6, i64 0}
!32 = !{!16, !16, i64 0}
!33 = !{!24, !24, i64 0}
!34 = !{!28, !28, i64 0}
