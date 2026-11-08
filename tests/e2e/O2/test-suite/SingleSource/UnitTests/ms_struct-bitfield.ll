; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/ms_struct-bitfield.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/ms_struct-bitfield.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/ms_struct-bitfield.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct._struct_0 = type { i8 }
%struct._struct_7 = type { double }

@test_struct_0 = dso_local local_unnamed_addr global %struct._struct_0 { i8 123 }, align 1
@test_struct_1 = dso_local local_unnamed_addr global { i8, i8, i8, i8 } { i8 82, i8 0, i8 57, i8 4 }, align 2
@test_struct_2 = dso_local local_unnamed_addr global { double, i8, [3 x i8], i8, i8, i8, i8, i8, i8, i8, i8, i8, i8, [2 x i8] } { double 2.000000e+01, i8 31, [3 x i8] zeroinitializer, i8 -48, i8 56, i8 6, i8 0, i8 1, i8 0, i8 68, i8 58, i8 56, i8 26, [2 x i8] zeroinitializer }, align 8
@test_struct_3 = dso_local local_unnamed_addr global { i8, i8, i8, i8, i8, [3 x i8] } { i8 39, i8 -6, i8 -39, i8 3, i8 1, [3 x i8] zeroinitializer }, align 4
@test_struct_4 = dso_local local_unnamed_addr global { i8, [7 x i8], double, double, i8, i8, i8, [5 x i8] } { i8 61, [7 x i8] zeroinitializer, double 2.000000e+01, double 2.000000e+01, i8 12, i8 0, i8 0, [5 x i8] zeroinitializer }, align 8
@test_struct_5 = dso_local local_unnamed_addr global { i8, i8, [2 x i8], i8, [3 x i8], i8, [3 x i8] } { i8 -115, i8 3, [2 x i8] zeroinitializer, i8 1, [3 x i8] zeroinitializer, i8 57, [3 x i8] zeroinitializer }, align 4
@test_struct_6 = dso_local local_unnamed_addr global { i8, [3 x i8], i8, i8, i8, i8, i8, [7 x i8], double, i8, i8, [6 x i8], double } { i8 12, [3 x i8] zeroinitializer, i8 20, i8 -35, i8 69, i8 1, i8 0, [7 x i8] zeroinitializer, double 2.000000e+01, i8 -45, i8 1, [6 x i8] zeroinitializer, double 2.000000e+01 }, align 8
@test_struct_7 = dso_local local_unnamed_addr global %struct._struct_7 { double 2.000000e+01 }, align 8
@test_struct_8 = dso_local local_unnamed_addr global { i8, [3 x i8], i8, i8, [2 x i8], i8, i8, i8, i8, i8, [3 x i8], i8, i8, i8, i8 } { i8 126, [3 x i8] zeroinitializer, i8 29, i8 -73, [2 x i8] zeroinitializer, i8 125, i8 0, i8 6, i8 0, i8 0, [3 x i8] zeroinitializer, i8 126, i8 30, i8 37, i8 0 }, align 4
@test_struct_9 = dso_local local_unnamed_addr global { double, i8, i8, i8, [5 x i8], double, i8, i8, i8, [5 x i8] } { double 2.000000e+01, i8 67, i8 101, i8 23, [5 x i8] zeroinitializer, double 2.000000e+01, i8 -97, i8 72, i8 15, [5 x i8] zeroinitializer }, align 8

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  ret i32 0
}

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

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
