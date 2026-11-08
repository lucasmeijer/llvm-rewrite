; @source: tests/function/src/arith/int_ops.c
; @opt: -O2
; @llc: -O2
; @driver: tests/function/src/arith/int_ops.driver.c
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/function/src/arith/int_ops.c'
source_filename = "tests/function/src/arith/int_ops.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

; Function Attrs: nounwind uwtable
define dso_local signext i8 @add8(i8 noundef signext %0, i8 noundef signext %1) #0 {
  %3 = alloca i8, align 1
  %4 = alloca i8, align 1
  store i8 %0, ptr %3, align 1, !tbaa !9
  store i8 %1, ptr %4, align 1, !tbaa !9
  %5 = load i8, ptr %3, align 1, !tbaa !9
  %6 = sext i8 %5 to i32
  %7 = load i8, ptr %4, align 1, !tbaa !9
  %8 = sext i8 %7 to i32
  %9 = add nsw i32 %6, %8
  %10 = trunc i32 %9 to i8
  ret i8 %10
}

; Function Attrs: nounwind uwtable
define dso_local zeroext i8 @mul8(i8 noundef zeroext %0, i8 noundef zeroext %1) #0 {
  %3 = alloca i8, align 1
  %4 = alloca i8, align 1
  store i8 %0, ptr %3, align 1, !tbaa !9
  store i8 %1, ptr %4, align 1, !tbaa !9
  %5 = load i8, ptr %3, align 1, !tbaa !9
  %6 = zext i8 %5 to i32
  %7 = load i8, ptr %4, align 1, !tbaa !9
  %8 = zext i8 %7 to i32
  %9 = mul nsw i32 %6, %8
  %10 = trunc i32 %9 to i8
  ret i8 %10
}

; Function Attrs: nounwind uwtable
define dso_local signext i16 @sub16(i16 noundef signext %0, i16 noundef signext %1) #0 {
  %3 = alloca i16, align 2
  %4 = alloca i16, align 2
  store i16 %0, ptr %3, align 2, !tbaa !10
  store i16 %1, ptr %4, align 2, !tbaa !10
  %5 = load i16, ptr %3, align 2, !tbaa !10
  %6 = sext i16 %5 to i32
  %7 = load i16, ptr %4, align 2, !tbaa !10
  %8 = sext i16 %7 to i32
  %9 = sub nsw i32 %6, %8
  %10 = trunc i32 %9 to i16
  ret i16 %10
}

; Function Attrs: nounwind uwtable
define dso_local zeroext i16 @shl16(i16 noundef zeroext %0, i32 noundef %1) #0 {
  %3 = alloca i16, align 2
  %4 = alloca i32, align 4
  store i16 %0, ptr %3, align 2, !tbaa !10
  store i32 %1, ptr %4, align 4, !tbaa !12
  %5 = load i16, ptr %3, align 2, !tbaa !10
  %6 = zext i16 %5 to i32
  %7 = load i32, ptr %4, align 4, !tbaa !12
  %8 = shl i32 %6, %7
  %9 = trunc i32 %8 to i16
  ret i16 %9
}

; Function Attrs: nounwind uwtable
define dso_local i32 @div32(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !12
  store i32 %1, ptr %4, align 4, !tbaa !12
  %5 = load i32, ptr %3, align 4, !tbaa !12
  %6 = load i32, ptr %4, align 4, !tbaa !12
  %7 = sdiv i32 %5, %6
  ret i32 %7
}

; Function Attrs: nounwind uwtable
define dso_local i32 @rem32(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !12
  store i32 %1, ptr %4, align 4, !tbaa !12
  %5 = load i32, ptr %3, align 4, !tbaa !12
  %6 = load i32, ptr %4, align 4, !tbaa !12
  %7 = srem i32 %5, %6
  ret i32 %7
}

; Function Attrs: nounwind uwtable
define dso_local i32 @udiv32(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !12
  store i32 %1, ptr %4, align 4, !tbaa !12
  %5 = load i32, ptr %3, align 4, !tbaa !12
  %6 = load i32, ptr %4, align 4, !tbaa !12
  %7 = udiv i32 %5, %6
  ret i32 %7
}

; Function Attrs: nounwind uwtable
define dso_local i32 @urem32(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !12
  store i32 %1, ptr %4, align 4, !tbaa !12
  %5 = load i32, ptr %3, align 4, !tbaa !12
  %6 = load i32, ptr %4, align 4, !tbaa !12
  %7 = urem i32 %5, %6
  ret i32 %7
}

; Function Attrs: nounwind uwtable
define dso_local i32 @ashr32(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !12
  store i32 %1, ptr %4, align 4, !tbaa !12
  %5 = load i32, ptr %3, align 4, !tbaa !12
  %6 = load i32, ptr %4, align 4, !tbaa !12
  %7 = ashr i32 %5, %6
  ret i32 %7
}

; Function Attrs: nounwind uwtable
define dso_local i32 @lshr32(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !12
  store i32 %1, ptr %4, align 4, !tbaa !12
  %5 = load i32, ptr %3, align 4, !tbaa !12
  %6 = load i32, ptr %4, align 4, !tbaa !12
  %7 = lshr i32 %5, %6
  ret i32 %7
}

