; @perf-size: 500
; @opt: -passes=loop-rotate
; @opt: -passes=licm
; @opt: -O2
; @perf: opt
; @perf: opt -passes=loop-rotate
; @perf: opt -passes=licm
; @perf: opt -O2
; @generated: harness/run gen-perf, shape 'loops', n=500
define i64 @f(ptr %p, i64 %len) {
entry:
  br label %h0
h0:
  %i0 = phi i64 [ 0, %entry ], [ %i0.n, %h0 ]
  %acc0 = phi i64 [ 0, %entry ], [ %acc0.n, %h0 ]
  %g0 = getelementptr inbounds i64, ptr %p, i64 %i0
  %v0 = load i64, ptr %g0, align 8
  %w0 = mul i64 %v0, 3
  %acc0.n = add i64 %acc0, %w0
  %i0.n = add nuw nsw i64 %i0, 1
  %c0 = icmp ult i64 %i0.n, %len
  br i1 %c0, label %h0, label %x0
x0:
  %acc0.out = phi i64 [ %acc0.n, %h0 ]
  br label %h1
h1:
  %i1 = phi i64 [ 0, %x0 ], [ %i1.n, %h1 ]
  %acc1 = phi i64 [ %acc0.out, %x0 ], [ %acc1.n, %h1 ]
  %g1 = getelementptr inbounds i64, ptr %p, i64 %i1
  %v1 = load i64, ptr %g1, align 8
  %w1 = mul i64 %v1, 4
  %acc1.n = add i64 %acc1, %w1
  %i1.n = add nuw nsw i64 %i1, 1
  %c1 = icmp ult i64 %i1.n, %len
  br i1 %c1, label %h1, label %x1
x1:
  %acc1.out = phi i64 [ %acc1.n, %h1 ]
  br label %h2
h2:
  %i2 = phi i64 [ 0, %x1 ], [ %i2.n, %h2 ]
  %acc2 = phi i64 [ %acc1.out, %x1 ], [ %acc2.n, %h2 ]
  %g2 = getelementptr inbounds i64, ptr %p, i64 %i2
  %v2 = load i64, ptr %g2, align 8
  %w2 = mul i64 %v2, 5
  %acc2.n = add i64 %acc2, %w2
  %i2.n = add nuw nsw i64 %i2, 1
  %c2 = icmp ult i64 %i2.n, %len
  br i1 %c2, label %h2, label %x2
x2:
  %acc2.out = phi i64 [ %acc2.n, %h2 ]
  br label %h3
h3:
  %i3 = phi i64 [ 0, %x2 ], [ %i3.n, %h3 ]
  %acc3 = phi i64 [ %acc2.out, %x2 ], [ %acc3.n, %h3 ]
  %g3 = getelementptr inbounds i64, ptr %p, i64 %i3
  %v3 = load i64, ptr %g3, align 8
  %w3 = mul i64 %v3, 6
  %acc3.n = add i64 %acc3, %w3
  %i3.n = add nuw nsw i64 %i3, 1
  %c3 = icmp ult i64 %i3.n, %len
  br i1 %c3, label %h3, label %x3
x3:
  %acc3.out = phi i64 [ %acc3.n, %h3 ]
  br label %h4
h4:
  %i4 = phi i64 [ 0, %x3 ], [ %i4.n, %h4 ]
  %acc4 = phi i64 [ %acc3.out, %x3 ], [ %acc4.n, %h4 ]
  %g4 = getelementptr inbounds i64, ptr %p, i64 %i4
  %v4 = load i64, ptr %g4, align 8
  %w4 = mul i64 %v4, 7
  %acc4.n = add i64 %acc4, %w4
  %i4.n = add nuw nsw i64 %i4, 1
  %c4 = icmp ult i64 %i4.n, %len
  br i1 %c4, label %h4, label %x4
x4:
  %acc4.out = phi i64 [ %acc4.n, %h4 ]
  br label %h5
h5:
  %i5 = phi i64 [ 0, %x4 ], [ %i5.n, %h5 ]
  %acc5 = phi i64 [ %acc4.out, %x4 ], [ %acc5.n, %h5 ]
  %g5 = getelementptr inbounds i64, ptr %p, i64 %i5
  %v5 = load i64, ptr %g5, align 8
  %w5 = mul i64 %v5, 8
  %acc5.n = add i64 %acc5, %w5
  %i5.n = add nuw nsw i64 %i5, 1
  %c5 = icmp ult i64 %i5.n, %len
  br i1 %c5, label %h5, label %x5
x5:
  %acc5.out = phi i64 [ %acc5.n, %h5 ]
  br label %h6
h6:
  %i6 = phi i64 [ 0, %x5 ], [ %i6.n, %h6 ]
  %acc6 = phi i64 [ %acc5.out, %x5 ], [ %acc6.n, %h6 ]
  %g6 = getelementptr inbounds i64, ptr %p, i64 %i6
  %v6 = load i64, ptr %g6, align 8
  %w6 = mul i64 %v6, 9
  %acc6.n = add i64 %acc6, %w6
  %i6.n = add nuw nsw i64 %i6, 1
  %c6 = icmp ult i64 %i6.n, %len
  br i1 %c6, label %h6, label %x6
x6:
  %acc6.out = phi i64 [ %acc6.n, %h6 ]
  br label %h7
h7:
  %i7 = phi i64 [ 0, %x6 ], [ %i7.n, %h7 ]
  %acc7 = phi i64 [ %acc6.out, %x6 ], [ %acc7.n, %h7 ]
  %g7 = getelementptr inbounds i64, ptr %p, i64 %i7
  %v7 = load i64, ptr %g7, align 8
  %w7 = mul i64 %v7, 10
  %acc7.n = add i64 %acc7, %w7
  %i7.n = add nuw nsw i64 %i7, 1
  %c7 = icmp ult i64 %i7.n, %len
  br i1 %c7, label %h7, label %x7
x7:
  %acc7.out = phi i64 [ %acc7.n, %h7 ]
  br label %h8
h8:
  %i8 = phi i64 [ 0, %x7 ], [ %i8.n, %h8 ]
  %acc8 = phi i64 [ %acc7.out, %x7 ], [ %acc8.n, %h8 ]
  %g8 = getelementptr inbounds i64, ptr %p, i64 %i8
  %v8 = load i64, ptr %g8, align 8
  %w8 = mul i64 %v8, 11
  %acc8.n = add i64 %acc8, %w8
  %i8.n = add nuw nsw i64 %i8, 1
  %c8 = icmp ult i64 %i8.n, %len
  br i1 %c8, label %h8, label %x8
x8:
  %acc8.out = phi i64 [ %acc8.n, %h8 ]
  br label %h9
h9:
  %i9 = phi i64 [ 0, %x8 ], [ %i9.n, %h9 ]
  %acc9 = phi i64 [ %acc8.out, %x8 ], [ %acc9.n, %h9 ]
  %g9 = getelementptr inbounds i64, ptr %p, i64 %i9
  %v9 = load i64, ptr %g9, align 8
  %w9 = mul i64 %v9, 12
  %acc9.n = add i64 %acc9, %w9
  %i9.n = add nuw nsw i64 %i9, 1
  %c9 = icmp ult i64 %i9.n, %len
  br i1 %c9, label %h9, label %x9
x9:
  %acc9.out = phi i64 [ %acc9.n, %h9 ]
  ret i64 %acc9.out
}
