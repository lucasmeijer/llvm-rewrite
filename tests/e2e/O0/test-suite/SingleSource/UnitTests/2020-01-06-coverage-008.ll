; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-008.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-008.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-008.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.a = type { i64, i64 }

@d = dso_local global %struct.a zeroinitializer, align 8
@s = dso_local global %struct.a zeroinitializer, align 8
@e = dso_local global i64 0, align 8
@__const.main.h = private unnamed_addr constant %struct.a { i64 0, i64 9 }, align 8
@.str = private unnamed_addr constant [11 x i8] c"d.b = %li\0A\00", align 1
@.str.1 = private unnamed_addr constant [11 x i8] c"d.c = %li\0A\00", align 1
@.str.2 = private unnamed_addr constant [11 x i8] c"s.b = %li\0A\00", align 1
@.str.3 = private unnamed_addr constant [11 x i8] c"s.c = %li\0A\00", align 1
@.str.4 = private unnamed_addr constant [9 x i8] c"e = %li\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local void @f(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8
  %3 = load ptr, ptr %2, align 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 @d, ptr align 8 %3, i64 16, i1 false)
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i64, align 8
  %3 = alloca i64, align 8
  %4 = alloca i64, align 8
  %5 = alloca i64, align 8
  %6 = alloca i64, align 8
  %7 = alloca %struct.a, align 8
  store i32 0, ptr %1, align 4
  store i64 -7988785259004943837, ptr %6, align 8
  store i64 -7, ptr %5, align 8
  store i64 -7, ptr %4, align 8
  store i64 -7988785259004943837, ptr %3, align 8
  store i64 -6, ptr %2, align 8
  %8 = load i64, ptr %3, align 8
  store i64 %8, ptr @s, align 8
  %9 = load i64, ptr %2, align 8
  store i64 %9, ptr getelementptr inbounds nuw (i8, ptr @s, i64 8), align 8
  %10 = load i64, ptr %4, align 8
  store i64 %10, ptr @e, align 8
  %11 = load i64, ptr %6, align 8
  store i64 %11, ptr @d, align 8
  %12 = load i64, ptr %5, align 8
  store i64 %12, ptr getelementptr inbounds nuw (i8, ptr @d, i64 8), align 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %7, ptr align 8 @__const.main.h, i64 16, i1 false)
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 @s, ptr align 8 %7, i64 16, i1 false)
  %13 = getelementptr inbounds nuw %struct.a, ptr %7, i32 0, i32 1
  %14 = load i64, ptr %13, align 8
  store i64 %14, ptr @e, align 8
  call void @f(ptr noundef %7)
  %15 = load i64, ptr @d, align 8
  %16 = call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef %15)
  %17 = load i64, ptr getelementptr inbounds nuw (i8, ptr @d, i64 8), align 8
  %18 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i64 noundef %17)
  %19 = load i64, ptr @s, align 8
  %20 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i64 noundef %19)
  %21 = load i64, ptr getelementptr inbounds nuw (i8, ptr @s, i64 8), align 8
  %22 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i64 noundef %21)
  %23 = load i64, ptr @e, align 8
  %24 = call i32 (ptr, ...) @printf(ptr noundef @.str.4, i64 noundef %23)
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
