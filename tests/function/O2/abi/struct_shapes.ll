; @source: tests/function/src/abi/struct_shapes.c
; @llc: -O2
; @driver: tests/function/src/abi/struct_shapes.driver.c
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/function/src/abi/struct_shapes.c'
source_filename = "tests/function/src/abi/struct_shapes.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.lll = type { i64, i64, i64 }
%struct.big = type { [10 x i32] }

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local range(i32 -128, 128) i32 @sum_c1(i8 %0) local_unnamed_addr #0 {
  %2 = sext i8 %0 to i32
  ret i32 %2
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local range(i32 -1152, 1144) i32 @sum_c3(i24 %0) local_unnamed_addr #0 {
  %2 = zext i24 %0 to i32
  %3 = lshr i24 %0, 8
  %4 = zext nneg i24 %3 to i32
  %5 = lshr i24 %0, 16
  %6 = zext nneg i24 %5 to i32
  %7 = shl i32 %2, 24
  %8 = ashr exact i32 %7, 24
  %9 = shl i32 %4, 24
  %10 = ashr exact i32 %9, 24
  %11 = mul nsw i32 %10, 3
  %12 = add nsw i32 %11, %8
  %13 = shl nuw i32 %6, 24
  %14 = ashr exact i32 %13, 24
  %15 = mul nsw i32 %14, 5
  %16 = add nsw i32 %12, %15
  ret i32 %16
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local range(i32 -65664, 65662) i32 @sum_sh(i32 %0) local_unnamed_addr #0 {
  %2 = shl i32 %0, 16
  %3 = ashr exact i32 %2, 15
  %4 = shl i32 %0, 8
  %5 = ashr i32 %4, 24
  %6 = add nsw i32 %3, %5
  ret i32 %6
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local range(i64 -17179869184, 17179869177) i64 @sum_ii(i64 %0) local_unnamed_addr #0 {
  %2 = shl i64 %0, 32
  %3 = ashr exact i64 %2, 32
  %4 = mul nsw i64 %3, 7
  %5 = ashr i64 %0, 32
  %6 = add nsw i64 %4, %5
  ret i64 %6
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local range(i64 -12884901888, 12884901883) i64 @sum_iii(i64 %0, i32 %1) local_unnamed_addr #0 {
  %3 = shl i64 %0, 32
  %4 = ashr exact i64 %3, 32
  %5 = ashr i64 %0, 31
  %6 = and i64 %5, -2
  %7 = add nsw i64 %4, %6
  %8 = sext i32 %1 to i64
  %9 = mul nsw i64 %8, 3
  %10 = add nsw i64 %7, %9
  ret i64 %10
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local i64 @sum_ll(i64 %0, i64 %1) local_unnamed_addr #0 {
  %3 = sub nsw i64 %0, %1
  ret i64 %3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: read) uwtable
