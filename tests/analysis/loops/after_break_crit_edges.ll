; break-crit-edges adds the blocks it creates to the cached LoopInfo (addBasicBlockToLoop) and updates the cached
; dominator tree with applyUpdates; both are preserved and printed.
; @analysis: -passes='require<loops>,break-crit-edges,print<loops>,print<domtree>'
define void @f(i1 %c, i1 %d, i1 %e) {
entry:
  br label %outer

outer:
  br label %inner

inner:
  br i1 %c, label %inner, label %latch

latch:
  br i1 %d, label %outer, label %exit

exit:
  br i1 %e, label %done, label %outer2

outer2:
  br i1 %d, label %outer2, label %done

done:
  ret void
}
