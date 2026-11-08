; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/vla.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/vla.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/vla.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@bork = dso_local global [4 x [3 x i32]] [[3 x i32] [i32 1, i32 2, i32 3], [3 x i32] [i32 4, i32 5, i32 6], [3 x i32] [i32 7, i32 8, i32 9], [3 x i32] [i32 10, i32 11, i32 12]], align 16
@bork2 = dso_local global [2 x [3 x [4 x i32]]] [[3 x [4 x i32]] [[4 x i32] [i32 1, i32 2, i32 3, i32 4], [4 x i32] [i32 5, i32 6, i32 7, i32 8], [4 x i32] [i32 9, i32 10, i32 11, i32 12]], [3 x [4 x i32]] [[4 x i32] [i32 13, i32 14, i32 15, i32 16], [4 x i32] [i32 17, i32 18, i32 19, i32 20], [4 x i32] [i32 21, i32 22, i32 23, i32 24]]], align 16

; Function Attrs: nounwind uwtable
define dso_local void @function(i16 noundef signext %0, ptr noundef %1) #0 {
  %3 = alloca i16, align 2
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  store i16 %0, ptr %3, align 2, !tbaa !9
  store ptr %1, ptr %4, align 8, !tbaa !11
  %7 = load i16, ptr %3, align 2, !tbaa !9
  %8 = zext i16 %7 to i64
  call void @llvm.lifetime.start.p0(ptr %5) #3
  call void @llvm.lifetime.start.p0(ptr %6) #3
  store i32 0, ptr %5, align 4, !tbaa !14
  br label %9

9:                                                ; preds = %42, %2
  %10 = load i32, ptr %5, align 4, !tbaa !14
  %11 = icmp slt i32 %10, 4
  br i1 %11, label %12, label %45

12:                                               ; preds = %9
  store i32 0, ptr %6, align 4, !tbaa !14
  br label %13

13:                                               ; preds = %38, %12
  %14 = load i32, ptr %6, align 4, !tbaa !14
  %15 = load i16, ptr %3, align 2, !tbaa !9
  %16 = sext i16 %15 to i32
  %17 = icmp slt i32 %14, %16
  br i1 %17, label %18, label %41

18:                                               ; preds = %13
  %19 = load i32, ptr %5, align 4, !tbaa !14
  %20 = sext i32 %19 to i64
  %21 = getelementptr inbounds [4 x [3 x i32]], ptr @bork, i64 0, i64 %20
  %22 = load i32, ptr %6, align 4, !tbaa !14
  %23 = sext i32 %22 to i64
  %24 = getelementptr inbounds [3 x i32], ptr %21, i64 0, i64 %23
  %25 = load i32, ptr %24, align 4, !tbaa !14
  %26 = load ptr, ptr %4, align 8, !tbaa !11
  %27 = load i32, ptr %5, align 4, !tbaa !14
  %28 = sext i32 %27 to i64
  %29 = mul nsw i64 %28, %8
  %30 = getelementptr inbounds i32, ptr %26, i64 %29
  %31 = load i32, ptr %6, align 4, !tbaa !14
  %32 = sext i32 %31 to i64
  %33 = getelementptr inbounds i32, ptr %30, i64 %32
  %34 = load i32, ptr %33, align 4, !tbaa !14
  %35 = icmp ne i32 %25, %34
  br i1 %35, label %36, label %37

36:                                               ; preds = %18
  call void @abort() #4
  unreachable

37:                                               ; preds = %18
  br label %38

38:                                               ; preds = %37
  %39 = load i32, ptr %6, align 4, !tbaa !14
  %40 = add nsw i32 %39, 1
  store i32 %40, ptr %6, align 4, !tbaa !14
  br label %13, !llvm.loop !15

41:                                               ; preds = %13
  br label %42

42:                                               ; preds = %41
  %43 = load i32, ptr %5, align 4, !tbaa !14
  %44 = add nsw i32 %43, 1
  store i32 %44, ptr %5, align 4, !tbaa !14
  br label %9, !llvm.loop !17

45:                                               ; preds = %9
  call void @llvm.lifetime.end.p0(ptr %6) #3
  call void @llvm.lifetime.end.p0(ptr %5) #3
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: noreturn nounwind
declare void @abort() #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local void @test() #0 {
  call void @function(i16 noundef signext 3, ptr noundef @bork)
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local void @function2(i16 noundef signext %0, i16 noundef signext %1, ptr noundef %2) #0 {
  %4 = alloca i16, align 2
  %5 = alloca i16, align 2
  %6 = alloca ptr, align 8
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  store i16 %0, ptr %4, align 2, !tbaa !9
  store i16 %1, ptr %5, align 2, !tbaa !9
  store ptr %2, ptr %6, align 8, !tbaa !11
  %10 = load i16, ptr %4, align 2, !tbaa !9
  %11 = zext i16 %10 to i64
  %12 = load i16, ptr %5, align 2, !tbaa !9
  %13 = zext i16 %12 to i64
  call void @llvm.lifetime.start.p0(ptr %7) #3
  call void @llvm.lifetime.start.p0(ptr %8) #3
  call void @llvm.lifetime.start.p0(ptr %9) #3
  store i32 0, ptr %7, align 4, !tbaa !14
  br label %14

