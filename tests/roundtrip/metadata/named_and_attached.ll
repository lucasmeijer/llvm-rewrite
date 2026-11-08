define i32 @f(ptr %p) !dbg_like !0 {
  %v = load i32, ptr %p, align 4, !tbaa !2, !range !6
  %c = icmp sgt i32 %v, 0
  br i1 %c, label %a, label %b, !prof !7
a:
  ret i32 %v
b:
  ret i32 0
}

!llvm.module.flags = !{!8, !9}
!llvm.ident = !{!10}

!0 = !{!"custom", i32 1}
!1 = !{!"omnipotent char", !3, i64 0}
!2 = !{!4, !4, i64 0}
!3 = !{!"Simple C/C++ TBAA"}
!4 = !{!"int", !1, i64 0}
!6 = !{i32 0, i32 100}
!7 = !{!"branch_weights", i32 1, i32 2000}
!8 = !{i32 1, !"wchar_size", i32 4}
!9 = !{i32 7, !"uwtable", i32 2}
!10 = !{!"clang version 23.1.5"}
