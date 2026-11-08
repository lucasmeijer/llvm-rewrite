; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2005-05-11-Popcount-ffs-fls.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2005-05-11-Popcount-ffs-fls.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2005-05-11-Popcount-ffs-fls.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@nlz10b.table = internal unnamed_addr constant [64 x i8] c" \14\13cc\12c\07\0A\11cc\0Ec\06cc\09c\10cc\01\1Ac\0Dcc\18\05ccc\15c\08\0Bc\0Fcccc\02\1B\00\19c\16c\0Ccc\03\1Cc\17c\04\1Dcc\1E\1F", align 16
@i = dso_local local_unnamed_addr global i32 0, align 4
@.str = private unnamed_addr constant [54 x i8] c"LLVM: n: %d, clz(n): %d, popcount(n): %d, ctz(n): %d\0A\00", align 1
@.str.1 = private unnamed_addr constant [54 x i8] c"REF : n: %d, clz(n): %d, popcount(n): %d, ctz(n): %d\0A\00", align 1
@.str.3 = private unnamed_addr constant [56 x i8] c"LLVM: n: %lld, clz(n): %d, popcount(n): %d, ctz(n): %d\0A\00", align 1
@.str.4 = private unnamed_addr constant [64 x i8] c"REF LO BITS : n: %lld, clz(n): %d, popcount(n): %d, ctz(n): %d\0A\00", align 1
@.str.5 = private unnamed_addr constant [58 x i8] c"FFS: 0:%d, 1:%d, 2:%d, 7:%d, 1024:%d, 1234:%d i:%d, l:%d\0A\00", align 1
@.str.6 = private unnamed_addr constant [67 x i8] c"__builtin_ffs: 0:%d, 1:%d, 2:%d, 7:%d, 1024:%d, 1234:%d i:%d l:%d\0A\00", align 1
@str.7 = private unnamed_addr constant [8 x i8] c"  ***  \00", align 1

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local range(i32 -128, 128) i32 @nlz10b(i32 noundef %0) local_unnamed_addr #0 {
  %2 = lshr i32 %0, 1
  %3 = or i32 %2, %0
  %4 = lshr i32 %3, 2
  %5 = or i32 %4, %3
  %6 = lshr i32 %5, 4
  %7 = or i32 %6, %5
  %8 = lshr i32 %7, 8
  %9 = or i32 %8, %7
  %10 = lshr i32 %9, 16
  %11 = xor i32 %10, -1
  %12 = and i32 %9, %11
  %13 = mul i32 %12, -42972673
  %14 = lshr i32 %13, 26
  %15 = zext nneg i32 %14 to i64
  %16 = getelementptr inbounds nuw i8, ptr @nlz10b.table, i64 %15
  %17 = load i8, ptr %16, align 1, !tbaa !9
  %18 = sext i8 %17 to i32
  ret i32 %18
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local range(i32 -128, 160) i32 @nlzll(i64 noundef %0) local_unnamed_addr #0 {
  %2 = lshr i64 %0, 32
  %3 = icmp eq i64 %2, 0
  br i1 %3, label %4, label %24

4:                                                ; preds = %1
  %5 = trunc nuw i64 %0 to i32
  %6 = lshr i32 %5, 1
  %7 = or i32 %6, %5
  %8 = lshr i32 %7, 2
  %9 = or i32 %8, %7
  %10 = lshr i32 %9, 4
  %11 = or i32 %10, %9
  %12 = lshr i32 %11, 8
  %13 = or i32 %12, %11
  %14 = lshr i32 %13, 16
  %15 = xor i32 %14, -1
  %16 = and i32 %13, %15
  %17 = mul i32 %16, -42972673
  %18 = lshr i32 %17, 26
  %19 = zext nneg i32 %18 to i64
  %20 = getelementptr inbounds nuw i8, ptr @nlz10b.table, i64 %19
  %21 = load i8, ptr %20, align 1, !tbaa !9
  %22 = sext i8 %21 to i32
  %23 = add nsw i32 %22, 32
  br label %43

24:                                               ; preds = %1
  %25 = trunc nuw i64 %2 to i32
  %26 = lshr i32 %25, 1
  %27 = or i32 %26, %25
  %28 = lshr i32 %27, 2
  %29 = or i32 %28, %27
  %30 = lshr i32 %29, 4
  %31 = or i32 %30, %29
  %32 = lshr i32 %31, 8
  %33 = or i32 %32, %31
  %34 = lshr i32 %33, 16
  %35 = xor i32 %34, -1
  %36 = and i32 %33, %35
  %37 = mul i32 %36, -42972673
  %38 = lshr i32 %37, 26
  %39 = zext nneg i32 %38 to i64
  %40 = getelementptr inbounds nuw i8, ptr @nlz10b.table, i64 %39
  %41 = load i8, ptr %40, align 1, !tbaa !9
  %42 = sext i8 %41 to i32
  br label %43

