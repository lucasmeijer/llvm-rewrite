; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/testtrace.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/testtrace.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/testtrace.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.DummyStruct = type { ptr, i32 }

@.str = private unnamed_addr constant [28 x i8] c"&S1 = %p\09&S2 = %p\09&S3 = %p\0A\00", align 1
@testAllocaOrder.count = internal global i32 0, align 4
@.str.1 = private unnamed_addr constant [10 x i8] c"sum = %d\0A\00", align 1
@.str.2 = private unnamed_addr constant [3 x i8] c"-d\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @AddCounts(ptr noundef %0, ptr noundef %1, ptr noundef %2, i32 noundef %3) #0 {
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca ptr, align 8
  %8 = alloca i32, align 4
  store ptr %0, ptr %5, align 8, !tbaa !9
  store ptr %1, ptr %6, align 8, !tbaa !9
  store ptr %2, ptr %7, align 8, !tbaa !9
  store i32 %3, ptr %8, align 4, !tbaa !12
  %9 = load i32, ptr %8, align 4, !tbaa !12
  %10 = icmp ne i32 %9, 0
  br i1 %10, label %16, label %11

11:                                               ; preds = %4
  %12 = load ptr, ptr %5, align 8, !tbaa !9
  %13 = load ptr, ptr %6, align 8, !tbaa !9
  %14 = load ptr, ptr %7, align 8, !tbaa !9
  %15 = call i32 (ptr, ...) @printf(ptr noundef @.str, ptr noundef %12, ptr noundef %13, ptr noundef %14)
  br label %16

16:                                               ; preds = %11, %4
  %17 = load ptr, ptr %5, align 8, !tbaa !9
  %18 = getelementptr inbounds nuw %struct.DummyStruct, ptr %17, i32 0, i32 1
  %19 = load i32, ptr %18, align 8, !tbaa !13
  %20 = load ptr, ptr %6, align 8, !tbaa !9
  %21 = getelementptr inbounds nuw %struct.DummyStruct, ptr %20, i32 0, i32 1
  %22 = load i32, ptr %21, align 8, !tbaa !13
  %23 = add nsw i32 %19, %22
  %24 = load ptr, ptr %7, align 8, !tbaa !9
  %25 = getelementptr inbounds nuw %struct.DummyStruct, ptr %24, i32 0, i32 1
  %26 = load i32, ptr %25, align 8, !tbaa !13
  %27 = add nsw i32 %23, %26
  ret i32 %27
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: nounwind uwtable
define dso_local void @testAllocaOrder(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca %struct.DummyStruct, align 8
  %4 = alloca %struct.DummyStruct, align 8
  %5 = alloca %struct.DummyStruct, align 8
  store i32 %0, ptr %2, align 4, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %3) #4
  call void @llvm.lifetime.start.p0(ptr %4) #4
  call void @llvm.lifetime.start.p0(ptr %5) #4
  %6 = load i32, ptr @testAllocaOrder.count, align 4, !tbaa !12
  %7 = add nsw i32 %6, 1
  store i32 %7, ptr @testAllocaOrder.count, align 4, !tbaa !12
  %8 = getelementptr inbounds nuw %struct.DummyStruct, ptr %3, i32 0, i32 1
  store i32 %7, ptr %8, align 8, !tbaa !13
  %9 = load i32, ptr @testAllocaOrder.count, align 4, !tbaa !12
  %10 = add nsw i32 %9, 1
  store i32 %10, ptr @testAllocaOrder.count, align 4, !tbaa !12
  %11 = getelementptr inbounds nuw %struct.DummyStruct, ptr %4, i32 0, i32 1
  store i32 %10, ptr %11, align 8, !tbaa !13
  %12 = load i32, ptr @testAllocaOrder.count, align 4, !tbaa !12
  %13 = add nsw i32 %12, 1
  store i32 %13, ptr @testAllocaOrder.count, align 4, !tbaa !12
  %14 = getelementptr inbounds nuw %struct.DummyStruct, ptr %5, i32 0, i32 1
  store i32 %13, ptr %14, align 8, !tbaa !13
  %15 = load i32, ptr %2, align 4, !tbaa !12
  %16 = call i32 @AddCounts(ptr noundef %3, ptr noundef %4, ptr noundef %5, i32 noundef %15)
  %17 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %16)
  call void @llvm.lifetime.end.p0(ptr %5) #4
  call void @llvm.lifetime.end.p0(ptr %4) #4
  call void @llvm.lifetime.end.p0(ptr %3) #4
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #2

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !12
  store ptr %1, ptr %5, align 8, !tbaa !15
  call void @llvm.lifetime.start.p0(ptr %6) #4
  call void @llvm.lifetime.start.p0(ptr %7) #4
  store i32 1, ptr %7, align 4, !tbaa !12
  %8 = load i32, ptr %4, align 4, !tbaa !12
  %9 = icmp sgt i32 %8, 1
  br i1 %9, label %10, label %17

10:                                               ; preds = %2
  %11 = load ptr, ptr %5, align 8, !tbaa !15
  %12 = getelementptr inbounds ptr, ptr %11, i64 1
  %13 = load ptr, ptr %12, align 8, !tbaa !18
  %14 = call i32 @strcmp(ptr noundef %13, ptr noundef @.str.2) #5
  %15 = icmp ne i32 %14, 0
  br i1 %15, label %17, label %16

16:                                               ; preds = %10
  store i32 0, ptr %7, align 4, !tbaa !12
  br label %17

17:                                               ; preds = %16, %10, %2
  store i32 0, ptr %6, align 4, !tbaa !12
  br label %18

18:                                               ; preds = %23, %17
  %19 = load i32, ptr %6, align 4, !tbaa !12
  %20 = icmp ult i32 %19, 10
  br i1 %20, label %21, label %26

21:                                               ; preds = %18
  %22 = load i32, ptr %7, align 4, !tbaa !12
  call void @testAllocaOrder(i32 noundef %22)
  br label %23

23:                                               ; preds = %21
  %24 = load i32, ptr %6, align 4, !tbaa !12
  %25 = add i32 %24, 1
  store i32 %25, ptr %6, align 4, !tbaa !12
  br label %18, !llvm.loop !20

26:                                               ; preds = %18
  call void @llvm.lifetime.end.p0(ptr %7) #4
  call void @llvm.lifetime.end.p0(ptr %6) #4
  ret i32 0
}

; Function Attrs: nounwind willreturn memory(read)
declare i32 @strcmp(ptr noundef, ptr noundef) #3

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
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
!10 = !{!"p1 _ZTS11DummyStruct", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!6, !6, i64 0}
!13 = !{!14, !6, i64 8}
!14 = !{!"DummyStruct", !10, i64 0, !6, i64 8}
!15 = !{!16, !16, i64 0}
!16 = !{!"p2 omnipotent char", !17, i64 0}
!17 = !{!"any p2 pointer", !11, i64 0}
!18 = !{!19, !19, i64 0}
!19 = !{!"p1 omnipotent char", !11, i64 0}
!20 = distinct !{!20, !21}
!21 = !{!"llvm.loop.mustprogress"}
