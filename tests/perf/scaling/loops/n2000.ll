; @perf-size: 2000
; @opt: -passes=loop-rotate
; @opt: -passes=licm
; @opt: -O2
; @perf: opt
; @perf: opt -passes=loop-rotate
; @perf: opt -passes=licm
; @perf: opt -O2
; @generated: harness/run gen-perf, shape 'loops', n=2000
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
  br label %h10
h10:
  %i10 = phi i64 [ 0, %x9 ], [ %i10.n, %h10 ]
  %acc10 = phi i64 [ %acc9.out, %x9 ], [ %acc10.n, %h10 ]
  %g10 = getelementptr inbounds i64, ptr %p, i64 %i10
  %v10 = load i64, ptr %g10, align 8
  %w10 = mul i64 %v10, 13
  %acc10.n = add i64 %acc10, %w10
  %i10.n = add nuw nsw i64 %i10, 1
  %c10 = icmp ult i64 %i10.n, %len
  br i1 %c10, label %h10, label %x10
x10:
  %acc10.out = phi i64 [ %acc10.n, %h10 ]
  br label %h11
h11:
  %i11 = phi i64 [ 0, %x10 ], [ %i11.n, %h11 ]
  %acc11 = phi i64 [ %acc10.out, %x10 ], [ %acc11.n, %h11 ]
  %g11 = getelementptr inbounds i64, ptr %p, i64 %i11
  %v11 = load i64, ptr %g11, align 8
  %w11 = mul i64 %v11, 14
  %acc11.n = add i64 %acc11, %w11
  %i11.n = add nuw nsw i64 %i11, 1
  %c11 = icmp ult i64 %i11.n, %len
  br i1 %c11, label %h11, label %x11
x11:
  %acc11.out = phi i64 [ %acc11.n, %h11 ]
  br label %h12
h12:
  %i12 = phi i64 [ 0, %x11 ], [ %i12.n, %h12 ]
  %acc12 = phi i64 [ %acc11.out, %x11 ], [ %acc12.n, %h12 ]
  %g12 = getelementptr inbounds i64, ptr %p, i64 %i12
  %v12 = load i64, ptr %g12, align 8
  %w12 = mul i64 %v12, 15
  %acc12.n = add i64 %acc12, %w12
  %i12.n = add nuw nsw i64 %i12, 1
  %c12 = icmp ult i64 %i12.n, %len
  br i1 %c12, label %h12, label %x12
x12:
  %acc12.out = phi i64 [ %acc12.n, %h12 ]
  br label %h13
h13:
  %i13 = phi i64 [ 0, %x12 ], [ %i13.n, %h13 ]
  %acc13 = phi i64 [ %acc12.out, %x12 ], [ %acc13.n, %h13 ]
  %g13 = getelementptr inbounds i64, ptr %p, i64 %i13
  %v13 = load i64, ptr %g13, align 8
  %w13 = mul i64 %v13, 16
  %acc13.n = add i64 %acc13, %w13
  %i13.n = add nuw nsw i64 %i13, 1
  %c13 = icmp ult i64 %i13.n, %len
  br i1 %c13, label %h13, label %x13
x13:
  %acc13.out = phi i64 [ %acc13.n, %h13 ]
  br label %h14
h14:
  %i14 = phi i64 [ 0, %x13 ], [ %i14.n, %h14 ]
  %acc14 = phi i64 [ %acc13.out, %x13 ], [ %acc14.n, %h14 ]
  %g14 = getelementptr inbounds i64, ptr %p, i64 %i14
  %v14 = load i64, ptr %g14, align 8
  %w14 = mul i64 %v14, 17
  %acc14.n = add i64 %acc14, %w14
  %i14.n = add nuw nsw i64 %i14, 1
  %c14 = icmp ult i64 %i14.n, %len
  br i1 %c14, label %h14, label %x14
x14:
  %acc14.out = phi i64 [ %acc14.n, %h14 ]
  br label %h15
h15:
  %i15 = phi i64 [ 0, %x14 ], [ %i15.n, %h15 ]
  %acc15 = phi i64 [ %acc14.out, %x14 ], [ %acc15.n, %h15 ]
  %g15 = getelementptr inbounds i64, ptr %p, i64 %i15
  %v15 = load i64, ptr %g15, align 8
  %w15 = mul i64 %v15, 18
  %acc15.n = add i64 %acc15, %w15
  %i15.n = add nuw nsw i64 %i15, 1
  %c15 = icmp ult i64 %i15.n, %len
  br i1 %c15, label %h15, label %x15