; Function Attrs: nounwind uwtable
define dso_local i64 @mul64(i64 noundef %0, i64 noundef %1) #0 {
  %3 = alloca i64, align 8
  %4 = alloca i64, align 8
  store i64 %0, ptr %3, align 8, !tbaa !13
  store i64 %1, ptr %4, align 8, !tbaa !13
  %5 = load i64, ptr %3, align 8, !tbaa !13
  %6 = load i64, ptr %4, align 8, !tbaa !13
  %7 = mul i64 %5, %6
  ret i64 %7
}

; Function Attrs: nounwind uwtable
define dso_local i64 @div64(i64 noundef %0, i64 noundef %1) #0 {
  %3 = alloca i64, align 8
  %4 = alloca i64, align 8
  store i64 %0, ptr %3, align 8, !tbaa !13
  store i64 %1, ptr %4, align 8, !tbaa !13
  %5 = load i64, ptr %3, align 8, !tbaa !13
  %6 = load i64, ptr %4, align 8, !tbaa !13
  %7 = sdiv i64 %5, %6
  ret i64 %7
}

; Function Attrs: nounwind uwtable
define dso_local i64 @udiv64(i64 noundef %0, i64 noundef %1) #0 {
  %3 = alloca i64, align 8
  %4 = alloca i64, align 8
  store i64 %0, ptr %3, align 8, !tbaa !13
  store i64 %1, ptr %4, align 8, !tbaa !13
  %5 = load i64, ptr %3, align 8, !tbaa !13
  %6 = load i64, ptr %4, align 8, !tbaa !13
  %7 = udiv i64 %5, %6
  ret i64 %7
}

; Function Attrs: nounwind uwtable
define dso_local i64 @mix64(i64 noundef %0, i64 noundef %1) #0 {
  %3 = alloca i64, align 8
  %4 = alloca i64, align 8
  store i64 %0, ptr %3, align 8, !tbaa !13
  store i64 %1, ptr %4, align 8, !tbaa !13
  %5 = load i64, ptr %3, align 8, !tbaa !13
  %6 = load i64, ptr %4, align 8, !tbaa !13
  %7 = shl i64 %6, 13
  %8 = xor i64 %5, %7
  %9 = load i64, ptr %3, align 8, !tbaa !13
  %10 = lshr i64 %9, 7
  %11 = add i64 %8, %10
  %12 = load i64, ptr %4, align 8, !tbaa !13
  %13 = or i64 %12, 4660
  %14 = sub i64 %11, %13
  ret i64 %14
}

; Function Attrs: nounwind uwtable
define dso_local i32 @cmp_signed(i64 noundef %0, i64 noundef %1) #0 {
  %3 = alloca i64, align 8
  %4 = alloca i64, align 8
  store i64 %0, ptr %3, align 8, !tbaa !13
  store i64 %1, ptr %4, align 8, !tbaa !13
  %5 = load i64, ptr %3, align 8, !tbaa !13
  %6 = load i64, ptr %4, align 8, !tbaa !13
  %7 = icmp slt i64 %5, %6
  %8 = zext i1 %7 to i32
  %9 = mul nsw i32 %8, 4
  %10 = load i64, ptr %3, align 8, !tbaa !13
  %11 = load i64, ptr %4, align 8, !tbaa !13
  %12 = icmp eq i64 %10, %11
  %13 = zext i1 %12 to i32
  %14 = mul nsw i32 %13, 2
  %15 = add nsw i32 %9, %14
  %16 = load i64, ptr %3, align 8, !tbaa !13
  %17 = load i64, ptr %4, align 8, !tbaa !13
  %18 = icmp sgt i64 %16, %17
  %19 = zext i1 %18 to i32
  %20 = add nsw i32 %15, %19
  ret i32 %20
}

; Function Attrs: nounwind uwtable
define dso_local i32 @cmp_unsigned(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !12
  store i32 %1, ptr %4, align 4, !tbaa !12
  %5 = load i32, ptr %3, align 4, !tbaa !12
  %6 = load i32, ptr %4, align 4, !tbaa !12
  %7 = icmp ult i32 %5, %6
  %8 = zext i1 %7 to i32
  %9 = mul nsw i32 %8, 4
  %10 = load i32, ptr %3, align 4, !tbaa !12
  %11 = load i32, ptr %4, align 4, !tbaa !12
  %12 = icmp eq i32 %10, %11
  %13 = zext i1 %12 to i32
  %14 = mul nsw i32 %13, 2
  %15 = add nsw i32 %9, %14
  %16 = load i32, ptr %3, align 4, !tbaa !12
  %17 = load i32, ptr %4, align 4, !tbaa !12
  %18 = icmp ugt i32 %16, %17
  %19 = zext i1 %18 to i32
  %20 = add nsw i32 %15, %19
  ret i32 %20
}

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

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
!9 = !{!7, !7, i64 0}
!10 = !{!11, !11, i64 0}
!11 = !{!"short", !7, i64 0}
!12 = !{!6, !6, i64 0}
!13 = !{!14, !14, i64 0}
!14 = !{!"long", !7, i64 0}
