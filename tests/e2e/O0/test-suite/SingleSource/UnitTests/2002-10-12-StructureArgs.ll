; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2002-10-12-StructureArgs.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2002-10-12-StructureArgs.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2002-10-12-StructureArgs.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.vec2 = type { double, double }

@.str = private unnamed_addr constant [16 x i8] c"%f, %f, %f, %f\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local void @print(double %0, double %1, double %2, double %3) #0 {
  %5 = alloca %struct.vec2, align 8
  %6 = alloca %struct.vec2, align 8
  %7 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 0
  store double %0, ptr %7, align 8
  %8 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 1
  store double %1, ptr %8, align 8
  %9 = getelementptr inbounds nuw { double, double }, ptr %6, i32 0, i32 0
  store double %2, ptr %9, align 8
  %10 = getelementptr inbounds nuw { double, double }, ptr %6, i32 0, i32 1
  store double %3, ptr %10, align 8
  %11 = getelementptr inbounds nuw %struct.vec2, ptr %5, i32 0, i32 0
  %12 = load double, ptr %11, align 8
  %13 = getelementptr inbounds nuw %struct.vec2, ptr %5, i32 0, i32 1
  %14 = load double, ptr %13, align 8
  %15 = getelementptr inbounds nuw %struct.vec2, ptr %6, i32 0, i32 0
  %16 = load double, ptr %15, align 8
  %17 = getelementptr inbounds nuw %struct.vec2, ptr %6, i32 0, i32 1
  %18 = load double, ptr %17, align 8
  %19 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %12, double noundef %14, double noundef %16, double noundef %18)
  ret void
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca %struct.vec2, align 8
  %3 = alloca %struct.vec2, align 8
  store i32 0, ptr %1, align 4
  %4 = getelementptr inbounds nuw %struct.vec2, ptr %2, i32 0, i32 0
  store double 5.000000e-01, ptr %4, align 8
  %5 = getelementptr inbounds nuw %struct.vec2, ptr %2, i32 0, i32 1
  store double 1.200000e+00, ptr %5, align 8
  %6 = getelementptr inbounds nuw %struct.vec2, ptr %3, i32 0, i32 0
  store double -1.230100e+02, ptr %6, align 8
  %7 = getelementptr inbounds nuw %struct.vec2, ptr %3, i32 0, i32 1
  store double f0x3FD5555555555555, ptr %7, align 8
  %8 = getelementptr inbounds nuw { double, double }, ptr %2, i32 0, i32 0
  %9 = load double, ptr %8, align 8
  %10 = getelementptr inbounds nuw { double, double }, ptr %2, i32 0, i32 1
  %11 = load double, ptr %10, align 8
  %12 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 0
  %13 = load double, ptr %12, align 8
  %14 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 1
  %15 = load double, ptr %14, align 8
  call void @print(double %9, double %11, double %13, double %15)
  ret i32 0
}

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{i32 7, !"frame-pointer", i32 2}
!4 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