14:                                               ; preds = %65, %3
  %15 = load i32, ptr %7, align 4, !tbaa !14
  %16 = icmp slt i32 %15, 2
  br i1 %16, label %17, label %68

17:                                               ; preds = %14
  store i32 0, ptr %8, align 4, !tbaa !14
  br label %18

18:                                               ; preds = %61, %17
  %19 = load i32, ptr %8, align 4, !tbaa !14
  %20 = load i16, ptr %4, align 2, !tbaa !9
  %21 = sext i16 %20 to i32
  %22 = icmp slt i32 %19, %21
  br i1 %22, label %23, label %64

23:                                               ; preds = %18
  store i32 0, ptr %9, align 4, !tbaa !14
  br label %24

24:                                               ; preds = %57, %23
  %25 = load i32, ptr %9, align 4, !tbaa !14
  %26 = load i16, ptr %5, align 2, !tbaa !9
  %27 = sext i16 %26 to i32
  %28 = icmp slt i32 %25, %27
  br i1 %28, label %29, label %60

29:                                               ; preds = %24
  %30 = load i32, ptr %7, align 4, !tbaa !14
  %31 = sext i32 %30 to i64
  %32 = getelementptr inbounds [2 x [3 x [4 x i32]]], ptr @bork2, i64 0, i64 %31
  %33 = load i32, ptr %8, align 4, !tbaa !14
  %34 = sext i32 %33 to i64
  %35 = getelementptr inbounds [3 x [4 x i32]], ptr %32, i64 0, i64 %34
  %36 = load i32, ptr %9, align 4, !tbaa !14
  %37 = sext i32 %36 to i64
  %38 = getelementptr inbounds [4 x i32], ptr %35, i64 0, i64 %37
  %39 = load i32, ptr %38, align 4, !tbaa !14
  %40 = load ptr, ptr %6, align 8, !tbaa !11
  %41 = load i32, ptr %7, align 4, !tbaa !14
  %42 = sext i32 %41 to i64
  %43 = mul nuw i64 %11, %13
  %44 = mul nsw i64 %42, %43
  %45 = getelementptr inbounds i32, ptr %40, i64 %44
  %46 = load i32, ptr %8, align 4, !tbaa !14
  %47 = sext i32 %46 to i64
  %48 = mul nsw i64 %47, %13
  %49 = getelementptr inbounds i32, ptr %45, i64 %48
  %50 = load i32, ptr %9, align 4, !tbaa !14
  %51 = sext i32 %50 to i64
  %52 = getelementptr inbounds i32, ptr %49, i64 %51
  %53 = load i32, ptr %52, align 4, !tbaa !14
  %54 = icmp ne i32 %39, %53
  br i1 %54, label %55, label %56

55:                                               ; preds = %29
  call void @abort() #4
  unreachable

56:                                               ; preds = %29
  br label %57

57:                                               ; preds = %56
  %58 = load i32, ptr %9, align 4, !tbaa !14
  %59 = add nsw i32 %58, 1
  store i32 %59, ptr %9, align 4, !tbaa !14
  br label %24, !llvm.loop !18

60:                                               ; preds = %24
  br label %61

61:                                               ; preds = %60
  %62 = load i32, ptr %8, align 4, !tbaa !14
  %63 = add nsw i32 %62, 1
  store i32 %63, ptr %8, align 4, !tbaa !14
  br label %18, !llvm.loop !19

64:                                               ; preds = %18
  br label %65

65:                                               ; preds = %64
  %66 = load i32, ptr %7, align 4, !tbaa !14
  %67 = add nsw i32 %66, 1
  store i32 %67, ptr %7, align 4, !tbaa !14
  br label %14, !llvm.loop !20

68:                                               ; preds = %14
  call void @llvm.lifetime.end.p0(ptr %9) #3
  call void @llvm.lifetime.end.p0(ptr %8) #3
  call void @llvm.lifetime.end.p0(ptr %7) #3
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local void @test2() #0 {
  call void @function2(i16 noundef signext 3, i16 noundef signext 4, ptr noundef @bork2)
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @test()
  call void @test2()
  ret i32 0
}

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { noreturn nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind }
attributes #4 = { noreturn nounwind }

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
!9 = !{!10, !10, i64 0}
!10 = !{!"short", !7, i64 0}
!11 = !{!12, !12, i64 0}
!12 = !{!"p1 int", !13, i64 0}
!13 = !{!"any pointer", !7, i64 0}
!14 = !{!6, !6, i64 0}
!15 = distinct !{!15, !16}
!16 = !{!"llvm.loop.mustprogress"}
!17 = distinct !{!17, !16}
!18 = distinct !{!18, !16}
!19 = distinct !{!19, !16}
!20 = distinct !{!20, !16}
