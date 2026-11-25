; SLP store chain whose pointer distance overflows int64: LLVM compares static_cast<uint64_t>(Dist) with
; VL.size() - 1 (found by a default<O2> sweep on Analysis/DependenceAnalysis/find-gcd-overflow.ll).
; @opt: -passes=slp-vectorizer
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"
define void @f(ptr %p) {
  %a = getelementptr i8, ptr %p, i64 6
  %b = getelementptr i8, ptr %p, i64 -9223372036854775802
  store i8 0, ptr %a, align 1
  store i8 1, ptr %b, align 1
  ret void
}
