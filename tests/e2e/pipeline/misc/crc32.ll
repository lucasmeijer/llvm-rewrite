; @source: tests/e2e/src/misc/crc32.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/misc/crc32.c'
source_filename = "tests/e2e/src/misc/crc32.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [44 x i8] c"The quick brown fox jumps over the lazy dog\00", align 1
@.str.1 = private unnamed_addr constant [6 x i8] c"%08x\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca ptr, align 8
  %3 = alloca [256 x i8], align 16
  %4 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #4
  store ptr @.str, ptr %2, align 8, !tbaa !9
  %5 = load ptr, ptr %2, align 8, !tbaa !9
  %6 = load ptr, ptr %2, align 8, !tbaa !9
  %7 = call i64 @strlen(ptr noundef %6) #5
  %8 = call i32 @crc32(ptr noundef %5, i64 noundef %7)
  %9 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %8)
  call void @llvm.lifetime.start.p0(ptr %3) #4
  call void @llvm.lifetime.start.p0(ptr %4) #4
  store i32 0, ptr %4, align 4, !tbaa !12
  br label %10

10:                                               ; preds = %22, %0
  %11 = load i32, ptr %4, align 4, !tbaa !12
  %12 = icmp slt i32 %11, 256
  br i1 %12, label %14, label %13

13:                                               ; preds = %10
  call void @llvm.lifetime.end.p0(ptr %4) #4
  br label %25

14:                                               ; preds = %10
  %15 = load i32, ptr %4, align 4, !tbaa !12
  %16 = mul nsw i32 %15, 37
  %17 = add nsw i32 %16, 11
  %18 = trunc i32 %17 to i8
  %19 = load i32, ptr %4, align 4, !tbaa !12
  %20 = sext i32 %19 to i64
  %21 = getelementptr inbounds [256 x i8], ptr %3, i64 0, i64 %20
  store i8 %18, ptr %21, align 1, !tbaa !13
  br label %22

22:                                               ; preds = %14
  %23 = load i32, ptr %4, align 4, !tbaa !12
  %24 = add nsw i32 %23, 1
  store i32 %24, ptr %4, align 4, !tbaa !12
  br label %10, !llvm.loop !14

25:                                               ; preds = %13
  %26 = getelementptr inbounds [256 x i8], ptr %3, i64 0, i64 0
  %27 = call i32 @crc32(ptr noundef %26, i64 noundef 256)
  %28 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %27)
  call void @llvm.lifetime.end.p0(ptr %3) #4
  call void @llvm.lifetime.end.p0(ptr %2) #4
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nounwind uwtable
define internal i32 @crc32(ptr noundef %0, i64 noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca i64, align 8
  %5 = alloca i32, align 4
  %6 = alloca i64, align 8
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !9
  store i64 %1, ptr %4, align 8, !tbaa !16
  call void @llvm.lifetime.start.p0(ptr %5) #4
  store i32 -1, ptr %5, align 4, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %6) #4
  store i64 0, ptr %6, align 8, !tbaa !16
  br label %9

9:                                                ; preds = %38, %2
  %10 = load i64, ptr %6, align 8, !tbaa !16
  %11 = load i64, ptr %4, align 8, !tbaa !16
  %12 = icmp ult i64 %10, %11
  br i1 %12, label %14, label %13

13:                                               ; preds = %9
  store i32 2, ptr %7, align 4
  call void @llvm.lifetime.end.p0(ptr %6) #4
  br label %41

14:                                               ; preds = %9
  %15 = load ptr, ptr %3, align 8, !tbaa !9
  %16 = load i64, ptr %6, align 8, !tbaa !16
  %17 = getelementptr inbounds nuw i8, ptr %15, i64 %16
  %18 = load i8, ptr %17, align 1, !tbaa !13
  %19 = zext i8 %18 to i32
  %20 = load i32, ptr %5, align 4, !tbaa !12
  %21 = xor i32 %20, %19
  store i32 %21, ptr %5, align 4, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %8) #4
  store i32 0, ptr %8, align 4, !tbaa !12
  br label %22

22:                                               ; preds = %34, %14
  %23 = load i32, ptr %8, align 4, !tbaa !12
  %24 = icmp slt i32 %23, 8
  br i1 %24, label %26, label %25

25:                                               ; preds = %22
  store i32 5, ptr %7, align 4
  call void @llvm.lifetime.end.p0(ptr %8) #4
  br label %37

26:                                               ; preds = %22
  %27 = load i32, ptr %5, align 4, !tbaa !12
  %28 = lshr i32 %27, 1
  %29 = load i32, ptr %5, align 4, !tbaa !12
  %30 = and i32 %29, 1
  %31 = sub i32 0, %30
  %32 = and i32 -306674912, %31
  %33 = xor i32 %28, %32
  store i32 %33, ptr %5, align 4, !tbaa !12
  br label %34

34:                                               ; preds = %26
  %35 = load i32, ptr %8, align 4, !tbaa !12
  %36 = add nsw i32 %35, 1
  store i32 %36, ptr %8, align 4, !tbaa !12
  br label %22, !llvm.loop !18

37:                                               ; preds = %25
  br label %38

38:                                               ; preds = %37
  %39 = load i64, ptr %6, align 8, !tbaa !16
  %40 = add i64 %39, 1
  store i64 %40, ptr %6, align 8, !tbaa !16
  br label %9, !llvm.loop !19

41:                                               ; preds = %13
  %42 = load i32, ptr %5, align 4, !tbaa !12
  %43 = xor i32 %42, -1
  store i32 1, ptr %7, align 4
  call void @llvm.lifetime.end.p0(ptr %5) #4
  ret i32 %43
}

; Function Attrs: nounwind willreturn memory(read)
declare i64 @strlen(ptr noundef) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind willreturn memory(read) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind }
attributes #5 = { nounwind willreturn memory(read) }

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
!12 = !{!6, !6, i64 0}
!13 = !{!7, !7, i64 0}
!14 = distinct !{!14, !15}
!15 = !{!"llvm.loop.mustprogress"}
!16 = !{!17, !17, i64 0}
!17 = !{!"long", !7, i64 0}
!18 = distinct !{!18, !15}
!19 = distinct !{!19, !15}
