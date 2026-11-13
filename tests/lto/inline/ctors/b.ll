; @source: tests/lto/src/inline/ctors/b.c
; @opt: -passes='lto-pre-link<O2>'
; @generated: clang -O2 -flto -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/lto/src/inline/ctors/b.c'
source_filename = "tests/lto/src/inline/ctors/b.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [6 x i8] c"b %d\0A\00", align 1
@n_order = external global i32, align 4
@.str.1 = private unnamed_addr constant [7 x i8] c"b2 %d\0A\00", align 1
@.str.2 = private unnamed_addr constant [9 x i8] c"fini %d\0A\00", align 1
@llvm.global_ctors = appending global [2 x { i32, ptr, ptr }] [{ i32, ptr, ptr } { i32 200, ptr @init_b, ptr null }, { i32, ptr, ptr } { i32 101, ptr @init_b2, ptr null }]
@llvm.global_dtors = appending global [1 x { i32, ptr, ptr }] [{ i32, ptr, ptr } { i32 65535, ptr @fini_b, ptr null }]

; Function Attrs: nounwind uwtable
define internal void @init_b() #0 {
  %1 = load i32, ptr @n_order, align 4, !tbaa !9
  %2 = add nsw i32 %1, 1
  store i32 %2, ptr @n_order, align 4, !tbaa !9
  %3 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %1)
  ret void
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: nounwind uwtable
define internal void @init_b2() #0 {
  %1 = load i32, ptr @n_order, align 4, !tbaa !9
  %2 = add nsw i32 %1, 1
  store i32 %2, ptr @n_order, align 4, !tbaa !9
  %3 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %1)
  ret void
}

; Function Attrs: nounwind uwtable
define internal void @fini_b() #0 {
  %1 = load i32, ptr @n_order, align 4, !tbaa !9
  %2 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i32 noundef %1)
  ret void
}

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
