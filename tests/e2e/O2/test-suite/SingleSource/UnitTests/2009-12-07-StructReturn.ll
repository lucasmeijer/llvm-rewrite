; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2009-12-07-StructReturn.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2009-12-07-StructReturn.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2009-12-07-StructReturn.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.barstruct = type { %struct.foostruct, float }
%struct.foostruct = type { [3 x float] }

@bar_ary = dso_local global [4 x %struct.barstruct] zeroinitializer, align 16
@str = private unnamed_addr constant [50 x i8] c"error: store clobbered memory outside destination\00", align 1

; Function Attrs: mustprogress nofree noinline norecurse nosync nounwind willreturn memory(write, argmem: none, inaccessiblemem: none, target_mem: none) uwtable
define dso_local noundef nonnull ptr @spooky(i32 noundef %0) local_unnamed_addr #0 {
  %2 = sext i32 %0 to i64
  %3 = getelementptr inbounds [16 x i8], ptr @bar_ary, i64 %2
  %4 = getelementptr inbounds nuw i8, ptr %3, i64 12
  store float 1.420000e+02, ptr %4, align 4, !tbaa !9
  ret ptr %4
}

; Function Attrs: mustprogress nofree noinline norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local { <2 x float>, float } @foobify() local_unnamed_addr #1 {
  ret { <2 x float>, float } { <2 x float> splat (float 4.200000e+01), float 4.200000e+01 }
}

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main(i32 noundef %0, ptr nofree noundef readnone captures(none) %1) local_unnamed_addr #2 {
  %3 = tail call ptr @spooky(i32 noundef 0)
  %4 = tail call { <2 x float>, float } @foobify()
  %5 = extractvalue { <2 x float>, float } %4, 0
  %6 = extractvalue { <2 x float>, float } %4, 1
  store <2 x float> %5, ptr @bar_ary, align 16
  store float %6, ptr getelementptr inbounds nuw (i8, ptr @bar_ary, i64 8), align 8, !tbaa !13
  %7 = load float, ptr %3, align 4, !tbaa !14
  %8 = fcmp une float %7, 1.420000e+02
  br i1 %8, label %9, label %11

9:                                                ; preds = %2
  %10 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str)
  tail call void @abort() #5
  unreachable

11:                                               ; preds = %2
  ret i32 0
}

; Function Attrs: cold nofree noreturn nounwind
declare void @abort() local_unnamed_addr #3

; Function Attrs: nofree nounwind
declare noundef i32 @puts(ptr noundef readonly captures(none)) local_unnamed_addr #4

attributes #0 = { mustprogress nofree noinline norecurse nosync nounwind willreturn memory(write, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nofree noinline norecurse nosync nounwind willreturn memory(none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nofree nounwind uwtable "min-legal-vector-width"="64" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { cold nofree noreturn nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nofree nounwind }
attributes #5 = { noreturn nounwind }

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
!9 = !{!10, !12, i64 12}
!10 = !{!"", !11, i64 0, !12, i64 12}
!11 = !{!"", !7, i64 0}
!12 = !{!"float", !7, i64 0}
!13 = !{!7, !7, i64 0}
!14 = !{!12, !12, i64 0}
