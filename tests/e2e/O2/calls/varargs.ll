; @source: tests/e2e/src/calls/varargs.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/calls/varargs.c'
source_filename = "tests/e2e/src/calls/varargs.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.__va_list_tag = type { i32, i32, ptr, ptr }

@.str = private unnamed_addr constant [5 x i8] c"%ld\0A\00", align 1
@.str.1 = private unnamed_addr constant [6 x i8] c"%.3f\0A\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = tail call i64 (i32, ...) @sum(i32 poison, i32 noundef 1, i32 noundef 2, i32 noundef 3, i32 noundef 4, i32 noundef 5, i32 noundef 6, i32 noundef 7, i32 noundef 8, i32 noundef 9, i32 noundef 10)
  %2 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i64 noundef %1)
  %3 = tail call double (i32, ...) @mixed(i32 poison, i64 noundef 1, double noundef 5.000000e-01, i64 noundef 2, double noundef 2.500000e-01, i64 noundef 3, double noundef 1.250000e-01, i64 noundef 4, double noundef 1.000000e+10)
  %4 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %3)
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #1

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn uwtable
define internal range(i64 -21474836480, 21474836471) i64 @sum(i32 %0, ...) unnamed_addr #2 {
  %2 = alloca [1 x %struct.__va_list_tag], align 16
  call void @llvm.lifetime.start.p0(ptr nonnull %2) #5
  call void @llvm.va_start.p0(ptr nonnull %2)
  %3 = load i32, ptr %2, align 16
  %4 = getelementptr inbounds nuw i8, ptr %2, i64 8
  %5 = getelementptr inbounds nuw i8, ptr %2, i64 16
  %6 = load ptr, ptr %5, align 16
  %7 = load ptr, ptr %4, align 8
  %8 = icmp ult i32 %3, 41
  br i1 %8, label %12, label %9

9:                                                ; preds = %1
  %10 = getelementptr i8, ptr %7, i64 8
  store ptr %10, ptr %4, align 8
  %11 = load i32, ptr %7, align 4, !tbaa !9
  br label %18

12:                                               ; preds = %1
  %13 = zext nneg i32 %3 to i64
  %14 = getelementptr i8, ptr %6, i64 %13
  %15 = add nuw nsw i32 %3, 8
  store i32 %15, ptr %2, align 16
  %16 = load i32, ptr %14, align 4, !tbaa !9
  %17 = icmp ult i32 %3, 33
  br i1 %17, label %23, label %18

18:                                               ; preds = %12, %9
  %19 = phi i32 [ %11, %9 ], [ %16, %12 ]
  %20 = phi ptr [ %10, %9 ], [ %7, %12 ]
  %21 = getelementptr i8, ptr %20, i64 8
  store ptr %21, ptr %4, align 8
  %22 = load i32, ptr %20, align 4, !tbaa !9
  br label %29

23:                                               ; preds = %12
  %24 = zext nneg i32 %15 to i64
  %25 = getelementptr i8, ptr %6, i64 %24
  %26 = add nuw nsw i32 %3, 16
  store i32 %26, ptr %2, align 16
  %27 = load i32, ptr %25, align 4, !tbaa !9
  %28 = icmp ult i32 %3, 25
  br i1 %28, label %35, label %29

29:                                               ; preds = %23, %18
  %30 = phi i32 [ %22, %18 ], [ %27, %23 ]
  %31 = phi ptr [ %21, %18 ], [ %7, %23 ]
  %32 = phi i32 [ %19, %18 ], [ %16, %23 ]
  %33 = getelementptr i8, ptr %31, i64 8
  store ptr %33, ptr %4, align 8
  %34 = load i32, ptr %31, align 4, !tbaa !9
  br label %41

35:                                               ; preds = %23
  %36 = zext nneg i32 %26 to i64
  %37 = getelementptr i8, ptr %6, i64 %36
  %38 = add nuw nsw i32 %3, 24
  store i32 %38, ptr %2, align 16
  %39 = load i32, ptr %37, align 4, !tbaa !9
  %40 = icmp ult i32 %3, 17
  br i1 %40, label %48, label %41

