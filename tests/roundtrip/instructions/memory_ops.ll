define i32 @mem(ptr %p, i64 %idx) {
  %slot = alloca [10 x i32], align 16
  %gep = getelementptr inbounds [10 x i32], ptr %slot, i64 0, i64 %idx
  store i32 5, ptr %gep, align 4
  %v = load i32, ptr %gep, align 4
  %vol = load volatile i32, ptr %p, align 4
  store atomic i32 %v, ptr %p seq_cst, align 4
  %old = atomicrmw add ptr %p, i32 1 monotonic, align 4
  %pair = cmpxchg ptr %p, i32 %old, i32 0 acq_rel acquire, align 4
  %ok = extractvalue { i32, i1 } %pair, 1
  fence release
  %r = select i1 %ok, i32 %vol, i32 %v
  ret i32 %r
}
