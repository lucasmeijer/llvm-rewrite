; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/revertBits.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/revertBits.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/revertBits.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [11 x i8] c"0x12345678\00", align 1
@.str.1 = private unnamed_addr constant [19 x i8] c"0x0123456789012345\00", align 1
@.str.2 = private unnamed_addr constant [14 x i8] c"0x%x -> 0x%x\0A\00", align 1
@.str.3 = private unnamed_addr constant [18 x i8] c"0x%llx -> 0x%llx\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @ReverseBits32(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4, !tbaa !9
  %3 = load i32, ptr %2, align 4, !tbaa !9
  %4 = lshr i32 %3, 1
  %5 = and i32 %4, 1431655765
  %6 = load i32, ptr %2, align 4, !tbaa !9
  %7 = and i32 %6, 1431655765
  %8 = shl i32 %7, 1
  %9 = or i32 %5, %8
  store i32 %9, ptr %2, align 4, !tbaa !9
  %10 = load i32, ptr %2, align 4, !tbaa !9
  %11 = lshr i32 %10, 2
  %12 = and i32 %11, 858993459
  %13 = load i32, ptr %2, align 4, !tbaa !9
  %14 = and i32 %13, 858993459
  %15 = shl i32 %14, 2
  %16 = or i32 %12, %15
  store i32 %16, ptr %2, align 4, !tbaa !9
  %17 = load i32, ptr %2, align 4, !tbaa !9
  %18 = lshr i32 %17, 4
  %19 = and i32 %18, 252645135
  %20 = load i32, ptr %2, align 4, !tbaa !9
  %21 = and i32 %20, 252645135
  %22 = shl i32 %21, 4
  %23 = or i32 %19, %22
  store i32 %23, ptr %2, align 4, !tbaa !9
  %24 = load i32, ptr %2, align 4, !tbaa !9
  %25 = and i32 %24, -16777216
  %26 = lshr i32 %25, 24
  %27 = load i32, ptr %2, align 4, !tbaa !9
  %28 = and i32 %27, 16711680
  %29 = lshr i32 %28, 8
  %30 = or i32 %26, %29
  %31 = load i32, ptr %2, align 4, !tbaa !9
  %32 = and i32 %31, 65280
  %33 = shl i32 %32, 8
  %34 = or i32 %30, %33
  %35 = load i32, ptr %2, align 4, !tbaa !9
  %36 = and i32 %35, 255
  %37 = shl i32 %36, 24
  %38 = or i32 %34, %37
  ret i32 %38
}

; Function Attrs: noinline nounwind uwtable
define dso_local i64 @ReverseBits64(i64 noundef %0) #0 {
  %2 = alloca i64, align 8
  store i64 %0, ptr %2, align 8, !tbaa !10
  %3 = load i64, ptr %2, align 8, !tbaa !10
  %4 = lshr i64 %3, 1
  %5 = and i64 %4, 6148914691236517205
  %6 = load i64, ptr %2, align 8, !tbaa !10
  %7 = and i64 %6, 6148914691236517205
  %8 = shl i64 %7, 1
  %9 = or i64 %5, %8
  store i64 %9, ptr %2, align 8, !tbaa !10
  %10 = load i64, ptr %2, align 8, !tbaa !10
  %11 = lshr i64 %10, 2
  %12 = and i64 %11, 3689348814741910323
  %13 = load i64, ptr %2, align 8, !tbaa !10
  %14 = and i64 %13, 3689348814741910323
  %15 = shl i64 %14, 2
  %16 = or i64 %12, %15
  store i64 %16, ptr %2, align 8, !tbaa !10
  %17 = load i64, ptr %2, align 8, !tbaa !10
  %18 = lshr i64 %17, 4
  %19 = and i64 %18, 1085102592571150095
  %20 = load i64, ptr %2, align 8, !tbaa !10
  %21 = and i64 %20, 1085102592571150095
  %22 = shl i64 %21, 4
  %23 = or i64 %19, %22
  store i64 %23, ptr %2, align 8, !tbaa !10
  %24 = load i64, ptr %2, align 8, !tbaa !10
  %25 = and i64 %24, -72057594037927936
  %26 = lshr i64 %25, 56
  %27 = load i64, ptr %2, align 8, !tbaa !10
  %28 = and i64 %27, 71776119061217280
  %29 = lshr i64 %28, 40
  %30 = or i64 %26, %29
  %31 = load i64, ptr %2, align 8, !tbaa !10
  %32 = and i64 %31, 280375465082880
  %33 = lshr i64 %32, 24
  %34 = or i64 %30, %33
  %35 = load i64, ptr %2, align 8, !tbaa !10
  %36 = and i64 %35, 1095216660480
  %37 = lshr i64 %36, 8
  %38 = or i64 %34, %37
  %39 = load i64, ptr %2, align 8, !tbaa !10
  %40 = and i64 %39, 255
  %41 = shl i64 %40, 56
  %42 = or i64 %38, %41
  %43 = load i64, ptr %2, align 8, !tbaa !10
  %44 = and i64 %43, 65280
  %45 = shl i64 %44, 40
  %46 = or i64 %42, %45
  %47 = load i64, ptr %2, align 8, !tbaa !10
  %48 = and i64 %47, 16711680
  %49 = shl i64 %48, 24
  %50 = or i64 %46, %49
  %51 = load i64, ptr %2, align 8, !tbaa !10
  %52 = and i64 %51, 4278190080
  %53 = shl i64 %52, 8
  %54 = or i64 %50, %53
  ret i64 %54
}

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #1 {
  %1 = alloca i32, align 4
  %2 = alloca i64, align 8
  %3 = alloca i64, align 8
  %4 = alloca i32, align 4
  %5 = alloca i64, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #6
  store i64 0, ptr %2, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %3) #6
  store i64 0, ptr %3, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %4) #6
  %8 = call i64 @strtoll(ptr noundef @.str, ptr noundef null, i32 noundef 16) #6
  %9 = trunc i64 %8 to i32
  store i32 %9, ptr %4, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %5) #6
  %10 = call i64 @strtoll(ptr noundef @.str.1, ptr noundef null, i32 noundef 16) #6
  store i64 %10, ptr %5, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %6) #6
  store i32 0, ptr %6, align 4, !tbaa !9
  br label %11