41:                                               ; preds = %35, %29
  %42 = phi i32 [ %34, %29 ], [ %39, %35 ]
  %43 = phi ptr [ %33, %29 ], [ %7, %35 ]
  %44 = phi i32 [ %32, %29 ], [ %16, %35 ]
  %45 = phi i32 [ %30, %29 ], [ %27, %35 ]
  %46 = getelementptr i8, ptr %43, i64 8
  store ptr %46, ptr %4, align 8
  %47 = load i32, ptr %43, align 4, !tbaa !9
  br label %54

48:                                               ; preds = %35
  %49 = zext nneg i32 %38 to i64
  %50 = getelementptr i8, ptr %6, i64 %49
  %51 = or disjoint i32 %3, 32
  store i32 %51, ptr %2, align 16
  %52 = load i32, ptr %50, align 4, !tbaa !9
  %53 = icmp samesign ult i32 %51, 41
  br i1 %53, label %62, label %54

54:                                               ; preds = %48, %41
  %55 = phi i32 [ %47, %41 ], [ %52, %48 ]
  %56 = phi ptr [ %46, %41 ], [ %7, %48 ]
  %57 = phi i32 [ %45, %41 ], [ %27, %48 ]
  %58 = phi i32 [ %44, %41 ], [ %16, %48 ]
  %59 = phi i32 [ %42, %41 ], [ %39, %48 ]
  %60 = getelementptr i8, ptr %56, i64 8
  store ptr %60, ptr %4, align 8
  %61 = load i32, ptr %56, align 4, !tbaa !9
  br label %68

62:                                               ; preds = %48
  %63 = zext nneg i32 %51 to i64
  %64 = getelementptr i8, ptr %6, i64 %63
  %65 = add nuw nsw i32 %3, 40
  store i32 %65, ptr %2, align 16
  %66 = icmp eq i32 %3, 0
  %67 = load i32, ptr %64, align 4, !tbaa !9
  br i1 %66, label %76, label %68

68:                                               ; preds = %54, %62
  %69 = phi i32 [ %61, %54 ], [ %67, %62 ]
  %70 = phi ptr [ %60, %54 ], [ %7, %62 ]
  %71 = phi i32 [ %59, %54 ], [ %39, %62 ]
  %72 = phi i32 [ %58, %54 ], [ %16, %62 ]
  %73 = phi i32 [ %57, %54 ], [ %27, %62 ]
  %74 = phi i32 [ %55, %54 ], [ %52, %62 ]
  %75 = getelementptr i8, ptr %70, i64 8
  store ptr %75, ptr %4, align 8
  br label %78

76:                                               ; preds = %62
  %77 = getelementptr i8, ptr %6, i64 40
  store i32 48, ptr %2, align 16
  br label %78

78:                                               ; preds = %76, %68
  %79 = phi i32 [ %67, %76 ], [ %69, %68 ]
  %80 = phi i32 [ %39, %76 ], [ %71, %68 ]
  %81 = phi i32 [ %16, %76 ], [ %72, %68 ]
  %82 = phi i32 [ %27, %76 ], [ %73, %68 ]
  %83 = phi i32 [ %52, %76 ], [ %74, %68 ]
  %84 = phi ptr [ %7, %76 ], [ %75, %68 ]
  %85 = phi ptr [ %77, %76 ], [ %70, %68 ]
  %86 = load i32, ptr %85, align 4, !tbaa !9
  %87 = getelementptr i8, ptr %84, i64 8
  store ptr %87, ptr %4, align 8
  %88 = load i32, ptr %84, align 4, !tbaa !9
  %89 = getelementptr i8, ptr %84, i64 16
  store ptr %89, ptr %4, align 8
  %90 = load i32, ptr %87, align 4, !tbaa !9
  %91 = getelementptr i8, ptr %84, i64 24
  store ptr %91, ptr %4, align 8
  %92 = load i32, ptr %89, align 4, !tbaa !9
  %93 = getelementptr i8, ptr %84, i64 32
  store ptr %93, ptr %4, align 8
  %94 = sext i32 %81 to i64
  %95 = sext i32 %82 to i64
  %96 = add nsw i64 %94, %95
  %97 = sext i32 %80 to i64
  %98 = add nsw i64 %96, %97
  %99 = sext i32 %83 to i64
  %100 = add nsw i64 %98, %99
  %101 = sext i32 %79 to i64
  %102 = add nsw i64 %100, %101
  %103 = sext i32 %86 to i64
  %104 = add nsw i64 %102, %103
  %105 = sext i32 %88 to i64
  %106 = add nsw i64 %104, %105
  %107 = sext i32 %90 to i64
  %108 = add nsw i64 %106, %107
  %109 = sext i32 %92 to i64
  %110 = add nsw i64 %108, %109
  %111 = load i32, ptr %91, align 4, !tbaa !9
  %112 = sext i32 %111 to i64
  %113 = add nsw i64 %110, %112
  call void @llvm.va_end.p0(ptr nonnull %2)
  call void @llvm.lifetime.end.p0(ptr nonnull %2) #5
  ret i64 %113
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn uwtable
define internal double @mixed(i32 %0, ...) unnamed_addr #2 {
  %2 = alloca [1 x %struct.__va_list_tag], align 16
  call void @llvm.lifetime.start.p0(ptr nonnull %2) #5
  call void @llvm.va_start.p0(ptr nonnull %2)
  %3 = load i32, ptr %2, align 16
  %4 = getelementptr inbounds nuw i8, ptr %2, i64 4
  %5 = getelementptr inbounds nuw i8, ptr %2, i64 8
  %6 = getelementptr inbounds nuw i8, ptr %2, i64 16
  %7 = load ptr, ptr %6, align 16
  %8 = load i32, ptr %4, align 4
  %9 = load ptr, ptr %5, align 8
  %10 = icmp ult i32 %3, 41
  br i1 %10, label %11, label %15

