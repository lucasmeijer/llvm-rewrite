; MemCpyOpt merges a store and two memsets into one memset whose length End-Start exceeds INT64_MAX: LLVM computes
; it in int64_t and emits the wrapped (negative) i64 length (found by a default<O2> sweep on
; Analysis/DependenceAnalysis/banerjee-overflow.ll).
; @opt: -passes=memcpyopt
define void @f(ptr %p) {
  store i8 0, ptr %p, align 8
  %q = getelementptr i8, ptr %p, i64 -8
  call void @llvm.memset.p0.i64(ptr align 8 %q, i8 0, i64 8, i1 false)
  %r = getelementptr i8, ptr %p, i64 1
  call void @llvm.memset.p0.i64(ptr %r, i8 0, i64 9223372036854775806, i1 false)
  ret void
}
