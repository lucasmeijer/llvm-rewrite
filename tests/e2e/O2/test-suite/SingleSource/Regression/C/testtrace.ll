; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/testtrace.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/testtrace.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/testtrace.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.DummyStruct = type { ptr, i32 }

@.str = private unnamed_addr constant [28 x i8] c"&S1 = %p\09&S2 = %p\09&S3 = %p\0A\00", align 1
@testAllocaOrder.count = internal unnamed_addr global i32 0, align 4
@.str.1 = private unnamed_addr constant [10 x i8] c"sum = %d\0A\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local i32 @AddCounts(ptr noundef %0, ptr noundef %1, ptr noundef %2, i32 noundef %3) local_unnamed_addr #0 {
  %5 = icmp eq i32 %3, 0
  br i1 %5, label %6, label %8

6:                                                ; preds = %4
  %7 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, ptr noundef %0, ptr noundef %1, ptr noundef %2)
  br label %8

8:                                                ; preds = %6, %4
  %9 = getelementptr inbounds nuw i8, ptr %0, i64 8
  %10 = load i32, ptr %9, align 8, !tbaa !9
  %11 = getelementptr inbounds nuw i8, ptr %1, i64 8
  %12 = load i32, ptr %11, align 8, !tbaa !9
  %13 = add nsw i32 %12, %10
  %14 = getelementptr inbounds nuw i8, ptr %2, i64 8
  %15 = load i32, ptr %14, align 8, !tbaa !9
  %16 = add nsw i32 %13, %15
  ret i32 %16
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #1

; Function Attrs: nofree nounwind uwtable
define dso_local void @testAllocaOrder(i32 noundef %0) local_unnamed_addr #0 {
  %2 = alloca %struct.DummyStruct, align 8
  %3 = alloca %struct.DummyStruct, align 8
  %4 = alloca %struct.DummyStruct, align 8
  call void @llvm.lifetime.start.p0(ptr nonnull %2) #3
  call void @llvm.lifetime.start.p0(ptr nonnull %3) #3
  call void @llvm.lifetime.start.p0(ptr nonnull %4) #3
  %5 = load i32, ptr @testAllocaOrder.count, align 4, !tbaa !13
  %6 = add nsw i32 %5, 1
  %7 = getelementptr inbounds nuw i8, ptr %2, i64 8
  store i32 %6, ptr %7, align 8, !tbaa !9
  %8 = add nsw i32 %5, 2
  %9 = getelementptr inbounds nuw i8, ptr %3, i64 8
  store i32 %8, ptr %9, align 8, !tbaa !9
  %10 = add nsw i32 %5, 3
  store i32 %10, ptr @testAllocaOrder.count, align 4, !tbaa !13
  %11 = getelementptr inbounds nuw i8, ptr %4, i64 8
  store i32 %10, ptr %11, align 8, !tbaa !9
  %12 = icmp eq i32 %0, 0
  br i1 %12, label %13, label %18

13:                                               ; preds = %1
  %14 = call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, ptr noundef nonnull %2, ptr noundef nonnull %3, ptr noundef nonnull %4)
  %15 = load i32, ptr %7, align 8, !tbaa !9
  %16 = load i32, ptr %9, align 8, !tbaa !9
  %17 = load i32, ptr %11, align 8, !tbaa !9
  br label %18

18:                                               ; preds = %1, %13
  %19 = phi i32 [ %10, %1 ], [ %17, %13 ]
  %20 = phi i32 [ %8, %1 ], [ %16, %13 ]
  %21 = phi i32 [ %6, %1 ], [ %15, %13 ]
  %22 = add nsw i32 %20, %21
  %23 = add nsw i32 %22, %19
  %24 = call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i32 noundef %23)
  call void @llvm.lifetime.end.p0(ptr nonnull %4) #3
  call void @llvm.lifetime.end.p0(ptr nonnull %3) #3
  call void @llvm.lifetime.end.p0(ptr nonnull %2) #3
  ret void
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #2

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #2

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main(i32 noundef %0, ptr nofree noundef readonly captures(none) %1) local_unnamed_addr #0 {
  %3 = alloca %struct.DummyStruct, align 8
  %4 = alloca %struct.DummyStruct, align 8
  %5 = alloca %struct.DummyStruct, align 8
  %6 = icmp sgt i32 %0, 1
  br i1 %6, label %7, label %20

