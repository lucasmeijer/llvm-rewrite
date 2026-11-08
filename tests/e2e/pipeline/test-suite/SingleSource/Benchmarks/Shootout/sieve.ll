; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/sieve.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/sieve.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/sieve.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@main.flags = internal global [8193 x i8] zeroinitializer, align 16
@.str = private unnamed_addr constant [11 x i8] c"Count: %d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i64, align 8
  %8 = alloca i64, align 8
  %9 = alloca i32, align 4
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %6) #5
  %10 = load i32, ptr %4, align 4, !tbaa !9
  %11 = icmp eq i32 %10, 2
  br i1 %11, label %12, label %17

12:                                               ; preds = %2
  %13 = load ptr, ptr %5, align 8, !tbaa !10
  %14 = getelementptr inbounds ptr, ptr %13, i64 1
  %15 = load ptr, ptr %14, align 8, !tbaa !14
  %16 = call i32 @atoi(ptr noundef %15) #6
  br label %18

17:                                               ; preds = %2
  br label %18

18:                                               ; preds = %17, %12
  %19 = phi i32 [ %16, %12 ], [ 170000, %17 ]
  store i32 %19, ptr %6, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %7) #5
  call void @llvm.lifetime.start.p0(ptr %8) #5
  call void @llvm.lifetime.start.p0(ptr %9) #5
  store i32 0, ptr %9, align 4, !tbaa !9
  br label %20

20:                                               ; preds = %64, %18
  %21 = load i32, ptr %6, align 4, !tbaa !9
  %22 = add nsw i32 %21, -1
  store i32 %22, ptr %6, align 4, !tbaa !9
  %23 = icmp ne i32 %21, 0
  br i1 %23, label %24, label %65

24:                                               ; preds = %20
  store i32 0, ptr %9, align 4, !tbaa !9
  store i64 2, ptr %7, align 8, !tbaa !16
  br label %25

25:                                               ; preds = %31, %24
  %26 = load i64, ptr %7, align 8, !tbaa !16
  %27 = icmp sle i64 %26, 8192
  br i1 %27, label %28, label %34

28:                                               ; preds = %25
  %29 = load i64, ptr %7, align 8, !tbaa !16
  %30 = getelementptr inbounds [8193 x i8], ptr @main.flags, i64 0, i64 %29
  store i8 1, ptr %30, align 1, !tbaa !18
  br label %31

31:                                               ; preds = %28
  %32 = load i64, ptr %7, align 8, !tbaa !16
  %33 = add nsw i64 %32, 1
  store i64 %33, ptr %7, align 8, !tbaa !16
  br label %25, !llvm.loop !19

34:                                               ; preds = %25
  store i64 2, ptr %7, align 8, !tbaa !16
  br label %35

35:                                               ; preds = %61, %34
  %36 = load i64, ptr %7, align 8, !tbaa !16
  %37 = icmp sle i64 %36, 8192
  br i1 %37, label %38, label %64

38:                                               ; preds = %35
  %39 = load i64, ptr %7, align 8, !tbaa !16
  %40 = getelementptr inbounds [8193 x i8], ptr @main.flags, i64 0, i64 %39
  %41 = load i8, ptr %40, align 1, !tbaa !18
  %42 = icmp ne i8 %41, 0
  br i1 %42, label %43, label %60

43:                                               ; preds = %38
  %44 = load i64, ptr %7, align 8, !tbaa !16
  %45 = load i64, ptr %7, align 8, !tbaa !16
  %46 = add nsw i64 %44, %45
  store i64 %46, ptr %8, align 8, !tbaa !16
  br label %47

47:                                               ; preds = %53, %43
  %48 = load i64, ptr %8, align 8, !tbaa !16
  %49 = icmp sle i64 %48, 8192
  br i1 %49, label %50, label %57

50:                                               ; preds = %47
  %51 = load i64, ptr %8, align 8, !tbaa !16
  %52 = getelementptr inbounds [8193 x i8], ptr @main.flags, i64 0, i64 %51
  store i8 0, ptr %52, align 1, !tbaa !18
  br label %53

53:                                               ; preds = %50
  %54 = load i64, ptr %7, align 8, !tbaa !16
  %55 = load i64, ptr %8, align 8, !tbaa !16
  %56 = add nsw i64 %55, %54
  store i64 %56, ptr %8, align 8, !tbaa !16
  br label %47, !llvm.loop !21

57:                                               ; preds = %47
  %58 = load i32, ptr %9, align 4, !tbaa !9
  %59 = add nsw i32 %58, 1
  store i32 %59, ptr %9, align 4, !tbaa !9
  br label %60

60:                                               ; preds = %57, %38
  br label %61

61:                                               ; preds = %60
  %62 = load i64, ptr %7, align 8, !tbaa !16
  %63 = add nsw i64 %62, 1
  store i64 %63, ptr %7, align 8, !tbaa !16
  br label %35, !llvm.loop !22

64:                                               ; preds = %35
  br label %20, !llvm.loop !23

65:                                               ; preds = %20
  %66 = load i32, ptr %9, align 4, !tbaa !9
  %67 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %66)
  call void @llvm.lifetime.end.p0(ptr %9) #5
  call void @llvm.lifetime.end.p0(ptr %8) #5
  call void @llvm.lifetime.end.p0(ptr %7) #5
  call void @llvm.lifetime.end.p0(ptr %6) #5
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: inlinehint nounwind willreturn memory(read) uwtable
define available_externally i32 @atoi(ptr noundef nonnull %0) #2 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !14
  %3 = load ptr, ptr %2, align 8, !tbaa !14
  %4 = call i64 @strtol(ptr noundef %3, ptr noundef null, i32 noundef 10) #5
  %5 = trunc i64 %4 to i32
  ret i32 %5
}

declare i32 @printf(ptr noundef, ...) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind
declare i64 @strtol(ptr noundef, ptr noundef, i32 noundef) #4

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { inlinehint nounwind willreturn memory(read) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind }
attributes #6 = { nounwind willreturn memory(read) }

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
!15 = !{!"p1 omnipotent char", !13, i64 0}
!16 = !{!17, !17, i64 0}
!17 = !{!"long", !7, i64 0}
!18 = !{!7, !7, i64 0}
!19 = distinct !{!19, !20}
!20 = !{!"llvm.loop.mustprogress"}
!21 = distinct !{!21, !20}
!22 = distinct !{!22, !20}
!23 = distinct !{!23, !20}
