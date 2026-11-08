; @source: tests/function/src/memory/buffers.c
; @opt: -O2
; @llc: -O2
; @driver: tests/function/src/memory/buffers.driver.c
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/function/src/memory/buffers.c'
source_filename = "tests/function/src/memory/buffers.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.pair = type { i32, i64 }

; Function Attrs: nounwind uwtable
define dso_local void @reverse(ptr noundef %0, i64 noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca i64, align 8
  %5 = alloca i64, align 8
  %6 = alloca i64, align 8
  %7 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !9
  store i64 %1, ptr %4, align 8, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %5) #2
  store i64 0, ptr %5, align 8, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %6) #2
  %8 = load i64, ptr %4, align 8, !tbaa !12
  %9 = icmp ne i64 %8, 0
  br i1 %9, label %10, label %13

10:                                               ; preds = %2
  %11 = load i64, ptr %4, align 8, !tbaa !12
  %12 = sub i64 %11, 1
  br label %14

13:                                               ; preds = %2
  br label %14

14:                                               ; preds = %13, %10
  %15 = phi i64 [ %12, %10 ], [ 0, %13 ]
  store i64 %15, ptr %6, align 8, !tbaa !12
  br label %16

16:                                               ; preds = %37, %14
  %17 = load i64, ptr %5, align 8, !tbaa !12
  %18 = load i64, ptr %6, align 8, !tbaa !12
  %19 = icmp ult i64 %17, %18
  br i1 %19, label %21, label %20

20:                                               ; preds = %16
  call void @llvm.lifetime.end.p0(ptr %6) #2
  call void @llvm.lifetime.end.p0(ptr %5) #2
  br label %42

21:                                               ; preds = %16
  call void @llvm.lifetime.start.p0(ptr %7) #2
  %22 = load ptr, ptr %3, align 8, !tbaa !9
  %23 = load i64, ptr %5, align 8, !tbaa !12
  %24 = getelementptr inbounds nuw i32, ptr %22, i64 %23
  %25 = load i32, ptr %24, align 4, !tbaa !14
  store i32 %25, ptr %7, align 4, !tbaa !14
  %26 = load ptr, ptr %3, align 8, !tbaa !9
  %27 = load i64, ptr %6, align 8, !tbaa !12
  %28 = getelementptr inbounds nuw i32, ptr %26, i64 %27
  %29 = load i32, ptr %28, align 4, !tbaa !14
  %30 = load ptr, ptr %3, align 8, !tbaa !9
  %31 = load i64, ptr %5, align 8, !tbaa !12
  %32 = getelementptr inbounds nuw i32, ptr %30, i64 %31
  store i32 %29, ptr %32, align 4, !tbaa !14
  %33 = load i32, ptr %7, align 4, !tbaa !14
  %34 = load ptr, ptr %3, align 8, !tbaa !9
  %35 = load i64, ptr %6, align 8, !tbaa !12
  %36 = getelementptr inbounds nuw i32, ptr %34, i64 %35
  store i32 %33, ptr %36, align 4, !tbaa !14
  call void @llvm.lifetime.end.p0(ptr %7) #2
  br label %37

37:                                               ; preds = %21
  %38 = load i64, ptr %5, align 8, !tbaa !12
  %39 = add i64 %38, 1
  store i64 %39, ptr %5, align 8, !tbaa !12
  %40 = load i64, ptr %6, align 8, !tbaa !12
  %41 = add i64 %40, -1
  store i64 %41, ptr %6, align 8, !tbaa !12
  br label %16, !llvm.loop !15

42:                                               ; preds = %20
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local i64 @dot(ptr noundef %0, ptr noundef %1, i32 noundef %2) #0 {
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i64, align 8
  %8 = alloca i32, align 4
  store ptr %0, ptr %4, align 8, !tbaa !17
  store ptr %1, ptr %5, align 8, !tbaa !17
  store i32 %2, ptr %6, align 4, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %7) #2
  store i64 0, ptr %7, align 8, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %8) #2
  store i32 0, ptr %8, align 4, !tbaa !14
  br label %9

9:                                                ; preds = %31, %3
  %10 = load i32, ptr %8, align 4, !tbaa !14
  %11 = load i32, ptr %6, align 4, !tbaa !14
  %12 = icmp slt i32 %10, %11
  br i1 %12, label %14, label %13

13:                                               ; preds = %9
  call void @llvm.lifetime.end.p0(ptr %8) #2
  br label %34

