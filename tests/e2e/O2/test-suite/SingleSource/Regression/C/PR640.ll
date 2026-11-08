; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/PR640.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/PR640.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/PR640.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.__va_list_tag = type { i32, i32, ptr, ptr }

@str = private unnamed_addr constant [10 x i8] c"All done.\00", align 1
@str.2 = private unnamed_addr constant [6 x i8] c"ERROR\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local range(i32 0, 2) i32 @main(i32 noundef %0, ptr nofree noundef readnone captures(none) %1) local_unnamed_addr #0 {
  %3 = alloca i32, align 4
  call void @llvm.lifetime.start.p0(ptr nonnull %3)
  store i32 1, ptr %3, align 4, !tbaa !9
  %4 = call i32 (ptr, ...) @test_stdarg_va(ptr noundef %3, i32 noundef 1, i64 noundef 1981891429, i32 noundef 2, ptr noundef nonnull %3)
  %5 = icmp eq i32 %4, 0
  br i1 %5, label %9, label %6

6:                                                ; preds = %2
  %7 = call i32 (ptr, ...) @test_stdarg_builtin_va(ptr noundef %3, i32 noundef 1, i64 noundef 1981891433, i32 noundef 2, ptr noundef nonnull %3)
  %8 = icmp eq i32 %7, 0
  br i1 %8, label %9, label %10

9:                                                ; preds = %2, %6
  call void @llvm.lifetime.end.p0(ptr nonnull %3)
  br label %16

10:                                               ; preds = %6
  %11 = load i32, ptr %3, align 4, !tbaa !9
  %12 = and i32 %11, 1
  call void @llvm.lifetime.end.p0(ptr nonnull %3)
  %13 = icmp eq i32 %12, 0
  %14 = select i1 %13, ptr @str.2, ptr @str
  %15 = xor i32 %12, 1
  br label %16

16:                                               ; preds = %10, %9
  %17 = phi ptr [ %14, %10 ], [ @str.2, %9 ]
  %18 = phi i32 [ %15, %10 ], [ 1, %9 ]
  %19 = call i32 @puts(ptr nonnull dereferenceable(1) %17)
  ret i32 %18
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn uwtable
define internal range(i32 0, 2) i32 @test_stdarg_va(ptr nofree noundef nonnull readnone captures(address) %0, ...) unnamed_addr #2 {
  %2 = alloca [1 x %struct.__va_list_tag], align 16
  call void @llvm.lifetime.start.p0(ptr nonnull %2) #5
  call void @llvm.va_start.p0(ptr nonnull %2)
  %3 = load i32, ptr %2, align 16
  %4 = icmp ult i32 %3, 41
  br i1 %4, label %10, label %5

5:                                                ; preds = %1
  %6 = getelementptr inbounds nuw i8, ptr %2, i64 8
  %7 = load ptr, ptr %6, align 8
  %8 = getelementptr i8, ptr %7, i64 8
  store ptr %8, ptr %6, align 8
  %9 = load i32, ptr %7, align 4, !tbaa !9
  br label %18

10:                                               ; preds = %1
  %11 = getelementptr inbounds nuw i8, ptr %2, i64 16
  %12 = load ptr, ptr %11, align 16
  %13 = zext nneg i32 %3 to i64
  %14 = getelementptr i8, ptr %12, i64 %13
  %15 = add nuw nsw i32 %3, 8
  store i32 %15, ptr %2, align 16
  %16 = load i32, ptr %14, align 4, !tbaa !9
  %17 = icmp ult i32 %3, 33
  br i1 %17, label %24, label %18

18:                                               ; preds = %10, %5
  %19 = phi i32 [ %9, %5 ], [ %16, %10 ]
  %20 = getelementptr inbounds nuw i8, ptr %2, i64 8
  %21 = load ptr, ptr %20, align 8
  %22 = getelementptr i8, ptr %21, i64 8
  store ptr %22, ptr %20, align 8
  %23 = load i64, ptr %21, align 8, !tbaa !10
  br label %32

24:                                               ; preds = %10
  %25 = getelementptr inbounds nuw i8, ptr %2, i64 16
  %26 = load ptr, ptr %25, align 16
  %27 = zext nneg i32 %15 to i64
  %28 = getelementptr i8, ptr %26, i64 %27
  %29 = add nuw nsw i32 %3, 16
  store i32 %29, ptr %2, align 16
  %30 = load i64, ptr %28, align 8, !tbaa !10
  %31 = icmp ult i32 %3, 25
  br i1 %31, label %39, label %32