43:                                               ; preds = %24, %4
  %44 = phi i32 [ %23, %4 ], [ %42, %24 ]
  ret i32 %44
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local range(i32 0, 33) i32 @pop(i32 noundef %0) local_unnamed_addr #0 {
  %2 = tail call range(i32 0, 33) i32 @llvm.ctpop.i32(i32 %0)
  ret i32 %2
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local range(i32 0, 65) i32 @popll(i64 noundef %0) local_unnamed_addr #0 {
  %2 = trunc i64 %0 to i32
  %3 = tail call range(i32 0, 33) i32 @llvm.ctpop.i32(i32 %2)
  %4 = lshr i64 %0, 32
  %5 = trunc nuw i64 %4 to i32
  %6 = tail call range(i32 0, 33) i32 @llvm.ctpop.i32(i32 %5)
  %7 = add nuw nsw i32 %6, %3
  ret i32 %7
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local range(i32 0, 33) i32 @ntz8(i32 noundef %0) local_unnamed_addr #0 {
  %2 = tail call range(i32 0, 33) i32 @llvm.cttz.i32(i32 %0, i1 false)
  ret i32 %2
}

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #1 {
  store i32 10, ptr @i, align 4, !tbaa !10
  br label %1

1:                                                ; preds = %0, %1
  %2 = phi i32 [ 10, %0 ], [ %31, %1 ]
  %3 = tail call range(i32 0, 33) i32 @llvm.ctlz.i32(i32 %2, i1 true)
  %4 = tail call range(i32 0, 33) i32 @llvm.ctpop.i32(i32 %2)
  %5 = tail call range(i32 0, 33) i32 @llvm.cttz.i32(i32 %2, i1 true)
  %6 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %2, i32 noundef %3, i32 noundef %4, i32 noundef %5)
  %7 = load i32, ptr @i, align 4, !tbaa !10
  %8 = lshr i32 %7, 1
  %9 = or i32 %8, %7
  %10 = lshr i32 %9, 2
  %11 = or i32 %10, %9
  %12 = lshr i32 %11, 4
  %13 = or i32 %12, %11
  %14 = lshr i32 %13, 8
  %15 = or i32 %14, %13
  %16 = lshr i32 %15, 16
  %17 = xor i32 %16, -1
  %18 = and i32 %15, %17
  %19 = mul i32 %18, -42972673
  %20 = lshr i32 %19, 26
  %21 = zext nneg i32 %20 to i64
  %22 = getelementptr inbounds nuw i8, ptr @nlz10b.table, i64 %21
  %23 = load i8, ptr %22, align 1, !tbaa !9
  %24 = sext i8 %23 to i32
  %25 = tail call range(i32 0, 33) i32 @llvm.ctpop.i32(i32 %7)
  %26 = tail call range(i32 0, 33) i32 @llvm.cttz.i32(i32 %7, i1 false)
  %27 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i32 noundef %7, i32 noundef %24, i32 noundef %25, i32 noundef %26)
  %28 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str.7)
  %29 = load i32, ptr @i, align 4, !tbaa !10
  %30 = mul i32 %29, -3
  %31 = add i32 %30, -3
  store i32 %31, ptr @i, align 4, !tbaa !10
  %32 = icmp slt i32 %31, 139045193
  br i1 %32, label %1, label %33, !llvm.loop !11

33:                                               ; preds = %1, %83
  %34 = phi i64 [ %92, %83 ], [ -10000, %1 ]
  %35 = tail call range(i64 0, 65) i64 @llvm.ctlz.i64(i64 %34, i1 true)
  %36 = trunc nuw nsw i64 %35 to i32
  %37 = tail call range(i64 0, 65) i64 @llvm.ctpop.i64(i64 %34)
  %38 = trunc nuw nsw i64 %37 to i32
  %39 = trunc i64 %34 to i32
  %40 = tail call range(i32 0, 33) i32 @llvm.cttz.i32(i32 %39, i1 true)
  %41 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.3, i64 noundef %34, i32 noundef %36, i32 noundef %38, i32 noundef %40)
  %42 = lshr i64 %34, 32
  %43 = icmp eq i64 %42, 0
  br i1 %43, label %44, label %63