11:                                               ; preds = %1
  %12 = zext nneg i32 %3 to i64
  %13 = getelementptr i8, ptr %7, i64 %12
  %14 = add nuw nsw i32 %3, 8
  store i32 %14, ptr %2, align 16
  br label %17

15:                                               ; preds = %1
  %16 = getelementptr i8, ptr %9, i64 8
  store ptr %16, ptr %5, align 8
  br label %17

17:                                               ; preds = %15, %11
  %18 = phi ptr [ %9, %11 ], [ %16, %15 ]
  %19 = phi i32 [ %14, %11 ], [ %3, %15 ]
  %20 = phi ptr [ %13, %11 ], [ %9, %15 ]
  %21 = load i64, ptr %20, align 8, !tbaa !10
  %22 = icmp ult i32 %8, 161
  br i1 %22, label %25, label %23

23:                                               ; preds = %17
  %24 = getelementptr i8, ptr %18, i64 8
  store ptr %24, ptr %5, align 8
  br label %29

25:                                               ; preds = %17
  %26 = zext nneg i32 %8 to i64
  %27 = getelementptr i8, ptr %7, i64 %26
  %28 = add nuw nsw i32 %8, 16
  store i32 %28, ptr %4, align 4
  br label %29

29:                                               ; preds = %25, %23
  %30 = phi ptr [ %18, %25 ], [ %24, %23 ]
  %31 = phi i32 [ %28, %25 ], [ %8, %23 ]
  %32 = phi ptr [ %27, %25 ], [ %18, %23 ]
  %33 = load double, ptr %32, align 8, !tbaa !12
  %34 = icmp ult i32 %19, 41
  br i1 %34, label %37, label %35

35:                                               ; preds = %29
  %36 = getelementptr i8, ptr %30, i64 8
  store ptr %36, ptr %5, align 8
  br label %41

37:                                               ; preds = %29
  %38 = zext nneg i32 %19 to i64
  %39 = getelementptr i8, ptr %7, i64 %38
  %40 = add nuw nsw i32 %19, 8
  store i32 %40, ptr %2, align 16
  br label %41

41:                                               ; preds = %37, %35
  %42 = phi ptr [ %30, %37 ], [ %36, %35 ]
  %43 = phi i32 [ %40, %37 ], [ %19, %35 ]
  %44 = phi ptr [ %39, %37 ], [ %30, %35 ]
  %45 = load i64, ptr %44, align 8, !tbaa !10
  %46 = icmp ult i32 %31, 161
  br i1 %46, label %49, label %47

47:                                               ; preds = %41
  %48 = getelementptr i8, ptr %42, i64 8
  store ptr %48, ptr %5, align 8
  br label %53

49:                                               ; preds = %41
  %50 = zext nneg i32 %31 to i64
  %51 = getelementptr i8, ptr %7, i64 %50
  %52 = add nuw nsw i32 %31, 16
  store i32 %52, ptr %4, align 4
  br label %53

