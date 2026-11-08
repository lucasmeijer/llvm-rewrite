; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2002-12-13-MishaTest.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2002-12-13-MishaTest.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2002-12-13-MishaTest.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [11 x i8] c"Sum is %d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @sum(ptr noundef %0, ptr noundef %1, i32 noundef %2) #0 {
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca i16, align 2
  %8 = alloca i32, align 4
  %9 = trunc i32 %2 to i16
  store ptr %0, ptr %5, align 8, !tbaa !9
  store ptr %1, ptr %6, align 8, !tbaa !9
  store i16 %9, ptr %7, align 2, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %8) #3
  store i32 0, ptr %8, align 4, !tbaa !14
  br label %10

10:                                               ; preds = %25, %3
  %11 = load i32, ptr %8, align 4, !tbaa !14
  %12 = load i16, ptr %7, align 2, !tbaa !12
  %13 = sext i16 %12 to i32
  %14 = icmp ne i32 %11, %13
  br i1 %14, label %15, label %28

15:                                               ; preds = %10
  %16 = load ptr, ptr %6, align 8, !tbaa !9
  %17 = getelementptr inbounds nuw i16, ptr %16, i32 1
  store ptr %17, ptr %6, align 8, !tbaa !9
  %18 = load i16, ptr %16, align 2, !tbaa !12
  %19 = sext i16 %18 to i32
  %20 = load ptr, ptr %5, align 8, !tbaa !9
  %21 = load i16, ptr %20, align 2, !tbaa !12
  %22 = sext i16 %21 to i32
  %23 = add nsw i32 %22, %19
  %24 = trunc i32 %23 to i16
  store i16 %24, ptr %20, align 2, !tbaa !12
  br label %25

25:                                               ; preds = %15
  %26 = load i32, ptr %8, align 4, !tbaa !14
  %27 = add nsw i32 %26, 1
  store i32 %27, ptr %8, align 4, !tbaa !14
  br label %10, !llvm.loop !15

28:                                               ; preds = %10
  call void @llvm.lifetime.end.p0(ptr %8) #3
  %29 = load i32, ptr %4, align 4
  ret i32 %29
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [2 x i16], align 2
  %3 = alloca i16, align 2
  %4 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  call void @llvm.lifetime.start.p0(ptr %3) #3
  store i16 0, ptr %3, align 2, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %4) #3
  store i32 0, ptr %4, align 4, !tbaa !14
  br label %5

5:                                                ; preds = %14, %0
  %6 = load i32, ptr %4, align 4, !tbaa !14
  %7 = icmp ne i32 %6, 2
  br i1 %7, label %8, label %17

8:                                                ; preds = %5
  %9 = load i32, ptr %4, align 4, !tbaa !14
  %10 = trunc i32 %9 to i16
  %11 = load i32, ptr %4, align 4, !tbaa !14
  %12 = sext i32 %11 to i64
  %13 = getelementptr inbounds [2 x i16], ptr %2, i64 0, i64 %12
  store i16 %10, ptr %13, align 2, !tbaa !12
  br label %14

14:                                               ; preds = %8
  %15 = load i32, ptr %4, align 4, !tbaa !14
  %16 = add nsw i32 %15, 1
  store i32 %16, ptr %4, align 4, !tbaa !14
  br label %5, !llvm.loop !17

17:                                               ; preds = %5
  %18 = getelementptr inbounds [2 x i16], ptr %2, i64 0, i64 0
  %19 = call i32 @sum(ptr noundef %3, ptr noundef %18, i32 noundef 2)
  %20 = load i16, ptr %3, align 2, !tbaa !12
  %21 = sext i16 %20 to i32
  %22 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %21)
  call void @llvm.lifetime.end.p0(ptr %4) #3
  call void @llvm.lifetime.end.p0(ptr %3) #3
  call void @llvm.lifetime.end.p0(ptr %2) #3
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #2

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
!9 = !{!10, !10, i64 0}
!10 = !{!"p1 short", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!13, !13, i64 0}
!13 = !{!"short", !7, i64 0}
!14 = !{!6, !6, i64 0}
!15 = distinct !{!15, !16}
!16 = !{!"llvm.loop.mustprogress"}
!17 = distinct !{!17, !16}