14:                                               ; preds = %9
  %15 = load ptr, ptr %4, align 8, !tbaa !17
  %16 = load i32, ptr %8, align 4, !tbaa !14
  %17 = sext i32 %16 to i64
  %18 = getelementptr inbounds i16, ptr %15, i64 %17
  %19 = load i16, ptr %18, align 2, !tbaa !19
  %20 = sext i16 %19 to i32
  %21 = load ptr, ptr %5, align 8, !tbaa !17
  %22 = load i32, ptr %8, align 4, !tbaa !14
  %23 = sext i32 %22 to i64
  %24 = getelementptr inbounds i16, ptr %21, i64 %23
  %25 = load i16, ptr %24, align 2, !tbaa !19
  %26 = sext i16 %25 to i32
  %27 = mul nsw i32 %20, %26
  %28 = sext i32 %27 to i64
  %29 = load i64, ptr %7, align 8, !tbaa !12
  %30 = add nsw i64 %29, %28
  store i64 %30, ptr %7, align 8, !tbaa !12
  br label %31

31:                                               ; preds = %14
  %32 = load i32, ptr %8, align 4, !tbaa !14
  %33 = add nsw i32 %32, 1
  store i32 %33, ptr %8, align 4, !tbaa !14
  br label %9, !llvm.loop !21

34:                                               ; preds = %13
  %35 = load i64, ptr %7, align 8, !tbaa !12
  call void @llvm.lifetime.end.p0(ptr %7) #2
  ret i64 %35
}

; Function Attrs: nounwind uwtable
define dso_local void @prefix_sum(ptr noundef %0, i32 noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !22
  store i32 %1, ptr %4, align 4, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %5) #2
  store i32 1, ptr %5, align 4, !tbaa !14
  br label %6

6:                                                ; preds = %24, %2
  %7 = load i32, ptr %5, align 4, !tbaa !14
  %8 = load i32, ptr %4, align 4, !tbaa !14
  %9 = icmp slt i32 %7, %8
  br i1 %9, label %11, label %10

10:                                               ; preds = %6
  call void @llvm.lifetime.end.p0(ptr %5) #2
  br label %27

11:                                               ; preds = %6
  %12 = load ptr, ptr %3, align 8, !tbaa !22
  %13 = load i32, ptr %5, align 4, !tbaa !14
  %14 = sub nsw i32 %13, 1
  %15 = sext i32 %14 to i64
  %16 = getelementptr inbounds double, ptr %12, i64 %15
  %17 = load double, ptr %16, align 8, !tbaa !24
  %18 = load ptr, ptr %3, align 8, !tbaa !22
  %19 = load i32, ptr %5, align 4, !tbaa !14
  %20 = sext i32 %19 to i64
  %21 = getelementptr inbounds double, ptr %18, i64 %20
  %22 = load double, ptr %21, align 8, !tbaa !24
  %23 = fadd double %22, %17
  store double %23, ptr %21, align 8, !tbaa !24
  br label %24

24:                                               ; preds = %11
  %25 = load i32, ptr %5, align 4, !tbaa !14
  %26 = add nsw i32 %25, 1
  store i32 %26, ptr %5, align 4, !tbaa !14
  br label %6, !llvm.loop !26

27:                                               ; preds = %10
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local i64 @count_byte(ptr noundef %0, i64 noundef %1, i8 noundef zeroext %2) #0 {
  %4 = alloca ptr, align 8
  %5 = alloca i64, align 8
  %6 = alloca i8, align 1
  %7 = alloca i64, align 8
  store ptr %0, ptr %4, align 8, !tbaa !27
  store i64 %1, ptr %5, align 8, !tbaa !12
  store i8 %2, ptr %6, align 1, !tbaa !29
  call void @llvm.lifetime.start.p0(ptr %7) #2
  store i64 0, ptr %7, align 8, !tbaa !12
  br label %8

8:                                                ; preds = %12, %3
  %9 = load i64, ptr %5, align 8, !tbaa !12
  %10 = add i64 %9, -1
  store i64 %10, ptr %5, align 8, !tbaa !12
  %11 = icmp ne i64 %9, 0
  br i1 %11, label %12, label %24

12:                                               ; preds = %8
  %13 = load ptr, ptr %4, align 8, !tbaa !27
  %14 = getelementptr inbounds nuw i8, ptr %13, i32 1
  store ptr %14, ptr %4, align 8, !tbaa !27
  %15 = load i8, ptr %13, align 1, !tbaa !29
  %16 = zext i8 %15 to i32
  %17 = load i8, ptr %6, align 1, !tbaa !29
  %18 = zext i8 %17 to i32
  %19 = icmp eq i32 %16, %18
  %20 = zext i1 %19 to i32
  %21 = sext i32 %20 to i64
  %22 = load i64, ptr %7, align 8, !tbaa !12
  %23 = add i64 %22, %21
  store i64 %23, ptr %7, align 8, !tbaa !12
  br label %8, !llvm.loop !30

