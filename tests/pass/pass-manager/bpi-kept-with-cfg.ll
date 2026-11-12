; BranchProbabilityInfo is kept by every pass that preserves CFGAnalyses (BranchProbabilityInfo::invalidate),
; even when the branch condition changes: instcombine turns `icmp sgt 0, %x` (no heuristic, 50%) into
; `icmp slt %x, 0` (zero heuristic), but print<branch-prob> in the last adaptor prints the cached result.
; @analysis: -passes='function(require<branch-prob>),function(instcombine),function(print<branch-prob>)'

define i32 @f(i32 %x) {
entry:
  %c = icmp sgt i32 0, %x
  br i1 %c, label %neg, label %done

neg:
  br label %done

done:
  %r = phi i32 [ 1, %neg ], [ 0, %entry ]
  ret i32 %r
}

define i32 @g(i32 %x) {
entry:
  %c = icmp sgt i32 0, %x
  br i1 %c, label %neg, label %done

neg:
  br label %done

done:
  %r = phi i32 [ 1, %neg ], [ 0, %entry ]
  ret i32 %r
}