7:                                                ; preds = %2
  %8 = getelementptr inbounds nuw i8, ptr %1, i64 8
  %9 = load ptr, ptr %8, align 8, !tbaa !14
  %10 = load i8, ptr %9, align 1
  %11 = icmp eq i8 %10, 45
  br i1 %11, label %12, label %20

12:                                               ; preds = %7
  %13 = getelementptr inbounds nuw i8, ptr %9, i64 1
  %14 = load i8, ptr %13, align 1
  %15 = icmp eq i8 %14, 100
  br i1 %15, label %16, label %20

16:                                               ; preds = %12
  %17 = getelementptr inbounds nuw i8, ptr %9, i64 2
  %18 = load i8, ptr %17, align 1
  %19 = icmp eq i8 %18, 0
  br label %20

20:                                               ; preds = %16, %12, %7, %2
  %21 = phi i1 [ false, %2 ], [ false, %7 ], [ false, %12 ], [ %19, %16 ]
  %22 = getelementptr inbounds nuw i8, ptr %3, i64 8
  %23 = getelementptr inbounds nuw i8, ptr %4, i64 8
  %24 = getelementptr inbounds nuw i8, ptr %5, i64 8
  br label %25

25:                                               ; preds = %20, %36
  %26 = phi i32 [ 0, %20 ], [ %43, %36 ]
  call void @llvm.lifetime.start.p0(ptr nonnull %3) #3
  call void @llvm.lifetime.start.p0(ptr nonnull %4) #3
  call void @llvm.lifetime.start.p0(ptr nonnull %5) #3
  %27 = load i32, ptr @testAllocaOrder.count, align 4, !tbaa !13
  %28 = add nsw i32 %27, 1
  store i32 %28, ptr %22, align 8, !tbaa !9
  %29 = add nsw i32 %27, 2
  store i32 %29, ptr %23, align 8, !tbaa !9
  %30 = add nsw i32 %27, 3
  store i32 %30, ptr @testAllocaOrder.count, align 4, !tbaa !13
  store i32 %30, ptr %24, align 8, !tbaa !9
  br i1 %21, label %31, label %36

31:                                               ; preds = %25
  %32 = call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, ptr noundef nonnull %3, ptr noundef nonnull %4, ptr noundef nonnull %5)
  %33 = load i32, ptr %22, align 8, !tbaa !9
  %34 = load i32, ptr %23, align 8, !tbaa !9
  %35 = load i32, ptr %24, align 8, !tbaa !9
  br label %36

36:                                               ; preds = %25, %31
  %37 = phi i32 [ %30, %25 ], [ %35, %31 ]
  %38 = phi i32 [ %29, %25 ], [ %34, %31 ]
  %39 = phi i32 [ %28, %25 ], [ %33, %31 ]
  %40 = add i32 %38, %37
  %41 = add i32 %40, %39
  %42 = call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i32 noundef %41)
  call void @llvm.lifetime.end.p0(ptr nonnull %5) #3
  call void @llvm.lifetime.end.p0(ptr nonnull %4) #3
  call void @llvm.lifetime.end.p0(ptr nonnull %3) #3
  %43 = add nuw nsw i32 %26, 1
  %44 = icmp eq i32 %43, 10
  br i1 %44, label %45, label %25, !llvm.loop !16

45:                                               ; preds = %36
  ret i32 0
}

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
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
!9 = !{!10, !6, i64 8}
!10 = !{!"DummyStruct", !11, i64 0, !6, i64 8}
!11 = !{!"p1 _ZTS11DummyStruct", !12, i64 0}
!12 = !{!"any pointer", !7, i64 0}
!13 = !{!6, !6, i64 0}
!14 = !{!15, !15, i64 0}
!15 = !{!"p1 omnipotent char", !12, i64 0}
!16 = distinct !{!16, !17}
!17 = !{!"llvm.loop.mustprogress"}
