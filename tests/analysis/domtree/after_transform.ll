; The dominator tree after break-crit-edges updates it (the tree printed must reflect the split edges).
; @analysis: -passes='require<domtree>,break-crit-edges,print<domtree>'
define void @crit(i1 %a, i1 %b) {
entry:
  br i1 %a, label %x, label %y

x:
  br i1 %b, label %y, label %z

y:
  br label %z

z:
  ret void
}