32:                                               ; preds = %24, %18
  %33 = phi i64 [ %23, %18 ], [ %30, %24 ]
  %34 = phi i32 [ %19, %18 ], [ %16, %24 ]
  %35 = getelementptr inbounds nuw i8, ptr %2, i64 8
  %36 = load ptr, ptr %35, align 8
  %37 = getelementptr i8, ptr %36, i64 8
  store ptr %37, ptr %35, align 8
  %38 = load i32, ptr %36, align 4, !tbaa !9
  br label %53

39:                                               ; preds = %24
  %40 = getelementptr inbounds nuw i8, ptr %2, i64 16
  %41 = load ptr, ptr %40, align 16
  %42 = zext nneg i32 %29 to i64
  %43 = getelementptr i8, ptr %41, i64 %42
  %44 = add nuw nsw i32 %3, 24
  store i32 %44, ptr %2, align 16
  %45 = load i32, ptr %43, align 4, !tbaa !9
  %46 = icmp ult i32 %3, 17
  br i1 %46, label %47, label %53

47:                                               ; preds = %39
  %48 = getelementptr inbounds nuw i8, ptr %2, i64 16
  %49 = load ptr, ptr %48, align 16
  %50 = zext nneg i32 %44 to i64
  %51 = getelementptr i8, ptr %49, i64 %50
  %52 = or disjoint i32 %3, 32
  store i32 %52, ptr %2, align 16
  br label %60

53:                                               ; preds = %32, %39
  %54 = phi i32 [ %38, %32 ], [ %45, %39 ]
  %55 = phi i32 [ %34, %32 ], [ %16, %39 ]
  %56 = phi i64 [ %33, %32 ], [ %30, %39 ]
  %57 = getelementptr inbounds nuw i8, ptr %2, i64 8
  %58 = load ptr, ptr %57, align 8
  %59 = getelementptr i8, ptr %58, i64 8
  store ptr %59, ptr %57, align 8
  br label %60

60:                                               ; preds = %53, %47
  %61 = phi i32 [ %45, %47 ], [ %54, %53 ]
  %62 = phi i32 [ %16, %47 ], [ %55, %53 ]
  %63 = phi i64 [ %30, %47 ], [ %56, %53 ]
  %64 = phi ptr [ %51, %47 ], [ %58, %53 ]
  %65 = load ptr, ptr %64, align 8, !tbaa !12
  call void @llvm.va_end.p0(ptr nonnull %2)
  %66 = icmp eq ptr %0, %65
  %67 = icmp eq i32 %62, 1
  %68 = select i1 %66, i1 %67, i1 false
  %69 = icmp eq i64 %63, 1981891429
  %70 = select i1 %68, i1 %69, i1 false
  %71 = icmp eq i32 %61, 2
  %72 = select i1 %70, i1 %71, i1 false
  %73 = zext i1 %72 to i32
  call void @llvm.lifetime.end.p0(ptr nonnull %2) #5
  ret i32 %73
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn uwtable
define internal range(i32 0, 2) i32 @test_stdarg_builtin_va(ptr nofree noundef nonnull readnone captures(address) %0, ...) unnamed_addr #2 {
  %2 = alloca [1 x %struct.__va_list_tag], align 16
  call void @llvm.lifetime.start.p0(ptr nonnull %2) #5
  call void @llvm.va_start.p0(ptr nonnull %2)
  %3 = load i32, ptr %2, align 16
  %4 = icmp ult i32 %3, 41
  br i1 %4, label %10, label %5

5:                                                ; preds = %1
  %6 = getelementptr inbounds nuw i8, ptr %2, i64 8
  %7 = load ptr, ptr %6, align 8
  %8 = getelementptr i8, ptr %7, i64 8
  store ptr %8, ptr %6, align 8
  %9 = load i32, ptr %7, align 4, !tbaa !9
  br label %18

10:                                               ; preds = %1
  %11 = getelementptr inbounds nuw i8, ptr %2, i64 16
  %12 = load ptr, ptr %11, align 16
  %13 = zext nneg i32 %3 to i64
  %14 = getelementptr i8, ptr %12, i64 %13
  %15 = add nuw nsw i32 %3, 8
  store i32 %15, ptr %2, align 16
  %16 = load i32, ptr %14, align 4, !tbaa !9
  %17 = icmp ult i32 %3, 33
  br i1 %17, label %24, label %18