x15:
  %acc15.out = phi i64 [ %acc15.n, %h15 ]
  br label %h16
h16:
  %i16 = phi i64 [ 0, %x15 ], [ %i16.n, %h16 ]
  %acc16 = phi i64 [ %acc15.out, %x15 ], [ %acc16.n, %h16 ]
  %g16 = getelementptr inbounds i64, ptr %p, i64 %i16
  %v16 = load i64, ptr %g16, align 8
  %w16 = mul i64 %v16, 19
  %acc16.n = add i64 %acc16, %w16
  %i16.n = add nuw nsw i64 %i16, 1
  %c16 = icmp ult i64 %i16.n, %len
  br i1 %c16, label %h16, label %x16
x16:
  %acc16.out = phi i64 [ %acc16.n, %h16 ]
  br label %h17
h17:
  %i17 = phi i64 [ 0, %x16 ], [ %i17.n, %h17 ]
  %acc17 = phi i64 [ %acc16.out, %x16 ], [ %acc17.n, %h17 ]
  %g17 = getelementptr inbounds i64, ptr %p, i64 %i17
  %v17 = load i64, ptr %g17, align 8
  %w17 = mul i64 %v17, 20
  %acc17.n = add i64 %acc17, %w17
  %i17.n = add nuw nsw i64 %i17, 1
  %c17 = icmp ult i64 %i17.n, %len
  br i1 %c17, label %h17, label %x17
x17:
  %acc17.out = phi i64 [ %acc17.n, %h17 ]
  br label %h18
h18:
  %i18 = phi i64 [ 0, %x17 ], [ %i18.n, %h18 ]
  %acc18 = phi i64 [ %acc17.out, %x17 ], [ %acc18.n, %h18 ]
  %g18 = getelementptr inbounds i64, ptr %p, i64 %i18
  %v18 = load i64, ptr %g18, align 8
  %w18 = mul i64 %v18, 21
  %acc18.n = add i64 %acc18, %w18
  %i18.n = add nuw nsw i64 %i18, 1
  %c18 = icmp ult i64 %i18.n, %len
  br i1 %c18, label %h18, label %x18
x18:
  %acc18.out = phi i64 [ %acc18.n, %h18 ]
  br label %h19
h19:
  %i19 = phi i64 [ 0, %x18 ], [ %i19.n, %h19 ]
  %acc19 = phi i64 [ %acc18.out, %x18 ], [ %acc19.n, %h19 ]
  %g19 = getelementptr inbounds i64, ptr %p, i64 %i19
  %v19 = load i64, ptr %g19, align 8
  %w19 = mul i64 %v19, 22
  %acc19.n = add i64 %acc19, %w19
  %i19.n = add nuw nsw i64 %i19, 1
  %c19 = icmp ult i64 %i19.n, %len
  br i1 %c19, label %h19, label %x19
x19:
  %acc19.out = phi i64 [ %acc19.n, %h19 ]
  br label %h20
h20:
  %i20 = phi i64 [ 0, %x19 ], [ %i20.n, %h20 ]
  %acc20 = phi i64 [ %acc19.out, %x19 ], [ %acc20.n, %h20 ]
  %g20 = getelementptr inbounds i64, ptr %p, i64 %i20
  %v20 = load i64, ptr %g20, align 8
  %w20 = mul i64 %v20, 23
  %acc20.n = add i64 %acc20, %w20
  %i20.n = add nuw nsw i64 %i20, 1
  %c20 = icmp ult i64 %i20.n, %len
  br i1 %c20, label %h20, label %x20
x20:
  %acc20.out = phi i64 [ %acc20.n, %h20 ]
  br label %h21
h21:
  %i21 = phi i64 [ 0, %x20 ], [ %i21.n, %h21 ]
  %acc21 = phi i64 [ %acc20.out, %x20 ], [ %acc21.n, %h21 ]
  %g21 = getelementptr inbounds i64, ptr %p, i64 %i21
  %v21 = load i64, ptr %g21, align 8
  %w21 = mul i64 %v21, 24
  %acc21.n = add i64 %acc21, %w21
  %i21.n = add nuw nsw i64 %i21, 1
  %c21 = icmp ult i64 %i21.n, %len
  br i1 %c21, label %h21, label %x21
