; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/ary3.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/ary3.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/ary3.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [7 x i8] c"%d %d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca ptr, align 8
  %10 = alloca ptr, align 8
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %6) #6
  %11 = load i32, ptr %4, align 4, !tbaa !9
  %12 = icmp eq i32 %11, 2
  br i1 %12, label %13, label %18

13:                                               ; preds = %2
  %14 = load ptr, ptr %5, align 8, !tbaa !10
  %15 = getelementptr inbounds ptr, ptr %14, i64 1
  %16 = load ptr, ptr %15, align 8, !tbaa !14
  %17 = call i32 @atoi(ptr noundef %16) #7
  br label %19

18:                                               ; preds = %2
  br label %19

19:                                               ; preds = %18, %13
  %20 = phi i32 [ %17, %13 ], [ 1500000, %18 ]
  store i32 %20, ptr %6, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %7) #6
  call void @llvm.lifetime.start.p0(ptr %8) #6
  call void @llvm.lifetime.start.p0(ptr %9) #6
  call void @llvm.lifetime.start.p0(ptr %10) #6
  %21 = load i32, ptr %6, align 4, !tbaa !9
  %22 = sext i32 %21 to i64
  %23 = call noalias ptr @calloc(i64 noundef %22, i64 noundef 4) #8
  store ptr %23, ptr %9, align 8, !tbaa !16
  %24 = load i32, ptr %6, align 4, !tbaa !9
  %25 = sext i32 %24 to i64
  %26 = call noalias ptr @calloc(i64 noundef %25, i64 noundef 4) #8
  store ptr %26, ptr %10, align 8, !tbaa !16
  store i32 0, ptr %7, align 4, !tbaa !9
  br label %27

27:                                               ; preds = %38, %19
  %28 = load i32, ptr %7, align 4, !tbaa !9
  %29 = load i32, ptr %6, align 4, !tbaa !9
  %30 = icmp slt i32 %28, %29
  br i1 %30, label %31, label %41

31:                                               ; preds = %27
  %32 = load i32, ptr %7, align 4, !tbaa !9
  %33 = add nsw i32 %32, 1
  %34 = load ptr, ptr %9, align 8, !tbaa !16
  %35 = load i32, ptr %7, align 4, !tbaa !9
  %36 = sext i32 %35 to i64
  %37 = getelementptr inbounds i32, ptr %34, i64 %36
  store i32 %33, ptr %37, align 4, !tbaa !9
  br label %38

38:                                               ; preds = %31
  %39 = load i32, ptr %7, align 4, !tbaa !9
  %40 = add nsw i32 %39, 1
  store i32 %40, ptr %7, align 4, !tbaa !9
  br label %27, !llvm.loop !18

41:                                               ; preds = %27
  store i32 0, ptr %8, align 4, !tbaa !9
  br label %42

42:                                               ; preds = %67, %41
  %43 = load i32, ptr %8, align 4, !tbaa !9
  %44 = icmp slt i32 %43, 1000
  br i1 %44, label %45, label %70

45:                                               ; preds = %42
  %46 = load i32, ptr %6, align 4, !tbaa !9
  %47 = sub nsw i32 %46, 1
  store i32 %47, ptr %7, align 4, !tbaa !9
  br label %48

48:                                               ; preds = %63, %45
  %49 = load i32, ptr %7, align 4, !tbaa !9
  %50 = icmp sge i32 %49, 0
  br i1 %50, label %51, label %66

51:                                               ; preds = %48
  %52 = load ptr, ptr %9, align 8, !tbaa !16
  %53 = load i32, ptr %7, align 4, !tbaa !9
  %54 = sext i32 %53 to i64
  %55 = getelementptr inbounds i32, ptr %52, i64 %54
  %56 = load i32, ptr %55, align 4, !tbaa !9
  %57 = load ptr, ptr %10, align 8, !tbaa !16
  %58 = load i32, ptr %7, align 4, !tbaa !9
  %59 = sext i32 %58 to i64
  %60 = getelementptr inbounds i32, ptr %57, i64 %59
  %61 = load i32, ptr %60, align 4, !tbaa !9
  %62 = add nsw i32 %61, %56
  store i32 %62, ptr %60, align 4, !tbaa !9
  br label %63

63:                                               ; preds = %51
  %64 = load i32, ptr %7, align 4, !tbaa !9
  %65 = add nsw i32 %64, -1
  store i32 %65, ptr %7, align 4, !tbaa !9
  br label %48, !llvm.loop !20

66:                                               ; preds = %48
  br label %67

67:                                               ; preds = %66
  %68 = load i32, ptr %8, align 4, !tbaa !9
  %69 = add nsw i32 %68, 1
  store i32 %69, ptr %8, align 4, !tbaa !9
  br label %42, !llvm.loop !21

70:                                               ; preds = %42
  %71 = load ptr, ptr %10, align 8, !tbaa !16
  %72 = getelementptr inbounds i32, ptr %71, i64 0
  %73 = load i32, ptr %72, align 4, !tbaa !9
  %74 = load ptr, ptr %10, align 8, !tbaa !16
  %75 = load i32, ptr %6, align 4, !tbaa !9
  %76 = sub nsw i32 %75, 1
  %77 = sext i32 %76 to i64
  %78 = getelementptr inbounds i32, ptr %74, i64 %77
  %79 = load i32, ptr %78, align 4, !tbaa !9
  %80 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %73, i32 noundef %79)
  %81 = load ptr, ptr %9, align 8, !tbaa !16
  call void @free(ptr noundef %81) #6
  %82 = load ptr, ptr %10, align 8, !tbaa !16
  call void @free(ptr noundef %82) #6
  call void @llvm.lifetime.end.p0(ptr %10) #6
  call void @llvm.lifetime.end.p0(ptr %9) #6
  call void @llvm.lifetime.end.p0(ptr %8) #6
  call void @llvm.lifetime.end.p0(ptr %7) #6
  call void @llvm.lifetime.end.p0(ptr %6) #6
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: inlinehint nounwind willreturn memory(read) uwtable
define available_externally i32 @atoi(ptr noundef nonnull %0) #2 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !14
  %3 = load ptr, ptr %2, align 8, !tbaa !14
  %4 = call i64 @strtol(ptr noundef %3, ptr noundef null, i32 noundef 10) #6
  %5 = trunc i64 %4 to i32
  ret i32 %5
}

; Function Attrs: nounwind allocsize(0,1)
declare noalias ptr @calloc(i64 noundef, i64 noundef) #3

declare i32 @printf(ptr noundef, ...) #4

; Function Attrs: nounwind
declare void @free(ptr noundef) #5

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind
declare i64 @strtol(ptr noundef, ptr noundef, i32 noundef) #5

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { inlinehint nounwind willreturn memory(read) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind allocsize(0,1) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { nounwind }
attributes #7 = { nounwind willreturn memory(read) }
attributes #8 = { nounwind allocsize(0,1) }

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
!17 = !{!"p1 int", !13, i64 0}
!18 = distinct !{!18, !19}
!19 = !{!"llvm.loop.mustprogress"}
!20 = distinct !{!20, !19}
!21 = distinct !{!21, !19}
