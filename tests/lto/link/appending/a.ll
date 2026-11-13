target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@llvm.global_ctors = appending global [1 x { i32, ptr, ptr }] [{ i32, ptr, ptr } { i32 65535, ptr @ctor_a, ptr null }]
@llvm.used = appending global [1 x ptr] [ptr @keep_a], section "llvm.metadata"
@llvm.compiler.used = appending global [1 x ptr] [ptr @ckeep_a], section "llvm.metadata"
@arr = appending global [2 x i32] [i32 1, i32 2]

define internal void @ctor_a() {
  ret void
}

define internal void @keep_a() {
  ret void
}

define internal void @ckeep_a() {
  ret void
}