x21:
  %acc21.out = phi i64 [ %acc21.n, %h21 ]
  br label %h22
h22:
  %i22 = phi i64 [ 0, %x21 ], [ %i22.n, %h22 ]
  %acc22 = phi i64 [ %acc21.out, %x21 ], [ %acc22.n, %h22 ]
  %g22 = getelementptr inbounds i64, ptr %p, i64 %i22
  %v22 = load i64, ptr %g22, align 8
  %w22 = mul i64 %v22, 25
  %acc22.n = add i64 %acc22, %w22
  %i22.n = add nuw nsw i64 %i22, 1
  %c22 = icmp ult i64 %i22.n, %len
  br i1 %c22, label %h22, label %x22
x22:
  %acc22.out = phi i64 [ %acc22.n, %h22 ]
  br label %h23
h23:
  %i23 = phi i64 [ 0, %x22 ], [ %i23.n, %h23 ]
  %acc23 = phi i64 [ %acc22.out, %x22 ], [ %acc23.n, %h23 ]
  %g23 = getelementptr inbounds i64, ptr %p, i64 %i23
  %v23 = load i64, ptr %g23, align 8
  %w23 = mul i64 %v23, 26
  %acc23.n = add i64 %acc23, %w23
  %i23.n = add nuw nsw i64 %i23, 1
  %c23 = icmp ult i64 %i23.n, %len
  br i1 %c23, label %h23, label %x23
x23:
  %acc23.out = phi i64 [ %acc23.n, %h23 ]
  br label %h24
h24:
  %i24 = phi i64 [ 0, %x23 ], [ %i24.n, %h24 ]
  %acc24 = phi i64 [ %acc23.out, %x23 ], [ %acc24.n, %h24 ]
  %g24 = getelementptr inbounds i64, ptr %p, i64 %i24
  %v24 = load i64, ptr %g24, align 8
  %w24 = mul i64 %v24, 27
  %acc24.n = add i64 %acc24, %w24
  %i24.n = add nuw nsw i64 %i24, 1
  %c24 = icmp ult i64 %i24.n, %len
  br i1 %c24, label %h24, label %x24
x24:
  %acc24.out = phi i64 [ %acc24.n, %h24 ]
  br label %h25
h25:
  %i25 = phi i64 [ 0, %x24 ], [ %i25.n, %h25 ]
  %acc25 = phi i64 [ %acc24.out, %x24 ], [ %acc25.n, %h25 ]
  %g25 = getelementptr inbounds i64, ptr %p, i64 %i25
  %v25 = load i64, ptr %g25, align 8
  %w25 = mul i64 %v25, 28
  %acc25.n = add i64 %acc25, %w25
  %i25.n = add nuw nsw i64 %i25, 1
  %c25 = icmp ult i64 %i25.n, %len
  br i1 %c25, label %h25, label %x25
x25:
  %acc25.out = phi i64 [ %acc25.n, %h25 ]
  br label %h26
h26:
  %i26 = phi i64 [ 0, %x25 ], [ %i26.n, %h26 ]
  %acc26 = phi i64 [ %acc25.out, %x25 ], [ %acc26.n, %h26 ]
  %g26 = getelementptr inbounds i64, ptr %p, i64 %i26
  %v26 = load i64, ptr %g26, align 8
  %w26 = mul i64 %v26, 29
  %acc26.n = add i64 %acc26, %w26
  %i26.n = add nuw nsw i64 %i26, 1
  %c26 = icmp ult i64 %i26.n, %len
  br i1 %c26, label %h26, label %x26
x26:
  %acc26.out = phi i64 [ %acc26.n, %h26 ]
  br label %h27
h27:
  %i27 = phi i64 [ 0, %x26 ], [ %i27.n, %h27 ]
  %acc27 = phi i64 [ %acc26.out, %x26 ], [ %acc27.n, %h27 ]
  %g27 = getelementptr inbounds i64, ptr %p, i64 %i27
  %v27 = load i64, ptr %g27, align 8
  %w27 = mul i64 %v27, 30
  %acc27.n = add i64 %acc27, %w27
  %i27.n = add nuw nsw i64 %i27, 1
  %c27 = icmp ult i64 %i27.n, %len
  br i1 %c27, label %h27, label %x27
