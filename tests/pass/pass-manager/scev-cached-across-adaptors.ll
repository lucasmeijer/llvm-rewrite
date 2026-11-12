; Function analyses persist across function adaptors (FunctionAnalysisManager): the ScalarEvolution of @f0,
; kept up to date by indvars, is reused by loop-unroll in the second adaptor after @f1 had its own. A fresh
; ScalarEvolution gives a different trip count (and output). Functions from
; llvm/test/Analysis/ScalarEvolution/solve-quadratic-i1.ll.
; @opt: -passes='function(loop(indvars,loop-deletion)),function(loop-unroll<O2>)'
target triple = "x86_64-unknown-linux-gnu"

define void @f0() {
b0:
  br label %b1

b1:                                               ; preds = %b1, %b0
  %v0 = phi i16 [ 2, %b0 ], [ %v2, %b1 ]
  %v1 = phi i16 [ 1, %b0 ], [ %v3, %b1 ]
  %v2 = add nsw i16 %v0, 1
  %v3 = add nsw i16 %v1, %v0
  %v4 = and i16 %v3, 1
  %v5 = icmp ne i16 %v4, 0
  br i1 %v5, label %b1, label %b2

b2:                                               ; preds = %b1
  ret void
}

@g0 = common dso_local global i16 0, align 2
@g1 = common dso_local global i32 0, align 4
@g2 = common dso_local global ptr null, align 8

define void @f1() #0 {
b0:
  store i16 0, ptr @g0, align 2
  store ptr @g1, ptr @g2, align 8
  br label %b1

b1:                                               ; preds = %b1, %b0
  %v0 = phi i16 [ 0, %b0 ], [ %v3, %b1 ]
  %v1 = phi i32 [ 3, %b0 ], [ %v6, %b1 ]
  %v2 = trunc i32 %v1 to i16
  %v3 = add i16 %v0, %v2
  %v4 = and i16 %v3, 1
  %v5 = icmp eq i16 %v4, 0
  %v6 = add nuw nsw i32 %v1, 1
  br i1 %v5, label %b2, label %b1

b2:                                               ; preds = %b1
  %v7 = phi i32 [ %v1, %b1 ]
  %v8 = phi i16 [ %v3, %b1 ]
  store i32 %v7, ptr @g1, align 4
  store i16 %v8, ptr @g0, align 2
  br label %b3

b3:                                               ; preds = %b3, %b2
  br label %b3
}

attributes #0 = { nounwind uwtable "target-cpu"="x86-64" }
