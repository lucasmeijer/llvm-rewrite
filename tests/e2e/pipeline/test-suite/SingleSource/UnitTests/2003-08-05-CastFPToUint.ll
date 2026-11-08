; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2003-08-05-CastFPToUint.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2003-08-05-CastFPToUint.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2003-08-05-CastFPToUint.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [30 x i8] c"DC = %lf, DS = %lf, DI = %lf\0A\00", align 1
@.str.1 = private unnamed_addr constant [27 x i8] c"uc = %u, us = %u, ui = %u\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca double, align 8
  %7 = alloca double, align 8
  %8 = alloca double, align 8
  %9 = alloca i8, align 1
  %10 = alloca i16, align 2
  %11 = alloca i32, align 4
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %6) #3
  %12 = call double @getDC()
  store double %12, ptr %6, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %7) #3
  %13 = call double @getDS()
  store double %13, ptr %7, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %8) #3
  %14 = call double @getDI()
  store double %14, ptr %8, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %9) #3
  %15 = load double, ptr %6, align 8, !tbaa !14
  %16 = fptoui double %15 to i8
  store i8 %16, ptr %9, align 1, !tbaa !16
  call void @llvm.lifetime.start.p0(ptr %10) #3
  %17 = load double, ptr %7, align 8, !tbaa !14
  %18 = fptoui double %17 to i16
  store i16 %18, ptr %10, align 2, !tbaa !17
  call void @llvm.lifetime.start.p0(ptr %11) #3
  %19 = load double, ptr %8, align 8, !tbaa !14
  %20 = fptoui double %19 to i32
  store i32 %20, ptr %11, align 4, !tbaa !9
  %21 = load double, ptr %6, align 8, !tbaa !14
  %22 = load double, ptr %7, align 8, !tbaa !14
  %23 = load double, ptr %8, align 8, !tbaa !14
  %24 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %21, double noundef %22, double noundef %23)
  %25 = load i8, ptr %9, align 1, !tbaa !16
  %26 = zext i8 %25 to i32
  %27 = load i16, ptr %10, align 2, !tbaa !17
  %28 = zext i16 %27 to i32
  %29 = load i32, ptr %11, align 4, !tbaa !9
  %30 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %26, i32 noundef %28, i32 noundef %29)
  call void @llvm.lifetime.end.p0(ptr %11) #3
  call void @llvm.lifetime.end.p0(ptr %10) #3
  call void @llvm.lifetime.end.p0(ptr %9) #3
  call void @llvm.lifetime.end.p0(ptr %8) #3
  call void @llvm.lifetime.end.p0(ptr %7) #3
  call void @llvm.lifetime.end.p0(ptr %6) #3
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define internal double @getDC() #0 {
  ret double 2.400000e+02
}

; Function Attrs: nounwind uwtable
define internal double @getDS() #0 {
  ret double 6.552000e+04
}

; Function Attrs: nounwind uwtable
define internal double @getDI() #0 {
  ret double f0x41EFFFFFFE000000
}

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind }

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
!11 = !{!"p2 omnipotent char", !12, i64 0}
!12 = !{!"any p2 pointer", !13, i64 0}
!13 = !{!"any pointer", !7, i64 0}
!14 = !{!15, !15, i64 0}
!15 = !{!"double", !7, i64 0}
!16 = !{!7, !7, i64 0}
!17 = !{!18, !18, i64 0}
!18 = !{!"short", !7, i64 0}
