; LoopAnalysis calls DominatorTree::updateDFSNumbers, so a dominator tree printed after print<loops> shows valid
; DFS numbers and no "DFSNumbers invalid" note.
; @analysis: -passes='print<loops>,print<domtree>'
define void @f(i1 %c, i1 %d) {
entry:
  br label %h

h:
  br i1 %c, label %body, label %exit

body:
  br i1 %d, label %h, label %side

side:
  br label %h

exit:
  ret void
}