18:                                               ; preds = %10, %5
  %19 = phi i32 [ %9, %5 ], [ %16, %10 ]
  %20 = getelementptr inbounds nuw i8, ptr %2, i64 8
  %21 = load ptr, ptr %20, align 8
  %22 = getelementptr i8, ptr %21, i64 8
  store ptr %22, ptr %20, align 8
  %23 = load i64, ptr %21, align 8, !tbaa !10
  br label %32

24:                                               ; preds = %10
  %25 = getelementptr inbounds nuw i8, ptr %2, i64 16
  %26 = load ptr, ptr %25, align 16
  %27 = zext nneg i32 %15 to i64
  %28 = getelementptr i8, ptr %26, i64 %27
  %29 = add nuw nsw i32 %3, 16
  store i32 %29, ptr %2, align 16
  %30 = load i64, ptr %28, align 8, !tbaa !10
  %31 = icmp ult i32 %3, 25
  br i1 %31, label %39, label %32

32:                                               ; preds = %24, %18
  %33 = phi i64 [ %23, %18 ], [ %30, %24 ]
  %34 = phi i32 [ %19, %18 ], [ %16, %24 ]
  %35 = getelementptr inbounds nuw i8, ptr %2, i64 8
  %36 = load ptr, ptr %35, align 8
  %37 = getelementptr i8, ptr %36, i64 8
  store ptr %37, ptr %35, align 8
  %38 = load i32, ptr %36, align 4, !tbaa !9
  br label %53

39:                                               ; preds = %24
  %40 = getelementptr inbounds nuw i8, ptr %2, i64 16
  %41 = load ptr, ptr %40, align 16
  %42 = zext nneg i32 %29 to i64
  %43 = getelementptr i8, ptr %41, i64 %42
  %44 = add nuw nsw i32 %3, 24
  store i32 %44, ptr %2, align 16
  %45 = load i32, ptr %43, align 4, !tbaa !9
  %46 = icmp ult i32 %3, 17
  br i1 %46, label %47, label %53

47:                                               ; preds = %39
  %48 = getelementptr inbounds nuw i8, ptr %2, i64 16
  %49 = load ptr, ptr %48, align 16
  %50 = zext nneg i32 %44 to i64
  %51 = getelementptr i8, ptr %49, i64 %50
  %52 = or disjoint i32 %3, 32
  store i32 %52, ptr %2, align 16
  br label %60

53:                                               ; preds = %32, %39
  %54 = phi i32 [ %38, %32 ], [ %45, %39 ]
  %55 = phi i32 [ %34, %32 ], [ %16, %39 ]
  %56 = phi i64 [ %33, %32 ], [ %30, %39 ]
  %57 = getelementptr inbounds nuw i8, ptr %2, i64 8
  %58 = load ptr, ptr %57, align 8
  %59 = getelementptr i8, ptr %58, i64 8
  store ptr %59, ptr %57, align 8
  br label %60

60:                                               ; preds = %53, %47
  %61 = phi i32 [ %45, %47 ], [ %54, %53 ]
  %62 = phi i32 [ %16, %47 ], [ %55, %53 ]
  %63 = phi i64 [ %30, %47 ], [ %56, %53 ]
  %64 = phi ptr [ %51, %47 ], [ %58, %53 ]
  %65 = load ptr, ptr %64, align 8, !tbaa !12
  call void @llvm.va_end.p0(ptr nonnull %2)
  %66 = icmp eq ptr %0, %65
  %67 = icmp eq i32 %62, 1
  %68 = select i1 %66, i1 %67, i1 false
  %69 = icmp eq i64 %63, 1981891433
  %70 = select i1 %68, i1 %69, i1 false
  %71 = icmp eq i32 %61, 2
  %72 = select i1 %70, i1 %71, i1 false
  %73 = zext i1 %72 to i32
  call void @llvm.lifetime.end.p0(ptr nonnull %2) #5
  ret i32 %73
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn
declare void @llvm.va_start.p0(ptr) #3

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn
declare void @llvm.va_end.p0(ptr) #3

; Function Attrs: nofree nounwind
declare noundef i32 @puts(ptr noundef readonly captures(none)) local_unnamed_addr #4

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { mustprogress nofree norecurse nosync nounwind willreturn uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { mustprogress nocallback nofree nosync nounwind willreturn }
attributes #4 = { nofree nounwind }
attributes #5 = { nounwind }

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
!11 = !{!"long", !7, i64 0}
!12 = !{!13, !13, i64 0}
!13 = !{!"any pointer", !7, i64 0}
