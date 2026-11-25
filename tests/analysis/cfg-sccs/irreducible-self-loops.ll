; CFGSCCPrinterPass on an irreducible region, self loops and unreachable blocks (not visited by scc_iterator).
; @analysis: '-passes=print<cfg-sccs>'
define void @f(i1 %c, i1 %d) {
entry:
  br i1 %c, label %a, label %b
a:
  br i1 %d, label %b, label %a
b:
  br i1 %d, label %a, label %exit
exit:
  ret void
dead:
  br label %dead
}
define void @g() {
  ret void
}
