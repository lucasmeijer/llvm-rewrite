; @source: tests/e2e/src/memory/pointers.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/memory/pointers.c'
source_filename = "tests/e2e/src/memory/pointers.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@__const.main.arr = private unnamed_addr constant [8 x i32] [i32 5, i32 3, i32 8, i32 1, i32 9, i32 2, i32 7, i32 4], align 16
@.str = private unnamed_addr constant [4 x i8] c"%d \00", align 1
@.str.1 = private unnamed_addr constant [5 x i8] c"%ld\0A\00", align 1
@.str.2 = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [8 x i32], align 16
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca ptr, align 8
  %7 = alloca ptr, align 8
  %8 = alloca i64, align 8
  %9 = alloca ptr, align 8
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  call void @llvm.memcpy.p0.p0.i64(ptr align 16 %2, ptr align 16 @__const.main.arr, i64 32, i1 false)
  call void @llvm.lifetime.start.p0(ptr %3) #3
  store i32 0, ptr %3, align 4, !tbaa !9
  br label %10

10:                                               ; preds = %46, %0
  %11 = load i32, ptr %3, align 4, !tbaa !9
  %12 = icmp slt i32 %11, 8
  br i1 %12, label %14, label %13

13:                                               ; preds = %10
  store i32 2, ptr %4, align 4
  call void @llvm.lifetime.end.p0(ptr %3) #3
  br label %49

14:                                               ; preds = %10
  call void @llvm.lifetime.start.p0(ptr %5) #3
  store i32 0, ptr %5, align 4, !tbaa !9
  br label %15

15:                                               ; preds = %42, %14
  %16 = load i32, ptr %5, align 4, !tbaa !9
  %17 = add nsw i32 %16, 1
  %18 = load i32, ptr %3, align 4, !tbaa !9
  %19 = sub nsw i32 8, %18
  %20 = icmp slt i32 %17, %19
  br i1 %20, label %22, label %21

21:                                               ; preds = %15
  store i32 5, ptr %4, align 4
  call void @llvm.lifetime.end.p0(ptr %5) #3
  br label %45

22:                                               ; preds = %15
  %23 = load i32, ptr %5, align 4, !tbaa !9
  %24 = sext i32 %23 to i64
  %25 = getelementptr inbounds [8 x i32], ptr %2, i64 0, i64 %24
  %26 = load i32, ptr %25, align 4, !tbaa !9
  %27 = load i32, ptr %5, align 4, !tbaa !9
  %28 = add nsw i32 %27, 1
  %29 = sext i32 %28 to i64
  %30 = getelementptr inbounds [8 x i32], ptr %2, i64 0, i64 %29
  %31 = load i32, ptr %30, align 4, !tbaa !9
  %32 = icmp sgt i32 %26, %31
  br i1 %32, label %33, label %41

33:                                               ; preds = %22
  %34 = load i32, ptr %5, align 4, !tbaa !9
  %35 = sext i32 %34 to i64
  %36 = getelementptr inbounds [8 x i32], ptr %2, i64 0, i64 %35
  %37 = load i32, ptr %5, align 4, !tbaa !9
  %38 = add nsw i32 %37, 1
  %39 = sext i32 %38 to i64
  %40 = getelementptr inbounds [8 x i32], ptr %2, i64 0, i64 %39
  call void @swap(ptr noundef %36, ptr noundef %40)
  br label %41

41:                                               ; preds = %33, %22
  br label %42

42:                                               ; preds = %41
  %43 = load i32, ptr %5, align 4, !tbaa !9
  %44 = add nsw i32 %43, 1
  store i32 %44, ptr %5, align 4, !tbaa !9
  br label %15, !llvm.loop !10

45:                                               ; preds = %21
  br label %46

46:                                               ; preds = %45
  %47 = load i32, ptr %3, align 4, !tbaa !9
  %48 = add nsw i32 %47, 1
  store i32 %48, ptr %3, align 4, !tbaa !9
  br label %10, !llvm.loop !12

