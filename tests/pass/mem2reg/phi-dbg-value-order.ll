; The dbg_values for promoted phis go at the head of the first insertion point's records (getFirstInsertionPt has
; the head bit), so they come out in reverse phi order.
; @opt: -passes=mem2reg
; @opt: -passes=sroa
define i32 @f(i32 %n) !dbg !5 {
entry:
  %a = alloca i32
  %b = alloca i32
    #dbg_declare(ptr %a, !10, !DIExpression(), !11)
    #dbg_declare(ptr %b, !12, !DIExpression(), !11)
  store i32 0, ptr %a
  store i32 0, ptr %b
  br label %loop
loop:
  %x = load i32, ptr %a
  %y = load i32, ptr %b
  %x1 = add i32 %x, 1
  %y1 = add i32 %y, %x
  store i32 %x1, ptr %a
  store i32 %y1, ptr %b
  %c = icmp slt i32 %x1, %n
  br i1 %c, label %loop, label %exit
exit:
  ret i32 %y1
}
!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!3}
!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, emissionKind: FullDebug)
!1 = !DIFile(filename: "a.c", directory: "/")
!3 = !{i32 2, !"Debug Info Version", i32 3}
!5 = distinct !DISubprogram(name: "f", scope: !1, file: !1, line: 1, type: !6, unit: !0, spFlags: DISPFlagDefinition)
!6 = !DISubroutineType(types: !7)
!7 = !{null}
!10 = !DILocalVariable(name: "a", scope: !5, file: !1, line: 1, type: !13)
!12 = !DILocalVariable(name: "b", scope: !5, file: !1, line: 1, type: !13)
!11 = !DILocation(line: 1, scope: !5)
!13 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