11:                                               ; preds = %26, %0
  %12 = load i32, ptr %6, align 4, !tbaa !9
  %13 = icmp slt i32 %12, 16777216
  br i1 %13, label %15, label %14

14:                                               ; preds = %11
  call void @llvm.lifetime.end.p0(ptr %6) #6
  br label %29

15:                                               ; preds = %11
  %16 = load i32, ptr %6, align 4, !tbaa !9
  %17 = call i32 @ReverseBits32(i32 noundef %16)
  %18 = zext i32 %17 to i64
  %19 = load i64, ptr %2, align 8, !tbaa !10
  %20 = add i64 %19, %18
  store i64 %20, ptr %2, align 8, !tbaa !10
  %21 = load i32, ptr %6, align 4, !tbaa !9
  %22 = sext i32 %21 to i64
  %23 = call i64 @ReverseBits64(i64 noundef %22)
  %24 = load i64, ptr %3, align 8, !tbaa !10
  %25 = add i64 %24, %23
  store i64 %25, ptr %3, align 8, !tbaa !10
  br label %26

26:                                               ; preds = %15
  %27 = load i32, ptr %6, align 4, !tbaa !9
  %28 = add nsw i32 %27, 1
  store i32 %28, ptr %6, align 4, !tbaa !9
  br label %11, !llvm.loop !12

29:                                               ; preds = %14
  call void @llvm.lifetime.start.p0(ptr %7) #6
  store i32 0, ptr %7, align 4, !tbaa !9
  br label %30

30:                                               ; preds = %45, %29
  %31 = load i32, ptr %7, align 4, !tbaa !9
  %32 = icmp slt i32 %31, 16777216
  br i1 %32, label %34, label %33

33:                                               ; preds = %30
  call void @llvm.lifetime.end.p0(ptr %7) #6
  br label %48

34:                                               ; preds = %30
  %35 = load i32, ptr %7, align 4, !tbaa !9
  %36 = call i32 @llvm.bitreverse.i32(i32 %35)
  %37 = zext i32 %36 to i64
  %38 = load i64, ptr %2, align 8, !tbaa !10
  %39 = sub i64 %38, %37
  store i64 %39, ptr %2, align 8, !tbaa !10
  %40 = load i32, ptr %7, align 4, !tbaa !9
  %41 = sext i32 %40 to i64
  %42 = call i64 @llvm.bitreverse.i64(i64 %41)
  %43 = load i64, ptr %3, align 8, !tbaa !10
  %44 = sub i64 %43, %42
  store i64 %44, ptr %3, align 8, !tbaa !10
  br label %45

45:                                               ; preds = %34
  %46 = load i32, ptr %7, align 4, !tbaa !9
  %47 = add nsw i32 %46, 1
  store i32 %47, ptr %7, align 4, !tbaa !9
  br label %30, !llvm.loop !14

48:                                               ; preds = %33
  %49 = load i32, ptr %4, align 4, !tbaa !9
  %50 = load i32, ptr %4, align 4, !tbaa !9
  %51 = call i32 @llvm.bitreverse.i32(i32 %50)
  %52 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i32 noundef %49, i32 noundef %51)
  %53 = load i64, ptr %5, align 8, !tbaa !10
  %54 = load i64, ptr %5, align 8, !tbaa !10
  %55 = call i64 @llvm.bitreverse.i64(i64 %54)
  %56 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i64 noundef %53, i64 noundef %55)
  %57 = load i64, ptr %2, align 8, !tbaa !10
  %58 = icmp eq i64 %57, 0
  br i1 %58, label %59, label %62

59:                                               ; preds = %48
  %60 = load i64, ptr %3, align 8, !tbaa !10
  %61 = icmp eq i64 %60, 0
  br label %62

62:                                               ; preds = %59, %48
  %63 = phi i1 [ false, %48 ], [ %61, %59 ]
  %64 = zext i1 %63 to i64
  %65 = select i1 %63, i32 0, i32 1
  call void @llvm.lifetime.end.p0(ptr %5) #6
  call void @llvm.lifetime.end.p0(ptr %4) #6
  call void @llvm.lifetime.end.p0(ptr %3) #6
  call void @llvm.lifetime.end.p0(ptr %2) #6
  ret i32 %65
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #2

; Function Attrs: nounwind
declare i64 @strtoll(ptr noundef, ptr noundef, i32 noundef) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #2

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.bitreverse.i32(i32) #4

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.bitreverse.i64(i64) #4

declare i32 @printf(ptr noundef, ...) #5

attributes #0 = { noinline nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #3 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #5 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!10 = !{!11, !11, i64 0}
!11 = !{!"long long", !7, i64 0}
!12 = distinct !{!12, !13}
!13 = !{!"llvm.loop.mustprogress"}
!14 = distinct !{!14, !13}
