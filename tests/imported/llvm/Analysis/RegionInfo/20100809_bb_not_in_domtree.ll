; @origin: llvm/test/Analysis/RegionInfo/20100809_bb_not_in_domtree.ll (llvmorg-23.1.5)
; @analysis: '-passes=print<regions>'
; RUN: opt < %s -passes='print<regions>'

define i32 @main() nounwind {
entry:
  br label %for.cond

test:
  br label %for.cond

for.cond:                                         ; preds = %for.inc, %entry
  br i1 true, label %for.body, label %for.end

for.body:                                         ; preds = %for.cond
  br label %for.inc

for.inc:                                          ; preds = %for.body
  br label %for.cond

for.end:                                          ; preds = %for.cond
  ret i32 0
}