define dso_local i64 @sum_lll(ptr nofree noundef readonly byval(%struct.lll) align 8 captures(none) %0) local_unnamed_addr #1 {
  %2 = load i64, ptr %0, align 8, !tbaa !9
  %3 = getelementptr inbounds nuw i8, ptr %0, i64 8
  %4 = load i64, ptr %3, align 8, !tbaa !12
  %5 = shl nsw i64 %4, 1
  %6 = add nsw i64 %5, %2
  %7 = getelementptr inbounds nuw i8, ptr %0, i64 16
  %8 = load i64, ptr %7, align 8, !tbaa !13
  %9 = mul nsw i64 %8, 3
  %10 = add nsw i64 %6, %9
  ret i64 %10
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local double @sum_ff(<2 x float> %0) local_unnamed_addr #2 {
  %2 = extractelement <2 x float> %0, i64 0
  %3 = extractelement <2 x float> %0, i64 1
  %4 = tail call float @llvm.fmuladd.f32(float %2, float 2.000000e+00, float %3)
  %5 = fpext float %4 to double
  ret double %5
}

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare float @llvm.fmuladd.f32(float, float, float) #3

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local double @sum_fff(<2 x float> %0, float %1) local_unnamed_addr #2 {
  %3 = extractelement <2 x float> %0, i64 0
  %4 = extractelement <2 x float> %0, i64 1
  %5 = tail call float @llvm.fmuladd.f32(float %4, float 2.000000e+00, float %3)
  %6 = tail call float @llvm.fmuladd.f32(float %1, float 3.000000e+00, float %5)
  %7 = fpext float %6 to double
  ret double %7
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local double @sum_dd(double %0, double %1) local_unnamed_addr #0 {
  %3 = fmul double %0, 5.000000e-01
  %4 = fadd double %3, %1
  ret double %4
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local double @sum_id(i32 %0, double %1) local_unnamed_addr #0 {
  %3 = sitofp i32 %0 to double
  %4 = fadd double %1, %3
  ret double %4
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local double @sum_di(double %0, i32 %1) local_unnamed_addr #0 {
  %3 = sitofp i32 %1 to double
  %4 = fmul double %0, %3
  ret double %4
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local double @sum_fi(i64 %0) local_unnamed_addr #0 {
  %2 = trunc i64 %0 to i32
  %3 = bitcast i32 %2 to float
  %4 = lshr i64 %0, 32
  %5 = trunc nuw i64 %4 to i32
  %6 = sitofp i32 %5 to float
  %7 = fsub float %3, %6
  %8 = fpext float %7 to double
  ret double %8
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: read) uwtable
define dso_local range(i64 -118111600640, 118111600586) i64 @sum_big(ptr nofree noundef readonly byval(%struct.big) align 8 captures(none) %0) local_unnamed_addr #1 {
  %2 = load i32, ptr %0, align 8, !tbaa !14
  %3 = sext i32 %2 to i64
  %4 = getelementptr inbounds nuw i8, ptr %0, i64 4
  %5 = load i32, ptr %4, align 4, !tbaa !14
  %6 = sext i32 %5 to i64
  %7 = shl nsw i64 %6, 1
  %8 = add nsw i64 %7, %3
  %9 = getelementptr inbounds nuw i8, ptr %0, i64 8
  %10 = load i32, ptr %9, align 8, !tbaa !14
  %11 = sext i32 %10 to i64
  %12 = mul nsw i64 %11, 3
  %13 = add nsw i64 %12, %8
  %14 = getelementptr inbounds nuw i8, ptr %0, i64 12
  %15 = load i32, ptr %14, align 4, !tbaa !14
  %16 = sext i32 %15 to i64
  %17 = shl nsw i64 %16, 2
  %18 = add nsw i64 %17, %13
  %19 = getelementptr inbounds nuw i8, ptr %0, i64 16
  %20 = load i32, ptr %19, align 8, !tbaa !14
  %21 = sext i32 %20 to i64
  %22 = mul nsw i64 %21, 5
  %23 = add nsw i64 %22, %18
  %24 = getelementptr inbounds nuw i8, ptr %0, i64 20
  %25 = load i32, ptr %24, align 4, !tbaa !14
  %26 = sext i32 %25 to i64
  %27 = mul nsw i64 %26, 6
  %28 = add nsw i64 %27, %23
  %29 = getelementptr inbounds nuw i8, ptr %0, i64 24
  %30 = load i32, ptr %29, align 8, !tbaa !14
  %31 = sext i32 %30 to i64
  %32 = mul nsw i64 %31, 7
  %33 = add nsw i64 %32, %28
  %34 = getelementptr inbounds nuw i8, ptr %0, i64 28
  %35 = load i32, ptr %34, align 4, !tbaa !14
  %36 = sext i32 %35 to i64
  %37 = shl nsw i64 %36, 3
  %38 = add nsw i64 %37, %33
  %39 = getelementptr inbounds nuw i8, ptr %0, i64 32
  %40 = load i32, ptr %39, align 8, !tbaa !14
  %41 = sext i32 %40 to i64
  %42 = mul nsw i64 %41, 9
  %43 = add nsw i64 %42, %38
  %44 = getelementptr inbounds nuw i8, ptr %0, i64 36
  %45 = load i32, ptr %44, align 4, !tbaa !14
  %46 = sext i32 %45 to i64
  %47 = mul nsw i64 %46, 10
  %48 = add nsw i64 %47, %43
  ret i64 %48
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local i24 @mk_c3(i32 noundef %0) local_unnamed_addr #0 {
  %2 = trunc i32 %0 to i8
  %3 = add i8 %2, 1
  %4 = add i8 %2, 2
  %5 = zext i8 %4 to i24
  %6 = shl nuw i24 %5, 16
  %7 = zext i8 %3 to i24
  %8 = shl nuw nsw i24 %7, 8
  %9 = or disjoint i24 %6, %8
  %10 = trunc i32 %0 to i24
  %11 = and i24 %10, 255
  %12 = or disjoint i24 %9, %11
  ret i24 %12
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local { i64, i32 } @mk_iii(i32 noundef %0) local_unnamed_addr #0 {
  %2 = sub nsw i32 0, %0
  %3 = mul nsw i32 %0, 3
  %4 = zext i32 %2 to i64
  %5 = shl nuw i64 %4, 32
  %6 = zext i32 %0 to i64
  %7 = or disjoint i64 %5, %6
  %8 = insertvalue { i64, i32 } poison, i64 %7, 0
  %9 = insertvalue { i64, i32 } %8, i32 %3, 1
  ret { i64, i32 } %9
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: write) uwtable
define dso_local void @mk_lll(ptr dead_on_unwind noalias nofree writable writeonly sret(%struct.lll) align 8 captures(none) initializes((0, 24)) %0, i64 noundef %1) local_unnamed_addr #4 {
  store i64 %1, ptr %0, align 8, !tbaa !9
  %3 = getelementptr inbounds nuw i8, ptr %0, i64 8
  %4 = shl nsw i64 %1, 20
  store i64 %4, ptr %3, align 8, !tbaa !12
  %5 = getelementptr inbounds nuw i8, ptr %0, i64 16
  %6 = xor i64 %1, -1
  store i64 %6, ptr %5, align 8, !tbaa !13
  ret void
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local { <2 x float>, float } @mk_fff(float noundef %0) local_unnamed_addr #0 {
  %2 = insertelement <2 x float> poison, float %0, i64 0
  %3 = fmul float %0, 2.000000e+00
  %4 = insertelement <2 x float> %2, float %3, i64 1
  %5 = fmul float %0, 4.000000e+00
  %6 = insertvalue { <2 x float>, float } poison, <2 x float> %4, 0
  %7 = insertvalue { <2 x float>, float } %6, float %5, 1
  ret { <2 x float>, float } %7
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local { double, double } @mk_dd(double noundef %0) local_unnamed_addr #0 {
  %2 = fneg double %0
  %3 = insertvalue { double, double } poison, double %0, 0
  %4 = insertvalue { double, double } %3, double %2, 1
  ret { double, double } %4
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local { i32, double } @mk_id(i32 noundef %0) local_unnamed_addr #0 {
  %2 = sitofp i32 %0 to double
  %3 = fmul nnan double %2, 2.500000e-01
  %4 = insertvalue { i32, double } poison, i32 %0, 0
  %5 = insertvalue { i32, double } %4, double %3, 1
  ret { i32, double } %5
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local { double, i32 } @mk_di(double noundef %0) local_unnamed_addr #0 {
  %2 = fptosi double %0 to i32
  %3 = shl nsw i32 %2, 1
  %4 = insertvalue { double, i32 } poison, double %0, 0
  %5 = insertvalue { double, i32 } %4, i32 %3, 1
  ret { double, i32 } %5
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: write) uwtable
define dso_local void @mk_big(ptr dead_on_unwind noalias nofree writable writeonly sret(%struct.big) align 4 captures(none) initializes((0, 40)) %0, i32 noundef %1) local_unnamed_addr #4 {
  store i32 0, ptr %0, align 4, !tbaa !14
  %3 = getelementptr inbounds nuw i8, ptr %0, i64 4
  store i32 %1, ptr %3, align 4, !tbaa !14
  %4 = shl i32 %1, 1
  %5 = getelementptr inbounds nuw i8, ptr %0, i64 8
  store i32 %4, ptr %5, align 4, !tbaa !14
  %6 = mul i32 %1, 3
  %7 = getelementptr inbounds nuw i8, ptr %0, i64 12
  store i32 %6, ptr %7, align 4, !tbaa !14
  %8 = shl i32 %1, 2
  %9 = getelementptr inbounds nuw i8, ptr %0, i64 16
  store i32 %8, ptr %9, align 4, !tbaa !14
  %10 = mul i32 %1, 5
  %11 = getelementptr inbounds nuw i8, ptr %0, i64 20
  store i32 %10, ptr %11, align 4, !tbaa !14
  %12 = mul i32 %1, 6
  %13 = getelementptr inbounds nuw i8, ptr %0, i64 24
  store i32 %12, ptr %13, align 4, !tbaa !14
  %14 = mul i32 %1, 7
  %15 = getelementptr inbounds nuw i8, ptr %0, i64 28
  store i32 %14, ptr %15, align 4, !tbaa !14
  %16 = shl i32 %1, 3
  %17 = getelementptr inbounds nuw i8, ptr %0, i64 32
  store i32 %16, ptr %17, align 4, !tbaa !14
  %18 = mul i32 %1, 9
  %19 = getelementptr inbounds nuw i8, ptr %0, i64 36
  store i32 %18, ptr %19, align 4, !tbaa !14
  ret void
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: read) uwtable
define dso_local double @many(i64 %0, double %1, double %2, ptr nofree noundef readonly byval(%struct.lll) align 8 captures(none) %3, i64 %4, <2 x float> %5, i32 %6, double %7, i64 %8, i64 %9, double %10, double %11, i64 %12) local_unnamed_addr #5 {
  %14 = trunc i64 %0 to i32
  %15 = lshr i64 %0, 32
  %16 = trunc nuw i64 %15 to i32
  %17 = trunc i64 %4 to i32
  %18 = bitcast i32 %17 to float
  %19 = lshr i64 %4, 32
  %20 = trunc nuw i64 %19 to i32
  %21 = trunc i64 %12 to i32
  %22 = lshr i64 %12, 32
  %23 = trunc nuw i64 %22 to i32
  %24 = add nsw i32 %16, %14
  %25 = sitofp i32 %24 to double
  %26 = fadd double %1, %25
  %27 = fadd double %2, %26
  %28 = load i64, ptr %3, align 8, !tbaa !9
  %29 = sitofp i64 %28 to double
  %30 = fadd double %27, %29
  %31 = getelementptr inbounds nuw i8, ptr %3, i64 8
  %32 = load i64, ptr %31, align 8, !tbaa !12
  %33 = sitofp i64 %32 to double
  %34 = fadd double %30, %33
  %35 = getelementptr inbounds nuw i8, ptr %3, i64 16
  %36 = load i64, ptr %35, align 8, !tbaa !13
  %37 = sitofp i64 %36 to double
  %38 = fadd double %34, %37
  %39 = fpext float %18 to double
  %40 = fadd double %38, %39
  %41 = sitofp i32 %20 to double
  %42 = fadd double %40, %41
  %43 = extractelement <2 x float> %5, i64 0
  %44 = fpext float %43 to double
  %45 = fadd double %42, %44
  %46 = extractelement <2 x float> %5, i64 1
  %47 = fpext float %46 to double
  %48 = fadd double %45, %47
  %49 = sitofp i32 %6 to double
  %50 = fadd double %48, %49
  %51 = fadd double %7, %50
  %52 = sitofp i64 %8 to double
  %53 = fadd double %51, %52
  %54 = sitofp i64 %9 to double
  %55 = fadd double %53, %54
  %56 = fadd double %10, %55
  %57 = fadd double %11, %56
  %58 = sitofp i32 %21 to double
  %59 = fadd double %57, %58
  %60 = sitofp i32 %23 to double
  %61 = fadd double %59, %60
  ret double %61
}

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: read) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable "min-legal-vector-width"="64" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #4 = { mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: write) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: read) uwtable "min-legal-vector-width"="64" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

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
!9 = !{!10, !11, i64 0}
!10 = !{!"lll", !11, i64 0, !11, i64 8, !11, i64 16}
!11 = !{!"long", !7, i64 0}
!12 = !{!10, !11, i64 8}
!13 = !{!10, !11, i64 16}
!14 = !{!6, !6, i64 0}
