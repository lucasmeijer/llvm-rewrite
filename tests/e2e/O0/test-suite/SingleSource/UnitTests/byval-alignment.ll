; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/byval-alignment.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/byval-alignment.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/byval-alignment.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.s0 = type { x86_fp80, x86_fp80 }

@g0 = dso_local global %struct.s0 zeroinitializer, align 16
@__const.main.a = private unnamed_addr constant %struct.s0 { x86_fp80 1.000000e+00, x86_fp80 2.000000e+00 }, align 16
@.str = private unnamed_addr constant [24 x i8] c"g0.x: %.4f, g0.y: %.4f\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local void @f0(i32 noundef %0, ptr noundef byval(%struct.s0) align 16 %1) #0 {
  %3 = alloca i32, align 4
  store i32 %0, ptr %3, align 4
  call void @llvm.memcpy.p0.p0.i64(ptr align 16 @g0, ptr align 16 %1, i64 32, i1 false)
  %4 = load i32, ptr %3, align 4
  %5 = sitofp i32 %4 to x86_fp80
  %6 = load x86_fp80, ptr @g0, align 16
  %7 = fadd x86_fp80 %6, %5
  store x86_fp80 %7, ptr @g0, align 16
  %8 = load i32, ptr %3, align 4
  %9 = sitofp i32 %8 to x86_fp80
  %10 = load x86_fp80, ptr getelementptr inbounds nuw (i8, ptr @g0, i64 16), align 16
  %11 = fadd x86_fp80 %10, %9
  store x86_fp80 %11, ptr getelementptr inbounds nuw (i8, ptr @g0, i64 16), align 16
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca %struct.s0, align 16
  store i32 0, ptr %1, align 4
  call void @llvm.memcpy.p0.p0.i64(ptr align 16 %2, ptr align 16 @__const.main.a, i64 32, i1 false)
  call void @f0(i32 noundef 1, ptr noundef byval(%struct.s0) align 16 %2)
  %3 = load x86_fp80, ptr @g0, align 16
  %4 = fptrunc x86_fp80 %3 to double
  %5 = load x86_fp80, ptr getelementptr inbounds nuw (i8, ptr @g0, i64 16), align 16
  %6 = fptrunc x86_fp80 %5 to double
  %7 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %4, double noundef %6)
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #2

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{i32 7, !"frame-pointer", i32 2}
!4 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