44:                                               ; preds = %33
  %45 = lshr i32 %39, 1
  %46 = or i32 %45, %39
  %47 = lshr i32 %46, 2
  %48 = or i32 %47, %46
  %49 = lshr i32 %48, 4
  %50 = or i32 %49, %48
  %51 = lshr i32 %50, 8
  %52 = or i32 %51, %50
  %53 = lshr i32 %52, 16
  %54 = xor i32 %53, -1
  %55 = and i32 %52, %54
  %56 = mul i32 %55, -42972673
  %57 = lshr i32 %56, 26
  %58 = zext nneg i32 %57 to i64
  %59 = getelementptr inbounds nuw i8, ptr @nlz10b.table, i64 %58
  %60 = load i8, ptr %59, align 1, !tbaa !9
  %61 = sext i8 %60 to i32
  %62 = add nsw i32 %61, 32
  br label %83

63:                                               ; preds = %33
  %64 = trunc nuw i64 %42 to i32
  %65 = lshr i32 %64, 1
  %66 = or i32 %65, %64
  %67 = lshr i32 %66, 2
  %68 = or i32 %67, %66
  %69 = lshr i32 %68, 4
  %70 = or i32 %69, %68
  %71 = lshr i32 %70, 8
  %72 = or i32 %71, %70
  %73 = lshr i32 %72, 16
  %74 = xor i32 %73, -1
  %75 = and i32 %72, %74
  %76 = mul i32 %75, -42972673
  %77 = lshr i32 %76, 26
  %78 = zext nneg i32 %77 to i64
  %79 = getelementptr inbounds nuw i8, ptr @nlz10b.table, i64 %78
  %80 = load i8, ptr %79, align 1, !tbaa !9
  %81 = sext i8 %80 to i32
  %82 = tail call range(i32 1, 33) i32 @llvm.ctpop.i32(i32 %64)
  br label %83

83:                                               ; preds = %44, %63
  %84 = phi i32 [ 0, %44 ], [ %82, %63 ]
  %85 = phi i32 [ %62, %44 ], [ %81, %63 ]
  %86 = tail call range(i32 0, 33) i32 @llvm.ctpop.i32(i32 %39)
  %87 = add nuw nsw i32 %84, %86
  %88 = tail call range(i32 0, 33) i32 @llvm.cttz.i32(i32 %39, i1 false)
  %89 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.4, i64 noundef %34, i32 noundef %85, i32 noundef %87, i32 noundef %88)
  %90 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str.7)
  %91 = mul i64 %34, -3
  %92 = add i64 %91, -3
  %93 = icmp slt i64 %92, 1390451930000
  br i1 %93, label %33, label %94, !llvm.loop !13

94:                                               ; preds = %83
  %95 = load i32, ptr @i, align 4, !tbaa !10
  %96 = tail call range(i32 0, 33) i32 @llvm.cttz.i32(i32 %95, i1 true)
  %97 = add nuw nsw i32 %96, 1
  %98 = icmp eq i32 %95, 0
  %99 = select i1 %98, i32 0, i32 %97
  %100 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.5, i32 noundef 0, i32 noundef 1, i32 noundef 2, i32 noundef 1, i32 noundef 11, i32 noundef 2, i32 noundef %99, i32 noundef 1)
  %101 = load i32, ptr @i, align 4, !tbaa !10
  %102 = tail call range(i32 0, 33) i32 @llvm.cttz.i32(i32 %101, i1 true)
  %103 = add nuw nsw i32 %102, 1
  %104 = icmp eq i32 %101, 0
  %105 = select i1 %104, i32 0, i32 %103
  %106 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.6, i32 noundef 0, i32 noundef 1, i32 noundef 2, i32 noundef 1, i32 noundef 11, i32 noundef 2, i32 noundef %105, i32 noundef 1)
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #2

; Function Attrs: mustprogress nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.ctlz.i32(i32, i1 immarg) #3

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.ctpop.i32(i32) #4

; Function Attrs: mustprogress nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.cttz.i32(i32, i1 immarg) #3

; Function Attrs: mustprogress nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.ctlz.i64(i64, i1 immarg) #3

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.ctpop.i64(i64) #4

; Function Attrs: nofree nounwind
declare noundef i32 @puts(ptr noundef readonly captures(none)) local_unnamed_addr #5

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { mustprogress nocallback nofree nosync nounwind speculatable willreturn memory(none) }
attributes #4 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #5 = { nofree nounwind }

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
!9 = !{!7, !7, i64 0}
!10 = !{!6, !6, i64 0}
!11 = distinct !{!11, !12}
!12 = !{!"llvm.loop.mustprogress"}
!13 = distinct !{!13, !12}
