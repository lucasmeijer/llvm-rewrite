; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Dhrystone/dry.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Dhrystone/dry.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Dhrystone/dry.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@Version = dso_local local_unnamed_addr global [4 x i8] c"1.1\00", align 1
@PtrGlbNext = dso_local local_unnamed_addr global ptr null, align 8
@PtrGlb = dso_local local_unnamed_addr global ptr null, align 8
@.str = private unnamed_addr constant [31 x i8] c"DHRYSTONE PROGRAM, SOME STRING\00", align 1
@Array2Glob = dso_local local_unnamed_addr global [51 x [51 x i32]] zeroinitializer, align 16
@BoolGlob = dso_local local_unnamed_addr global i32 0, align 4
@Array1Glob = dso_local local_unnamed_addr global [51 x i32] zeroinitializer, align 16
@Char2Glob = dso_local local_unnamed_addr global i8 0, align 1
@Char1Glob = dso_local local_unnamed_addr global i8 0, align 1
@IntGlob = dso_local local_unnamed_addr global i32 0, align 4

; Function Attrs: nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = tail call i32 @Proc0()
  ret i32 0
}

; Function Attrs: nounwind uwtable
define dso_local i32 @Proc0() local_unnamed_addr #0 {
  %1 = tail call i64 @clock() #13
  %2 = tail call i64 @clock() #13
  %3 = tail call noalias dereferenceable_or_null(56) ptr @malloc(i64 noundef 56) #14
  store ptr %3, ptr @PtrGlbNext, align 8, !tbaa !9
  %4 = tail call noalias dereferenceable_or_null(56) ptr @malloc(i64 noundef 56) #14
  store ptr %4, ptr @PtrGlb, align 8, !tbaa !9
  store ptr %3, ptr %4, align 8, !tbaa !12
  %5 = getelementptr inbounds nuw i8, ptr %4, i64 8
  store i32 0, ptr %5, align 8, !tbaa !14
  %6 = getelementptr inbounds nuw i8, ptr %4, i64 12
  store i32 10001, ptr %6, align 4, !tbaa !15
  %7 = getelementptr inbounds nuw i8, ptr %4, i64 16
  store i32 40, ptr %7, align 8, !tbaa !16
  %8 = getelementptr inbounds nuw i8, ptr %4, i64 20
  tail call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 1 dereferenceable(31) %8, ptr noundef nonnull align 1 dereferenceable(31) @.str, i64 31, i1 false) #13
  store i32 10, ptr getelementptr inbounds nuw (i8, ptr @Array2Glob, i64 1660), align 4, !tbaa !17
  %9 = tail call i64 @clock() #13
  store i8 65, ptr @Char1Glob, align 1, !tbaa !18
  store i8 66, ptr @Char2Glob, align 1, !tbaa !18
  store i32 5, ptr @IntGlob, align 4, !tbaa !17
  br label %10

10:                                               ; preds = %0, %10
  %11 = phi i32 [ 0, %0 ], [ %18, %10 ]
  store i32 7, ptr getelementptr inbounds nuw (i8, ptr @Array1Glob, i64 32), align 16, !tbaa !17
  store i32 7, ptr getelementptr inbounds nuw (i8, ptr @Array1Glob, i64 36), align 4, !tbaa !17
  store i32 8, ptr getelementptr inbounds nuw (i8, ptr @Array1Glob, i64 152), align 8, !tbaa !17
  store i32 8, ptr getelementptr inbounds nuw (i8, ptr @Array2Glob, i64 1664), align 16, !tbaa !17
  store i32 8, ptr getelementptr inbounds nuw (i8, ptr @Array2Glob, i64 1668), align 4, !tbaa !17
  %12 = load i32, ptr getelementptr inbounds nuw (i8, ptr @Array2Glob, i64 1660), align 4, !tbaa !17
  %13 = add nsw i32 %12, 1
  store i32 %13, ptr getelementptr inbounds nuw (i8, ptr @Array2Glob, i64 1660), align 4, !tbaa !17
  store i32 7, ptr getelementptr inbounds nuw (i8, ptr @Array2Glob, i64 5744), align 16, !tbaa !17
  %14 = load ptr, ptr @PtrGlb, align 8, !tbaa !9
  %15 = getelementptr inbounds nuw i8, ptr %14, i64 16
  store i32 5, ptr %15, align 8, !tbaa !16
  %16 = load ptr, ptr %14, align 8, !tbaa !12
  %17 = getelementptr inbounds nuw i8, ptr %16, i64 16
  store i32 5, ptr %17, align 8, !tbaa !16
  store ptr %16, ptr %16, align 8, !tbaa !12
  %18 = add nuw nsw i32 %11, 1
  %19 = icmp eq i32 %18, 100000000
  br i1 %19, label %20, label %10, !llvm.loop !19

20:                                               ; preds = %10
  store i32 1, ptr @BoolGlob, align 4, !tbaa !17
  ret i32 undef
}

