; Intrinsics that loop-vectorize creates (FindLast reductions: llvm.experimental.vector.extract.last.active),
; declared here so that impl/jai/gen/gen_intrinsics.py sees their attributes.
define i32 @extract_last_active(<4 x i32> %d, <4 x i1> %m, i32 %def) {
  %r = call i32 @llvm.experimental.vector.extract.last.active.v4i32(<4 x i32> %d, <4 x i1> %m, i32 %def)
  ret i32 %r
}

declare i32 @llvm.experimental.vector.extract.last.active.v4i32(<4 x i32>, <4 x i1>, i32)
