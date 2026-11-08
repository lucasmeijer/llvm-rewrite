; @source: tests/e2e/src/intrinsics/builtins.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/intrinsics/builtins.c'
source_filename = "tests/e2e/src/intrinsics/builtins.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@__const.main.vals = private unnamed_addr constant [5 x i32] [i32 1, i32 -2147483648, i32 -252645136, i32 12345, i32 -1], align 16
@.str = private unnamed_addr constant [18 x i8] c"%d %d %d %08x %d\0A\00", align 1
@.str.1 = private unnamed_addr constant [15 x i8] c"%d %d %016llx\0A\00", align 1
@.str.2 = private unnamed_addr constant [14 x i8] c"%d %d %d %ld\0A\00", align 1
@.str.3 = private unnamed_addr constant [10 x i8] c"%d %d %d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [5 x i32], align 16
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i64, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca i64, align 8
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #6
  call void @llvm.memcpy.p0.p0.i64(ptr align 16 %2, ptr align 16 @__const.main.vals, i64 20, i1 false)
  call void @llvm.lifetime.start.p0(ptr %3) #6
  store i32 0, ptr %3, align 4, !tbaa !9
  br label %11

11:                                               ; preds = %32, %0
  %12 = load i32, ptr %3, align 4, !tbaa !9
  %13 = icmp slt i32 %12, 5
  br i1 %13, label %15, label %14

14:                                               ; preds = %11
  call void @llvm.lifetime.end.p0(ptr %3) #6
  br label %35

15:                                               ; preds = %11
  call void @llvm.lifetime.start.p0(ptr %4) #6
  %16 = load i32, ptr %3, align 4, !tbaa !9
  %17 = sext i32 %16 to i64
  %18 = getelementptr inbounds [5 x i32], ptr %2, i64 0, i64 %17
  %19 = load i32, ptr %18, align 4, !tbaa !9
  store i32 %19, ptr %4, align 4, !tbaa !9
  %20 = load i32, ptr %4, align 4, !tbaa !9
  %21 = call i32 @llvm.ctpop.i32(i32 %20)
  %22 = load i32, ptr %4, align 4, !tbaa !9
  %23 = call i32 @llvm.ctlz.i32(i32 %22, i1 true)
  %24 = load i32, ptr %4, align 4, !tbaa !9
  %25 = call i32 @llvm.cttz.i32(i32 %24, i1 true)
  %26 = load i32, ptr %4, align 4, !tbaa !9
  %27 = call i32 @llvm.bswap.i32(i32 %26)
  %28 = load i32, ptr %4, align 4, !tbaa !9
  %29 = call i32 @llvm.ctpop.i32(i32 %28)
  %30 = and i32 %29, 1
  %31 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %21, i32 noundef %23, i32 noundef %25, i32 noundef %27, i32 noundef %30)
  call void @llvm.lifetime.end.p0(ptr %4) #6
  br label %32

32:                                               ; preds = %15
  %33 = load i32, ptr %3, align 4, !tbaa !9
  %34 = add nsw i32 %33, 1
  store i32 %34, ptr %3, align 4, !tbaa !9
  br label %11, !llvm.loop !10

