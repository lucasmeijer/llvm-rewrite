; @source: tests/e2e/src/memory/heap.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/memory/heap.c'
source_filename = "tests/e2e/src/memory/heap.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.node = type { i32, ptr }

@.str = private unnamed_addr constant [6 x i8] c"-tail\00", align 1
@.str.1 = private unnamed_addr constant [12 x i8] c"%ld %s %zu\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca ptr, align 8
  %3 = alloca i32, align 4
  %4 = alloca ptr, align 8
  %5 = alloca i64, align 8
  %6 = alloca i32, align 4
  %7 = alloca ptr, align 8
  %8 = alloca ptr, align 8
  %9 = alloca ptr, align 8
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #8
  store ptr null, ptr %2, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #8
  store i32 0, ptr %3, align 4, !tbaa !12
  br label %10

10:                                               ; preds = %25, %0
  %11 = load i32, ptr %3, align 4, !tbaa !12
  %12 = icmp slt i32 %11, 50
  br i1 %12, label %14, label %13

13:                                               ; preds = %10
  call void @llvm.lifetime.end.p0(ptr %3) #8
  br label %28

14:                                               ; preds = %10
  call void @llvm.lifetime.start.p0(ptr %4) #8
  %15 = call noalias ptr @malloc(i64 noundef 16) #9
  store ptr %15, ptr %4, align 8, !tbaa !9
  %16 = load i32, ptr %3, align 4, !tbaa !12
  %17 = mul nsw i32 %16, 7
  %18 = srem i32 %17, 13
  %19 = load ptr, ptr %4, align 8, !tbaa !9
  %20 = getelementptr inbounds nuw %struct.node, ptr %19, i32 0, i32 0
  store i32 %18, ptr %20, align 8, !tbaa !13
  %21 = load ptr, ptr %2, align 8, !tbaa !9
  %22 = load ptr, ptr %4, align 8, !tbaa !9
  %23 = getelementptr inbounds nuw %struct.node, ptr %22, i32 0, i32 1
  store ptr %21, ptr %23, align 8, !tbaa !15
  %24 = load ptr, ptr %4, align 8, !tbaa !9
  store ptr %24, ptr %2, align 8, !tbaa !9
  call void @llvm.lifetime.end.p0(ptr %4) #8
  br label %25

25:                                               ; preds = %14
  %26 = load i32, ptr %3, align 4, !tbaa !12
  %27 = add nsw i32 %26, 1
  store i32 %27, ptr %3, align 4, !tbaa !12
  br label %10, !llvm.loop !16

28:                                               ; preds = %13
  call void @llvm.lifetime.start.p0(ptr %5) #8
  store i64 0, ptr %5, align 8, !tbaa !18
  call void @llvm.lifetime.start.p0(ptr %6) #8
  store i32 0, ptr %6, align 4, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %7) #8
  %29 = load ptr, ptr %2, align 8, !tbaa !9
  store ptr %29, ptr %7, align 8, !tbaa !9
  br label %30

30:                                               ; preds = %44, %28
  %31 = load ptr, ptr %7, align 8, !tbaa !9
  %32 = icmp ne ptr %31, null
  br i1 %32, label %34, label %33

33:                                               ; preds = %30
  call void @llvm.lifetime.end.p0(ptr %7) #8
  br label %48

34:                                               ; preds = %30
  %35 = load ptr, ptr %7, align 8, !tbaa !9
  %36 = getelementptr inbounds nuw %struct.node, ptr %35, i32 0, i32 0
  %37 = load i32, ptr %36, align 8, !tbaa !13
  %38 = load i32, ptr %6, align 4, !tbaa !12
  %39 = add nsw i32 %38, 1
  store i32 %39, ptr %6, align 4, !tbaa !12
  %40 = mul nsw i32 %37, %39
  %41 = sext i32 %40 to i64
  %42 = load i64, ptr %5, align 8, !tbaa !18
  %43 = add nsw i64 %42, %41
  store i64 %43, ptr %5, align 8, !tbaa !18
  br label %44

