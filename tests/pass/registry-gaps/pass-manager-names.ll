; PassRegistry.def names that only touch the pass manager: extension-point callbacks without registered callbacks,
; no-op and marker analyses, invalidate<all> at every level, no-op-loopnest, count-visits, instcount,
; extra-vector-passes, inliner-wrapper-no-mandatory-first, function-simplification<O#>.
; @opt: '-passes=pipeline-start-callbacks<O3>,function(peephole-callbacks<O2>),cgscc(cgscc-optimizer-late-callbacks<O1>),function(loop(loop-optimizer-end-callbacks<O2>))'
; @opt: '-passes=require<no-op-module>,require<callgraph>,require<inline-advisor>,require<ir-similarity>,function(require<no-op-function>,require<access-info>,require<ephemerals>,loop(require<no-op-loop>,require<should-run-extra-simple-loop-unswitch>))'
; @opt: '-passes=invalidate<all>,function(invalidate<all>,instsimplify),cgscc(invalidate<all>),function(loop(no-op-loopnest))'
; @opt: '-passes=function(count-visits,instcount,instcount<pre-opt>,extra-vector-passes)'
; @opt: -passes=inliner-wrapper-no-mandatory-first
; @opt: '-passes=function(function-simplification<O1>)'
; @opt: '-passes=function-simplification<O2>'
; @opt: '-passes=function-simplification<O3>'
target triple = "x86_64-unknown-linux-gnu"

define internal i32 @callee(i32 %x) alwaysinline {
  %a = add i32 %x, 1
  ret i32 %a
}

define i32 @caller(i32 %n) {
entry:
  %s = alloca i32
  store i32 0, ptr %s
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %i.next, %loop ]
  %v = load i32, ptr %s
  %w = call i32 @callee(i32 %v)
  store i32 %w, ptr %s
  %i.next = add i32 %i, 1
  %c = icmp slt i32 %i.next, %n
  br i1 %c, label %loop, label %exit
exit:
  %r = load i32, ptr %s
  ret i32 %r
}
