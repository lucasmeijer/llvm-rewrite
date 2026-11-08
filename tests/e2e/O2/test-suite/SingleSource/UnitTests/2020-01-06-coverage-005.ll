; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-005.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-005.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-005.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@b = dso_local global i64 0, align 8
@r = dso_local local_unnamed_addr global ptr null, align 8
@s = dso_local local_unnamed_addr global ptr null, align 8
@p = dso_local local_unnamed_addr global ptr null, align 8
@e = dso_local global i16 0, align 2
@t = dso_local local_unnamed_addr global ptr null, align 8
@q = dso_local local_unnamed_addr global ptr null, align 8
@c = dso_local local_unnamed_addr global i32 0, align 4
@d = dso_local local_unnamed_addr global i32 0, align 4
@a = dso_local local_unnamed_addr global i32 0, align 4
@.str = private unnamed_addr constant [8 x i8] c"a = %u\0A\00", align 1
@.str.1 = private unnamed_addr constant [9 x i8] c"b = %lu\0A\00", align 1
@.str.2 = private unnamed_addr constant [8 x i8] c"c = %u\0A\00", align 1
@.str.3 = private unnamed_addr constant [8 x i8] c"d = %u\0A\00", align 1
@.str.4 = private unnamed_addr constant [9 x i8] c"e = %hi\0A\00", align 1

; Function Attrs: nofree norecurse nosync nounwind memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @h() local_unnamed_addr #0 {
  store ptr @b, ptr @r, align 8, !tbaa !9
  store ptr @b, ptr @s, align 8, !tbaa !9
  store ptr @b, ptr @p, align 8, !tbaa !9
  store ptr @e, ptr @t, align 8, !tbaa !12
  store ptr @e, ptr @q, align 8, !tbaa !12
  %1 = load i32, ptr @c, align 4, !tbaa !14
  %2 = load i32, ptr @d, align 4, !tbaa !14
  %3 = icmp eq i32 %2, 0
  %4 = and i32 %1, 6
  %5 = zext nneg i32 %4 to i64
  br i1 %3, label %8, label %6

6:                                                ; preds = %0
  store i16 0, ptr @e, align 2, !tbaa !15
  store i64 %5, ptr @b, align 8, !tbaa !17
  store i32 %2, ptr @a, align 4, !tbaa !14
  br label %7

7:                                                ; preds = %7, %6
  br label %7

8:                                                ; preds = %0
  %9 = load i16, ptr @e, align 2, !tbaa !15
  %10 = add i16 %9, -1
  store i16 %10, ptr @e, align 2, !tbaa !15
  store i64 %5, ptr @b, align 8, !tbaa !17
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @g() local_unnamed_addr #0 {
  store ptr @b, ptr @s, align 8, !tbaa !9
  store ptr @b, ptr @p, align 8, !tbaa !9
  store ptr @e, ptr @t, align 8, !tbaa !12
  store ptr @e, ptr @q, align 8, !tbaa !12
  %1 = load i32, ptr @c, align 4, !tbaa !14
  %2 = zext i32 %1 to i64
  %3 = load i32, ptr @d, align 4, !tbaa !14
  %4 = icmp eq i32 %3, 0
  %5 = load i64, ptr @b, align 8, !tbaa !17
  %6 = and i64 %5, %2
  br i1 %4, label %9, label %7

7:                                                ; preds = %0
  store i16 0, ptr @e, align 2, !tbaa !15
  store i64 %6, ptr @b, align 8, !tbaa !17
  store i32 %3, ptr @a, align 4, !tbaa !14
  br label %8

8:                                                ; preds = %7, %8
  br label %8

9:                                                ; preds = %0
  %10 = load i16, ptr @e, align 2, !tbaa !15
  %11 = add i16 %10, -1
  store i16 %11, ptr @e, align 2, !tbaa !15
  store i64 %6, ptr @b, align 8, !tbaa !17
  ret void
}

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #1 {
  store i32 0, ptr @d, align 4, !tbaa !14
  store i32 -6, ptr @c, align 4, !tbaa !14
  store i32 16777101, ptr @a, align 4, !tbaa !14
  store ptr @b, ptr @r, align 8, !tbaa !9
  store ptr @b, ptr @s, align 8, !tbaa !9
  store ptr @b, ptr @p, align 8, !tbaa !9
  store ptr @e, ptr @t, align 8, !tbaa !12
  store ptr @e, ptr @q, align 8, !tbaa !12
  store i16 -9, ptr @e, align 2, !tbaa !15
  store i64 2, ptr @b, align 8, !tbaa !17
  %1 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef 16777101)
  %2 = load i64, ptr @b, align 8, !tbaa !17
  %3 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i64 noundef %2)
  %4 = load i32, ptr @c, align 4, !tbaa !14
  %5 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.2, i32 noundef %4)
  %6 = load i32, ptr @d, align 4, !tbaa !14
  %7 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.3, i32 noundef %6)
  %8 = load i16, ptr @e, align 2, !tbaa !15
  %9 = sext i16 %8 to i32
  %10 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.4, i32 noundef %9)
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #2

attributes #0 = { nofree norecurse nosync nounwind memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

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
!10 = !{!"p1 long", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!13, !13, i64 0}
!13 = !{!"p1 short", !11, i64 0}
!14 = !{!6, !6, i64 0}
!15 = !{!16, !16, i64 0}
!16 = !{!"short", !7, i64 0}
!17 = !{!18, !18, i64 0}
!18 = !{!"long", !7, i64 0}
