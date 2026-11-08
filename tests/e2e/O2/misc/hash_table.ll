; @source: tests/e2e/src/misc/hash_table.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/misc/hash_table.c'
source_filename = "tests/e2e/src/misc/hash_table.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.entry = type { [16 x i8], i32, i32 }

@.str = private unnamed_addr constant [6 x i8] c"key%d\00", align 1
@.str.1 = private unnamed_addr constant [6 x i8] c"key13\00", align 1
@.str.2 = private unnamed_addr constant [11 x i8] c"%ld %d %d\0A\00", align 1
@.str.3 = private unnamed_addr constant [5 x i8] c"nope\00", align 1
@table = internal global [64 x %struct.entry] zeroinitializer, align 16

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = alloca [16 x i8], align 16
  call void @llvm.lifetime.start.p0(ptr nonnull %1) #6
  br label %19

2:                                                ; preds = %10
  %3 = add nuw nsw i32 %12, 1
  %4 = and i32 %3, 63
  %5 = zext nneg i32 %4 to i64
  %6 = getelementptr inbounds nuw [24 x i8], ptr @table, i64 %5
  %7 = getelementptr inbounds nuw i8, ptr %6, i64 20
  %8 = load i32, ptr %7, align 4, !tbaa !9
  %9 = icmp eq i32 %8, 0
  br i1 %9, label %15, label %10, !llvm.loop !11

10:                                               ; preds = %65, %2
  %11 = phi ptr [ %6, %2 ], [ getelementptr inbounds nuw (i8, ptr @table, i64 432), %65 ]
  %12 = phi i32 [ %4, %2 ], [ 18, %65 ]
  %13 = tail call i32 @strcmp(ptr noundef nonnull dereferenceable(1) %11, ptr noundef nonnull dereferenceable(6) @.str.1) #7
  %14 = icmp eq i32 %13, 0
  br i1 %14, label %15, label %2

15:                                               ; preds = %2, %10, %65
  %16 = phi ptr [ getelementptr inbounds nuw (i8, ptr @table, i64 432), %65 ], [ %11, %10 ], [ %6, %2 ]
  %17 = getelementptr inbounds nuw i8, ptr %16, i64 20
  tail call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 1 dereferenceable(6) %16, ptr noundef nonnull align 1 dereferenceable(6) @.str.1, i64 6, i1 false) #6
  %18 = getelementptr inbounds nuw i8, ptr %16, i64 16
  store i32 -5, ptr %18, align 8, !tbaa !13
  store i32 1, ptr %17, align 4, !tbaa !9
  br label %110

19:                                               ; preds = %0, %58
  %20 = phi i32 [ 0, %0 ], [ %63, %58 ]
  %21 = mul nuw nsw i32 %20, 13
  %22 = call i32 (ptr, i64, ptr, ...) @snprintf(ptr noundef nonnull dereferenceable(1) %1, i64 noundef 16, ptr noundef nonnull @.str, i32 noundef %21) #6
  %23 = mul nuw nsw i32 %20, %20
  %24 = load i8, ptr %1, align 16, !tbaa !14
  %25 = icmp eq i8 %24, 0
  br i1 %25, label %38, label %26

26:                                               ; preds = %19, %26
  %27 = phi i8 [ %34, %26 ], [ %24, %19 ]
  %28 = phi i32 [ %33, %26 ], [ 5381, %19 ]
  %29 = phi ptr [ %31, %26 ], [ %1, %19 ]
  %30 = mul i32 %28, 33
  %31 = getelementptr inbounds nuw i8, ptr %29, i64 1
  %32 = zext i8 %27 to i32
  %33 = add i32 %30, %32
  %34 = load i8, ptr %31, align 1, !tbaa !14
  %35 = icmp eq i8 %34, 0
  br i1 %35, label %36, label %26, !llvm.loop !15

36:                                               ; preds = %26
  %37 = and i32 %33, 63
  br label %38

38:                                               ; preds = %36, %19
  %39 = phi i32 [ 5, %19 ], [ %37, %36 ]
  %40 = zext nneg i32 %39 to i64
  %41 = getelementptr inbounds nuw [24 x i8], ptr @table, i64 %40
  %42 = getelementptr inbounds nuw i8, ptr %41, i64 20
  %43 = load i32, ptr %42, align 4, !tbaa !9
  %44 = icmp eq i32 %43, 0
  br i1 %44, label %58, label %53

45:                                               ; preds = %53
  %46 = add nuw nsw i32 %55, 1
  %47 = and i32 %46, 63
  %48 = zext nneg i32 %47 to i64
  %49 = getelementptr inbounds nuw [24 x i8], ptr @table, i64 %48
  %50 = getelementptr inbounds nuw i8, ptr %49, i64 20
  %51 = load i32, ptr %50, align 4, !tbaa !9
  %52 = icmp eq i32 %51, 0
  br i1 %52, label %58, label %53, !llvm.loop !11

