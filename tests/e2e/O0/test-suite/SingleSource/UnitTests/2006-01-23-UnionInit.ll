; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2006-01-23-UnionInit.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2006-01-23-UnionInit.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2006-01-23-UnionInit.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.task_struct = type { [16 x i8] }
%struct.anon = type { i8, i8 }
%union.bt4 = type { %struct.at4 }
%struct.at4 = type { i64 }
%struct.anon.0 = type { i8, i8 }
%union.anon.3 = type { %struct.dvd_send_key }
%struct.dvd_send_key = type { i8, [5 x i8], [2 x i8] }
%struct.s = type { i32, i32, i32 }
%struct.foo2 = type <{ i16, [2 x i8], i64, i16, [2 x i8] }>
%union.ucast = type { %struct.s }
%struct.spinlock_t = type {}
%struct.emptystruct = type {}

@init_task_union = dso_local global { %struct.task_struct, [16368 x i8] } { %struct.task_struct { [16 x i8] c"swapper\00\00\00\00\00\00\00\00\00" }, [16368 x i8] zeroinitializer }, align 8
@fixed_tl = dso_local global [1 x { { %struct.anon, [2 x i8] }, i32 }] [{ { %struct.anon, [2 x i8] }, i32 } { { %struct.anon, [2 x i8] } { %struct.anon { i8 96, i8 7 }, [2 x i8] zeroinitializer }, i32 256 }], align 4
@bkv4 = dso_local global %union.bt4 { %struct.at4 { i64 61172160 } }, align 8
@cav1 = dso_local global { i8, i8, [1 x i8], i8 } { i8 100, i8 1, [1 x i8] c"\02", i8 0 }, align 4
@V = dso_local global { %struct.anon.0, [2 x i8] } { %struct.anon.0 { i8 1, i8 2 }, [2 x i8] zeroinitializer }, align 4
@nd = dso_local global { [64 x i8] } { [64 x i8] c"relname\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00" }, align 4
@hobbit = dso_local global { i32, [3 x i32] } { i32 5, [3 x i32] [i32 1, i32 2, i32 3] }, align 4
@hobbit2 = dso_local global { i32, [3 x i32] } { i32 5, [3 x i32] [i32 1, i32 2, i32 3] }, align 4
@data = dso_local global { i32, [3 x i32] } { i32 0, [3 x i32] [i32 1, i32 2, i32 3] }, align 4
@s = dso_local global <{ ptr, [19 x i8] }> <{ ptr null, [19 x i8] c"   xyzkasjdlf     \00" }>, align 8
@ai = dso_local global %union.anon.3 { %struct.dvd_send_key { i8 3, [5 x i8] c"foo\00\00", [2 x i8] zeroinitializer } }, align 4
@.str = private unnamed_addr constant [20 x i8] c"returning raw_lock\0A\00", align 1
@__const.ucast_test.y = private unnamed_addr constant %struct.s { i32 1, i32 2, i32 0 }, align 4
@foo2 = dso_local global %struct.foo2 <{ i16 23122, [2 x i8] zeroinitializer, i64 -12312731, i16 -312, [2 x i8] zeroinitializer }>, align 4
@.str.2 = private unnamed_addr constant [11 x i8] c"PR156: %s\0A\00", align 1
@.str.3 = private unnamed_addr constant [21 x i8] c"PR295/PR568: %d, %d\0A\00", align 1
@.str.4 = private unnamed_addr constant [23 x i8] c"PR574: %d, %d, %d, %d\0A\00", align 1
@.str.5 = private unnamed_addr constant [19 x i8] c"PR162: %d, %d, %d\0A\00", align 1
@.str.6 = private unnamed_addr constant [15 x i8] c"PR650: %s, %d\0A\00", align 1
@.str.7 = private unnamed_addr constant [23 x i8] c"PR199: %d, %d, %d, %d\0A\00", align 1
@.str.8 = private unnamed_addr constant [23 x i8] c"PR431: %d, %d, %d, %d\0A\00", align 1
@.str.9 = private unnamed_addr constant [18 x i8] c"PR654: %ld, '%s'\0A\00", align 1
@.str.10 = private unnamed_addr constant [17 x i8] c"PR323: %d, '%s'\0A\00", align 1
@.str.11 = private unnamed_addr constant [11 x i8] c"PR627: %d\0A\00", align 1
@.str.12 = private unnamed_addr constant [22 x i8] c"PR684: %d, %d, %d %d\0A\00", align 1
@.str.13 = private unnamed_addr constant [28 x i8] c"rdar://6828787: %d, %d, %d\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local ptr @foo() #0 {
  ret ptr @hobbit2
}

