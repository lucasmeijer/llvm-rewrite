; @source: tests/lto/src/inline/dead_code/lib.c
; @opt: -passes='lto-pre-link<O2>'
; @generated: clang -O2 -flto -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/lto/src/inline/dead_code/lib.c'
source_filename = "tests/lto/src/inline/dead_code/lib.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [11 x i8] c"unused %s\0A\00", align 1
@lib_state = dso_local global i32 42, align 4
@unused_state = dso_local global <{ i32, i32, i32, [97 x i32] }> <{ i32 1, i32 2, i32 3, [97 x i32] zeroinitializer }>, align 16

; Function Attrs: nounwind uwtable
define dso_local i32 @used_value(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4, !tbaa !9
  %3 = load i32, ptr %2, align 4, !tbaa !9
  %4 = mul nsw i32 %3, 3
  %5 = add nsw i32 %4, 1
  ret i32 %5
}

; Function Attrs: nounwind uwtable
define dso_local i32 @unused_value(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4, !tbaa !9
  %3 = load i32, ptr %2, align 4, !tbaa !9
  %4 = load i32, ptr %2, align 4, !tbaa !9
  %5 = mul nsw i32 %3, %4
  %6 = load i32, ptr %2, align 4, !tbaa !9
  %7 = mul nsw i32 %5, %6
  %8 = sub nsw i32 %7, 7
  ret i32 %8
}

; Function Attrs: nounwind uwtable
define dso_local void @unused_print(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !10
  %3 = load ptr, ptr %2, align 8, !tbaa !10
  %4 = call i32 (ptr, ...) @printf(ptr noundef @.str, ptr noundef %3)
  ret void
}

declare i32 @printf(ptr noundef, ...) #1

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

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
!11 = !{!"p1 omnipotent char", !12, i64 0}
!12 = !{!"any pointer", !7, i64 0}