x27:
  %acc27.out = phi i64 [ %acc27.n, %h27 ]
  br label %h28
h28:
  %i28 = phi i64 [ 0, %x27 ], [ %i28.n, %h28 ]
  %acc28 = phi i64 [ %acc27.out, %x27 ], [ %acc28.n, %h28 ]
  %g28 = getelementptr inbounds i64, ptr %p, i64 %i28
  %v28 = load i64, ptr %g28, align 8
  %w28 = mul i64 %v28, 31
  %acc28.n = add i64 %acc28, %w28
  %i28.n = add nuw nsw i64 %i28, 1
  %c28 = icmp ult i64 %i28.n, %len
  br i1 %c28, label %h28, label %x28
x28:
  %acc28.out = phi i64 [ %acc28.n, %h28 ]
  br label %h29
h29:
  %i29 = phi i64 [ 0, %x28 ], [ %i29.n, %h29 ]
  %acc29 = phi i64 [ %acc28.out, %x28 ], [ %acc29.n, %h29 ]
  %g29 = getelementptr inbounds i64, ptr %p, i64 %i29
  %v29 = load i64, ptr %g29, align 8
  %w29 = mul i64 %v29, 32
  %acc29.n = add i64 %acc29, %w29
  %i29.n = add nuw nsw i64 %i29, 1
  %c29 = icmp ult i64 %i29.n, %len
  br i1 %c29, label %h29, label %x29
x29:
  %acc29.out = phi i64 [ %acc29.n, %h29 ]
  br label %h30
h30:
  %i30 = phi i64 [ 0, %x29 ], [ %i30.n, %h30 ]
  %acc30 = phi i64 [ %acc29.out, %x29 ], [ %acc30.n, %h30 ]
  %g30 = getelementptr inbounds i64, ptr %p, i64 %i30
  %v30 = load i64, ptr %g30, align 8
  %w30 = mul i64 %v30, 33
  %acc30.n = add i64 %acc30, %w30
  %i30.n = add nuw nsw i64 %i30, 1
  %c30 = icmp ult i64 %i30.n, %len
  br i1 %c30, label %h30, label %x30
x30:
  %acc30.out = phi i64 [ %acc30.n, %h30 ]
  br label %h31
h31:
  %i31 = phi i64 [ 0, %x30 ], [ %i31.n, %h31 ]
  %acc31 = phi i64 [ %acc30.out, %x30 ], [ %acc31.n, %h31 ]
  %g31 = getelementptr inbounds i64, ptr %p, i64 %i31
  %v31 = load i64, ptr %g31, align 8
  %w31 = mul i64 %v31, 34
  %acc31.n = add i64 %acc31, %w31
  %i31.n = add nuw nsw i64 %i31, 1
  %c31 = icmp ult i64 %i31.n, %len
  br i1 %c31, label %h31, label %x31
x31:
  %acc31.out = phi i64 [ %acc31.n, %h31 ]
  br label %h32
h32:
  %i32 = phi i64 [ 0, %x31 ], [ %i32.n, %h32 ]
  %acc32 = phi i64 [ %acc31.out, %x31 ], [ %acc32.n, %h32 ]
  %g32 = getelementptr inbounds i64, ptr %p, i64 %i32
  %v32 = load i64, ptr %g32, align 8
  %w32 = mul i64 %v32, 35
  %acc32.n = add i64 %acc32, %w32
  %i32.n = add nuw nsw i64 %i32, 1
  %c32 = icmp ult i64 %i32.n, %len
  br i1 %c32, label %h32, label %x32
x32:
  %acc32.out = phi i64 [ %acc32.n, %h32 ]
  br label %h33
h33:
  %i33 = phi i64 [ 0, %x32 ], [ %i33.n, %h33 ]
  %acc33 = phi i64 [ %acc32.out, %x32 ], [ %acc33.n, %h33 ]
  %g33 = getelementptr inbounds i64, ptr %p, i64 %i33
  %v33 = load i64, ptr %g33, align 8
  %w33 = mul i64 %v33, 36
  %acc33.n = add i64 %acc33, %w33
  %i33.n = add nuw nsw i64 %i33, 1
  %c33 = icmp ult i64 %i33.n, %len
  br i1 %c33, label %h33, label %x33