53:                                               ; preds = %38, %45
  %54 = phi ptr [ %49, %45 ], [ %41, %38 ]
  %55 = phi i32 [ %47, %45 ], [ %39, %38 ]
  %56 = call i32 @strcmp(ptr noundef nonnull dereferenceable(1) %54, ptr noundef nonnull readonly dereferenceable(1) %1) #7
  %57 = icmp eq i32 %56, 0
  br i1 %57, label %58, label %45

58:                                               ; preds = %45, %53, %38
  %59 = phi ptr [ %41, %38 ], [ %54, %53 ], [ %49, %45 ]
  %60 = getelementptr inbounds nuw i8, ptr %59, i64 20
  %61 = call ptr @strcpy(ptr noundef nonnull dereferenceable(1) %59, ptr noundef nonnull readonly dereferenceable(1) %1) #6
  %62 = getelementptr inbounds nuw i8, ptr %59, i64 16
  store i32 %23, ptr %62, align 8, !tbaa !13
  store i32 1, ptr %60, align 4, !tbaa !9
  %63 = add nuw nsw i32 %20, 1
  %64 = icmp eq i32 %63, 40
  br i1 %64, label %65, label %19, !llvm.loop !16

65:                                               ; preds = %58
  %66 = load i32, ptr getelementptr inbounds nuw (i8, ptr @table, i64 452), align 4, !tbaa !9
  %67 = icmp eq i32 %66, 0
  br i1 %67, label %15, label %10

68:                                               ; preds = %153
  %69 = load i32, ptr getelementptr inbounds nuw (i8, ptr @table, i64 452), align 4, !tbaa !9
  %70 = icmp eq i32 %69, 0
  br i1 %70, label %87, label %79

71:                                               ; preds = %79
  %72 = add nuw nsw i32 %81, 1
  %73 = and i32 %72, 63
  %74 = zext nneg i32 %73 to i64
  %75 = getelementptr inbounds nuw [24 x i8], ptr @table, i64 %74
  %76 = getelementptr inbounds nuw i8, ptr %75, i64 20
  %77 = load i32, ptr %76, align 4, !tbaa !9
  %78 = icmp eq i32 %77, 0
  br i1 %78, label %87, label %79, !llvm.loop !17

79:                                               ; preds = %68, %71
  %80 = phi ptr [ %75, %71 ], [ getelementptr inbounds nuw (i8, ptr @table, i64 432), %68 ]
  %81 = phi i32 [ %73, %71 ], [ 18, %68 ]
  %82 = tail call i32 @strcmp(ptr noundef nonnull dereferenceable(1) %80, ptr noundef nonnull dereferenceable(6) @.str.1) #7
  %83 = icmp eq i32 %82, 0
  br i1 %83, label %84, label %71

84:                                               ; preds = %79
  %85 = getelementptr inbounds nuw i8, ptr %80, i64 16
  %86 = load i32, ptr %85, align 8, !tbaa !13
  br label %87

87:                                               ; preds = %71, %68, %84
  %88 = phi i32 [ %86, %84 ], [ -1, %68 ], [ -1, %71 ]
  %89 = load i32, ptr getelementptr inbounds nuw (i8, ptr @table, i64 1340), align 4, !tbaa !9
  %90 = icmp eq i32 %89, 0
  br i1 %90, label %107, label %99

91:                                               ; preds = %99
  %92 = add nuw nsw i32 %101, 1
  %93 = and i32 %92, 63
  %94 = zext nneg i32 %93 to i64
  %95 = getelementptr inbounds nuw [24 x i8], ptr @table, i64 %94
  %96 = getelementptr inbounds nuw i8, ptr %95, i64 20
  %97 = load i32, ptr %96, align 4, !tbaa !9
  %98 = icmp eq i32 %97, 0
  br i1 %98, label %107, label %99, !llvm.loop !17

99:                                               ; preds = %87, %91
  %100 = phi ptr [ %95, %91 ], [ getelementptr inbounds nuw (i8, ptr @table, i64 1320), %87 ]
  %101 = phi i32 [ %93, %91 ], [ 55, %87 ]
  %102 = tail call i32 @strcmp(ptr noundef nonnull dereferenceable(1) %100, ptr noundef nonnull dereferenceable(5) @.str.3) #7
  %103 = icmp eq i32 %102, 0
  br i1 %103, label %104, label %91

104:                                              ; preds = %99
  %105 = getelementptr inbounds nuw i8, ptr %100, i64 16
  %106 = load i32, ptr %105, align 8, !tbaa !13
  br label %107