; Function Attrs: nounwind
declare i64 @clock() local_unnamed_addr #1

; Function Attrs: mustprogress nofree nounwind willreturn allockind("alloc,uninitialized") allocsize(0) memory(inaccessiblemem: readwrite, errnomem: write)
declare noalias noundef ptr @malloc(i64 noundef) local_unnamed_addr #2

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(write, argmem: readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local i32 @Proc1(ptr nofree noundef captures(none) initializes((16, 20)) %0) local_unnamed_addr #3 {
  %2 = getelementptr inbounds nuw i8, ptr %0, i64 16
  store i32 5, ptr %2, align 8, !tbaa !16
  %3 = load ptr, ptr %0, align 8, !tbaa !12
  %4 = getelementptr inbounds nuw i8, ptr %3, i64 16
  store i32 5, ptr %4, align 8, !tbaa !16
  store ptr %3, ptr %3, align 8, !tbaa !12
  ret i32 undef
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local i32 @Proc2(ptr nofree noundef captures(none) %0) local_unnamed_addr #4 {
  %2 = load i8, ptr @Char1Glob, align 1, !tbaa !18
  %3 = icmp eq i8 %2, 65
  br i1 %3, label %4, label %9

4:                                                ; preds = %1
  %5 = load i32, ptr %0, align 4, !tbaa !17
  %6 = add nsw i32 %5, 9
  %7 = load i32, ptr @IntGlob, align 4, !tbaa !17
  %8 = sub i32 %6, %7
  store i32 %8, ptr %0, align 4, !tbaa !17
  br label %9

9:                                                ; preds = %1, %4
  ret i32 undef
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local i32 @Proc3(ptr nofree noundef writeonly captures(none) initializes((0, 8)) %0) local_unnamed_addr #5 {
  %2 = load ptr, ptr @PtrGlb, align 8, !tbaa !9, !nonnull !21, !noundef !21
  %3 = load ptr, ptr %2, align 8, !tbaa !12
  store ptr %3, ptr %0, align 8, !tbaa !9
  %4 = load i32, ptr @IntGlob, align 4, !tbaa !17
  %5 = load ptr, ptr @PtrGlb, align 8, !tbaa !9
  %6 = add nsw i32 %4, 12
  %7 = getelementptr inbounds nuw i8, ptr %5, i64 16
  store i32 %6, ptr %7, align 4, !tbaa !17
  ret i32 undef
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(write, argmem: none, inaccessiblemem: none, target_mem: none) uwtable
define dso_local i32 @Proc4() local_unnamed_addr #6 {
  store i8 66, ptr @Char2Glob, align 1, !tbaa !18
  ret i32 undef
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(write, argmem: none, inaccessiblemem: none, target_mem: none) uwtable
define dso_local i32 @Proc5() local_unnamed_addr #6 {
  store i8 65, ptr @Char1Glob, align 1, !tbaa !18
  store i32 0, ptr @BoolGlob, align 4, !tbaa !17
  ret i32 undef
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(read, argmem: write, inaccessiblemem: none, target_mem: none) uwtable
define dso_local i32 @Proc6(i32 noundef %0, ptr nofree noundef writeonly captures(none) initializes((0, 4)) %1) local_unnamed_addr #7 {
  %3 = icmp eq i32 %0, 10001
  %4 = select i1 %3, i32 10001, i32 10002
  store i32 %4, ptr %1, align 4
  switch i32 %0, label %13 [
    i32 0, label %11
    i32 10000, label %5
    i32 10001, label %9
    i32 10003, label %10
  ]

5:                                                ; preds = %2
  %6 = load i32, ptr @IntGlob, align 4, !tbaa !17
  %7 = icmp sgt i32 %6, 100
  %8 = select i1 %7, i32 0, i32 10002
  br label %11

9:                                                ; preds = %2
  br label %11

10:                                               ; preds = %2
  br label %11

11:                                               ; preds = %5, %2, %9, %10
  %12 = phi i32 [ %8, %5 ], [ %0, %2 ], [ 10001, %10 ], [ 10000, %9 ]
  store i32 %12, ptr %1, align 4, !tbaa !17
  br label %13

13:                                               ; preds = %11, %2
  ret i32 undef
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: write) uwtable
define dso_local i32 @Proc7(i32 noundef %0, i32 noundef %1, ptr nofree noundef writeonly captures(none) initializes((0, 4)) %2) local_unnamed_addr #8 {
  %4 = add nsw i32 %0, 2
  %5 = add nsw i32 %4, %1
  store i32 %5, ptr %2, align 4, !tbaa !17
  ret i32 undef
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(write, argmem: readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local i32 @Proc8(ptr nofree noundef captures(none) %0, ptr nofree noundef captures(none) %1, i32 noundef %2, i32 noundef %3) local_unnamed_addr #3 {
  %5 = add nsw i32 %2, 5
  %6 = sext i32 %5 to i64
  %7 = getelementptr inbounds [4 x i8], ptr %0, i64 %6
  store i32 %3, ptr %7, align 4, !tbaa !17
  %8 = sext i32 %2 to i64
  %9 = getelementptr [4 x i8], ptr %0, i64 %8
  %10 = getelementptr i8, ptr %9, i64 24
  store i32 %3, ptr %10, align 4, !tbaa !17
  %11 = sext i32 %2 to i64
  %12 = getelementptr [4 x i8], ptr %0, i64 %11
  %13 = getelementptr i8, ptr %12, i64 140
  store i32 %5, ptr %13, align 4, !tbaa !17
  %14 = getelementptr inbounds [204 x i8], ptr %1, i64 %6
  %15 = getelementptr inbounds [4 x i8], ptr %14, i64 %6
  store i32 %5, ptr %15, align 4, !tbaa !17
  %16 = getelementptr [4 x i8], ptr %14, i64 %6
  %17 = getelementptr i8, ptr %16, i64 4
  store i32 %5, ptr %17, align 4, !tbaa !17
  %18 = getelementptr [4 x i8], ptr %14, i64 %11
  %19 = getelementptr i8, ptr %18, i64 16
  %20 = load i32, ptr %19, align 4, !tbaa !17
  %21 = add nsw i32 %20, 1
  store i32 %21, ptr %19, align 4, !tbaa !17
  %22 = load i32, ptr %7, align 4, !tbaa !17
  %23 = getelementptr [204 x i8], ptr %1, i64 %11
  %24 = getelementptr i8, ptr %23, i64 5100
  %25 = getelementptr inbounds [4 x i8], ptr %24, i64 %6
  store i32 %22, ptr %25, align 4, !tbaa !17
  store i32 5, ptr @IntGlob, align 4, !tbaa !17
  ret i32 undef
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef range(i32 0, 10001) i32 @Func1(i32 noundef %0, i32 noundef %1) local_unnamed_addr #9 {
  %3 = xor i32 %1, %0
  %4 = and i32 %3, 255
  %5 = icmp eq i32 %4, 0
  %6 = select i1 %5, i32 10000, i32 0
  ret i32 %6
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: read) uwtable
define dso_local range(i32 0, 2) i32 @Func2(ptr nofree noundef readonly captures(none) %0, ptr nofree noundef readonly captures(none) %1) local_unnamed_addr #10 {
  %3 = getelementptr inbounds nuw i8, ptr %0, i64 1
  %4 = load i8, ptr %3, align 1, !tbaa !18
  %5 = getelementptr inbounds nuw i8, ptr %1, i64 2
  %6 = load i8, ptr %5, align 1, !tbaa !18
  %7 = icmp eq i8 %6, %4
  br label %8