35:                                               ; preds = %14
  call void @llvm.lifetime.start.p0(ptr %5) #6
  store i64 81985529216486895, ptr %5, align 8, !tbaa !12
  %36 = load i64, ptr %5, align 8, !tbaa !12
  %37 = call i64 @llvm.ctpop.i64(i64 %36)
  %38 = trunc i64 %37 to i32
  %39 = load i64, ptr %5, align 8, !tbaa !12
  %40 = call i64 @llvm.ctlz.i64(i64 %39, i1 true)
  %41 = trunc i64 %40 to i32
  %42 = load i64, ptr %5, align 8, !tbaa !12
  %43 = call i64 @llvm.bswap.i64(i64 %42)
  %44 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %38, i32 noundef %41, i64 noundef %43)
  call void @llvm.lifetime.start.p0(ptr %6) #6
  call void @llvm.lifetime.start.p0(ptr %7) #6
  %45 = call { i32, i1 } @llvm.sadd.with.overflow.i32(i32 2147483600, i32 100)
  %46 = extractvalue { i32, i1 } %45, 1
  %47 = extractvalue { i32, i1 } %45, 0
  store i32 %47, ptr %6, align 4
  %48 = zext i1 %46 to i32
  store i32 %48, ptr %7, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %8) #6
  call void @llvm.lifetime.start.p0(ptr %9) #6
  %49 = call { i64, i1 } @llvm.smul.with.overflow.i64(i64 3037000500, i64 3037000500)
  %50 = extractvalue { i64, i1 } %49, 1
  %51 = extractvalue { i64, i1 } %49, 0
  store i64 %51, ptr %8, align 8
  %52 = zext i1 %50 to i32
  store i32 %52, ptr %9, align 4, !tbaa !9
  %53 = load i32, ptr %7, align 4, !tbaa !9
  %54 = load i32, ptr %6, align 4, !tbaa !9
  %55 = load i32, ptr %9, align 4, !tbaa !9
  %56 = load i64, ptr %8, align 8, !tbaa !14
  %57 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i32 noundef %53, i32 noundef %54, i32 noundef %55, i64 noundef %56)
  call void @llvm.lifetime.start.p0(ptr %10) #6
  store i32 -17, ptr %10, align 4, !tbaa !9
  %58 = load i32, ptr %10, align 4, !tbaa !9
  %59 = call i32 @llvm.abs.i32(i32 %58, i1 true)
  %60 = load i32, ptr %10, align 4, !tbaa !9
  %61 = sext i32 %60 to i64
  %62 = call i64 @llvm.expect.i64(i64 %61, i64 0)
  %63 = icmp slt i64 %62, 0
  %64 = zext i1 %63 to i32
  %65 = load i32, ptr %10, align 4, !tbaa !9
  %66 = icmp slt i32 %65, 0
  br i1 %66, label %67, label %70

67:                                               ; preds = %35
  %68 = load i32, ptr %10, align 4, !tbaa !9
  %69 = sub nsw i32 0, %68
  br label %72

70:                                               ; preds = %35
  %71 = load i32, ptr %10, align 4, !tbaa !9
  br label %72

72:                                               ; preds = %70, %67
  %73 = phi i32 [ %69, %67 ], [ %71, %70 ]
  %74 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i32 noundef %59, i32 noundef %64, i32 noundef %73)
  call void @llvm.lifetime.end.p0(ptr %10) #6
  call void @llvm.lifetime.end.p0(ptr %9) #6
  call void @llvm.lifetime.end.p0(ptr %8) #6
  call void @llvm.lifetime.end.p0(ptr %7) #6
  call void @llvm.lifetime.end.p0(ptr %6) #6
  call void @llvm.lifetime.end.p0(ptr %5) #6
  call void @llvm.lifetime.end.p0(ptr %2) #6
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.ctpop.i32(i32) #3

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.ctlz.i32(i32, i1 immarg) #4

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.cttz.i32(i32, i1 immarg) #4

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.bswap.i32(i32) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.ctpop.i64(i64) #3

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.ctlz.i64(i64, i1 immarg) #4

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.bswap.i64(i64) #3

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare { i32, i1 } @llvm.sadd.with.overflow.i32(i32, i32) #3

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare { i64, i1 } @llvm.smul.with.overflow.i64(i64, i64) #3

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.abs.i32(i32, i1 immarg) #4

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(none)
declare i64 @llvm.expect.i64(i64, i64) #5

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #4 = { nocallback nofree nosync nounwind speculatable willreturn memory(none) }
attributes #5 = { nocallback nofree nosync nounwind willreturn memory(none) }
attributes #6 = { nounwind }

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
!10 = distinct !{!10, !11}
!11 = !{!"llvm.loop.mustprogress"}
!12 = !{!13, !13, i64 0}
!13 = !{!"long long", !7, i64 0}
!14 = !{!15, !15, i64 0}
!15 = !{!"long", !7, i64 0}
