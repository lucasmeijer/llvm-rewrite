; @source: tests/lto/src/split/crc32/crc.c
; @opt: -passes='lto-pre-link<O2>'
; @generated: clang -O2 -flto -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/lto/src/split/crc32/crc.c'
source_filename = "tests/lto/src/split/crc32/crc.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

; Function Attrs: nounwind uwtable
define dso_local i32 @crc32(ptr noundef %0, i64 noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca i64, align 8
  %5 = alloca i32, align 4
  %6 = alloca i64, align 8
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !9
  store i64 %1, ptr %4, align 8, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %5) #2
  store i32 -1, ptr %5, align 4, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %6) #2
  store i64 0, ptr %6, align 8, !tbaa !12
  br label %9

9:                                                ; preds = %38, %2
  %10 = load i64, ptr %6, align 8, !tbaa !12
  %11 = load i64, ptr %4, align 8, !tbaa !12
  %12 = icmp ult i64 %10, %11
  br i1 %12, label %14, label %13

13:                                               ; preds = %9
  store i32 2, ptr %7, align 4
  call void @llvm.lifetime.end.p0(ptr %6) #2
  br label %41

14:                                               ; preds = %9
  %15 = load ptr, ptr %3, align 8, !tbaa !9
  %16 = load i64, ptr %6, align 8, !tbaa !12
  %17 = getelementptr inbounds nuw i8, ptr %15, i64 %16
  %18 = load i8, ptr %17, align 1, !tbaa !15
  %19 = zext i8 %18 to i32
  %20 = load i32, ptr %5, align 4, !tbaa !14
  %21 = xor i32 %20, %19
  store i32 %21, ptr %5, align 4, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %8) #2
  store i32 0, ptr %8, align 4, !tbaa !14
  br label %22

22:                                               ; preds = %34, %14
  %23 = load i32, ptr %8, align 4, !tbaa !14
  %24 = icmp slt i32 %23, 8
  br i1 %24, label %26, label %25

25:                                               ; preds = %22
  store i32 5, ptr %7, align 4
  call void @llvm.lifetime.end.p0(ptr %8) #2
  br label %37

26:                                               ; preds = %22
  %27 = load i32, ptr %5, align 4, !tbaa !14
  %28 = lshr i32 %27, 1
  %29 = load i32, ptr %5, align 4, !tbaa !14
  %30 = and i32 %29, 1
  %31 = sub i32 0, %30
  %32 = and i32 -306674912, %31
  %33 = xor i32 %28, %32
  store i32 %33, ptr %5, align 4, !tbaa !14
  br label %34

34:                                               ; preds = %26
  %35 = load i32, ptr %8, align 4, !tbaa !14
  %36 = add nsw i32 %35, 1
  store i32 %36, ptr %8, align 4, !tbaa !14
  br label %22, !llvm.loop !16

37:                                               ; preds = %25
  br label %38

38:                                               ; preds = %37
  %39 = load i64, ptr %6, align 8, !tbaa !12
  %40 = add i64 %39, 1
  store i64 %40, ptr %6, align 8, !tbaa !12
  br label %9, !llvm.loop !18

41:                                               ; preds = %13
  %42 = load i32, ptr %5, align 4, !tbaa !14
  %43 = xor i32 %42, -1
  store i32 1, ptr %7, align 4
  call void @llvm.lifetime.end.p0(ptr %5) #2
  ret i32 %43
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

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
!10 = !{!"p1 omnipotent char", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!13, !13, i64 0}
!13 = !{!"long", !7, i64 0}
!14 = !{!6, !6, i64 0}
!15 = !{!7, !7, i64 0}
!16 = distinct !{!16, !17}
!17 = !{!"llvm.loop.mustprogress"}
!18 = distinct !{!18, !17}