; Function Attrs: noinline nounwind uwtable
define dso_local void @one_raw_spinlock() #0 {
  %1 = call i32 (ptr, ...) @printf(ptr noundef @.str)
  ret void
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: noinline nounwind uwtable
define dso_local { i64, i32 } @ucast_test() #0 {
  %1 = alloca %union.ucast, align 4
  %2 = alloca %struct.s, align 4
  %3 = alloca { i64, i32 }, align 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %2, ptr align 4 @__const.ucast_test.y, i64 12, i1 false)
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %1, ptr align 4 %2, i64 12, i1 false)
  %4 = getelementptr inbounds nuw %union.ucast, ptr %1, i32 0, i32 0
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %3, ptr align 4 %4, i64 12, i1 false)
  %5 = load { i64, i32 }, ptr %3, align 8
  ret { i64, i32 } %5
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #2

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca %union.ucast, align 4
  %3 = alloca %struct.spinlock_t, align 1
  %4 = alloca %struct.spinlock_t, align 1
  %5 = alloca %struct.emptystruct, align 1
  %6 = alloca %union.ucast, align 4
  %7 = alloca { i64, i32 }, align 8
  store i32 0, ptr %1, align 4
  %8 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, ptr noundef @init_task_union)
  %9 = load i32, ptr @fixed_tl, align 4
  %10 = load i32, ptr getelementptr inbounds nuw (i8, ptr @fixed_tl, i64 4), align 4
  %11 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i32 noundef %9, i32 noundef %10)
  %12 = load i64, ptr @bkv4, align 8
  %13 = trunc i64 %12 to i32
  %14 = load i16, ptr @cav1, align 4
  %15 = shl i16 %14, 12
  %16 = ashr i16 %15, 12
  %17 = sext i16 %16 to i32
  %18 = load i16, ptr @cav1, align 4
  %19 = shl i16 %18, 6
  %20 = ashr i16 %19, 10
  %21 = sext i16 %20 to i32
  %22 = load i8, ptr getelementptr inbounds nuw (i8, ptr @cav1, i64 2), align 2
  %23 = zext i8 %22 to i32
  %24 = call i32 (ptr, ...) @printf(ptr noundef @.str.4, i32 noundef %13, i32 noundef %17, i32 noundef %21, i32 noundef %23)
  %25 = load i8, ptr @V, align 4
  %26 = sext i8 %25 to i32
  %27 = load i8, ptr getelementptr inbounds nuw (i8, ptr @V, i64 1), align 1
  %28 = sext i8 %27 to i32
  %29 = load i32, ptr @V, align 4
  %30 = call i32 (ptr, ...) @printf(ptr noundef @.str.5, i32 noundef %26, i32 noundef %28, i32 noundef %29)
  %31 = load i32, ptr @nd, align 4
  %32 = call i32 (ptr, ...) @printf(ptr noundef @.str.6, ptr noundef @nd, i32 noundef %31)
  %33 = load i32, ptr @hobbit, align 4
  %34 = load i32, ptr getelementptr inbounds nuw (i8, ptr @hobbit, i64 4), align 4
  %35 = load i32, ptr getelementptr inbounds nuw (i8, ptr @hobbit, i64 8), align 4
  %36 = load i32, ptr getelementptr inbounds nuw (i8, ptr @hobbit, i64 12), align 4
  %37 = call i32 (ptr, ...) @printf(ptr noundef @.str.7, i32 noundef %33, i32 noundef %34, i32 noundef %35, i32 noundef %36)
  %38 = load i32, ptr @hobbit2, align 4
  %39 = load i32, ptr getelementptr inbounds nuw (i8, ptr @hobbit2, i64 4), align 4
  %40 = load i32, ptr getelementptr inbounds nuw (i8, ptr @hobbit2, i64 8), align 4
  %41 = load i32, ptr getelementptr inbounds nuw (i8, ptr @hobbit2, i64 12), align 4
  %42 = call i32 (ptr, ...) @printf(ptr noundef @.str.7, i32 noundef %38, i32 noundef %39, i32 noundef %40, i32 noundef %41)
  %43 = load i32, ptr @data, align 4
  %44 = load i32, ptr getelementptr inbounds nuw (i8, ptr @data, i64 4), align 4
  %45 = load i32, ptr getelementptr inbounds nuw (i8, ptr @data, i64 8), align 4
  %46 = load i32, ptr getelementptr inbounds nuw (i8, ptr @data, i64 12), align 4
  %47 = call i32 (ptr, ...) @printf(ptr noundef @.str.8, i32 noundef %43, i32 noundef %44, i32 noundef %45, i32 noundef %46)
  %48 = load ptr, ptr @s, align 8
  %49 = ptrtoint ptr %48 to i64
  %50 = call i32 (ptr, ...) @printf(ptr noundef @.str.9, i64 noundef %49, ptr noundef getelementptr inbounds nuw (i8, ptr @s, i64 8))
  %51 = load i8, ptr @ai, align 4
  %52 = and i8 %51, 3
  %53 = zext i8 %52 to i32
  %54 = call i32 (ptr, ...) @printf(ptr noundef @.str.10, i32 noundef %53, ptr noundef getelementptr inbounds nuw (i8, ptr @ai, i64 1))
  call void @one_raw_spinlock()
  call void @llvm.memcpy.p0.p0.i64(ptr align 1 %3, ptr align 1 %4, i64 0, i1 false)
  %55 = call i32 (ptr, ...) @printf(ptr noundef @.str.11, i32 noundef 0)
  %56 = call { i64, i32 } @ucast_test()
  %57 = getelementptr inbounds nuw %union.ucast, ptr %6, i32 0, i32 0
  store { i64, i32 } %56, ptr %7, align 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %57, ptr align 8 %7, i64 12, i1 false)
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %2, ptr align 4 %6, i64 12, i1 false)
  %58 = getelementptr inbounds nuw %struct.s, ptr %2, i32 0, i32 0
  %59 = load i32, ptr %58, align 4
  %60 = getelementptr inbounds nuw %struct.s, ptr %2, i32 0, i32 1
  %61 = load i32, ptr %60, align 4
  %62 = getelementptr inbounds nuw %struct.s, ptr %2, i32 0, i32 2
  %63 = load i32, ptr %62, align 4
  %64 = load i32, ptr %2, align 4
  %65 = call i32 (ptr, ...) @printf(ptr noundef @.str.12, i32 noundef %59, i32 noundef %61, i32 noundef %63, i32 noundef %64)
  %66 = load i16, ptr @foo2, align 4
  %67 = sext i16 %66 to i32
  %68 = load i64, ptr getelementptr inbounds nuw (i8, ptr @foo2, i64 4), align 4
  %69 = trunc i64 %68 to i32
  %70 = load i16, ptr getelementptr inbounds nuw (i8, ptr @foo2, i64 12), align 4
  %71 = sext i16 %70 to i32
  %72 = call i32 (ptr, ...) @printf(ptr noundef @.str.13, i32 noundef %67, i32 noundef %69, i32 noundef %71)
  ret i32 0
}

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{i32 7, !"frame-pointer", i32 2}
!4 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
