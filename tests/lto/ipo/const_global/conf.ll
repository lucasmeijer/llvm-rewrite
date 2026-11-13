; @source: tests/lto/src/ipo/const_global/conf.c
; @opt: -passes='lto-pre-link<O2>'
; @generated: clang -O2 -flto -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/lto/src/ipo/const_global/conf.c'
source_filename = "tests/lto/src/ipo/const_global/conf.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@mode = dso_local global i32 2, align 4
@calls = internal global i32 0, align 4

; Function Attrs: nounwind uwtable
define dso_local i32 @get_mode() #0 {
  %1 = load i32, ptr @calls, align 4, !tbaa !9
  %2 = add nsw i32 %1, 1
  store i32 %2, ptr @calls, align 4, !tbaa !9
  %3 = load i32, ptr @mode, align 4, !tbaa !9
  ret i32 %3
}

; Function Attrs: nounwind uwtable
define dso_local i32 @get_calls() #0 {
  %1 = load i32, ptr @calls, align 4, !tbaa !9
  ret i32 %1
}

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

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