44:                                               ; preds = %34
  %45 = load ptr, ptr %7, align 8, !tbaa !9
  %46 = getelementptr inbounds nuw %struct.node, ptr %45, i32 0, i32 1
  %47 = load ptr, ptr %46, align 8, !tbaa !15
  store ptr %47, ptr %7, align 8, !tbaa !9
  br label %30, !llvm.loop !20

48:                                               ; preds = %33
  br label %49

49:                                               ; preds = %52, %48
  %50 = load ptr, ptr %2, align 8, !tbaa !9
  %51 = icmp ne ptr %50, null
  br i1 %51, label %52, label %58

52:                                               ; preds = %49
  call void @llvm.lifetime.start.p0(ptr %8) #8
  %53 = load ptr, ptr %2, align 8, !tbaa !9
  %54 = getelementptr inbounds nuw %struct.node, ptr %53, i32 0, i32 1
  %55 = load ptr, ptr %54, align 8, !tbaa !15
  store ptr %55, ptr %8, align 8, !tbaa !9
  %56 = load ptr, ptr %2, align 8, !tbaa !9
  call void @free(ptr noundef %56) #8
  %57 = load ptr, ptr %8, align 8, !tbaa !9
  store ptr %57, ptr %2, align 8, !tbaa !9
  call void @llvm.lifetime.end.p0(ptr %8) #8
  br label %49, !llvm.loop !21

58:                                               ; preds = %49
  call void @llvm.lifetime.start.p0(ptr %9) #8
  %59 = call noalias ptr @calloc(i64 noundef 64, i64 noundef 1) #10
  store ptr %59, ptr %9, align 8, !tbaa !22
  %60 = load ptr, ptr %9, align 8, !tbaa !22
  call void @llvm.memset.p0.i64(ptr align 1 %60, i8 120, i64 10, i1 false)
  %61 = load ptr, ptr %9, align 8, !tbaa !22
  %62 = getelementptr inbounds i8, ptr %61, i64 10
  %63 = call ptr @strcpy(ptr noundef %62, ptr noundef @.str) #8
  %64 = load i64, ptr %5, align 8, !tbaa !18
  %65 = load ptr, ptr %9, align 8, !tbaa !22
  %66 = load ptr, ptr %9, align 8, !tbaa !22
  %67 = call i64 @strlen(ptr noundef %66) #11
  %68 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i64 noundef %64, ptr noundef %65, i64 noundef %67)
  %69 = load ptr, ptr %9, align 8, !tbaa !22
  call void @free(ptr noundef %69) #8
  call void @llvm.lifetime.end.p0(ptr %9) #8
  call void @llvm.lifetime.end.p0(ptr %6) #8
  call void @llvm.lifetime.end.p0(ptr %5) #8
  call void @llvm.lifetime.end.p0(ptr %2) #8
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nounwind allocsize(0)
declare noalias ptr @malloc(i64 noundef) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind
declare void @free(ptr noundef) #3

; Function Attrs: nounwind allocsize(0,1)
declare noalias ptr @calloc(i64 noundef, i64 noundef) #4

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #5

; Function Attrs: nounwind
declare ptr @strcpy(ptr noundef, ptr noundef) #3

declare i32 @printf(ptr noundef, ...) #6

; Function Attrs: nounwind willreturn memory(read)
declare i64 @strlen(ptr noundef) #7

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind allocsize(0) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind allocsize(0,1) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #6 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #7 = { nounwind willreturn memory(read) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #8 = { nounwind }
attributes #9 = { nounwind allocsize(0) }
attributes #10 = { nounwind allocsize(0,1) }
attributes #11 = { nounwind willreturn memory(read) }

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
!10 = !{!"p1 _ZTS4node", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!6, !6, i64 0}
!13 = !{!14, !6, i64 0}
!14 = !{!"node", !6, i64 0, !10, i64 8}
!15 = !{!14, !10, i64 8}
!16 = distinct !{!16, !17}
!17 = !{!"llvm.loop.mustprogress"}
!18 = !{!19, !19, i64 0}
!19 = !{!"long", !7, i64 0}
!20 = distinct !{!20, !17}
!21 = distinct !{!21, !17}
!22 = !{!23, !23, i64 0}
!23 = !{!"p1 omnipotent char", !11, i64 0}
