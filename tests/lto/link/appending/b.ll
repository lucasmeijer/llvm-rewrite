target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@llvm.global_ctors = appending global [2 x { i32, ptr, ptr }] [{ i32, ptr, ptr } { i32 100, ptr @ctor_b, ptr @data_b }, { i32, ptr, ptr } { i32 65535, ptr @ctor_b2, ptr null }]
@llvm.global_dtors = appending global [1 x { i32, ptr, ptr }] [{ i32, ptr, ptr } { i32 65535, ptr @dtor_b, ptr null }]
@llvm.used = appending global [2 x ptr] [ptr @keep_b, ptr @data_b], section "llvm.metadata"
@arr = appending global [1 x i32] [i32 3]
@data_b = global i32 0

define internal void @ctor_b() {
  ret void
}

define internal void @ctor_b2() {
  ret void
}

define internal void @dtor_b() {
  ret void
}

define void @keep_b() {
  ret void
}
