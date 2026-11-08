; @source: tests/function/src/arith/int_ops.c
; @llc: -O2
; @driver: tests/function/src/arith/int_ops.driver.c
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/function/src/arith/int_ops.c'
source_filename = "tests/function/src/arith/int_ops.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef signext i8 @add8(i8 noundef signext %0, i8 noundef signext %1) local_unnamed_addr #0 {
  %3 = add i8 %1, %0
  ret i8 %3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef zeroext i8 @mul8(i8 noundef zeroext %0, i8 noundef zeroext %1) local_unnamed_addr #0 {
  %3 = mul i8 %1, %0
  ret i8 %3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef signext i16 @sub16(i16 noundef signext %0, i16 noundef signext %1) local_unnamed_addr #0 {
  %3 = sub i16 %0, %1
  ret i16 %3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local zeroext i16 @shl16(i16 noundef zeroext %0, i32 noundef %1) local_unnamed_addr #0 {
  %3 = zext i16 %0 to i32
  %4 = shl i32 %3, %1
  %5 = trunc i32 %4 to i16
  ret i16 %5
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef i32 @div32(i32 noundef %0, i32 noundef %1) local_unnamed_addr #0 {
  %3 = sdiv i32 %0, %1
  ret i32 %3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local range(i32 -2147483647, -2147483648) i32 @rem32(i32 noundef %0, i32 noundef %1) local_unnamed_addr #0 {
  %3 = srem i32 %0, %1
  ret i32 %3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef i32 @udiv32(i32 noundef %0, i32 noundef %1) local_unnamed_addr #0 {
  %3 = udiv i32 %0, %1
  ret i32 %3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local range(i32 0, -1) i32 @urem32(i32 noundef %0, i32 noundef %1) local_unnamed_addr #0 {
  %3 = urem i32 %0, %1
  ret i32 %3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local i32 @ashr32(i32 noundef %0, i32 noundef %1) local_unnamed_addr #0 {
  %3 = ashr i32 %0, %1
  ret i32 %3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local i32 @lshr32(i32 noundef %0, i32 noundef %1) local_unnamed_addr #0 {
  %3 = lshr i32 %0, %1
  ret i32 %3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef i64 @mul64(i64 noundef %0, i64 noundef %1) local_unnamed_addr #0 {
  %3 = mul i64 %1, %0
  ret i64 %3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef i64 @div64(i64 noundef %0, i64 noundef %1) local_unnamed_addr #0 {
  %3 = sdiv i64 %0, %1
  ret i64 %3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef i64 @udiv64(i64 noundef %0, i64 noundef %1) local_unnamed_addr #0 {
  %3 = udiv i64 %0, %1
  ret i64 %3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef i64 @mix64(i64 noundef %0, i64 noundef %1) local_unnamed_addr #0 {
  %3 = shl i64 %1, 13
  %4 = xor i64 %3, %0
  %5 = lshr i64 %0, 7
  %6 = or i64 %1, 4660
  %7 = sub i64 %5, %6
  %8 = add i64 %7, %4
  ret i64 %8
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local range(i32 0, 8) i32 @cmp_signed(i64 noundef %0, i64 noundef %1) local_unnamed_addr #0 {
  %3 = icmp slt i64 %0, %1
  %4 = select i1 %3, i32 4, i32 0
  %5 = icmp eq i64 %0, %1
  %6 = select i1 %5, i32 2, i32 0
  %7 = or disjoint i32 %4, %6
  %8 = icmp sgt i64 %0, %1
  %9 = zext i1 %8 to i32
  %10 = or disjoint i32 %7, %9
  ret i32 %10
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local range(i32 0, 8) i32 @cmp_unsigned(i32 noundef %0, i32 noundef %1) local_unnamed_addr #0 {
  %3 = icmp ult i32 %0, %1
  %4 = select i1 %3, i32 4, i32 0
  %5 = icmp eq i32 %0, %1
  %6 = select i1 %5, i32 2, i32 0
  %7 = or disjoint i32 %4, %6
  %8 = icmp ugt i32 %0, %1
  %9 = zext i1 %8 to i32
  %10 = or disjoint i32 %7, %9
  ret i32 %10
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
