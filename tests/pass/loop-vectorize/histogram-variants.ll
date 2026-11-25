; @opt: -passes=loop-vectorize -enable-histogram-loop-vectorization -force-vector-width=4
; @opt: -passes=loop-vectorize -enable-histogram-loop-vectorization -mtriple=x86_64-unknown-linux-gnu -mattr=+avx2
; @opt: -passes=loop-vectorize -enable-histogram-loop-vectorization -mtriple=x86_64-unknown-linux-gnu -mattr=+avx512f -force-vector-width=8
; @opt: -passes=loop-vectorize -enable-histogram-loop-vectorization -force-vector-width=4 -force-target-supports-masked-memory-ops -tail-folding-policy=must-fold-tail
; Histogram updates (buckets[indices[i]] op= inc) for loop-vectorize: a sub, a loop-invariant increment that is not
; one, a conditional update, i64 buckets with sext indices, and with and without a target.

define void @hist_sub(ptr noalias %buckets, ptr readonly %indices, i64 %N) {
entry:
  br label %for.body

for.body:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %for.body ]
  %gep.indices = getelementptr inbounds i32, ptr %indices, i64 %iv
  %l.idx = load i32, ptr %gep.indices, align 4
  %idxprom = zext i32 %l.idx to i64
  %gep.bucket = getelementptr inbounds i32, ptr %buckets, i64 %idxprom
  %l.bucket = load i32, ptr %gep.bucket, align 4
  %dec = sub nsw i32 %l.bucket, 1
  store i32 %dec, ptr %gep.bucket, align 4
  %iv.next = add nuw nsw i64 %iv, 1
  %exitcond = icmp eq i64 %iv.next, %N
  br i1 %exitcond, label %for.exit, label %for.body

for.exit:
  ret void
}

define void @hist_inc_var(ptr noalias %buckets, ptr readonly %indices, i64 %N, i32 %inc) {
entry:
  br label %for.body

for.body:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %for.body ]
  %gep.indices = getelementptr inbounds i32, ptr %indices, i64 %iv
  %l.idx = load i32, ptr %gep.indices, align 4
  %idxprom = sext i32 %l.idx to i64
  %gep.bucket = getelementptr inbounds i64, ptr %buckets, i64 %idxprom
  %l.bucket = load i64, ptr %gep.bucket, align 8
  %inc64 = zext i32 %inc to i64
  %add = add i64 %l.bucket, %inc64
  store i64 %add, ptr %gep.bucket, align 8
  %iv.next = add nuw nsw i64 %iv, 1
  %exitcond = icmp eq i64 %iv.next, %N
  br i1 %exitcond, label %for.exit, label %for.body

for.exit:
  ret void
}

define void @hist_inc_const(ptr noalias %buckets, ptr readonly %indices, i64 %N) {
entry:
  br label %for.body

for.body:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %for.body ]
  %gep.indices = getelementptr inbounds i32, ptr %indices, i64 %iv
  %l.idx = load i32, ptr %gep.indices, align 4
  %idxprom = zext i32 %l.idx to i64
  %gep.bucket = getelementptr inbounds i32, ptr %buckets, i64 %idxprom
  %l.bucket = load i32, ptr %gep.bucket, align 4
  %add = add i32 %l.bucket, 7
  store i32 %add, ptr %gep.bucket, align 4
  %iv.next = add nuw nsw i64 %iv, 1
  %exitcond = icmp eq i64 %iv.next, %N
  br i1 %exitcond, label %for.exit, label %for.body

for.exit:
  ret void
}

define void @hist_conditional(ptr noalias %buckets, ptr readonly %indices, ptr readonly %conds, i64 %N) {
entry:
  br label %for.body

for.body:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %for.latch ]
  %gep.cond = getelementptr inbounds i32, ptr %conds, i64 %iv
  %c = load i32, ptr %gep.cond, align 4
  %tobool = icmp eq i32 %c, 0
  br i1 %tobool, label %for.latch, label %if.then

if.then:
  %gep.indices = getelementptr inbounds i32, ptr %indices, i64 %iv
  %l.idx = load i32, ptr %gep.indices, align 4
  %idxprom = zext i32 %l.idx to i64
  %gep.bucket = getelementptr inbounds i32, ptr %buckets, i64 %idxprom
  %l.bucket = load i32, ptr %gep.bucket, align 4
  %inc = add nsw i32 %l.bucket, 1
  store i32 %inc, ptr %gep.bucket, align 4
  br label %for.latch

for.latch:
  %iv.next = add nuw nsw i64 %iv, 1
  %exitcond = icmp eq i64 %iv.next, %N
  br i1 %exitcond, label %for.exit, label %for.body

for.exit:
  ret void
}