8:                                                ; preds = %8, %2
  br i1 %7, label %8, label %9, !llvm.loop !22

9:                                                ; preds = %8
  %10 = tail call i32 @strcmp(ptr noundef nonnull dereferenceable(1) %0, ptr noundef nonnull dereferenceable(1) %1) #15
  %11 = icmp sgt i32 %10, 0
  %12 = zext i1 %11 to i32
  ret i32 %12
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: read)
declare i32 @strcmp(ptr noundef captures(none), ptr noundef captures(none)) local_unnamed_addr #11

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local range(i32 0, 2) i32 @Func3(i32 noundef %0) local_unnamed_addr #9 {
  %2 = icmp eq i32 %0, 10001
  %3 = zext i1 %2 to i32
  ret i32 %3
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #12

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { mustprogress nofree nounwind willreturn allockind("alloc,uninitialized") allocsize(0) memory(inaccessiblemem: readwrite, errnomem: write) "alloc-family"="malloc" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { mustprogress nofree norecurse nosync nounwind willreturn memory(write, argmem: readwrite, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { mustprogress nofree norecurse nosync nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { mustprogress nofree norecurse nosync nounwind willreturn memory(write, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #7 = { mustprogress nofree norecurse nosync nounwind willreturn memory(read, argmem: write, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #8 = { mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: write) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #9 = { mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #10 = { nofree norecurse nosync nounwind memory(argmem: read) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #11 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: read) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #12 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #13 = { nounwind }
attributes #14 = { nounwind allocsize(0) }
attributes #15 = { nounwind willreturn memory(read) }

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
!10 = !{!"p1 _ZTS6Record", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!13, !10, i64 0}
!13 = !{!"Record", !10, i64 0, !6, i64 8, !6, i64 12, !6, i64 16, !7, i64 20}
!14 = !{!13, !6, i64 8}
!15 = !{!13, !6, i64 12}
!16 = !{!13, !6, i64 16}
!17 = !{!6, !6, i64 0}
!18 = !{!7, !7, i64 0}
!19 = distinct !{!19, !20}
!20 = !{!"llvm.loop.mustprogress"}
!21 = !{}
!22 = distinct !{!22, !23}
!23 = !{!"llvm.loop.peeled.count", i32 1}
