; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/byval-alignment.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/byval-alignment.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/byval-alignment.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.s0 = type { x86_fp80, x86_fp80 }

@g0 = dso_local local_unnamed_addr global %struct.s0 zeroinitializer, align 16
@__const.main.a = private unnamed_addr constant %struct.s0 { x86_fp80 1.000000e+00, x86_fp80 2.000000e+00 }, align 16
@.str = private unnamed_addr constant [24 x i8] c"g0.x: %.4f, g0.y: %.4f\0A\00", align 1

; Function Attrs: mustprogress nofree noinline norecurse nosync nounwind willreturn memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @f0(i32 noundef %0, ptr nofree noundef readonly byval(%struct.s0) align 16 captures(none) %1) local_unnamed_addr #0 {
  call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 16 dereferenceable(32) @g0, ptr noundef nonnull align 16 dereferenceable(32) %1, i64 32, i1 false), !tbaa.struct !9
  %3 = sitofp i32 %0 to x86_fp80
  %4 = load x86_fp80, ptr @g0, align 16, !tbaa !12
  %5 = fadd x86_fp80 %4, %3
  store x86_fp80 %5, ptr @g0, align 16, !tbaa !12
  %6 = load x86_fp80, ptr getelementptr inbounds nuw (i8, ptr @g0, i64 16), align 16, !tbaa !14
  %7 = fadd x86_fp80 %6, %3
  store x86_fp80 %7, ptr getelementptr inbounds nuw (i8, ptr @g0, i64 16), align 16, !tbaa !14
  ret void
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #2 {
  tail call void @f0(i32 noundef 1, ptr noundef nonnull byval(%struct.s0) align 16 @__const.main.a)
  %1 = load x86_fp80, ptr @g0, align 16, !tbaa !12
  %2 = fptrunc x86_fp80 %1 to double
  %3 = load x86_fp80, ptr getelementptr inbounds nuw (i8, ptr @g0, i64 16), align 16, !tbaa !14
  %4 = fptrunc x86_fp80 %3 to double
  %5 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %2, double noundef %4)
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #3

attributes #0 = { mustprogress nofree noinline norecurse nosync nounwind willreturn memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

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
!9 = !{i64 0, i64 16, !10, i64 16, i64 16, !10}
!10 = !{!11, !11, i64 0}
!11 = !{!"long double", !7, i64 0}
!12 = !{!13, !11, i64 0}
!13 = !{!"s0", !11, i64 0, !11, i64 16}
!14 = !{!13, !11, i64 16}
