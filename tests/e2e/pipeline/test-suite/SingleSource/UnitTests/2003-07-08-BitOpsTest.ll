; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2003-07-08-BitOpsTest.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2003-07-08-BitOpsTest.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2003-07-08-BitOpsTest.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [16 x i8] c"%d %d %d %d %d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local void @test(i32 noundef %0, i32 noundef %1, i32 noundef %2, i32 noundef %3) #0 {
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  %11 = alloca i32, align 4
  %12 = alloca i32, align 4
  %13 = alloca i32, align 4
  store i32 %0, ptr %5, align 4, !tbaa !9
  store i32 %1, ptr %6, align 4, !tbaa !9
  store i32 %2, ptr %7, align 4, !tbaa !9
  store i32 %3, ptr %8, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %9) #3
  %14 = load i32, ptr %5, align 4, !tbaa !9
  %15 = load i32, ptr %6, align 4, !tbaa !9
  %16 = xor i32 %14, %15
  %17 = load i32, ptr %7, align 4, !tbaa !9
  %18 = xor i32 %16, %17
  %19 = load i32, ptr %8, align 4, !tbaa !9
  %20 = xor i32 %18, %19
  store i32 %20, ptr %9, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %10) #3
  %21 = load i32, ptr %5, align 4, !tbaa !9
  %22 = load i32, ptr %6, align 4, !tbaa !9
  %23 = or i32 %21, %22
  %24 = load i32, ptr %7, align 4, !tbaa !9
  %25 = or i32 %23, %24
  %26 = load i32, ptr %8, align 4, !tbaa !9
  %27 = or i32 %25, %26
  store i32 %27, ptr %10, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %11) #3
  %28 = load i32, ptr %5, align 4, !tbaa !9
  %29 = load i32, ptr %6, align 4, !tbaa !9
  %30 = and i32 %28, %29
  %31 = load i32, ptr %7, align 4, !tbaa !9
  %32 = and i32 %30, %31
  %33 = load i32, ptr %8, align 4, !tbaa !9
  %34 = and i32 %32, %33
  store i32 %34, ptr %11, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %12) #3
  %35 = load i32, ptr %5, align 4, !tbaa !9
  %36 = load i32, ptr %6, align 4, !tbaa !9
  %37 = xor i32 %36, -1
  %38 = and i32 %35, %37
  %39 = load i32, ptr %7, align 4, !tbaa !9
  %40 = load i32, ptr %8, align 4, !tbaa !9
  %41 = xor i32 %40, -1
  %42 = and i32 %39, %41
  %43 = xor i32 %38, %42
  store i32 %43, ptr %12, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %13) #3
  %44 = load i32, ptr %5, align 4, !tbaa !9
  %45 = load i32, ptr %6, align 4, !tbaa !9
  %46 = xor i32 %45, -1
  %47 = or i32 %44, %46
  %48 = load i32, ptr %7, align 4, !tbaa !9
  %49 = load i32, ptr %8, align 4, !tbaa !9
  %50 = xor i32 %49, -1
  %51 = or i32 %48, %50
  %52 = xor i32 %47, %51
  store i32 %52, ptr %13, align 4, !tbaa !9
  %53 = load i32, ptr %9, align 4, !tbaa !9
  %54 = load i32, ptr %10, align 4, !tbaa !9
  %55 = load i32, ptr %11, align 4, !tbaa !9
  %56 = load i32, ptr %12, align 4, !tbaa !9
  %57 = load i32, ptr %13, align 4, !tbaa !9
  %58 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %53, i32 noundef %54, i32 noundef %55, i32 noundef %56, i32 noundef %57)
  call void @llvm.lifetime.end.p0(ptr %13) #3
  call void @llvm.lifetime.end.p0(ptr %12) #3
  call void @llvm.lifetime.end.p0(ptr %11) #3
  call void @llvm.lifetime.end.p0(ptr %10) #3
  call void @llvm.lifetime.end.p0(ptr %9) #3
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @test(i32 noundef 7, i32 noundef 8, i32 noundef -5, i32 noundef 5)
  ret i32 0
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