107:                                              ; preds = %91, %87, %104
  %108 = phi i32 [ %106, %104 ], [ -1, %87 ], [ -1, %91 ]
  %109 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.2, i64 noundef %155, i32 noundef %88, i32 noundef %108)
  call void @llvm.lifetime.end.p0(ptr nonnull %1) #6
  ret i32 0

110:                                              ; preds = %15, %153
  %111 = phi i32 [ 0, %15 ], [ %156, %153 ]
  %112 = phi i64 [ 0, %15 ], [ %155, %153 ]
  %113 = mul nuw nsw i32 %111, 13
  %114 = call i32 (ptr, i64, ptr, ...) @snprintf(ptr noundef nonnull dereferenceable(1) %1, i64 noundef 16, ptr noundef nonnull @.str, i32 noundef %113) #6
  %115 = load i8, ptr %1, align 16, !tbaa !14
  %116 = icmp eq i8 %115, 0
  br i1 %116, label %129, label %117

117:                                              ; preds = %110, %117
  %118 = phi i8 [ %125, %117 ], [ %115, %110 ]
  %119 = phi i32 [ %124, %117 ], [ 5381, %110 ]
  %120 = phi ptr [ %122, %117 ], [ %1, %110 ]
  %121 = mul i32 %119, 33
  %122 = getelementptr inbounds nuw i8, ptr %120, i64 1
  %123 = zext i8 %118 to i32
  %124 = add i32 %121, %123
  %125 = load i8, ptr %122, align 1, !tbaa !14
  %126 = icmp eq i8 %125, 0
  br i1 %126, label %127, label %117, !llvm.loop !15

127:                                              ; preds = %117
  %128 = and i32 %124, 63
  br label %129

129:                                              ; preds = %127, %110
  %130 = phi i32 [ 5, %110 ], [ %128, %127 ]
  %131 = zext nneg i32 %130 to i64
  %132 = getelementptr inbounds nuw [24 x i8], ptr @table, i64 %131
  %133 = getelementptr inbounds nuw i8, ptr %132, i64 20
  %134 = load i32, ptr %133, align 4, !tbaa !9
  %135 = icmp eq i32 %134, 0
  br i1 %135, label %153, label %144

136:                                              ; preds = %144
  %137 = add nuw nsw i32 %146, 1
  %138 = and i32 %137, 63
  %139 = zext nneg i32 %138 to i64
  %140 = getelementptr inbounds nuw [24 x i8], ptr @table, i64 %139
  %141 = getelementptr inbounds nuw i8, ptr %140, i64 20
  %142 = load i32, ptr %141, align 4, !tbaa !9
  %143 = icmp eq i32 %142, 0
  br i1 %143, label %153, label %144, !llvm.loop !17

144:                                              ; preds = %129, %136
  %145 = phi ptr [ %140, %136 ], [ %132, %129 ]
  %146 = phi i32 [ %138, %136 ], [ %130, %129 ]
  %147 = call i32 @strcmp(ptr noundef nonnull dereferenceable(1) %145, ptr noundef nonnull readonly dereferenceable(1) %1) #7
  %148 = icmp eq i32 %147, 0
  br i1 %148, label %149, label %136

149:                                              ; preds = %144
  %150 = getelementptr inbounds nuw i8, ptr %145, i64 16
  %151 = load i32, ptr %150, align 8, !tbaa !13
  %152 = sext i32 %151 to i64
  br label %153

153:                                              ; preds = %136, %129, %149
  %154 = phi i64 [ %152, %149 ], [ -1, %129 ], [ -1, %136 ]
  %155 = add nsw i64 %154, %112
  %156 = add nuw nsw i32 %111, 1
  %157 = icmp eq i32 %156, 60
  br i1 %157, label %68, label %110, !llvm.loop !18
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nofree nounwind
declare noundef i32 @snprintf(ptr noalias noundef writeonly captures(none), i64 noundef, ptr noundef readonly captures(none), ...) local_unnamed_addr #2

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #2

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: read)
declare i32 @strcmp(ptr noundef captures(none), ptr noundef captures(none)) local_unnamed_addr #3

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare ptr @strcpy(ptr noalias noundef returned writeonly, ptr noalias noundef readonly captures(none)) local_unnamed_addr #4

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #5

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: read) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #6 = { nounwind }
attributes #7 = { nounwind willreturn memory(read) }

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
!9 = !{!10, !6, i64 20}
!10 = !{!"entry", !7, i64 0, !6, i64 16, !6, i64 20}
!11 = distinct !{!11, !12}
!12 = !{!"llvm.loop.mustprogress"}
!13 = !{!10, !6, i64 16}
!14 = !{!7, !7, i64 0}
!15 = distinct !{!15, !12}
!16 = distinct !{!16, !12}
!17 = distinct !{!17, !12}
!18 = distinct !{!18, !12}