49:                                               ; preds = %13
  call void @llvm.lifetime.start.p0(ptr %6) #3
  %50 = getelementptr inbounds [8 x i32], ptr %2, i64 0, i64 0
  store ptr %50, ptr %6, align 8, !tbaa !13
  call void @llvm.lifetime.start.p0(ptr %7) #3
  %51 = getelementptr inbounds [8 x i32], ptr %2, i64 0, i64 0
  %52 = getelementptr inbounds i32, ptr %51, i64 8
  store ptr %52, ptr %7, align 8, !tbaa !13
  call void @llvm.lifetime.start.p0(ptr %8) #3
  %53 = load ptr, ptr %7, align 8, !tbaa !13
  %54 = load ptr, ptr %6, align 8, !tbaa !13
  %55 = ptrtoint ptr %53 to i64
  %56 = ptrtoint ptr %54 to i64
  %57 = sub i64 %55, %56
  %58 = sdiv exact i64 %57, 4
  store i64 %58, ptr %8, align 8, !tbaa !16
  br label %59

59:                                               ; preds = %63, %49
  %60 = load ptr, ptr %6, align 8, !tbaa !13
  %61 = load ptr, ptr %7, align 8, !tbaa !13
  %62 = icmp ult ptr %60, %61
  br i1 %62, label %63, label %68

63:                                               ; preds = %59
  %64 = load ptr, ptr %6, align 8, !tbaa !13
  %65 = getelementptr inbounds nuw i32, ptr %64, i32 1
  store ptr %65, ptr %6, align 8, !tbaa !13
  %66 = load i32, ptr %64, align 4, !tbaa !9
  %67 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %66)
  br label %59, !llvm.loop !18

68:                                               ; preds = %59
  %69 = load i64, ptr %8, align 8, !tbaa !16
  %70 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i64 noundef %69)
  call void @llvm.lifetime.start.p0(ptr %9) #3
  store ptr %6, ptr %9, align 8, !tbaa !19
  %71 = getelementptr inbounds [8 x i32], ptr %2, i64 0, i64 0
  %72 = getelementptr inbounds i32, ptr %71, i64 3
  %73 = load ptr, ptr %9, align 8, !tbaa !19
  store ptr %72, ptr %73, align 8, !tbaa !13
  %74 = load ptr, ptr %9, align 8, !tbaa !19
  %75 = load ptr, ptr %74, align 8, !tbaa !13
  %76 = load i32, ptr %75, align 4, !tbaa !9
  %77 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i32 noundef %76)
  store i32 0, ptr %1, align 4
  store i32 1, ptr %4, align 4
  call void @llvm.lifetime.end.p0(ptr %9) #3
  call void @llvm.lifetime.end.p0(ptr %8) #3
  call void @llvm.lifetime.end.p0(ptr %7) #3
  call void @llvm.lifetime.end.p0(ptr %6) #3
  call void @llvm.lifetime.end.p0(ptr %2) #3
  %78 = load i32, ptr %1, align 4
  ret i32 %78
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

; Function Attrs: nounwind uwtable
define internal void @swap(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !13
  store ptr %1, ptr %4, align 8, !tbaa !13
  call void @llvm.lifetime.start.p0(ptr %5) #3
  %6 = load ptr, ptr %3, align 8, !tbaa !13
  %7 = load i32, ptr %6, align 4, !tbaa !9
  store i32 %7, ptr %5, align 4, !tbaa !9
  %8 = load ptr, ptr %4, align 8, !tbaa !13
  %9 = load i32, ptr %8, align 4, !tbaa !9
  %10 = load ptr, ptr %3, align 8, !tbaa !13
  store i32 %9, ptr %10, align 4, !tbaa !9
  %11 = load i32, ptr %5, align 4, !tbaa !9
  %12 = load ptr, ptr %4, align 8, !tbaa !13
  store i32 %11, ptr %12, align 4, !tbaa !9
  call void @llvm.lifetime.end.p0(ptr %5) #3
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

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
!9 = !{!6, !6, i64 0}
!10 = distinct !{!10, !11}
!11 = !{!"llvm.loop.mustprogress"}
!12 = distinct !{!12, !11}
!13 = !{!14, !14, i64 0}
!14 = !{!"p1 int", !15, i64 0}
!15 = !{!"any pointer", !7, i64 0}
!16 = !{!17, !17, i64 0}
!17 = !{!"long", !7, i64 0}
!18 = distinct !{!18, !11}
!19 = !{!20, !20, i64 0}
!20 = !{!"p2 int", !21, i64 0}
!21 = !{!"any p2 pointer", !15, i64 0}