x33:
  %acc33.out = phi i64 [ %acc33.n, %h33 ]
  br label %h34
h34:
  %i34 = phi i64 [ 0, %x33 ], [ %i34.n, %h34 ]
  %acc34 = phi i64 [ %acc33.out, %x33 ], [ %acc34.n, %h34 ]
  %g34 = getelementptr inbounds i64, ptr %p, i64 %i34
  %v34 = load i64, ptr %g34, align 8
  %w34 = mul i64 %v34, 37
  %acc34.n = add i64 %acc34, %w34
  %i34.n = add nuw nsw i64 %i34, 1
  %c34 = icmp ult i64 %i34.n, %len
  br i1 %c34, label %h34, label %x34
x34:
  %acc34.out = phi i64 [ %acc34.n, %h34 ]
  br label %h35
h35:
  %i35 = phi i64 [ 0, %x34 ], [ %i35.n, %h35 ]
  %acc35 = phi i64 [ %acc34.out, %x34 ], [ %acc35.n, %h35 ]
  %g35 = getelementptr inbounds i64, ptr %p, i64 %i35
  %v35 = load i64, ptr %g35, align 8
  %w35 = mul i64 %v35, 38
  %acc35.n = add i64 %acc35, %w35
  %i35.n = add nuw nsw i64 %i35, 1
  %c35 = icmp ult i64 %i35.n, %len
  br i1 %c35, label %h35, label %x35
x35:
  %acc35.out = phi i64 [ %acc35.n, %h35 ]
  br label %h36
h36:
  %i36 = phi i64 [ 0, %x35 ], [ %i36.n, %h36 ]
  %acc36 = phi i64 [ %acc35.out, %x35 ], [ %acc36.n, %h36 ]
  %g36 = getelementptr inbounds i64, ptr %p, i64 %i36
  %v36 = load i64, ptr %g36, align 8
  %w36 = mul i64 %v36, 39
  %acc36.n = add i64 %acc36, %w36
  %i36.n = add nuw nsw i64 %i36, 1
  %c36 = icmp ult i64 %i36.n, %len
  br i1 %c36, label %h36, label %x36
x36:
  %acc36.out = phi i64 [ %acc36.n, %h36 ]
  br label %h37
h37:
  %i37 = phi i64 [ 0, %x36 ], [ %i37.n, %h37 ]
  %acc37 = phi i64 [ %acc36.out, %x36 ], [ %acc37.n, %h37 ]
  %g37 = getelementptr inbounds i64, ptr %p, i64 %i37
  %v37 = load i64, ptr %g37, align 8
  %w37 = mul i64 %v37, 40
  %acc37.n = add i64 %acc37, %w37
  %i37.n = add nuw nsw i64 %i37, 1
  %c37 = icmp ult i64 %i37.n, %len
  br i1 %c37, label %h37, label %x37
x37:
  %acc37.out = phi i64 [ %acc37.n, %h37 ]
  br label %h38
h38:
  %i38 = phi i64 [ 0, %x37 ], [ %i38.n, %h38 ]
  %acc38 = phi i64 [ %acc37.out, %x37 ], [ %acc38.n, %h38 ]
  %g38 = getelementptr inbounds i64, ptr %p, i64 %i38
  %v38 = load i64, ptr %g38, align 8
  %w38 = mul i64 %v38, 41
  %acc38.n = add i64 %acc38, %w38
  %i38.n = add nuw nsw i64 %i38, 1
  %c38 = icmp ult i64 %i38.n, %len
  br i1 %c38, label %h38, label %x38
x38:
  %acc38.out = phi i64 [ %acc38.n, %h38 ]
  br label %h39
h39:
  %i39 = phi i64 [ 0, %x38 ], [ %i39.n, %h39 ]
  %acc39 = phi i64 [ %acc38.out, %x38 ], [ %acc39.n, %h39 ]
  %g39 = getelementptr inbounds i64, ptr %p, i64 %i39
  %v39 = load i64, ptr %g39, align 8
  %w39 = mul i64 %v39, 42
  %acc39.n = add i64 %acc39, %w39
  %i39.n = add nuw nsw i64 %i39, 1
  %c39 = icmp ult i64 %i39.n, %len
  br i1 %c39, label %h39, label %x39
x39:
  %acc39.out = phi i64 [ %acc39.n, %h39 ]
  ret i64 %acc39.out
}
