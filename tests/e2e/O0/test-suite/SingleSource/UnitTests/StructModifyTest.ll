; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/StructModifyTest.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/StructModifyTest.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/StructModifyTest.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.S1Ty = type { i32, float, double, i64 }
%struct.S2Ty = type { %struct.S1Ty, %struct.S1Ty }

@.str = private unnamed_addr constant [18 x i8] c"%d, %f, %f, %lld\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local void @printS1(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8
  %3 = load ptr, ptr %2, align 8
  %4 = getelementptr inbounds nuw %struct.S1Ty, ptr %3, i32 0, i32 0
  %5 = load i32, ptr %4, align 8
  %6 = load ptr, ptr %2, align 8
  %7 = getelementptr inbounds nuw %struct.S1Ty, ptr %6, i32 0, i32 1
  %8 = load float, ptr %7, align 4
  %9 = fpext float %8 to double
  %10 = load ptr, ptr %2, align 8
  %11 = getelementptr inbounds nuw %struct.S1Ty, ptr %10, i32 0, i32 2
  %12 = load double, ptr %11, align 8
  %13 = load ptr, ptr %2, align 8
  %14 = getelementptr inbounds nuw %struct.S1Ty, ptr %13, i32 0, i32 3
  %15 = load i64, ptr %14, align 8
  %16 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %5, double noundef %9, double noundef %12, i64 noundef %15)
  ret void
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca %struct.S2Ty, align 8
  store i32 0, ptr %1, align 4
  %3 = getelementptr inbounds nuw %struct.S2Ty, ptr %2, i32 0, i32 0
  %4 = getelementptr inbounds nuw %struct.S1Ty, ptr %3, i32 0, i32 0
  store i32 1, ptr %4, align 8
  %5 = getelementptr inbounds nuw %struct.S2Ty, ptr %2, i32 0, i32 0
  %6 = getelementptr inbounds nuw %struct.S1Ty, ptr %5, i32 0, i32 1
  store float 1.234200e+02, ptr %6, align 4
  %7 = getelementptr inbounds nuw %struct.S2Ty, ptr %2, i32 0, i32 0
  %8 = getelementptr inbounds nuw %struct.S1Ty, ptr %7, i32 0, i32 2
  store double 1.900000e+01, ptr %8, align 8
  %9 = getelementptr inbounds nuw %struct.S2Ty, ptr %2, i32 0, i32 0
  %10 = getelementptr inbounds nuw %struct.S1Ty, ptr %9, i32 0, i32 3
  store i64 123455678902, ptr %10, align 8
  %11 = getelementptr inbounds nuw %struct.S2Ty, ptr %2, i32 0, i32 1
  %12 = getelementptr inbounds nuw %struct.S1Ty, ptr %11, i32 0, i32 0
  store i32 2, ptr %12, align 8
  %13 = getelementptr inbounds nuw %struct.S2Ty, ptr %2, i32 0, i32 1
  %14 = getelementptr inbounds nuw %struct.S1Ty, ptr %13, i32 0, i32 1
  store float 2.342000e+01, ptr %14, align 4
  %15 = getelementptr inbounds nuw %struct.S2Ty, ptr %2, i32 0, i32 1
  %16 = getelementptr inbounds nuw %struct.S1Ty, ptr %15, i32 0, i32 2
  store double 2.900000e+01, ptr %16, align 8
  %17 = getelementptr inbounds nuw %struct.S2Ty, ptr %2, i32 0, i32 1
  %18 = getelementptr inbounds nuw %struct.S1Ty, ptr %17, i32 0, i32 3
  store i64 23455678902, ptr %18, align 8
  %19 = getelementptr inbounds nuw %struct.S2Ty, ptr %2, i32 0, i32 0
  call void @printS1(ptr noundef %19)
  %20 = getelementptr inbounds nuw %struct.S2Ty, ptr %2, i32 0, i32 1
  call void @printS1(ptr noundef %20)
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
