; @source: tests/e2e/src/memory/static_local_volatile.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/memory/static_local_volatile.c'
source_filename = "tests/e2e/src/memory/static_local_volatile.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [7 x i8] c"%d %d\0A\00", align 1
@next_id.id = internal unnamed_addr global i32 100, align 4

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = alloca i32, align 4
  call void @llvm.lifetime.start.p0(ptr nonnull %1)
  store volatile i32 3, ptr %1, align 4, !tbaa !9
  %2 = load i32, ptr @next_id.id, align 4
  %3 = load volatile i32, ptr %1, align 4, !tbaa !9
  %4 = shl nsw i32 %3, 1
  store volatile i32 %4, ptr %1, align 4, !tbaa !9
  %5 = load volatile i32, ptr %1, align 4, !tbaa !9
  %6 = load volatile i32, ptr %1, align 4, !tbaa !9
  %7 = shl nsw i32 %6, 1
  store volatile i32 %7, ptr %1, align 4, !tbaa !9
  %8 = load volatile i32, ptr %1, align 4, !tbaa !9
  %9 = load volatile i32, ptr %1, align 4, !tbaa !9
  %10 = shl nsw i32 %9, 1
  store volatile i32 %10, ptr %1, align 4, !tbaa !9
  %11 = load volatile i32, ptr %1, align 4, !tbaa !9
  %12 = load volatile i32, ptr %1, align 4, !tbaa !9
  %13 = shl nsw i32 %12, 1
  store volatile i32 %13, ptr %1, align 4, !tbaa !9
  %14 = load volatile i32, ptr %1, align 4, !tbaa !9
  %15 = load volatile i32, ptr %1, align 4, !tbaa !9
  %16 = shl nsw i32 %15, 1
  store volatile i32 %16, ptr %1, align 4, !tbaa !9
  %17 = add nsw i32 %2, 5
  store i32 %17, ptr @next_id.id, align 4, !tbaa !9
  %18 = load volatile i32, ptr %1, align 4, !tbaa !9
  %19 = mul i32 %2, 5
  %20 = add i32 %19, 10
  %21 = add i32 %20, %18
  %22 = add i32 %14, %11
  %23 = add i32 %8, %5
  %24 = add i32 %21, %22
  %25 = add i32 %24, %23
  %26 = load volatile i32, ptr %1, align 4, !tbaa !9
  %27 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %25, i32 noundef %26)
  call void @llvm.lifetime.end.p0(ptr nonnull %1)
  ret i32 0
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #2

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
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
!9 = !{!6, !6, i64 0}