24:                                               ; preds = %8
  %25 = load i64, ptr %7, align 8, !tbaa !12
  call void @llvm.lifetime.end.p0(ptr %7) #2
  ret i64 %25
}

; Function Attrs: nounwind uwtable
define dso_local void @transpose4(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca float, align 4
  store ptr %0, ptr %2, align 8, !tbaa !31
  call void @llvm.lifetime.start.p0(ptr %3) #2
  store i32 0, ptr %3, align 4, !tbaa !14
  br label %7

7:                                                ; preds = %54, %1
  %8 = load i32, ptr %3, align 4, !tbaa !14
  %9 = icmp slt i32 %8, 4
  br i1 %9, label %11, label %10

10:                                               ; preds = %7
  store i32 2, ptr %4, align 4
  call void @llvm.lifetime.end.p0(ptr %3) #2
  br label %57

11:                                               ; preds = %7
  call void @llvm.lifetime.start.p0(ptr %5) #2
  %12 = load i32, ptr %3, align 4, !tbaa !14
  %13 = add nsw i32 %12, 1
  store i32 %13, ptr %5, align 4, !tbaa !14
  br label %14

14:                                               ; preds = %50, %11
  %15 = load i32, ptr %5, align 4, !tbaa !14
  %16 = icmp slt i32 %15, 4
  br i1 %16, label %18, label %17

17:                                               ; preds = %14
  store i32 5, ptr %4, align 4
  call void @llvm.lifetime.end.p0(ptr %5) #2
  br label %53

18:                                               ; preds = %14
  call void @llvm.lifetime.start.p0(ptr %6) #2
  %19 = load ptr, ptr %2, align 8, !tbaa !31
  %20 = load i32, ptr %3, align 4, !tbaa !14
  %21 = sext i32 %20 to i64
  %22 = getelementptr inbounds [4 x float], ptr %19, i64 %21
  %23 = load i32, ptr %5, align 4, !tbaa !14
  %24 = sext i32 %23 to i64
  %25 = getelementptr inbounds [4 x float], ptr %22, i64 0, i64 %24
  %26 = load float, ptr %25, align 4, !tbaa !33
  store float %26, ptr %6, align 4, !tbaa !33
  %27 = load ptr, ptr %2, align 8, !tbaa !31
  %28 = load i32, ptr %5, align 4, !tbaa !14
  %29 = sext i32 %28 to i64
  %30 = getelementptr inbounds [4 x float], ptr %27, i64 %29
  %31 = load i32, ptr %3, align 4, !tbaa !14
  %32 = sext i32 %31 to i64
  %33 = getelementptr inbounds [4 x float], ptr %30, i64 0, i64 %32
  %34 = load float, ptr %33, align 4, !tbaa !33
  %35 = load ptr, ptr %2, align 8, !tbaa !31
  %36 = load i32, ptr %3, align 4, !tbaa !14
  %37 = sext i32 %36 to i64
  %38 = getelementptr inbounds [4 x float], ptr %35, i64 %37
  %39 = load i32, ptr %5, align 4, !tbaa !14
  %40 = sext i32 %39 to i64
  %41 = getelementptr inbounds [4 x float], ptr %38, i64 0, i64 %40
  store float %34, ptr %41, align 4, !tbaa !33
  %42 = load float, ptr %6, align 4, !tbaa !33
  %43 = load ptr, ptr %2, align 8, !tbaa !31
  %44 = load i32, ptr %5, align 4, !tbaa !14
  %45 = sext i32 %44 to i64
  %46 = getelementptr inbounds [4 x float], ptr %43, i64 %45
  %47 = load i32, ptr %3, align 4, !tbaa !14
  %48 = sext i32 %47 to i64
  %49 = getelementptr inbounds [4 x float], ptr %46, i64 0, i64 %48
  store float %42, ptr %49, align 4, !tbaa !33
  call void @llvm.lifetime.end.p0(ptr %6) #2
  br label %50

50:                                               ; preds = %18
  %51 = load i32, ptr %5, align 4, !tbaa !14
  %52 = add nsw i32 %51, 1
  store i32 %52, ptr %5, align 4, !tbaa !14
  br label %14, !llvm.loop !35

53:                                               ; preds = %17
  br label %54

54:                                               ; preds = %53
  %55 = load i32, ptr %3, align 4, !tbaa !14
  %56 = add nsw i32 %55, 1
  store i32 %56, ptr %3, align 4, !tbaa !14
  br label %7, !llvm.loop !36

57:                                               ; preds = %10
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local i64 @find(ptr noundef %0, i32 noundef %1, i32 noundef %2) #0 {
  %4 = alloca i64, align 8
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  store ptr %0, ptr %5, align 8, !tbaa !37
  store i32 %1, ptr %6, align 4, !tbaa !14
  store i32 %2, ptr %7, align 4, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %8) #2
  store i32 0, ptr %8, align 4, !tbaa !14
  br label %10

