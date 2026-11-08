; @source: tests/e2e/src/arith/mul_div_rem.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/arith/mul_div_rem.c'
source_filename = "tests/e2e/src/arith/mul_div_rem.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@__const.main.xs = private unnamed_addr constant [6 x i32] [i32 17, i32 -17, i32 1000003, i32 -5, i32 0, i32 2147483647], align 16
@__const.main.ds = private unnamed_addr constant [6 x i32] [i32 3, i32 -3, i32 7, i32 1, i32 -1, i32 100], align 16
@.str = private unnamed_addr constant [19 x i8] c"%d %d: %lld %d %d\0A\00", align 1
@.str.1 = private unnamed_addr constant [10 x i8] c"%u %u %u\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [6 x i32], align 16
  %3 = alloca [6 x i32], align 16
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  call void @llvm.memcpy.p0.p0.i64(ptr align 16 %2, ptr align 16 @__const.main.xs, i64 24, i1 false)
  call void @llvm.lifetime.start.p0(ptr %3) #3
  call void @llvm.memcpy.p0.p0.i64(ptr align 16 %3, ptr align 16 @__const.main.ds, i64 24, i1 false)
  call void @llvm.lifetime.start.p0(ptr %4) #3
  store i32 0, ptr %4, align 4, !tbaa !9
  br label %10

10:                                               ; preds = %57, %0
  %11 = load i32, ptr %4, align 4, !tbaa !9
  %12 = icmp slt i32 %11, 6
  br i1 %12, label %14, label %13

13:                                               ; preds = %10
  store i32 2, ptr %5, align 4
  call void @llvm.lifetime.end.p0(ptr %4) #3
  br label %60

14:                                               ; preds = %10
  call void @llvm.lifetime.start.p0(ptr %6) #3
  store i32 0, ptr %6, align 4, !tbaa !9
  br label %15

15:                                               ; preds = %53, %14
  %16 = load i32, ptr %6, align 4, !tbaa !9
  %17 = icmp slt i32 %16, 6
  br i1 %17, label %19, label %18

18:                                               ; preds = %15
  store i32 5, ptr %5, align 4
  call void @llvm.lifetime.end.p0(ptr %6) #3
  br label %56

19:                                               ; preds = %15
  call void @llvm.lifetime.start.p0(ptr %7) #3
  %20 = load i32, ptr %4, align 4, !tbaa !9
  %21 = sext i32 %20 to i64
  %22 = getelementptr inbounds [6 x i32], ptr %2, i64 0, i64 %21
  %23 = load i32, ptr %22, align 4, !tbaa !9
  store i32 %23, ptr %7, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %8) #3
  %24 = load i32, ptr %6, align 4, !tbaa !9
  %25 = sext i32 %24 to i64
  %26 = getelementptr inbounds [6 x i32], ptr %3, i64 0, i64 %25
  %27 = load i32, ptr %26, align 4, !tbaa !9
  store i32 %27, ptr %8, align 4, !tbaa !9
  %28 = load i32, ptr %7, align 4, !tbaa !9
  %29 = icmp eq i32 %28, -2147483648
  br i1 %29, label %30, label %34

30:                                               ; preds = %19
  %31 = load i32, ptr %8, align 4, !tbaa !9
  %32 = icmp eq i32 %31, -1
  br i1 %32, label %33, label %34

33:                                               ; preds = %30
  store i32 7, ptr %5, align 4
  br label %50

34:                                               ; preds = %30, %19
  %35 = load i32, ptr %7, align 4, !tbaa !9
  %36 = load i32, ptr %8, align 4, !tbaa !9
  %37 = load i32, ptr %7, align 4, !tbaa !9
  %38 = sext i32 %37 to i64
  %39 = load i32, ptr %8, align 4, !tbaa !9
  %40 = sext i32 %39 to i64
  %41 = mul nsw i64 %38, %40
  %42 = sdiv i64 %41, 3
  %43 = load i32, ptr %7, align 4, !tbaa !9
  %44 = load i32, ptr %8, align 4, !tbaa !9
  %45 = sdiv i32 %43, %44
  %46 = load i32, ptr %7, align 4, !tbaa !9
  %47 = load i32, ptr %8, align 4, !tbaa !9
  %48 = srem i32 %46, %47
  %49 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %35, i32 noundef %36, i64 noundef %42, i32 noundef %45, i32 noundef %48)
  store i32 0, ptr %5, align 4
  br label %50

50:                                               ; preds = %34, %33
  call void @llvm.lifetime.end.p0(ptr %8) #3
  call void @llvm.lifetime.end.p0(ptr %7) #3
  %51 = load i32, ptr %5, align 4
  switch i32 %51, label %69 [
    i32 0, label %52
    i32 7, label %53
  ]

52:                                               ; preds = %50
  br label %53

53:                                               ; preds = %52, %50
  %54 = load i32, ptr %6, align 4, !tbaa !9
  %55 = add nsw i32 %54, 1
  store i32 %55, ptr %6, align 4, !tbaa !9
  br label %15, !llvm.loop !10

56:                                               ; preds = %18
  br label %57

57:                                               ; preds = %56
  %58 = load i32, ptr %4, align 4, !tbaa !9
  %59 = add nsw i32 %58, 1
  store i32 %59, ptr %4, align 4, !tbaa !9
  br label %10, !llvm.loop !12

60:                                               ; preds = %13
  call void @llvm.lifetime.start.p0(ptr %9) #3
  store i32 -294967296, ptr %9, align 4, !tbaa !9
  %61 = load i32, ptr %9, align 4, !tbaa !9
  %62 = udiv i32 %61, 7
  %63 = load i32, ptr %9, align 4, !tbaa !9
  %64 = urem i32 %63, 7
  %65 = load i32, ptr %9, align 4, !tbaa !9
  %66 = mul i32 %65, 3
  %67 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %62, i32 noundef %64, i32 noundef %66)
  store i32 0, ptr %1, align 4
  store i32 1, ptr %5, align 4
  call void @llvm.lifetime.end.p0(ptr %9) #3
  call void @llvm.lifetime.end.p0(ptr %3) #3
  call void @llvm.lifetime.end.p0(ptr %2) #3
  %68 = load i32, ptr %1, align 4
  ret i32 %68

69:                                               ; preds = %50
  unreachable
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

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
!10 = distinct !{!10, !11}
!11 = !{!"llvm.loop.mustprogress"}
!12 = distinct !{!12, !11}
