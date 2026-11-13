; LoopPeel clones the assume without registerAssumption, and the AssumptionCache is never invalidated, so
; drop-unnecessary-assumes (which only visits the cached assumptions) keeps the peeled copy. In the O2 pipeline the
; cache is scanned long before loop-unroll-full peels the loop.
; @opt: -passes='default<O2>'
define i32 @test2(i32 %arg, i1 %b) {
  br label %bb

bb:
  %a = phi i32 [ 1, %0 ], [ 2, %bb ]
  %cmp = icmp eq i32 %arg, %a
  call void @llvm.assume(i1 %cmp)
  br i1 %b, label %bb, label %end

end:
  %r = add i32 %arg, 0
  ret i32 %r
}
declare void @llvm.assume(i1)