10:                                               ; preds = %32, %3
  %11 = load i32, ptr %8, align 4, !tbaa !14
  %12 = load i32, ptr %6, align 4, !tbaa !14
  %13 = icmp slt i32 %11, %12
  br i1 %13, label %15, label %14

14:                                               ; preds = %10
  store i32 2, ptr %9, align 4
  br label %35

15:                                               ; preds = %10
  %16 = load ptr, ptr %5, align 8, !tbaa !37
  %17 = load i32, ptr %8, align 4, !tbaa !14
  %18 = sext i32 %17 to i64
  %19 = getelementptr inbounds %struct.pair, ptr %16, i64 %18
  %20 = getelementptr inbounds nuw %struct.pair, ptr %19, i32 0, i32 0
  %21 = load i32, ptr %20, align 8, !tbaa !39
  %22 = load i32, ptr %7, align 4, !tbaa !14
  %23 = icmp eq i32 %21, %22
  br i1 %23, label %24, label %31

24:                                               ; preds = %15
  %25 = load ptr, ptr %5, align 8, !tbaa !37
  %26 = load i32, ptr %8, align 4, !tbaa !14
  %27 = sext i32 %26 to i64
  %28 = getelementptr inbounds %struct.pair, ptr %25, i64 %27
  %29 = getelementptr inbounds nuw %struct.pair, ptr %28, i32 0, i32 1
  %30 = load i64, ptr %29, align 8, !tbaa !41
  store i64 %30, ptr %4, align 8
  store i32 1, ptr %9, align 4
  br label %35

31:                                               ; preds = %15
  br label %32

32:                                               ; preds = %31
  %33 = load i32, ptr %8, align 4, !tbaa !14
  %34 = add nsw i32 %33, 1
  store i32 %34, ptr %8, align 4, !tbaa !14
  br label %10, !llvm.loop !42

35:                                               ; preds = %24, %14
  call void @llvm.lifetime.end.p0(ptr %8) #2
  %36 = load i32, ptr %9, align 4
  switch i32 %36, label %40 [
    i32 2, label %37
    i32 1, label %38
  ]

37:                                               ; preds = %35
  store i64 -1, ptr %4, align 8
  br label %38

38:                                               ; preds = %37, %35
  %39 = load i64, ptr %4, align 8
  ret i64 %39

40:                                               ; preds = %35
  unreachable
}

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind }

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
!10 = !{!"p1 int", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!13, !13, i64 0}
!13 = !{!"long", !7, i64 0}
!14 = !{!6, !6, i64 0}
!15 = distinct !{!15, !16}
!16 = !{!"llvm.loop.mustprogress"}
!17 = !{!18, !18, i64 0}
!18 = !{!"p1 short", !11, i64 0}
!19 = !{!20, !20, i64 0}
!20 = !{!"short", !7, i64 0}
!21 = distinct !{!21, !16}
!22 = !{!23, !23, i64 0}
!23 = !{!"p1 double", !11, i64 0}
!24 = !{!25, !25, i64 0}
!25 = !{!"double", !7, i64 0}
!26 = distinct !{!26, !16}
!27 = !{!28, !28, i64 0}
!28 = !{!"p1 omnipotent char", !11, i64 0}
!29 = !{!7, !7, i64 0}
!30 = distinct !{!30, !16}
!31 = !{!32, !32, i64 0}
!32 = !{!"p1 float", !11, i64 0}
!33 = !{!34, !34, i64 0}
!34 = !{!"float", !7, i64 0}
!35 = distinct !{!35, !16}
!36 = distinct !{!36, !16}
!37 = !{!38, !38, i64 0}
!38 = !{!"p1 _ZTS4pair", !11, i64 0}
!39 = !{!40, !6, i64 0}
!40 = !{!"pair", !6, i64 0, !13, i64 8}
!41 = !{!40, !13, i64 8}
!42 = distinct !{!42, !16}