53:                                               ; preds = %49, %47
  %54 = phi ptr [ %42, %49 ], [ %48, %47 ]
  %55 = phi i32 [ %52, %49 ], [ %31, %47 ]
  %56 = phi ptr [ %51, %49 ], [ %42, %47 ]
  %57 = load double, ptr %56, align 8, !tbaa !12
  %58 = icmp ult i32 %43, 41
  br i1 %58, label %61, label %59

59:                                               ; preds = %53
  %60 = getelementptr i8, ptr %54, i64 8
  store ptr %60, ptr %5, align 8
  br label %65

61:                                               ; preds = %53
  %62 = zext nneg i32 %43 to i64
  %63 = getelementptr i8, ptr %7, i64 %62
  %64 = add nuw nsw i32 %43, 8
  store i32 %64, ptr %2, align 16
  br label %65

65:                                               ; preds = %61, %59
  %66 = phi ptr [ %54, %61 ], [ %60, %59 ]
  %67 = phi i32 [ %64, %61 ], [ %43, %59 ]
  %68 = phi ptr [ %63, %61 ], [ %54, %59 ]
  %69 = load i64, ptr %68, align 8, !tbaa !10
  %70 = icmp ult i32 %55, 161
  br i1 %70, label %73, label %71

71:                                               ; preds = %65
  %72 = getelementptr i8, ptr %66, i64 8
  store ptr %72, ptr %5, align 8
  br label %77

73:                                               ; preds = %65
  %74 = zext nneg i32 %55 to i64
  %75 = getelementptr i8, ptr %7, i64 %74
  %76 = add nuw nsw i32 %55, 16
  store i32 %76, ptr %4, align 4
  br label %77

77:                                               ; preds = %73, %71
  %78 = phi ptr [ %66, %73 ], [ %72, %71 ]
  %79 = phi i32 [ %76, %73 ], [ %55, %71 ]
  %80 = phi ptr [ %75, %73 ], [ %66, %71 ]
  %81 = load double, ptr %80, align 8, !tbaa !12
  %82 = icmp ult i32 %67, 41
  br i1 %82, label %85, label %83

83:                                               ; preds = %77
  %84 = getelementptr i8, ptr %78, i64 8
  store ptr %84, ptr %5, align 8
  br label %89

85:                                               ; preds = %77
  %86 = zext nneg i32 %67 to i64
  %87 = getelementptr i8, ptr %7, i64 %86
  %88 = add nuw nsw i32 %67, 8
  store i32 %88, ptr %2, align 16
  br label %89

89:                                               ; preds = %85, %83
  %90 = phi ptr [ %78, %85 ], [ %84, %83 ]
  %91 = phi ptr [ %87, %85 ], [ %78, %83 ]
  %92 = load i64, ptr %91, align 8, !tbaa !10
  %93 = icmp ult i32 %79, 161
  br i1 %93, label %96, label %94

94:                                               ; preds = %89
  %95 = getelementptr i8, ptr %90, i64 8
  store ptr %95, ptr %5, align 8
  br label %100

96:                                               ; preds = %89
  %97 = zext nneg i32 %79 to i64
  %98 = getelementptr i8, ptr %7, i64 %97
  %99 = add nuw nsw i32 %79, 16
  store i32 %99, ptr %4, align 4
  br label %100

100:                                              ; preds = %94, %96
  %101 = phi ptr [ %98, %96 ], [ %90, %94 ]
  %102 = load double, ptr %101, align 8, !tbaa !12
  %103 = sitofp i64 %21 to double
  %104 = fadd double %33, %103
  %105 = sitofp i64 %45 to double
  %106 = fadd double %104, %105
  %107 = fadd double %106, %57
  %108 = sitofp i64 %69 to double
  %109 = fadd double %107, %108
  %110 = fadd double %109, %81
  %111 = sitofp i64 %92 to double
  %112 = fadd double %110, %111
  %113 = fadd double %112, %102
  call void @llvm.va_end.p0(ptr nonnull %2)
  call void @llvm.lifetime.end.p0(ptr nonnull %2) #5
  ret double %113
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #3

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn
declare void @llvm.va_start.p0(ptr) #4

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #3

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn
declare void @llvm.va_end.p0(ptr) #4

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { mustprogress nofree norecurse nosync nounwind willreturn uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #4 = { mustprogress nocallback nofree nosync nounwind willreturn }
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
!13 = !{!"double", !7, i64 0}
